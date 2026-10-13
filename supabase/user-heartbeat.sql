-- 用户在线心跳与使用时长（2026-10-13）
--
-- 目标：管理后台能看到「现在谁在线」和「每个人今天/累计用了多久」。
--
-- 设计取舍（为什么不是每次心跳就 UPDATE 时长）：
--   · 客户端每 60s 发一次心跳。若每分钟直接累加，任何一次网络抖动/被杀都会
--     造成时长虚高或虚低，且并发写同一行容易丢更新。
--   · 改为**只写明细**（th_user_heartbeat，每次心跳一行，TTL 7 天自动清），
--     时长在**查询时**按 last_seen 的时间差累加 —— 口径可复核、可重算，
--     也不怕客户端写坏。
--
-- 在线判定：now() - last_seen < 90 秒（心跳 60s，留一格余量）。

-- ① 心跳明细表（append-only，按天分区靠索引，7 天后自动清）
create table if not exists public.th_user_heartbeat (
  id         bigserial primary key,
  user_id    uuid not null references public.th_profiles(id) on delete cascade,
  platform   text,                              -- android / web / ios
  app_version text,
  at         timestamptz not null default now()
);

create index if not exists th_user_heartbeat_user_at_idx
  on public.th_user_heartbeat (user_id, at desc);
create index if not exists th_user_heartbeat_at_idx
  on public.th_user_heartbeat (at desc);

comment on table public.th_user_heartbeat is
  '客户端心跳明细（每次心跳一行）。在线判定与时长统计都从这里算，避免并发累加丢更新。';

-- ② profile 上的在线快照（列表页秒开，不必扫明细表）
alter table public.th_profiles
  add column if not exists last_platform text,
  add column if not exists last_app_version text;

-- ③ 客户端上报心跳（幂等：同一次调用只写一行）
create or replace function public.admin_user_heartbeat(
  p_user_id    uuid,
  p_platform   text default null,
  p_app_version text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.th_user_heartbeat (user_id, platform, app_version)
  values (p_user_id, p_platform, p_app_version);

  update public.th_profiles
     set last_seen    = now(),
         last_platform = coalesce(p_platform, last_platform),
         last_app_version = coalesce(p_app_version, last_app_version)
   where id = p_user_id;
end;
$$;

-- ④ 在线判定 + 时长汇总（管理后台一次调用拿全）
--    在线：last_seen 在 90 秒内
--    today_minutes：今天的心跳跨度累加（相邻两次心跳的间隔，封顶 5 分钟防挂死）
create or replace function public.admin_online_stats()
returns table (
  user_id      uuid,
  email       text,
  nickname    text,
  level       text,
  last_seen   timestamptz,
  platform    text,
  app_version text,
  online      boolean,
  today_minutes integer,
  total_minutes  integer,
  days_active    integer
)
language sql
security definer
set search_path = public
as $$
  with hb as (
    select user_id, at, platform, app_version,
           lag(at) over (partition by user_id order by at) as prev_at
      from public.th_user_heartbeat
     where at > now() - interval '30 days'
  ),
  agg as (
    select user_id,
           sum(least(extract(epoch from (at - prev_at)) / 60.0, 5.0))::int as minutes,
           max(at)                as last_at,
           max(platform)          as platform,
           max(app_version)       as app_version
      from hb
     where prev_at is not null
        and at - prev_at < interval '5 minutes'
     group by user_id
  ),
  today as (
    select user_id,
           sum(least(extract(epoch from (at - prev_at)) / 60.0, 5.0))::int as minutes
      from hb
     where prev_at is not null
       and at >= date_trunc('day', now())
       and at - prev_at < interval '5 minutes'
     group by user_id
  )
  select p.id,
         p.email,
         p.nickname,
         p.level,
         p.last_seen,
         coalesce(a.platform, p.last_platform),
         coalesce(a.app_version, p.last_app_version),
         (p.last_seen is not null and p.last_seen > now() - interval '90 seconds'),
         coalesce(t.minutes, 0),
         coalesce(a.minutes, 0),
         (select count(distinct date_trunc('day', hb2.at))::int
            from public.th_user_heartbeat hb2
           where hb2.user_id = p.id and hb2.at > now() - interval '30 days')
    from public.th_profiles p
    left join agg   a on a.user_id = p.id
    left join today t on t.user_id = p.id
   order by p.last_seen desc nulls last;
$$;

-- ⑤ 清理：心跳明细只留 30 天（在线/时长统计窗口之外的无用）
create or replace function public.admin_prune_heartbeats()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare n int;
begin
  delete from public.th_user_heartbeat where at < now() - interval '30 days';
  get diagnostics n = row_count;
  return n;
end;
$$;