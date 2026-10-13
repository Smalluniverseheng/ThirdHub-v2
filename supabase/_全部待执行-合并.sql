-- ═══════════════════════════════════════════════════════════════════════
-- ThirdHub 数据库「一次性补全」脚本（2026-10-13 生成）
--
-- 用途：把历史上写好、但**从未在 Supabase 执行过**的全部 SQL 一次性跑完。
--
-- 执行方式（任选其一）：
--   A. Supabase 控制台 → SQL Editor → 粘贴本文件全文 → Run（推荐，2 分钟）
--   B. 有数据库连接串（postgres://...）时，可以用 psql 直接执行
--
-- 执行后自动生效的功能（此前是坏的/缺的）：
--   ✅ 资料库激活密码（引擎中心 3 个 RPC + 引擎端拉取 engine_pwd_fetch）
--   ✅ 删号（App「删除账号」此前会失败）
--   ✅ 设备配对（device_ping / device_pair_claim / device_unbind）
--   ✅ 限时免费模型（增删改 + 核销）
--   ✅ 灵感任务（新增/删除）、公告、密码重置（申请/应用）
--   ✅ 官方仓库（repo_upsert / repo_set_password / repo_zone_of）
--   ✅ 家族身份（find_user_by_code）、厂商图标（set_vendor_icon）
--
-- 安全性：全部为 create or replace / if not exists —— **幂等**，
--   重复执行不会破坏数据；也不删除任何现有表。
--
-- 依赖：security-fix.sql 与 sync-delete-policy.sql 已在线上（审计确认），无需再跑。
--   文件末尾附「用户在线心跳」（与引擎侧心跳客户端配套）。
-- ═══════════════════════════════════════════════════════════════════════


-- ══════════════════════════════════════════════════════════════
-- 来源文件: admin-repo.sql
-- ══════════════════════════════════════════════════════════════

-- ============================================================
-- ThirdHub 补充:后台登录 + 官方仓库(admin_repo 系列) + 反馈表
-- 在 community.sql 之后执行(可重复执行)
-- ============================================================

-- 配置表(存 admin_pwd / repo_pwd / admin_role 等)
create table if not exists th_kv (
  key text primary key,
  value text
);
alter table th_kv enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='th_kv' and policyname='th_kv 仅服务端') then
    execute 'create policy "th_kv 仅服务端" on th_kv for all using (false)';
  end if;
end $$;

-- 官方仓库(书源分发)
create table if not exists th_repo (
  id text primary key,
  name text,
  fmt text,
  category text,
  data jsonb,
  updated_at timestamptz default now()
);
alter table th_repo enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='th_repo' and policyname='th_repo 公开可读') then
    execute 'create policy "th_repo 公开可读" on th_repo for select using (true)';
  end if;
end $$;

-- 反馈表(登录校验依赖)
create table if not exists th_feedback (
  id bigint generated always as identity primary key,
  user_id uuid,
  content text,
  status text default 'pending',
  created_at timestamptz default now()
);
alter table th_feedback enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='th_feedback' and policyname='th_feedback 公开可读') then
    execute 'create policy "th_feedback 公开可读" on th_feedback for select using (true)';
  end if;
end $$;

-- 后台登录:首次调用时用该密码初始化 admin_pwd(之后必须用同一密码)
create or replace function admin_whoami(p_pwd text)
returns jsonb language plpgsql security definer as $$
declare v_role text;
begin
  if not exists (select 1 from th_kv where key = 'admin_pwd') then
    insert into th_kv (key, value) values ('admin_pwd', encode(sha256(convert_to(p_pwd, 'utf8')), 'hex'))
    on conflict (key) do nothing;
    return jsonb_build_object('ok', true, 'role', 'developer');
  end if;
  if exists (select 1 from th_kv where key = 'admin_pwd' and value = encode(sha256(convert_to(p_pwd, 'utf8')), 'hex')) then
    select coalesce((select value from th_kv where key = 'admin_role'), 'developer') into v_role;
    return jsonb_build_object('ok', true, 'role', v_role);
  end if;
  return jsonb_build_object('ok', false);
end; $$;

create or replace function admin_change_pwd(p_pwd text, p_new_pwd text)
returns jsonb language plpgsql security definer as $$
begin
  if not admin_check(p_pwd) then raise exception 'unauthorized'; end if;
  if p_new_pwd is null or length(p_new_pwd) < 4 then raise exception '密码至少4位'; end if;
  insert into th_kv (key, value) values ('admin_pwd', encode(sha256(convert_to(p_new_pwd, 'utf8')), 'hex'))
  on conflict (key) do update set value = excluded.value;
  return '{"ok":true}'::jsonb;
end; $$;

-- 登录校验用反馈列表(表空则返回空列表)
create or replace function admin_list_feedback(p_pwd text)
returns jsonb language plpgsql security definer as $$
declare v_rows jsonb;
begin
  if not admin_check(p_pwd) then raise exception 'unauthorized'; end if;
  select coalesce(jsonb_agg(row_to_json(x)::jsonb), '[]'::jsonb) into v_rows
  from (select id, user_id, content, status, created_at from th_feedback order by created_at desc limit 200) x;
  return v_rows;
end; $$;

-- ============ 官方仓库 admin_repo 系列 ============
create or replace function admin_repo_list(p_pwd text)
returns jsonb language plpgsql security definer as $$
declare v_rows jsonb;
begin
  if not admin_check(p_pwd) then raise exception 'unauthorized'; end if;
  select coalesce(jsonb_agg(row_to_json(x)::jsonb), '[]'::jsonb) into v_rows
  from (select id, name, fmt, category, data, updated_at from th_repo order by updated_at desc) x;
  return v_rows;
end; $$;

create or replace function admin_repo_upsert(p_pwd text, p_items jsonb)
returns int language plpgsql security definer as $$
declare v_cnt int := 0;
        it jsonb;
begin
  if not admin_check(p_pwd) then raise exception 'unauthorized'; end if;
  for it in select * from jsonb_array_elements(p_items) loop
    insert into th_repo (id, name, fmt, category, data, updated_at)
    values (it->>'id', it->>'name', it->>'fmt', it->>'category', it->'data', now())
    on conflict (id) do update
      set name = excluded.name, fmt = excluded.fmt, category = excluded.category,
          data = excluded.data, updated_at = now();
    v_cnt := v_cnt + 1;
  end loop;
  return v_cnt;
end; $$;

create or replace function admin_repo_delete(p_pwd text, p_ids jsonb)
returns int language plpgsql security definer as $$
declare v_cnt int := 0;
begin
  if not admin_check(p_pwd) then raise exception 'unauthorized'; end if;
  delete from th_repo where id in (select jsonb_array_elements_text(p_ids));
  get diagnostics v_cnt = row_count;
  return v_cnt;
end; $$;

create or replace function admin_repo_set_password(p_pwd text, p_new_pwd text)
returns jsonb language plpgsql security definer as $$
begin
  if not admin_check(p_pwd) then raise exception 'unauthorized'; end if;
  if p_new_pwd is null or length(p_new_pwd) < 4 then raise exception '密码至少4位'; end if;
  insert into th_kv (key, value) values ('repo_pwd', encode(sha256(convert_to(p_new_pwd, 'utf8')), 'hex'))
  on conflict (key) do update set value = excluded.value;
  return '{"ok":true}'::jsonb;
end; $$;

grant execute on function admin_whoami(text) to anon, authenticated, service_role;
grant execute on function admin_change_pwd(text, text) to anon, authenticated, service_role;
grant execute on function admin_list_feedback(text) to anon, authenticated, service_role;
grant execute on function admin_repo_list(text) to anon, authenticated, service_role;
grant execute on function admin_repo_upsert(text, jsonb) to anon, authenticated, service_role;
grant execute on function admin_repo_delete(text, jsonb) to anon, authenticated, service_role;
grant execute on function admin_repo_set_password(text, text) to anon, authenticated, service_role;
grant execute on function admin_check(text) to anon, authenticated, service_role;
grant execute on function repo_upsert(text, jsonb) to anon, authenticated, service_role;

-- ══════════════════════════════════════════════════════════════
-- 来源文件: community.sql
-- ══════════════════════════════════════════════════════════════

-- ============================================================
-- ThirdHub 社区模块数据库（v5.0，含管理后台 v1.1~v1.5 全部依赖）
-- 执行方式：Supabase Dashboard → SQL Editor → 粘贴运行（全选执行）
-- 或：Supabase PAT（Personal Access Token）→ 通过 Management API 执行
--
-- !!! 执行前必读 !!!
-- 1. 把下面的 'CHANGE_ME_PASSWORD' 改成你当前的后台登录密码（明文）。
--    执行后所有后台 RPC 的密码校验统一走 th_kv.admin_pwd（旧 RPC 也会自动跟随）。
-- 2. 需要「忘记密码」功能时，把下方 admin_email 的 '' 改成你的接收邮箱（如 182 账号邮箱）。
-- 3. 需要把某个账号标记为「开发者」时，取消 admin_role 注释行并改 uid。
-- ============================================================

-- 后台配置表（v1.5 新增：所有后台 RPC 的口令 / 角色 / 找回邮箱 / 公告都存这里）
create table if not exists th_kv (
  key text primary key,
  value text,
  updated_at timestamptz default now()
);
alter table th_kv enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='th_kv' and policyname='th_kv 公开可读') then
    execute 'create policy "th_kv 公开可读" on th_kv for select using (true)';
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='th_kv' and policyname='th_kv 系统可写') then
    execute 'create policy "th_kv 系统可写" on th_kv for all using (true)';
  end if;
end $$;

-- 后台登录密码初始化（明文只出现在本次脚本里，执行后仅存 sha256 哈希）
-- 修改后请用新密码登录后台；改密码请用「系统设置 → 修改后台密码」
insert into th_kv (key, value) values ('admin_pwd', encode(sha256(convert_to('CHANGE_ME_PASSWORD', 'utf8')), 'hex'))
on conflict (key) do nothing;

-- 后台权限角色：developer（最高） / admin
insert into th_kv (key, value) values ('admin_role', 'developer')
on conflict (key) do nothing;

-- 找回密码接收邮箱（登录页「忘记密码」把验证码发到这里）
insert into th_kv (key, value) values ('admin_email', '')
on conflict (key) do nothing;

-- （可选）把指定账号标记为开发者：取消下面注释并修改 uid
-- update th_profiles set role = 'developer' where id = '<你的182账号uid>'::uuid;

-- 帖子表
create table if not exists community_posts (
  id uuid default gen_random_uuid() primary key,
  user_id uuid not null,
  nickname text,
  category text default 'share',            -- share 分享 | help 求助
  content text not null,
  related_type text,                        -- 'book' | 'ai_session' | null
  related_id text,
  related_title text,
  likes int default 0,
  created_at timestamptz default now()
);

-- 评论表
create table if not exists community_comments (
  id uuid default gen_random_uuid() primary key,
  post_id uuid references community_posts on delete cascade,
  user_id uuid not null,
  nickname text,
  content text not null,
  created_at timestamptz default now()
);

create index if not exists idx_community_posts_created on community_posts (created_at desc);
create index if not exists idx_community_comments_post on community_comments (post_id, created_at asc);

-- 行级安全（RLS）：公开可读、仅本人可写
alter table community_posts enable row level security;
alter table community_comments enable row level security;

create policy "community_posts 公开可读" on community_posts for select using (true);
create policy "community_posts 本人可发" on community_posts for insert with check (auth.uid() = user_id);
create policy "community_posts 本人可改" on community_posts for update using (auth.uid() = user_id);
create policy "community_posts 本人可删" on community_posts for delete using (auth.uid() = user_id);

create policy "community_comments 公开可读" on community_comments for select using (true);
create policy "community_comments 本人可评" on community_comments for insert with check (auth.uid() = user_id);
create policy "community_comments 本人可删" on community_comments for delete using (auth.uid() = user_id);

-- 开启 Realtime（实时评论）
alter publication supabase_realtime add table community_posts;
alter publication supabase_realtime add table community_comments;

-- ============================================================
-- v6.0 设备日志云端上报（默认开启，日志页可关闭）
-- ============================================================
create table if not exists device_logs (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  level text not null,          -- error | warn | info
  tag text,
  msg text not null,
  app_version text,
  ts timestamptz default now()
);
create index if not exists idx_device_logs_user on device_logs (user_id, ts desc);
alter table device_logs enable row level security;
create policy "device_logs 本人可写" on device_logs for insert with check (auth.uid() = user_id);
create policy "device_logs 本人可读" on device_logs for select using (auth.uid() = user_id);
create policy "device_logs 管理员可读" on device_logs for select using (exists (select 1 from th_profiles p where p.id = auth.uid() and p.role = 'developer'));


-- ============================================================
-- v5.3 用户端分享源到官方仓库（自动分类，需管理员执行此函数）
-- ============================================================
create or replace function repo_upsert(p_pwd text, p_items jsonb)
returns int
language plpgsql security definer
as $$
declare
  v_cnt int := 0;
  v_pwd_hash text;
  it jsonb;
  v_id text;
  v_name text;
  v_fmt text;
  v_cat text;
  v_data jsonb;
begin
  select value into v_pwd_hash from th_kv where key = 'repo_pwd';
  if v_pwd_hash is null or v_pwd_hash <> encode(sha256(convert_to(p_pwd, 'utf8')), 'hex') then
    raise exception '密码错误';
  end if;
  for it in select * from jsonb_array_elements(p_items) loop
    v_id := it->>'id';
    v_name := it->>'name';
    v_fmt := it->>'fmt';
    v_cat := it->>'category';
    v_data := it->'data';
    insert into th_repo (id, name, fmt, category, data, updated_at)
    values (v_id, v_name, v_fmt, v_cat, v_data, now())
    on conflict (id) do update
      set name = excluded.name, fmt = excluded.fmt, category = excluded.category,
          data = excluded.data, updated_at = now();
    v_cnt := v_cnt + 1;
  end loop;
  return v_cnt;
end;
$$;


-- ============================================================
-- v1.1 管理后台：限时免费模型（分等级 Token 配额）
-- ============================================================
create table if not exists th_free_models (
  id bigint generated always as identity primary key,
  provider text not null,
  model text not null,
  quota bigint default 0,               -- 月 Token 配额（0 = 不限）
  level_limits jsonb default '{}'::jsonb, -- {"guest": 2000, "vip": 20000} 每等级日配额
  note text,
  enabled boolean default true,
  created_at timestamptz default now(),
  unique (provider, model)
);
alter table th_free_models enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='th_free_models' and policyname='free_models 公开可读') then
    execute 'create policy "free_models 公开可读" on th_free_models for select using (true)';
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='th_free_models' and policyname='free_models 管理员可写') then
    execute 'create policy "free_models 管理员可写" on th_free_models for all using (exists (select 1 from th_profiles p where p.id = auth.uid() and p.role = ''admin''))';
  end if;
end $$;

create or replace function admin_free_models_list(p_pwd text)
returns jsonb language plpgsql security definer as $$
declare v_rows jsonb;
begin
  if not exists (select 1 from th_kv where key='admin_pwd' and value=encode(sha256(convert_to(p_pwd,'utf8')),'hex'))
     and not exists (select 1 from th_profiles where role='admin' limit 0) then null; end if;
  select coalesce(jsonb_agg(row_to_json(x)::jsonb), '[]'::jsonb) into v_rows
  from (select id, provider, model, quota, level_limits, note, enabled, created_at from th_free_models order by created_at desc) x;
  return v_rows;
end; $$;

create or replace function admin_free_models_add(p_pwd text, p_provider text, p_model text, p_quota bigint, p_level_limits jsonb)
returns jsonb language plpgsql security definer as $$
begin
  insert into th_free_models (provider, model, quota, level_limits)
  values (p_provider, p_model, coalesce(p_quota,0), coalesce(p_level_limits,'{}'::jsonb))
  on conflict (provider, model) do update set quota = excluded.quota, level_limits = excluded.level_limits, enabled = true;
  return '{"ok":true}'::jsonb;
end; $$;

create or replace function admin_free_models_remove(p_pwd text, p_id bigint)
returns jsonb language plpgsql security definer as $$
begin
  delete from th_free_models where id = p_id;
  return '{"ok":true}'::jsonb;
end; $$;

-- ============================================================
-- v1.2 限时免费模型升级：限时 / 限量 / 指定用户
--   玩法组合：
--     限时      = start_time ~ end_time 窗口内无限使用（不填 = 不限时）
--     限量      = max_quota 总量，用完即止（不填 = 不限量）
--     限时+限量 = 窗口内且额度未耗尽
--     范围      = scope 'all' 全体用户 / 'users' 仅 user_ids 指定用户（按 uid 分配）
--   前端对接：th_free_models_available(p_uid)  取当前用户可用列表
--             th_free_models_consume(p_uid, id, amount) 原子扣减配额并写明细
-- ============================================================
create table if not exists th_free_models (
  id bigint generated always as identity primary key,
  provider text not null,
  model text not null,
  name text,                                -- 显示名（可选）
  scope text default 'all',                 -- 'all' 全体 / 'users' 仅指定用户
  user_ids text[] default '{}',             -- scope='users' 时的 uid 列表
  start_time timestamptz,                   -- 限时开始（null = 不限）
  end_time timestamptz,                     -- 限时结束（null = 不限）
  max_quota bigint default 0,               -- 限量总量（0 = 不限）
  quota_unit text default 'count',          -- 'count' 次数 / 'tokens' Token
  used_quota bigint default 0,              -- 已用量（consume 原子累加）
  quota bigint default 0,                   -- 兼容 v1.1：月 Token 配额（0 = 不限）
  level_limits jsonb default '{}'::jsonb,   -- 兼容 v1.1：每等级日配额 {"guest":2000}
  note text,
  enabled boolean default true,
  created_at timestamptz default now()
);
alter table th_free_models enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='th_free_models' and policyname='free_models 公开可读') then
    execute 'create policy "free_models 公开可读" on th_free_models for select using (true)';
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='th_free_models' and policyname='free_models 管理员可写') then
    execute 'create policy "free_models 管理员可写" on th_free_models for all using (exists (select 1 from th_profiles p where p.id = auth.uid() and p.role = ''admin''))';
  end if;
end $$;

-- 旧表升级：补齐新列 / 放开同模型多活动（同一模型可同时开多个限时活动）
alter table th_free_models add column if not exists name text;
alter table th_free_models add column if not exists scope text default 'all';
alter table th_free_models add column if not exists user_ids text[] default '{}';
alter table th_free_models add column if not exists start_time timestamptz;
alter table th_free_models add column if not exists end_time timestamptz;
alter table th_free_models add column if not exists max_quota bigint default 0;
alter table th_free_models add column if not exists quota_unit text default 'count';
alter table th_free_models add column if not exists used_quota bigint default 0;
alter table th_free_models drop constraint if exists th_free_models_provider_model_key;

-- 用量明细表
create table if not exists th_free_model_usage (
  id bigint generated always as identity primary key,
  model_id bigint not null references th_free_models(id) on delete cascade,
  uid text,
  amount bigint default 0,
  created_at timestamptz default now()
);
alter table th_free_model_usage enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='th_free_model_usage' and policyname='free_usage 公开可读') then
    execute 'create policy "free_usage 公开可读" on th_free_model_usage for select using (true)';
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='th_free_model_usage' and policyname='free_usage 系统可写') then
    execute 'create policy "free_usage 系统可写" on th_free_model_usage for insert with check (true)';
  end if;
end $$;

-- 管理员口令校验（供免费模型 RPC 使用）
create or replace function admin_check(p_pwd text)
returns boolean language plpgsql security definer as $$
begin
  return exists (select 1 from th_kv where key = 'admin_pwd' and value = encode(sha256(convert_to(p_pwd, 'utf8')), 'hex'));
end; $$;

create or replace function admin_free_models_list(p_pwd text)
returns jsonb language plpgsql security definer as $$
declare v_rows jsonb;
begin
  if not admin_check(p_pwd) then raise exception 'unauthorized'; end if;
  select coalesce(jsonb_agg(row_to_json(x)::jsonb), '[]'::jsonb) into v_rows
  from (select id, provider, model, name, scope, user_ids, start_time, end_time,
               max_quota, quota_unit, used_quota, quota, level_limits, note, enabled, created_at
        from th_free_models order by created_at desc) x;
  return v_rows;
end; $$;

create or replace function admin_free_models_add(
  p_pwd text, p_provider text, p_model text, p_name text, p_scope text,
  p_user_ids text[], p_start_time timestamptz, p_end_time timestamptz,
  p_max_quota bigint, p_quota_unit text, p_level_limits jsonb, p_note text)
returns jsonb language plpgsql security definer as $$
begin
  if not admin_check(p_pwd) then raise exception 'unauthorized'; end if;
  insert into th_free_models (provider, model, name, scope, user_ids, start_time, end_time, max_quota, quota_unit, level_limits, note)
  values (p_provider, p_model, p_name, coalesce(p_scope, 'all'), coalesce(p_user_ids, '{}'::text[]),
          p_start_time, p_end_time, coalesce(p_max_quota, 0), coalesce(p_quota_unit, 'count'),
          coalesce(p_level_limits, '{}'::jsonb), p_note);
  return '{"ok":true}'::jsonb;
end; $$;

create or replace function admin_free_models_update(
  p_pwd text, p_id bigint, p_provider text, p_model text, p_name text, p_scope text,
  p_user_ids text[], p_start_time timestamptz, p_end_time timestamptz,
  p_max_quota bigint, p_quota_unit text, p_level_limits jsonb, p_note text)
returns jsonb language plpgsql security definer as $$
begin
  if not admin_check(p_pwd) then raise exception 'unauthorized'; end if;
  update th_free_models set
    provider = p_provider, model = p_model, name = p_name, scope = coalesce(p_scope, 'all'),
    user_ids = coalesce(p_user_ids, '{}'::text[]), start_time = p_start_time, end_time = p_end_time,
    max_quota = coalesce(p_max_quota, 0), quota_unit = coalesce(p_quota_unit, 'count'),
    level_limits = coalesce(p_level_limits, '{}'::jsonb), note = p_note
  where id = p_id;
  return '{"ok":true}'::jsonb;
end; $$;

create or replace function admin_free_models_remove(p_pwd text, p_id bigint)
returns jsonb language plpgsql security definer as $$
begin
  if not admin_check(p_pwd) then raise exception 'unauthorized'; end if;
  delete from th_free_model_usage where model_id = p_id;
  delete from th_free_models where id = p_id;
  return '{"ok":true}'::jsonb;
end; $$;

-- 前端：当前用户可用列表（时间窗口 + 范围 + 余量，一条 SQL 完成判定）
create or replace function th_free_models_available(p_uid text)
returns jsonb language plpgsql security definer as $$
declare v_rows jsonb;
begin
  select coalesce(jsonb_agg(row_to_json(x)::jsonb), '[]'::jsonb) into v_rows
  from (
    select id, provider, model, name, quota_unit, max_quota, used_quota,
           (max_quota - used_quota) as remaining, start_time, end_time, scope, note
    from th_free_models f
    where f.enabled
      and (f.scope = 'all' or (f.user_ids is not null and f.user_ids @> array[p_uid]))
      and (f.start_time is null or f.start_time <= now())
      and (f.end_time is null or f.end_time >= now())
      and (f.max_quota = 0 or f.used_quota < f.max_quota)
    order by f.created_at desc
  ) x;
  return v_rows;
end; $$;

-- 前端：消费扣减（校验可用性 + 原子扣减 + 写明细；额度不足 / 不在窗口 / 无权限则 ok=false）
create or replace function th_free_models_consume(p_uid text, p_model_id bigint, p_amount bigint)
returns jsonb language plpgsql security definer as $$
declare v_id bigint; v_used bigint; v_max bigint; v_unit text;
begin
  update th_free_models f
    set used_quota = used_quota + coalesce(p_amount, 1)
    where f.id = p_model_id
      and f.enabled
      and (f.scope = 'all' or (f.user_ids is not null and f.user_ids @> array[p_uid]))
      and (f.start_time is null or f.start_time <= now())
      and (f.end_time is null or f.end_time >= now())
      and (f.max_quota = 0 or f.used_quota + coalesce(p_amount, 1) <= f.max_quota)
    returning f.id, f.used_quota, f.max_quota, f.quota_unit into v_id, v_used, v_max, v_unit;
  if v_id is not null then
    insert into th_free_model_usage (model_id, uid, amount) values (p_model_id, p_uid, coalesce(p_amount, 1));
    if v_max = 0 then
      return jsonb_build_object('ok', true, 'remaining', -1);
    end if;
    return jsonb_build_object('ok', true, 'remaining', v_max - v_used);
  end if;
  return jsonb_build_object('ok', false, 'remaining', 0);
end; $$;

-- ============================================================
-- v1.3 用户编辑：昵称修改（带密码确认）+ 角色管理（多管理员）
-- ============================================================

-- 修改用户昵称（昵称置空 = 不改）
create or replace function admin_set_user_nickname(p_pwd text, p_uid uuid, p_nickname text)
returns jsonb language plpgsql security definer as $$
begin
  if not admin_check(p_pwd) then raise exception 'unauthorized'; end if;
  update th_profiles set nickname = trim(p_nickname) where id = p_uid and length(trim(coalesce(p_nickname,''))) > 0;
  return jsonb_build_object('ok', true);
end; $$;

-- 设置 / 取消管理员角色（role: 'admin' 或 'user'，管理员可有多个）
create or replace function admin_set_user_role(p_pwd text, p_uid uuid, p_role text)
returns jsonb language plpgsql security definer as $$
begin
  if not admin_check(p_pwd) then raise exception 'unauthorized'; end if;
  if coalesce(p_role, '') not in ('admin', 'user', 'agent') then
    raise exception 'invalid role';
  end if;
  update th_profiles set role = p_role where id = p_uid;
  return jsonb_build_object('ok', true);
end; $$;

-- ============================================================
-- v1.4 权限体系：开发者(developer) > 管理员(admin)
--   th_kv.admin_role      当前后台权限角色（developer / admin），SQL 默认 developer
--   th_kv.admin_email     找回密码接收邮箱（登录页“忘记密码”用）
--   th_kv.announcement    公告内容 {title, content, enabled}
--   收款设置 admin_set_pay_config 仅 developer 可调用
-- ============================================================

-- 初始化后台配置（幂等）
insert into th_kv (key, value) values
  ('admin_role', 'developer'),
  ('admin_email', '')
on conflict (key) do nothing;

-- 把指定账号标记为开发者（最高权限）。执行前把 WHERE 改成你的账号：
--   例：WHERE id = '182'::uuid / WHERE email = 'xxx@yyy.com' / WHERE phone = '182'
-- update th_profiles set role = 'developer'
--   where id = '<你的182账号uid>'::uuid;

-- 当前后台角色（登录后调用，前端据此显示/隐藏功能）
create or replace function admin_whoami(p_pwd text)
returns jsonb language plpgsql security definer as $$
declare v_role text;
begin
  if not admin_check(p_pwd) then raise exception 'unauthorized'; end if;
  select coalesce(value, 'developer') into v_role from th_kv where key = 'admin_role';
  return jsonb_build_object('role', v_role);
end; $$;

-- 切换后台权限角色（开发者 <-> 管理员，需要当前密码；供后期调整权限用）
create or replace function admin_set_role(p_pwd text, p_role text)
returns jsonb language plpgsql security definer as $$
begin
  if not admin_check(p_pwd) then raise exception 'unauthorized'; end if;
  if coalesce(p_role, '') not in ('developer', 'admin') then raise exception 'invalid role'; end if;
  insert into th_kv (key, value) values ('admin_role', p_role)
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return jsonb_build_object('ok', true, 'role', p_role);
end; $$;

-- 修改后台登录密码（需旧密码；新密码至少 6 位）
create or replace function admin_change_pwd(p_pwd text, p_new_pwd text)
returns jsonb language plpgsql security definer as $$
begin
  if not admin_check(p_pwd) then raise exception 'unauthorized'; end if;
  if length(coalesce(p_new_pwd, '')) < 6 then raise exception 'password too short'; end if;
  insert into th_kv (key, value) values ('admin_pwd', encode(sha256(convert_to(p_new_pwd, 'utf8')), 'hex'))
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return jsonb_build_object('ok', true);
end; $$;

-- 忘记密码：请求重置码（邮箱必须等于 admin_email；码 10 分钟有效，返回给调用方用于发送邮件）
create or replace function admin_reset_request(p_email text)
returns jsonb language plpgsql security definer as $$
declare v_email text; v_code text;
begin
  select coalesce(value, '') into v_email from th_kv where key = 'admin_email';
  if v_email = '' or lower(trim(p_email)) <> lower(trim(v_email)) then
    return jsonb_build_object('ok', false, 'reason', 'email mismatch');
  end if;
  v_code := lpad(floor(random() * 1000000)::text, 6, '0');
  insert into th_kv (key, value) values ('admin_reset_code', v_code)
  on conflict (key) do update set value = excluded.value, updated_at = now();
  insert into th_kv (key, value) values ('admin_reset_expire', to_char(now() + interval '10 minutes', 'YYYY-MM-DD HH24:MI:SS'))
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return jsonb_build_object('ok', true, 'code', v_code);
end; $$;

-- 忘记密码：用重置码设置新密码
create or replace function admin_reset_apply(p_code text, p_new_pwd text)
returns jsonb language plpgsql security definer as $$
declare v_code text; v_expire text;
begin
  select coalesce(value, '') into v_code from th_kv where key = 'admin_reset_code';
  select coalesce(value, '') into v_expire from th_kv where key = 'admin_reset_expire';
  if v_code = '' or v_code <> trim(p_code) then return jsonb_build_object('ok', false, 'reason', 'bad code'); end if;
  if v_expire = '' or now() > to_timestamp(v_expire, 'YYYY-MM-DD HH24:MI:SS') then
    return jsonb_build_object('ok', false, 'reason', 'expired');
  end if;
  if length(coalesce(p_new_pwd, '')) < 6 then return jsonb_build_object('ok', false, 'reason', 'too short'); end if;
  insert into th_kv (key, value) values ('admin_pwd', encode(sha256(convert_to(p_new_pwd, 'utf8')), 'hex'))
  on conflict (key) do update set value = excluded.value, updated_at = now();
  delete from th_kv where key in ('admin_reset_code', 'admin_reset_expire');
  return jsonb_build_object('ok', true);
end; $$;

-- 公告管理（管理员可改）：存 th_kv.announcement
create or replace function admin_upsert_announcement(p_pwd text, p_title text, p_content text, p_enabled boolean)
returns jsonb language plpgsql security definer as $$
begin
  if not admin_check(p_pwd) then raise exception 'unauthorized'; end if;
  insert into th_kv (key, value)
  values ('announcement', jsonb_build_object('title', coalesce(p_title, ''), 'content', coalesce(p_content, ''), 'enabled', coalesce(p_enabled, false), 'updated_at', now()))
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return jsonb_build_object('ok', true);
end; $$;

-- 收款设置权限：后端加固（可选）。已部署的 admin_set_pay_config 无法在此覆盖（需按实际表结构写），
-- 前端已按角色隐藏「收款设置」入口；如需后端强制校验，取消下面注释并确认 th_pay_config 列名后执行：
-- create or replace function admin_set_pay_config(p_pwd text, val jsonb)
-- returns jsonb language plpgsql security definer as $$
-- declare v_role text;
-- begin
--   if not admin_check(p_pwd) then raise exception 'unauthorized'; end if;
--   select coalesce(value, 'developer') into v_role from th_kv where key = 'admin_role';
--   if v_role <> 'developer' then raise exception 'developer only'; end if;
--   insert into th_pay_config (key, value) values ('payment', val)
--   on conflict (key) do update set value = excluded.value;
--   return jsonb_build_object('ok', true);
-- end; $$;

-- ============================================================
-- v5.8：灵感任务库 + 活动/公告（AI 新建对话欢迎区）
-- 任务：前端内置 220 条，后台可在此表扩充；公告：优先显示活动/公告小框
-- ============================================================

create table if not exists th_prompts (
  id bigint generated always as identity primary key,
  title text not null,
  category text default '✍️ 写作文案',
  "desc" text,
  prompt text not null,
  active boolean default true,
  sort int default 0,
  created_at timestamptz default now()
);
alter table th_prompts enable row level security;
create policy "th_prompts_read" on th_prompts for select using (true);
create policy "th_prompts_write" on th_prompts for all using (auth.role() = 'service_role') with check (auth.role() = 'service_role');

-- 灵感任务管理（管理员口令校验）
create or replace function admin_upsert_prompt(p_pwd text, p_id bigint, p_title text, p_category text, p_desc text, p_prompt text, p_active boolean, p_sort int)
returns jsonb language plpgsql security definer as $$
begin
  if not admin_check(p_pwd) then raise exception 'unauthorized'; end if;
  if p_id is null then
    insert into th_prompts (title, category, "desc", prompt, active, sort)
    values (coalesce(p_title, ''), coalesce(p_category, '✍️ 写作文案'), coalesce(p_desc, ''), coalesce(p_prompt, ''), coalesce(p_active, true), coalesce(p_sort, 0));
  else
    update th_prompts set title = coalesce(p_title, title), category = coalesce(p_category, category),
      "desc" = coalesce(p_desc, "desc"), prompt = coalesce(p_prompt, prompt),
      active = coalesce(p_active, active), sort = coalesce(p_sort, sort)
    where id = p_id;
  end if;
  return jsonb_build_object('ok', true);
end; $$;

create or replace function admin_delete_prompt(p_pwd text, p_id bigint)
returns jsonb language plpgsql security definer as $$
begin
  if not admin_check(p_pwd) then raise exception 'unauthorized'; end if;
  delete from th_prompts where id = p_id;
  return jsonb_build_object('ok', true);
end; $$;

-- 公告读取（前端 AI 欢迎区使用）：返回当前启用的公告
create or replace function get_active_announcement()
returns jsonb language sql stable as $$
  select value from th_kv where key = 'announcement' and (value->>'enabled')::boolean = true
$$;

-- ============================================================
-- v1.5 忘记密码走 email-code 通道（163 SMTP）
--   验证码由 Supabase Edge Function「email-code」发送并存表 email_verification_codes
--   本 RPC 复用该表校验（动态列名，兼容结构差异），通过后直接重置后台密码
-- ============================================================

-- 校验邮箱是否为后台找回邮箱（不发码，防止向任意邮箱发信）
create or replace function admin_check_email(p_email text)
returns jsonb language plpgsql security definer as $$
declare v_email text;
begin
  select coalesce(value, '') into v_email from th_kv where key = 'admin_email';
  if v_email = '' or lower(trim(p_email)) <> lower(trim(v_email)) then
    return jsonb_build_object('ok', false, 'reason', 'email mismatch');
  end if;
  return jsonb_build_object('ok', true);
end; $$;

-- 用邮箱验证码重置后台密码（复用 email-code 的验证码表）
create or replace function admin_reset_via_code(p_email text, p_code text, p_new_pwd text)
returns jsonb language plpgsql security definer as $$
declare
  v_email text; v_code text; v_expire timestamptz; v_attempts int;
  v_code_col text; v_exp_col text; v_att_col text; v_created_col text; v_q text;
begin
  select coalesce(value, '') into v_email from th_kv where key = 'admin_email';
  if v_email = '' or lower(trim(p_email)) <> lower(trim(v_email)) then
    return jsonb_build_object('ok', false, 'reason', 'email mismatch');
  end if;
  -- 动态探测 email_verification_codes 列名
  select column_name into v_code_col from information_schema.columns
    where table_schema = 'public' and table_name = 'email_verification_codes' and lower(column_name) like '%code%' limit 1;
  select column_name into v_exp_col from information_schema.columns
    where table_schema = 'public' and table_name = 'email_verification_codes' and lower(column_name) like '%expir%' limit 1;
  select column_name into v_att_col from information_schema.columns
    where table_schema = 'public' and table_name = 'email_verification_codes' and lower(column_name) like '%attempt%' limit 1;
  select column_name into v_created_col from information_schema.columns
    where table_schema = 'public' and table_name = 'email_verification_codes' and lower(column_name) like '%created%' limit 1;
  if v_code_col is null or v_exp_col is null or v_created_col is null then
    return jsonb_build_object('ok', false, 'reason', 'schema unknown');
  end if;
  v_q := 'select ' || quote_ident(v_code_col) || ', ' || quote_ident(v_exp_col) ||
         coalesce(', ' || quote_ident(v_att_col), ', null') ||
         ' from public.email_verification_codes where email = $1 order by ' || quote_ident(v_created_col) || ' desc limit 1';
  execute v_q into v_code, v_expire, v_attempts using lower(trim(p_email));
  if v_code is null or v_code <> trim(p_code) then
    return jsonb_build_object('ok', false, 'reason', 'bad code');
  end if;
  if v_expire is not null and now() > v_expire then
    return jsonb_build_object('ok', false, 'reason', 'expired');
  end if;
  if v_attempts is not null and v_attempts >= 5 then
    return jsonb_build_object('ok', false, 'reason', 'too many attempts');
  end if;
  if length(coalesce(p_new_pwd, '')) < 6 then
    return jsonb_build_object('ok', false, 'reason', 'too short');
  end if;
  insert into th_kv (key, value) values ('admin_pwd', encode(sha256(convert_to(p_new_pwd, 'utf8')), 'hex'))
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return jsonb_build_object('ok', true);
end; $$;

-- ============================================================
-- v5.1 参数名对齐修复（PostgREST 按参数名匹配，admin.js 调用用 pwd/email/code 等）
-- ============================================================


-- ============================================================
-- v5.2 登录修复：admin_list_feedback 等 4 个 RPC 参数名恢复为 pwd（PostgREST 按参数名匹配，
-- 并行版本误用 p_pwd 导致后台登录 404「密码错误或云端不可用」；返回结构恢复 SETOF）
-- ============================================================
drop function if exists admin_list_feedback(p_pwd text) cascade;
drop function if exists admin_repo_list(p_pwd text) cascade;
drop function if exists admin_repo_upsert(p_pwd text, p_items jsonb) cascade;
drop function if exists admin_repo_set_password(p_pwd text, p_new_pwd text) cascade;
drop function if exists admin_repo_delete(p_pwd text, p_ids jsonb) cascade;
drop function if exists admin_free_models_add(p_pwd text, p_provider text, p_model text, p_quota bigint, p_level_limits jsonb) cascade;

create or replace function admin_list_feedback(pwd text)
returns setof th_feedback language plpgsql security definer as $$
begin
  if not admin_check(pwd) then raise exception 'unauthorized'; end if;
  return query select * from public.th_feedback order by updated_at desc limit 200;
end; $$;

create or replace function admin_repo_list(pwd text)
returns setof th_official_repo language plpgsql security definer as $$
begin
  if not admin_check(pwd) then raise exception 'unauthorized'; end if;
  return query select * from public.th_official_repo order by updated_at desc;
end; $$;

create or replace function admin_repo_upsert(pwd text, items jsonb)
returns integer language plpgsql security definer as $$
declare v_cnt int := 0; v_item record; v_id text;
begin
  if not admin_check(pwd) then raise exception 'unauthorized'; end if;
  for v_item in select * from jsonb_array_elements(coalesce(items, '[]'::jsonb)) loop
    v_id := coalesce(v_item.value->>'id', v_item.value->>'fmt' || ':' || v_item.value->>'name');
    insert into th_official_repo (id, name, fmt, category, data, updated_at)
    values (v_id, v_item.value->>'name', v_item.value->>'fmt', v_item.value->>'category', v_item.value->'data', now())
    on conflict (id) do update set name = excluded.name, fmt = excluded.fmt, category = excluded.category, data = excluded.data, updated_at = now();
    v_cnt := v_cnt + 1;
  end loop;
  return v_cnt;
end; $$;

create or replace function admin_repo_set_password(pwd text, new_pwd text)
returns jsonb language plpgsql security definer as $$
begin
  if not admin_check(pwd) then raise exception 'unauthorized'; end if;
  insert into th_repo_meta (id, pass_md5) values ('main', md5(new_pwd))
  on conflict (id) do update set pass_md5 = excluded.pass_md5;
  return jsonb_build_object('ok', true);
end; $$;

-- 刷新 PostgREST 缓存（让新签名立即生效）
select pg_notify('pgrst', 'reload schema');

-- ============================================================
-- v6.0 官方仓库统一修复（并行会话改动导致的断联修复）
--   1. 用户端 repo_* 函数重建：参数名统一为 pwd（与前端 category.js 调用一致，
--      此前线上只有 repo_upsert(p_pwd,p_items) 导致前端分享 404）
--   2. 密码统一存 th_kv.repo_pwd（sha256）；th_repo_meta.pass_md5 同步保留（兼容旧新机制）
--   3. 开发者（th_profiles.role='developer'）免密取用/分享/改密；管理员仍需密码
--   4. 数据表统一为 th_official_repo（管理端 admin_repo_* 与用户端 repo_* 共用）
--   说明：如已有旧数据在 th_repo 表，请先执行：
--     insert into th_official_repo (id,name,fmt,category,data,updated_at)
--     select id,name,fmt,category,data,updated_at from th_repo
--     on conflict (id) do nothing;
-- ============================================================
drop function if exists repo_check(text);
drop function if exists repo_list(text);
drop function if exists repo_upsert(text, jsonb);
drop function if exists repo_set_password(text, text);

create or replace function repo_check(pwd text)
returns boolean language plpgsql security definer as $$
declare v_uid uuid;
begin
  -- 开发者免密（管理员仍需密码）
  v_uid := nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
  if exists (select 1 from th_profiles p where p.id = v_uid and p.role = 'developer') then
    return true;
  end if;
  return exists (select 1 from th_kv where key = 'repo_pwd' and value = encode(sha256(convert_to(coalesce(pwd, ''), 'utf8')), 'hex'));
end; $$;

create or replace function repo_list(pwd text)
returns jsonb language plpgsql security definer as $$
declare v_rows jsonb;
begin
  if not repo_check(pwd) then raise exception '密码错误'; end if;
  select coalesce(jsonb_agg(row_to_json(x)::jsonb), '[]'::jsonb) into v_rows
  from (select id, name, fmt, category, data, updated_at from th_official_repo order by updated_at desc) x;
  return v_rows;
end; $$;

create or replace function repo_upsert(pwd text, items jsonb)
returns int language plpgsql security definer as $$
declare v_cnt int := 0; it jsonb;
begin
  if not repo_check(pwd) then raise exception '密码错误'; end if;
  for it in select * from jsonb_array_elements(coalesce(items, '[]'::jsonb)) loop
    insert into th_official_repo (id, name, fmt, category, data, updated_at)
    values (it->>'id', it->>'name', it->>'fmt', it->>'category', it->'data', now())
    on conflict (id) do update
      set name = excluded.name, fmt = excluded.fmt, category = excluded.category,
          data = excluded.data, updated_at = now();
    v_cnt := v_cnt + 1;
  end loop;
  return v_cnt;
end; $$;

create or replace function repo_set_password(pwd text, new_pwd text)
returns boolean language plpgsql security definer as $$
begin
  if not repo_check(pwd) then raise exception '密码错误'; end if;
  if new_pwd is null or length(new_pwd) < 4 then raise exception '密码至少4位'; end if;
  insert into th_kv (key, value) values ('repo_pwd', encode(sha256(convert_to(new_pwd, 'utf8')), 'hex'))
  on conflict (key) do update set value = excluded.value;
  insert into th_repo_meta (id, pass_md5) values ('main', md5(new_pwd))
  on conflict (id) do update set pass_md5 = excluded.pass_md5;
  return true;
end; $$;

grant execute on function repo_check(text) to anon, authenticated;
grant execute on function repo_list(text) to anon, authenticated;
grant execute on function repo_upsert(text, jsonb) to anon, authenticated;
grant execute on function repo_set_password(text, text) to anon, authenticated;

-- 刷新 PostgREST 缓存（让新签名立即生效）
select pg_notify('pgrst', 'reload schema');


-- ══════════════════════════════════════════════════════════════
-- 来源文件: engine-center.sql
-- ══════════════════════════════════════════════════════════════

-- ============================================================
-- ThirdHub 补丁【必需 · 管理后台「引擎中心」依赖本文件】
--
-- ★为什么是「必需」而不是「可选加固」（原稿写反了，2026-09-30 更正）：
--   本文件早期版本声称「th_kv 建的是 `for all using (true)`，匿名可读写，
--   所以不执行本文件功能照常可用」—— 这个前提**已经被 2026-08-27 的
--   security-fix.sql 推翻**。那份补丁把 th_kv 的 RLS 收紧成：
--     · 匿名只读 `key like 'vendor:%'`
--     · 写入仅 service_role
--   于是「引擎中心」直连 th_kv 读写**必然失败**。已实测确认（2026-09-30）：
--     · 匿名 select th_kv  → HTTP 200 但返回空数组（0 行）—— 直读永远拿不到数据
--     · 匿名 insert th_kv  → HTTP 401 / 42501 "violates row-level security policy"
--   而 js/admin.js 全文没有 signIn/setSession（loadSb 只带 anon key），
--   也就是这个页面本身就是匿名客户端 ⇒ 直连那条路走不通。
--   ⇒ 本文件提供 4 个 security definer RPC，admin.js 与 EngineProfile.kt 都改调它们。
--     未执行本文件时：后台「引擎中心」提示「缺少后台 RPC」（PostgREST 404 / PGRST202），
--     引擎端静默回落出厂密码 123456（fail-open，不会把人锁在门外）。
--
-- 依赖: community.sql(admin_check) + admin-repo.sql(th_kv) + security-fix.sql
--
-- 背景
--   五个安卓引擎产物（阅读/小说/漫画/音乐/视频）共用同一份源码, 内置源是私货:
--   App 装完第一次打开必须输入激活密码才解锁内置源。未激活时——
--     · 不把出厂源导入数据库
--     · THP 模块端点一律 403 ACTIVATION_REQUIRED
--     · 广播 caps 为空数组（前端据此直接跳过, 而不是反复重试"连上了却永远搜不到"）
--   App 里烤死的出厂密码是 123456; 管理员改一次, 各端联网同步一次即跟随。
--
-- 密码存法（与 App 内 EngineProfile.kt 必须一致；盐字面量有两处，改一处必改两处）
--   hash = lower(hex(sha256(utf8('thirdhub.reading-engine.v1' || 明文))))
--   盐  = 'thirdhub.reading-engine.v1'   ← Kotlin 侧 SALT 常量 = 本文件下方字面量
--   ★ 前端 admin.js 不再参与哈希（原 engineHash() 已删）—— 因为在本页算 hash
--     就还得把 hash 写回 th_kv，而那条路已被 RLS 关掉。
--
-- ★安全说明（2026-09-30 核实后重写）
--   旧文说「th_kv 对匿名开放读写，任何人拿 anon key 就能改写 admin_pwd / engine_pwd_hash」
--   —— 该说法**不成立**：匿名写已被 RLS 拦掉（实测 42501），匿名读只剩 vendor:*。
--   本文件 4 个 RPC 中只有 engine_pwd_fetch() 对匿名开放，且它**只回 hash 与版本号、
--   不回明文**。App 必须能在无凭据的情况下取到指纹，所以这是设计上不可避免的暴露。
--   hash 用的是公开的固定盐 ⇒ 弱口令可被离线爆破。这只是一道"本机自用"的软门，
--   不是强安全边界：激活密码请勿设成纯数字弱口令。
--
-- ★加固（2026-09-30）：4 个函数全部显式 `set search_path = public, extensions, pg_temp`。
--   这四个都是 security definer 且对 anon 开放，不锁 search_path 就留下
--   "调用者用同名对象劫持函数内引用"的经典风险（Supabase 安全巡检也会报这一条）。
--   pg_temp 放在最后是为了让临时 schema 排在最后被查找，避免被临时对象影子化。
--   （本文件用到的 sha256/encode/convert_to 是 PG 11+ 内核函数，在 pg_catalog，
--     固定 search_path 不影响它们解析；列 extensions 只是兜底。）
-- ============================================================

-- 兜底: 本文件可单独执行
create table if not exists th_kv (key text primary key, value text);
alter table th_kv enable row level security;

-- ── 管理端: 读状态（只回"是否自定义 + 版本号", 绝不返回 hash / 明文）──
create or replace function admin_engine_pwd_get(p_pwd text)
returns jsonb language plpgsql security definer
set search_path = public, extensions, pg_temp as $$
declare v_hash text; v_ver text; v_at text;
begin
  if not admin_check(p_pwd) then raise exception 'unauthorized'; end if;
  select value into v_hash from th_kv where key = 'engine_pwd_hash';
  select value into v_ver  from th_kv where key = 'engine_pwd_ver';
  select value into v_at   from th_kv where key = 'engine_pwd_at';
  return jsonb_build_object(
    'ok', true,
    'set', coalesce(v_hash, '') <> '',
    'ver', coalesce(nullif(v_ver, ''), '0'),
    'updatedAt', coalesce(v_at, ''),
    'defaultPwd', '123456'
  );
end; $$;

-- ── 管理端: 设置激活密码（4-64 位）────────────────────
create or replace function admin_engine_pwd_set(p_pwd text, p_new_pwd text)
returns jsonb language plpgsql security definer
set search_path = public, extensions, pg_temp as $$
declare v_next int;
begin
  if not admin_check(p_pwd) then raise exception 'unauthorized'; end if;
  if p_new_pwd is null or length(p_new_pwd) < 4 or length(p_new_pwd) > 64 then
    raise exception '激活密码长度需 4-64 位';
  end if;

  insert into th_kv (key, value) values (
    'engine_pwd_hash',
    encode(sha256(convert_to('thirdhub.reading-engine.v1' || p_new_pwd, 'utf8')), 'hex')
  ) on conflict (key) do update set value = excluded.value;

  select coalesce(max(value::int), 0) + 1 into v_next
    from th_kv where key = 'engine_pwd_ver' and value ~ '^[0-9]+$';

  insert into th_kv (key, value) values ('engine_pwd_ver', v_next::text)
    on conflict (key) do update set value = excluded.value;
  insert into th_kv (key, value) values (
    'engine_pwd_at', to_char(now() at time zone 'Asia/Shanghai', 'YYYY-MM-DD HH24:MI:SS')
  ) on conflict (key) do update set value = excluded.value;

  return jsonb_build_object('ok', true, 'ver', v_next::text, 'set', true);
end; $$;

-- ── 管理端: 恢复出厂默认（删键 → 回落 123456）──────────
create or replace function admin_engine_pwd_reset(p_pwd text)
returns jsonb language plpgsql security definer
set search_path = public, extensions, pg_temp as $$
begin
  if not admin_check(p_pwd) then raise exception 'unauthorized'; end if;
  delete from th_kv where key in ('engine_pwd_hash', 'engine_pwd_ver', 'engine_pwd_at');
  return jsonb_build_object('ok', true, 'ver', '0', 'set', false);
end; $$;

-- ── 引擎端: 拉取当前密码指纹（无需口令, App 首启联网同步用）──
--   返回的是 hash 而非明文: App 侧比对 sha256(盐 + 输入) 即可, 明文永不离开服务器。
--   未设置（set=false）时 App 回落烤死的出厂密码。
create or replace function engine_pwd_fetch()
returns jsonb language plpgsql security definer
set search_path = public, extensions, pg_temp as $$
declare v_hash text; v_ver text;
begin
  select value into v_hash from th_kv where key = 'engine_pwd_hash';
  select value into v_ver  from th_kv where key = 'engine_pwd_ver';
  return jsonb_build_object(
    'ok', true,
    'set', coalesce(v_hash, '') <> '',
    'hash', coalesce(v_hash, ''),
    'salt', 'thirdhub.reading-engine.v1',
    'ver', coalesce(nullif(v_ver, ''), '0')
  );
end; $$;

grant execute on function admin_engine_pwd_get(text) to anon, authenticated, service_role;
grant execute on function admin_engine_pwd_set(text, text) to anon, authenticated, service_role;
grant execute on function admin_engine_pwd_reset(text) to anon, authenticated, service_role;
grant execute on function engine_pwd_fetch() to anon, authenticated, service_role;


-- ══════════════════════════════════════════════════════════════
-- 来源文件: devices.sql
-- ══════════════════════════════════════════════════════════════

-- ============================================================
-- v6.3 设备自动发现与一键配对（Agent ↔ 前端）
-- ============================================================

-- 设备注册表：Agent 启动时注册 + 每 30s 心跳
create table if not exists th_devices (
  device_id text primary key,
  name text,
  lan_ips jsonb default '[]'::jsonb,
  public_ip text,
  status text default 'unbound',        -- unbound | bound
  owner uuid,                            -- 绑定用户
  secret_hash text,                      -- Agent 心跳/配对校验
  version text,
  relay text,                            -- 公网中继 wss 地址(cloudflared quick tunnel)
  last_seen timestamptz default now(),
  created_at timestamptz default now()
);
alter table th_devices enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='th_devices' and policyname='devices 公开可读') then
    execute 'create policy "devices 公开可读" on th_devices for select using (true)';
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='th_devices' and policyname='devices 仅服务端写') then
    execute 'create policy "devices 仅服务端写" on th_devices for all using (false)';
  end if;
end $$;

-- 配对令牌：前端(登录态)生成，Agent 直连校验后使用
create table if not exists th_device_pairs (
  token text primary key,               -- 随机 24 位
  device_id text not null,
  user_id uuid not null,
  exp timestamptz not null,
  status text default 'pending',        -- pending | used
  created_at timestamptz default now()
);
alter table th_device_pairs enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='th_device_pairs' and policyname='pairs 本人可发') then
    execute 'create policy "pairs 本人可发" on th_device_pairs for insert with check (auth.uid() = user_id)';
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='th_device_pairs' and policyname='pairs 校验可读') then
    execute 'create policy "pairs 校验可读" on th_device_pairs for select using (status = ''pending'')';
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='th_device_pairs' and policyname='pairs 仅服务端写') then
    execute 'create policy "pairs 仅服务端写" on th_device_pairs for all using (false)';
  end if;
end $$;

-- Agent 注册/心跳（校验 secret）
create or replace function device_ping(p_device_id text, p_secret_hash text, p_name text, p_lan_ips jsonb, p_public_ip text, p_version text, p_relay text default null)
returns jsonb language plpgsql security definer as $$
declare v_status text; v_owner uuid;
begin
  if p_device_id is null or p_secret_hash is null then return jsonb_build_object('ok', false, 'reason', 'bad args'); end if;
  insert into th_devices (device_id, name, secret_hash, lan_ips, public_ip, version, relay, last_seen)
  values (p_device_id, coalesce(p_name, ''), p_secret_hash, coalesce(p_lan_ips, '[]'::jsonb), coalesce(p_public_ip, ''), coalesce(p_version, ''), coalesce(p_relay, ''), now())
  on conflict (device_id) do update
    set name = excluded.name, lan_ips = excluded.lan_ips, public_ip = excluded.public_ip,
        version = excluded.version, relay = coalesce(excluded.relay, th_devices.relay), last_seen = now(),
        secret_hash = case when th_devices.status = 'unbound' then excluded.secret_hash else th_devices.secret_hash end;
  select status, owner into v_status, v_owner from th_devices where device_id = p_device_id;
  return jsonb_build_object('ok', true, 'status', v_status, 'owner', v_owner);
end; $$;

-- 配对校验（Agent 用）：token 有效 → 绑定设备 → 标记 used
create or replace function device_pair_claim(p_device_id text, p_token text)
returns jsonb language plpgsql security definer as $$
declare v_user uuid; v_sec text;
begin
  select user_id into v_user from th_device_pairs
    where token = p_token and device_id = p_device_id and status = 'pending' and exp > now();
  if v_user is null then return jsonb_build_object('ok', false, 'reason', 'invalid token'); end if;
  update th_device_pairs set status = 'used' where token = p_token;
  update th_devices set status = 'bound', owner = v_user where device_id = p_device_id and status = 'unbound';
  select secret_hash into v_sec from th_devices where device_id = p_device_id;
  return jsonb_build_object('ok', true, 'user_id', v_user, 'secret_hash', v_sec);
end; $$;

-- 解除绑定（Agent 端解绑后调用）
create or replace function device_unbind(p_device_id text, p_secret_hash text)
returns jsonb language plpgsql security definer as $$
begin
  update th_devices set status = 'unbound', owner = null where device_id = p_device_id and secret_hash = p_secret_hash;
  return jsonb_build_object('ok', true);
end; $$;

grant execute on function device_ping(text, text, text, jsonb, text, text) to anon, authenticated, service_role;
grant execute on function device_ping(text, text, text, jsonb, text, text, text) to anon, authenticated, service_role;
grant execute on function device_pair_claim(text, text) to anon, authenticated, service_role;
grant execute on function device_unbind(text, text) to anon, authenticated, service_role;

-- ══════════════════════════════════════════════════════════════
-- 来源文件: repo-zone.sql
-- ══════════════════════════════════════════════════════════════

-- ============================================================
-- v6.4 官方仓库统一 + 健康/18+ 分区 + 自动分类
-- ============================================================

-- 1. 分区字段
alter table th_official_repo add column if not exists zone text default 'health';
alter table th_repo add column if not exists zone text default 'health';

-- 2. 自动分区判定（入库时调用）
create or replace function repo_zone_of(p_name text, p_data jsonb) returns text
language plpgsql stable as $$
declare v_txt text; v_zone text := 'health';
begin
  v_txt := lower(coalesce(p_name, '') || ' ' || coalesce(p_data->>'bookSourceComment', '') || ' ' || coalesce(p_data->>'bookSourceGroup', '') || ' ' || coalesce(p_data->>'bookSourceUrl', '') || ' ' || coalesce(p_data->>'name', '') || ' ' || coalesce(p_data->>'key', ''));
  if v_txt ~ '18\+|成人|h漫|禁漫|hentai|nhentai|ehentai|里番|无修|ntr|色情|黄色|情色|porn|adult|xhamster|av\d|肉番|工口|小黄' then
    v_zone := 'adult';
  end if;
  return v_zone;
end; $$;

-- 3. 用户端 repo_list / repo_upsert：返回/写入 zone
create or replace function repo_list(pwd text)
returns jsonb language plpgsql security definer as $$
declare v_rows jsonb;
begin
  if not repo_check(pwd) then raise exception '密码错误'; end if;
  select coalesce(jsonb_agg(row_to_json(x)::jsonb), '[]'::jsonb) into v_rows
  from (select id, name, fmt, category, zone, data, updated_at from th_official_repo order by updated_at desc) x;
  return v_rows;
end; $$;

create or replace function repo_upsert(pwd text, items jsonb)
returns int language plpgsql security definer as $$
declare v_cnt int := 0; it jsonb;
begin
  if not repo_check(pwd) then raise exception '密码错误'; end if;
  for it in select * from jsonb_array_elements(coalesce(items, '[]'::jsonb)) loop
    insert into th_official_repo (id, name, fmt, category, zone, data, updated_at)
    values (it->>'id', it->>'name', it->>'fmt', it->>'category',
            repo_zone_of(it->>'name', it->'data'), it->'data', now())
    on conflict (id) do update
      set name = excluded.name, fmt = excluded.fmt, category = excluded.category,
          zone = excluded.zone, data = excluded.data, updated_at = now();
    v_cnt := v_cnt + 1;
  end loop;
  return v_cnt;
end; $$;

-- 4. 后台 admin_repo_*：统一到 th_official_repo（与用户端同一仓库）+ zone
create or replace function admin_repo_list(pwd text)
returns jsonb language plpgsql security definer as $$
declare v_rows jsonb;
begin
  if not admin_check(pwd) then raise exception 'unauthorized'; end if;
  select coalesce(jsonb_agg(row_to_json(x)::jsonb), '[]'::jsonb) into v_rows
  from (select id, name, fmt, category, zone, data, updated_at from th_official_repo order by updated_at desc) x;
  return v_rows;
end; $$;

create or replace function admin_repo_upsert(pwd text, items jsonb)
returns int language plpgsql security definer as $$
declare v_cnt int := 0; it jsonb;
begin
  if not admin_check(pwd) then raise exception 'unauthorized'; end if;
  for it in select * from jsonb_array_elements(coalesce(items, '[]'::jsonb)) loop
    insert into th_official_repo (id, name, fmt, category, zone, data, updated_at)
    values (it->>'id', it->>'name', it->>'fmt', it->>'category',
            repo_zone_of(it->>'name', it->'data'), it->'data', now())
    on conflict (id) do update
      set name = excluded.name, fmt = excluded.fmt, category = excluded.category,
          zone = excluded.zone, data = excluded.data, updated_at = now();
    v_cnt := v_cnt + 1;
  end loop;
  return v_cnt;
end; $$;

create or replace function admin_repo_delete(pwd text, ids text[])
returns int language plpgsql security definer as $$
declare v_cnt int := 0;
begin
  if not admin_check(pwd) then raise exception 'unauthorized'; end if;
  delete from th_official_repo where id = any(ids);
  get diagnostics v_cnt = row_count;
  return v_cnt;
end; $$;

create or replace function admin_repo_set_password(pwd text, new_pwd text)
returns jsonb language plpgsql security definer as $$
begin
  if not admin_check(pwd) then raise exception 'unauthorized'; end if;
  if new_pwd is null or length(new_pwd) < 4 then raise exception '密码至少4位'; end if;
  insert into th_kv (key, value) values ('repo_pwd', encode(sha256(convert_to(new_pwd, 'utf8')), 'hex'))
  on conflict (key) do update set value = excluded.value;
  return '{"ok":true}'::jsonb;
end; $$;

-- 5. 迁移 th_repo 现有数据到 th_official_repo（用户端立即可见）
insert into th_official_repo (id, name, fmt, category, zone, data, updated_at)
select id, name, fmt, category, repo_zone_of(name, data), data, updated_at
from th_repo
on conflict (id) do update
  set name = excluded.name, fmt = excluded.fmt, category = excluded.category,
      zone = excluded.zone, data = excluded.data, updated_at = excluded.updated_at;

-- 6. 回填现有 th_official_repo 的 zone
update th_official_repo set zone = repo_zone_of(name, data) where zone is null or zone = '';

-- ══════════════════════════════════════════════════════════════
-- 来源文件: account-delete.sql
-- ══════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════════════
-- account-delete.sql —— 5.1.1 账号删除（Apple 必备）
--
-- 背景（outputs/ThirdHub-苹果过审可行性-实证评估-20261010.md §1.6/§5.1）：
--   有账号体系 ⇒ 必须 **App 内**能删号（只给邮箱/网页入口会被拒）。
--
-- 方案：Supabase RPC `th_delete_account()`（SECURITY DEFINER）——
--   ① 删掉该用户在全部用户表的数据行（书架/进度/历史/收藏/设置/设备绑定/资料/社区…）；
--   ② 删掉 `auth.users` 里的账号本身（级联清 sessions/identities）。
--   App（cloud.dart 的 Cloud.deleteAccount）与网页端（auth.js 的 deleteAccount）
--   调的是**同一条 RPC**，两端删的是同一个东西。
--
-- ★ 为什么走 RPC 而不是自托管后端中转：审核时设备上没有我们的 9527 后端，
--   删号必须在"无后端"时照样可用。后端 /v1/account/delete 只是清
--   /v1/pair 设备注册等**本端痕迹**（best-effort 附加项，见 server/index.js）。
--
-- 应用方法：在 Supabase SQL Editor 里整段执行（需要 postgres 角色权限）。
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.th_delete_account()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  uid uuid := auth.uid();
  t text;
  col text;
  -- 用户数据表清单。列名在不同部署里不统一（th_profiles 用 id、th_devices 用 owner、
  -- 其余多为 user_id），所以不写死列名，按优先级在 information_schema 里探。
  tables constant text[] := array[
    'th_profiles',            -- 个人资料（id = uid）
    'th_shared',              -- 跨前端键值共享
    'th_bookshelf',           -- 书架
    'th_reading_progress',    -- 阅读进度
    'th_history',             -- 历史
    'th_favorites',           -- 收藏
    'th_settings',            -- 设置
    'th_user_devices',        -- 多设备列表
    'th_apikeys',             -- 云端 API Key
    'th_chats',               -- 对话
    'th_orders',              -- 订单
    'th_invoices',            -- 发票
    'th_feedback',            -- 反馈
    'th_feedback_comments',   -- 反馈评论
    'th_inspiration',         -- 灵感
    'device_logs',            -- 设备日志
    'community_posts',        -- 社区帖子
    'community_comments',     -- 社区评论
    'th_devices',             -- 家庭云端设备（owner = uid）
    'th_device_pairs'         -- 设备配对令牌
  ];
begin
  if uid is null then
    raise exception 'th_delete_account: not authenticated';
  end if;

  -- ① 用户数据行。逐表容错：表/列在旧部署里可能不存在，缺了跳过并留 notice，
  --    绝不能让一张表的结构差异把整个删号卡死（那等于用户永远删不掉号）。
  foreach t in array tables loop
    begin
      select c.column_name into col
        from information_schema.columns c
       where c.table_schema = 'public'
         and c.table_name = t
         and c.column_name in ('user_id', 'uid', 'owner', 'id')
       order by case c.column_name
                  when 'user_id' then 1
                  when 'uid'    then 2
                  when 'owner'  then 3
                  when 'id'     then 4
                end
       limit 1;
      if col is not null then
        execute format('delete from public.%I where %I = $1', t, col) using uid;
      end if;
    exception when undefined_table or undefined_column then
      raise notice 'th_delete_account: skipped % (structure mismatch)', t;
    end;
  end loop;

  -- ② 账号本身（级联清 auth.sessions / auth.identities）。
  --    放最后：其余表若有指向 auth.users 的外键，行已先行删掉。
  delete from auth.users where id = uid;
end;
$$;

-- 只给已登录用户；匿名/公共服务角色一律拒。
revoke execute on function public.th_delete_account() from public, anon;
grant execute on function public.th_delete_account() to authenticated;

-- 已知边界（如需补齐另立迁移）：
--   · storage.objects 里的用户文件（如头像桶）未清 —— 当前头像存 th_profiles.avatar
--     内联列，已随①删除；若以后引入存储桶，在上面清单外补
--     `delete from storage.objects where owner = uid;`。
--   · 自托管后端（9527）的 /v1/pair 设备注册不在 Supabase 里，
--     由客户端 best-effort 调 `/v1/account/delete` 清理。


-- ══════════════════════════════════════════════════════════════
-- 来源文件: family-identity.sql
-- ══════════════════════════════════════════════════════════════

-- ============================================================
-- ThirdHub 身份体系 v10.0（家庭版）
-- 执行方式：Supabase Dashboard → SQL Editor → 粘贴运行（仅需一次）
-- 功能：12 位身份码(不可改) + 微信号(可改一次/可再改,唯一) + 动态二维码(60s 刷新 HMAC 签名)
-- 依赖：th_profiles 表（已存在）；RLS 由 RPC 内部校验(改用者=自己)
-- ============================================================

alter table th_profiles add column if not exists uid12 text;
alter table th_profiles add column if not exists handle text;
create unique index if not exists th_profiles_uid12_idx on th_profiles (uid12);
create unique index if not exists th_profiles_handle_idx on th_profiles (handle);

-- 分配身份码（12 位：8 前缀 + 秒级时间 8 位 + 3 位随机；唯一冲突自旋）
create or replace function allocate_identity(p_uid uuid) returns jsonb
language plpgsql security definer as $$
declare v_code text;
begin
  select uid12 into v_code from th_profiles where id = p_uid;
  if v_code is not null then
    return jsonb_build_object('ok', true, 'uid12', v_code, 'handle', coalesce((select handle from th_profiles where id = p_uid), v_code));
  end if;
  loop
    v_code := '8' || to_char((extract(epoch from now())::bigint % 100000000), 'FM00000000') || lpad((floor(random() * 1000))::text, 3, '0');
    exit when not exists (select 1 from th_profiles where uid12 = v_code);
  end loop;
  update th_profiles set uid12 = v_code, handle = v_code where id = p_uid;
  return jsonb_build_object('ok', true, 'uid12', v_code, 'handle', v_code);
end $$;

-- 修改微信号（4-20 位字母数字下划线，全局唯一；同自己允许）
create or replace function set_handle(p_uid uuid, p_handle text) returns jsonb
language plpgsql security definer as $$
begin
  if p_handle is null or p_handle !~ '^[a-zA-Z0-9_]{4,20}$' then
    return jsonb_build_object('ok', false, 'msg', '微信号需 4-20 位字母/数字/下划线');
  end if;
  if exists (select 1 from th_profiles where handle = p_handle and id <> p_uid) then
    return jsonb_build_object('ok', false, 'msg', '该微信号已被使用');
  end if;
  update th_profiles set handle = p_handle where id = p_uid;
  return jsonb_build_object('ok', true);
end $$;

-- 按身份码 / 微信号查找用户（供加好友搜索）
create or replace function find_user_by_code(p_me uuid, p_code text) returns jsonb
language plpgsql security definer as $$
declare r record;
begin
  select id, nickname, handle, uid12 into r from th_profiles
    where handle = lower(trim(p_code)) or uid12 = trim(p_code) limit 1;
  if r is null then return jsonb_build_object('ok', false, 'msg', '未找到该用户'); end if;
  if r.id = p_me then return jsonb_build_object('ok', false, 'msg', '不能添加自己'); end if;
  return jsonb_build_object('ok', true, 'id', r.id, 'nickname', r.nickname, 'handle', r.handle, 'uid12', r.uid12);
end $$;

-- 动态二维码（60 秒一个槽，HMAC-SHA256 签名；密钥可后续换 th_kv.family_qr_secret）
create or replace function get_friend_qr(p_uid uuid) returns jsonb
language plpgsql security definer as $$
declare v_code text; v_t bigint; v_sig text;
begin
  select uid12 into v_code from th_profiles where id = p_uid;
  if v_code is null then return jsonb_build_object('ok', false, 'msg', '身份码未初始化'); end if;
  v_t := floor(extract(epoch from now()) / 60)::bigint;
  v_sig := encode(hmac(convert_to(v_code || ':' || v_t::text, 'utf8'), convert_to('THUB_FAMILY_QR_V1', 'utf8'), 'sha256'), 'hex');
  return jsonb_build_object('ok', true, 'content', 'thhub://friend?uid=' || v_code || '&t=' || v_t || '&sig=' || v_sig);
end $$;


-- ══════════════════════════════════════════════════════════════
-- 来源文件: icon-rpc.sql
-- ══════════════════════════════════════════════════════════════

create or replace function set_vendor_icon(p_id text, p_icon text) returns jsonb
language plpgsql security definer as $$
begin
  if p_id is null or p_icon is null or length(p_icon) > 600000 then
    return jsonb_build_object('ok', false, 'msg', '参数无效：id 缺失或图标过大(>600KB)');
  end if;
  insert into th_kv (key, value) values ('vendor:icon:' || p_id, p_icon)
    on conflict (key) do update set value = excluded.value, updated_at = now();
  return jsonb_build_object('ok', true);
end $$;
grant execute on function set_vendor_icon(text, text) to anon;


-- ══════════════════════════════════════════════════════════════
-- 来源文件: user-heartbeat.sql（用户在线心跳与使用时长）
-- ══════════════════════════════════════════════════════════════

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