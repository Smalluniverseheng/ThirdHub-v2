// ─────────────────────────────────────────────────────────────────────────────
// routes.js — 能力路由表 + 权重取源 + 健康度自动摘除
//
// 解决 `docs/TASKS.md` 组C 里挂着的两条（C1 大半、C2 后半）：
//   · C1「routes 表 + 并行 fan-out」—— fan-out 与 IR 合并去重早就有
//     （`routes-search.js` 的 `Promise.all` + 并发池 + 按 `name|author` 去重），
//     但"该问哪些源、问几个"**是写死的**：`sources.slice(0, 3)` / `.slice(0, 2)`
//     一共 5 处硬编码。后果是**永远只问排在前面的那几个源**：第 4 个之后的书源
//     哪怕质量最好也永远不会被用到 —— 用户体感就是"我导了几十条源，还是那几本"。
//   · C2「动态权重 + 自动禁用/恢复」—— 只有 `health` Map，且**仅用于排序**：
//     `routes-search.js` 里"成功率差 >30% 才置前"。一个彻底死掉的源
//     每次搜索都还要再等它超时一遍，白占并发位、拉长整体延迟。
//
// 本文件把这两件事合成一个**纯逻辑层**（不碰 IO、不 require 引擎），
// 于是它可以被单独测（`test_routes.cjs`，20+ 条断言），也方便以后换策略。
//
// 三个关键设计：
//   ① **路由表是数据，不是 if 链**。`ROUTES` 里每一行声明"这类需求问哪种源、取几个"，
//      以后加板块只加一行，不动搜索主流程。
//   ② **取源按权重，且带"探索配额"**。纯按权重排会变成"强者恒强"，
//      新导入的源永远没机会证明自己 —— 所以固定留 1 个名额给"最少被用到的源"（探索位）。
//      这是推荐系统里的老办法，但在这里特别要紧：用户导源就是希望新源能被试试。
//   ③ **摘除是"临时静默"，不是"删除"**。连续失败到阈值 → 静默一段时间（默认 5 分钟）
//      → 静默期满放它**探一次**（half-open）→ 成功即恢复、失败则重新静默。
//      绝不永久拉黑：源站恢复、网络抖动都很常见，永久拉黑等于把用户自己修好的源也一起废了。
'use strict';

/** 路由表：`需求类型 → 用哪种源 / 取几个 / 每源要几条` */
const ROUTES = [
  // ── 搜索类 ──
  { id: 'search.novel',  match: 'search', type: 'novel', kinds: ['book'],  limit: 3, perSource: 10, aggLimit: 5 },
  { id: 'search.comic',  match: 'search', type: 'comic', kinds: ['comic'], limit: 2, perSource: 10, aggLimit: 5 },
  { id: 'search.video',  match: 'search', type: 'video', kinds: ['drpy'],  limit: 2, perSource: 10, aggLimit: 5 },
  { id: 'search.music',  match: 'search', type: 'music', kinds: ['music'], limit: 2, perSource: 10, aggLimit: 5 },
  // ── 取内容类（正文/目录/详情）：单源即可，不需要 fan-out ──
  { id: 'toc.novel',     match: 'toc',     type: 'novel', kinds: ['book'],  limit: 1, perSource: 0, aggLimit: 0 },
  { id: 'content.novel', match: 'content', type: 'novel', kinds: ['book'],  limit: 1, perSource: 0, aggLimit: 0 },
];

/** 按 id 取路由；找不到按 `match` 回落到第一个同类路由。 */
function route(idOrMatch) {
  return ROUTES.find(r => r.id === idOrMatch)
      || ROUTES.find(r => r.match === idOrMatch)
      || null;
}

// ── 健康度账本 ────────────────────────────────────────────────────────────────
const DEFAULTS = {
  failStreakToSuppress: 3,     // 连续失败几次 → 静默
  suppressMs: 5 * 60 * 1000,   // 静默多久（之后放一次探测）
  restoreOkStreak: 1,          // half-open 后成功几次算真正恢复
  rateFloor: 0.15,             // 样本足够时，成功率低于此值也静默
};

class HealthGate {
  constructor(opts = {}) {
    this.opt = { ...DEFAULTS, ...opts };
    // id → { ok, fail, latencySum, streakFail, streakOk, suppressedUntil, probes, lastError, lastAt }
    this.map = new Map();
  }
  _e(id) {
    let e = this.map.get(id);
    if (!e) {
      e = { ok: 0, fail: 0, latencySum: 0, streakFail: 0, streakOk: 0, suppressedUntil: 0, probes: 0, lastError: '', lastAt: 0 };
      this.map.set(id, e);
    }
    return e;
  }
  /**
   * 记一次结果，并按规则决定是否静默/恢复。
   * @returns {{state:'ok'|'suppressed'|'restored', entry:object}}
   */
  note(id, ok, latency = 0, error = '') {
    const e = this._e(id);
    e.lastAt = Date.now();
    if (ok) {
      e.ok++; e.latencySum += Math.max(0, latency || 0);
      e.streakFail = 0; e.streakOk++;
      if (e.suppressedUntil && e.streakOk >= this.opt.restoreOkStreak) {
        e.suppressedUntil = 0; e.probes = 0;
        return { state: 'restored', entry: e };
      }
      return { state: 'ok', entry: e };
    }
    e.fail++; e.streakFail++; e.streakOk = 0;
    if (error) e.lastError = String(error).slice(0, 200);
    if (e.streakFail >= this.opt.failStreakToSuppress) {
      e.suppressedUntil = Date.now() + this.opt.suppressMs;
      return { state: 'suppressed', entry: e };
    }
    return { state: 'ok', entry: e };
  }
  /** 成功率（无样本时给 1 —— 新源不该因为"还没数据"被歧视）。 */
  rate(id) {
    const e = this.map.get(id);
    if (!e || e.ok + e.fail === 0) return 1;
    return e.ok / (e.ok + e.fail);
  }
  /** 平均延迟（无样本给 0，排序时视为最快 → 先给新源机会）。 */
  avgMs(id) {
    const e = this.map.get(id);
    if (!e || e.ok + e.fail === 0) return 0;
    return e.latencySum / (e.ok + e.fail);
  }
  /** 是否处于"静默期"（还没到探测时刻）。 */
  isSuppressed(id) {
    const e = this.map.get(id);
    if (!e || !e.suppressedUntil) return false;
    return Date.now() < e.suppressedUntil;
  }
  /** 静默期已过 → 是否该放一次探测（half-open）。 */
  isProbeDue(id) {
    const e = this.map.get(id);
    if (!e || !e.suppressedUntil) return false;
    return Date.now() >= e.suppressedUntil;
  }
  /**
   * 综合权重：成功率为主、延迟为辅。范围 0~1。
   * 延迟用 `1/(1+秒数)` 压成 0~1，避免"慢 100ms"和"慢 10s"在权重里差得不够。
   *
   * ★ **无样本的源用中性先验 0.5，而不是 1**。这条是被单测抓出来的：
   *   第一版把"无样本"当 rate=1、avgMs=0 → 权重正好 1.0，结果**一个从没用过的源
   *   排在"已验证又快又稳"的源前面**（0.95）。那样排序就失去意义了 ——
   *   用户的体感会变成"每次搜索先问几个没名堂的新源"。
   *   现在的关系是：**已验证的好源 > 未知新源(0.5) > 已验证的差源 > 静默源(0)**。
   *   新源仍然有机会 —— 那由 `pickSources` 的**探索位**保证，而不是靠虚高权重。
   */
  static PRIOR_UNKNOWN = 0.5;
  weight(id) {
    if (this.isSuppressed(id)) return 0;
    const e = this.map.get(id);
    if (!e || e.ok + e.fail === 0) return HealthGate.PRIOR_UNKNOWN;
    const r = this.rate(id);
    const a = this.avgMs(id) / 1000;
    return r * (1 / (1 + a));
  }
  snapshot() {
    const out = {};
    for (const [id, e] of this.map) {
      // 无样本时不显示 "100%" —— 那是假话（真实含义是"还不知道"）。
      out[id] = { ok: e.ok, fail: e.fail, rate: (e.ok + e.fail) ? Math.round(this.rate(id) * 100) + '%' : '-',
        avgMs: Math.round(this.avgMs(id)), weight: Number(this.weight(id).toFixed(4)),
        streakFail: e.streakFail, suppressed: this.isSuppressed(id),
        probeDue: this.isProbeDue(id), lastError: e.lastError, lastAt: e.lastAt };
    }
    return out;
  }
}

/**
 * 按权重取源 —— 替换 `slice(0, N)` 的硬编码。
 *
 * 行为约定（每条都有对应单测）：
 *   · 静默中的源**排除**；
 *   · 若排除后一个都不剩 → **全部放回**并按权重排（宁可问死源，也不能搜不出东西）；
 *   · 正常时：前 (limit-1) 个位置给权重最高的；**留 1 个"探索位"给最少被用到的源**；
 *   · limit=1 时不存在探索位（取内容场景，必须用最高权重那个）。
 *
 * @param {Array<object>} list 候选源
 * @param {{limit?:number, idOf?:Function, gate?:HealthGate, usage?:Map<string,number>}} o
 */
function pickSources(list, o = {}) {
  const all = Array.isArray(list) ? list.filter(s => s && s.enabled !== false) : [];
  const limit = Math.max(1, o.limit || 1);
  const idOf = o.idOf || ((s) => s.id || s.bookSourceUrl || s.name || '');
  const gate = o.gate || null;
  if (all.length <= limit) return all.slice();
  if (!gate) return all.slice(0, limit);

  const active = all.filter(s => !gate.isSuppressed(idOf(s)));
  // 全被静默 → 全部放回（否则"搜索不出任何东西"比"问一次死源"更糟）
  const pool = active.length ? active : all;

  const scored = pool.map(s => ({ s, id: idOf(s), w: gate.weight(idOf(s)) }))
    .sort((a, b) => (b.w - a.w) || (gate.avgMs(a.id) - gate.avgMs(b.id)));

  if (limit === 1) return scored.slice(0, 1).map(x => x.s);

  const head = scored.slice(0, limit - 1);
  // 探索位：在剩余里挑"被用过次数最少"的；并列时挑权重高的。
  const usage = o.usage;
  const rest = scored.slice(limit - 1);
  let probe = null;
  if (rest.length) {
    if (usage && typeof usage.get === 'function') {
      rest.sort((a, b) => (usage.get(a.id) || 0) - (usage.get(b.id) || 0) || (b.w - a.w));
      probe = rest[0];
    } else {
      probe = rest[0]; // 没有用量统计时退化为"次高权重"
    }
  }
  const out = [...head, ...(probe ? [probe] : [])].map(x => x.s);
  // 去重（headIds 理论上不含 probe，但比较函数可能把同一个源排两次的极端情况要挡住）
  return out.filter((s, i) => out.findIndex(x => idOf(x) === idOf(s)) === i);
}

module.exports = { ROUTES, route, pickSources, HealthGate, DEFAULTS };
