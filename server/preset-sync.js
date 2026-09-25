/* ===== 预置源包「增量导入 + 撤销」纯函数 =====
 *
 * 为什么需要它（2026-09-25 记）：
 *   旧的 `importPreset()` 是**只增不减**的 —— 判据只有
 *   `if (item.bookSourceUrl && !sources.some(x => x.bookSourceUrl === item.bookSourceUrl)) push`。
 *   于是「把烂源从 health-book.json 里剔掉」这件事**对老安装完全无效**：
 *   老安装的 data/sources.json 里那条烂源还在、而且 `enabled: true`，
 *   换包只是又追加几条新源 —— 用户的阅读线依旧一堆「点进去是文字墙」的源。
 *   ⇒ 净化源包必须配一条**撤销通道**，否则等于没改。
 *
 * 设计取舍：
 *   · 撤销用 **enabled:false + 换组名**，不是删除 —— 用户的源列表是他自己的数据，
 *     删了没法恢复；停用可以手动再打开，且不违反「不改用户数据」。
 *   · 标记用**源包文件内容的 sha1 前缀**，而不是「条目数」：条目数在
 *     「删一条加一条」时会不变 → 恰好漏掉一类变更（而且条目数是老格式，顺手一起升级）。
 *   · **只动源对象里 Legado 本来就有的两个字段**（`enabled` / `bookSourceGroup`），
 *     其余簿记（原组名、停用时间、原因）全放在标记文件里 →
 *     `data/sources.json` 不会被塞进私有字段，客户端/外部导入不会看到怪东西。
 *   · 纯函数：不读文件、不写文件、不碰全局，输入输出全是值 → 可直接单测。
 *   · 幂等：同一份包跑两次，第二次 `changed` 为空、`sources` 逐字节等价。
 *   · 尊重用户：包没变 → 一律不动（用户手动删掉的源不会被每次重启塞回来；
 *     用户手动重新启用的源也不会被再次停用）。
 */
'use strict';
const crypto = require('crypto');

/** 被本机制停用的源会被打上这个组名，便于用户在管理台里一眼认出来 */
const DISABLED_GROUP = '已停用·双闸门未通过';

const tokenOf = (text) => crypto.createHash('sha1').update(String(text || '')).digest('hex').slice(0, 16);

/**
 * 把 `data/preset-imported.json` 的任意历史形态归一成 `{ packs, revoked }`。
 * 历史形态：`{ "demo.json": 1, "health-book.json": 12 }`（数字 = 条目数）。
 * 数字标记一定匹配不上新 token → 会触发一次全量对齐；而「加源」本身按 url 去重，
 * 所以这次对齐是幂等且安全的。
 */
function normalizeState(state) {
  const out = { packs: {}, revoked: {} };
  if (!state || typeof state !== 'object') return out;
  const src = state.packs && typeof state.packs === 'object' ? state.packs : state;
  for (const k of Object.keys(src)) {
    const v = src[k];
    if (typeof v === 'string') out.packs[k] = v;
    else if (typeof v === 'number') out.packs[k] = 'legacy:' + v;   // 显式区分，永远不相等
  }
  if (state.revoked && typeof state.revoked === 'object') out.revoked = Object.assign({}, state.revoked);
  return out;
}

/**
 * @param {Array} current  data/sources.json 的当前内容（不会被修改）
 * @param {Array} entries  [{ file, text, list, revoked }]
 *                         file=包文件名；text=原始文件文本（用来算 token）；
 *                         list=源数组；revoked=该包声明要停用的源（可缺省）
 * @param {Object} state   data/preset-imported.json 的解析结果（可为 {}）
 * @returns {{sources:Array, state:Object, added:number, disabled:number, restored:number, changed:string[], notes:string[]}}
 */
function planPresetSync(current, entries, state) {
  const st = normalizeState(state);
  const sources = (Array.isArray(current) ? current : []).map((s) => Object.assign({}, s));
  const index = new Map();
  sources.forEach((s, i) => { if (s && s.bookSourceUrl) index.set(s.bookSourceUrl, i); });

  // 全量白名单：任何「当前仍在某个包里的 url」都不允许被撤销（包 = 刚验过的事实）
  const allowed = new Set();
  for (const e of entries || []) for (const it of (e && e.list) || []) if (it && it.bookSourceUrl) allowed.add(it.bookSourceUrl);

  let added = 0, disabled = 0, restored = 0;
  const changed = [];
  const notes = [];

  for (const e of entries || []) {
    if (!e || !e.file) continue;
    const token = tokenOf(e.text);
    if (st.packs[e.file] === token) continue;            // 包没变 → 跳过（尊重用户删改）
    changed.push(e.file);

    // ① 撤销通道：包声明「这些源不该再用」
    for (const rv of e.revoked || []) {
      const url = rv && rv.bookSourceUrl;
      if (!url || allowed.has(url)) continue;              // 同时在白名单里 → 以白名单为准
      const i = index.get(url);
      if (i === undefined) continue;                       // 用户没有这条 → 无事可做
      const s = sources[i];
      if (s.enabled === false && s.bookSourceGroup === DISABLED_GROUP) continue;  // 已停用，幂等
      st.revoked[url] = { name: s.bookSourceName || rv.bookSourceName || '', prevGroup: s.bookSourceGroup || '', reason: rv.reason || '', at: Date.now() };
      s.bookSourceGroup = DISABLED_GROUP;
      s.enabled = false;
      disabled++;
      notes.push('停用 ' + (s.bookSourceName || url) + ' ← ' + (rv.reason || ''));
    }

    // ② 导入通道：把包里（新出现或重新回到白名单的）源补齐
    for (const item of e.list || []) {
      if (!item || !item.bookSourceUrl || !item.bookSourceName) continue;
      const i = index.get(item.bookSourceUrl);
      if (i === undefined) {
        sources.push(Object.assign({}, item, { enabled: true }));
        index.set(item.bookSourceUrl, sources.length - 1);
        added++;
        continue;
      }
      // 已在列表里：若此前被本机制停用、现在又回到白名单 → 恢复启用 + 还原组名
      const s = sources[i];
      if (s.enabled === false && s.bookSourceGroup === DISABLED_GROUP) {
        const prev = st.revoked[item.bookSourceUrl];
        s.bookSourceGroup = (prev && prev.prevGroup) || '';
        s.enabled = true;
        delete st.revoked[item.bookSourceUrl];
        restored++;
        notes.push('恢复 ' + (s.bookSourceName || item.bookSourceUrl));
      }
    }

    st.packs[e.file] = token;
  }

  return { sources, state: st, added, disabled, restored, changed, notes };
}

module.exports = { planPresetSync, DISABLED_GROUP, tokenOf, normalizeState };
