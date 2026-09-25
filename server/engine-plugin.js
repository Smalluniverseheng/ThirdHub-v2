/**
 * EnginePlugin —— 内置引擎的**统一接口 + 注册表**。
 *
 * ────────────────────────────────────────────────────────────────────────
 * 为什么要有这个文件（`docs/TASKS.md` 组E·E1「EnginePlugin 统一接口落地」）
 * ────────────────────────────────────────────────────────────────────────
 * 在此之前，六个引擎各有一套调用约定：
 *
 *   引擎            搜索                                    详情 / 播放
 *   ──────────────  ──────────────────────────────────────  ────────────────────────────
 *   engine.js       search(source, q)                        detail/catalog/content
 *   engine-drpy.js  runSource(code,'search',[q]) + irSearch  runSource(code,'play',[f,id])
 *   engine-lx.js    runLX(code,action,{...}) + irSearch      runLX(code,'musicUrl',{...})
 *   engine-comic.js runSource(code,'search',[q,1]) + irComic*runSource(code,'comicPages')
 *   engine-music.js runPlugin(code,'search',[q,1]) + ir*     runPlugin(code,'getMediaSource')
 *   engine-tvbox.js cmsSearch(api, q)                        cmsDetail / cmsPlay
 *
 * 于是**每个调用点都得自己判断"这个源属于哪个引擎、该调哪个函数"**。
 * 在 `routes-media.js` 里这件事被写了七八遍，全是同一个形状：
 *
 *     s.format === 'lx' ? lx.irSearch(await lx.runLX(s.code, 'search', {...}))
 *                       : music.irSearch(await music.runPlugin(s.code, 'search', [...]))
 *     s.api             ? drpy.irSearch(await tvbox.cmsSearch(s.api, q))
 *                       : drpy.irSearch(await drpy.runSource(s.code, 'search', [q]))
 *
 * 这类重复的真实代价不是"代码长"，而是**漏改不报错**：
 * 新增一种源格式时，只要有一个分支忘了加，那类内容就是"静默搜不到"——
 * 和本次修掉的鉴权黑洞是同一类病（把错误表现成"没内容"）。
 *
 * 所以这里收敛成两层：
 *   ① `EnginePlugin` 实例：固定五个动作 `search/detail/catalog/content/play`
 *      （外加可选的 `lyric/probe`），**每个动作都返回 IR** —— 调用方不需要
 *      知道底层是 runSource 还是 runPlugin、参数是数组还是对象。
 *   ② `forSource(src, kind)`：**按源对象自动挑选插件**，把上面那些三元表达式
 *      全部消掉。调用方只写 `await plugin.forSource(s).search(s, q)`。
 *
 * 设计上刻意保持两点"不越界"：
 *   · 不做 IR 归一 —— 各引擎的 `ir*` 已经产出同一种 IR，这里只做**转发**，
 *     免得在中间层再引入一套可能漂移的映射；
 *   · 不接管源的存取（`data/*-sources.json`）—— 那是调用方的职责，
 *     插件只管"给我一个源，我把它跑起来"。
 */

const engine = require('./engine.js');
const drpyE = require('./engine-drpy.js');
const lxE = require('./engine-lx.js');
const comicE = require('./engine-comic.js');
const musicE = require('./engine-music.js');
const tvboxE = require('./engine-tvbox.js');

/** IR 空结果的统一形状：各引擎的 `ir*` 在出错时都会给出 `{ error }`。 */
const errOf = (e) => ({ error: String((e && e.message) || e || '未知错误') });

/**
 * 一个 EnginePlugin 就是一个「能跑某类源」的适配器。
 * 所有动作**均为 async**，且**一律返回 IR**（不抛异常；失败写成 `{error}`），
 * 这样调用方可以放心 `Promise.all` 而不用给每个引擎裹一层 try/catch。
 */
class EnginePlugin {
  /**
   * @param {object} spec
   * @param {string}   spec.id     插件标识（与源对象的选取规则对应）
   * @param {string[]} spec.kinds  支持的内容类型：novel/comic/video/music/live
   * @param {string}   spec.label  给人看的名字（日志/自检输出用）
   * @param {Function} spec.pick   判断"某个源是否该由我处理"
   * @param {object}   spec.actions 动作实现：{search, detail, catalog, content, play, url, lyric}
   */
  constructor(spec) {
    this.id = spec.id;
    this.kinds = spec.kinds || [];
    this.label = spec.label || spec.id;
    this._pick = spec.pick || (() => false);
    this._actions = spec.actions || {};
  }

  /** 这个源是否归我管。 */
  handles(src) { try { return !!this._pick(src); } catch (_) { return false; } }

  supports(action) { return typeof this._actions[action] === 'function'; }

  /** 动作总入口：找不到实现时给一条**能指出原因**的 IR，而不是抛。 */
  async call(action, src, ...args) {
    const fn = this._actions[action];
    if (typeof fn !== 'function') {
      return errOf(`插件 ${this.id} 不支持动作 ${action}（其支持: ${Object.keys(this._actions).join(',') || '无'}）`);
    }
    try { return await fn(src, ...args); }
    catch (e) { return errOf(e); }
  }

  // ── 五个标准动作的语法糖，统一返回 IR ──
  search(src, q, page) { return this.call('search', src, q, page); }
  detail(src, item) { return this.call('detail', src, item); }
  catalog(src, item) { return this.call('catalog', src, item); }
  content(src, item) { return this.call('content', src, item); }
  play(src, item) { return this.call('play', src, item); }
  /** 音源专用：把条目换成播放直链 / 歌词。 */
  url(src, item, quality) { return this.call('url', src, item, quality); }
  lyric(src, item) { return this.call('lyric', src, item); }

  /** 能力自述（给管理面板/自检用）。 */
  describe() {
    return { id: this.id, label: this.label, kinds: [...this.kinds],
      actions: Object.keys(this._actions) };
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 六个适配器 —— 只做"转发 + 参数形状对齐"，不碰 IR
// ═══════════════════════════════════════════════════════════════════════════

/** Legado 书源（`data/sources.json`，本体是 JSON 规则，无需沙箱）。 */
const legacyPlugin = new EnginePlugin({
  id: 'legado', kinds: ['novel'], label: 'Legado 书源引擎',
  pick: (s) => !!(s && s.bookSourceUrl && !s.code),
  actions: {
    search: async (s, q) => ({ items: await engine.search(s, q) }),
    detail: async (s, item) => await engine.detail(s, (item && item.bookUrl) || item),
    catalog: async (s, item) => await engine.catalog(s, (item && item.bookUrl) || item),
    content: async (s, item) => await engine.content(s, (item && item.url) || item),
  },
});

/**
 * drpy 影视/直播源（`data/drpy-sources.json`）。
 *
 * ★判别方式说明（第一版曾写错，自检当场抓到）：
 *   我曾按"有 code 且无 format 且无 api"来判断 drpy，意图是"兜底接住它"。
 *   但真实数据里**每条 drpy 源都带 `format: 'drpy'`**（60/60），
 *   而 musicfree 的兜底条件与它**完全重叠** → 于是 `DJ音乐` 被选成了
 *   musicfree 插件，端到端冒烟直接失败。
 *   现在改为**只认明确标识**：认不出来就返回 null，让调用方报"无人认领"。
 *   宁可明确报错，也不猜 —— 猜错的表现正是"某类源永远搜不到"。
 */
const drpyPlugin = new EnginePlugin({
  id: 'drpy', kinds: ['video', 'live', 'audiobook', 'novel'], label: 'drpy 影视源引擎',
  pick: (s) => !!(s && s.code && s.format === 'drpy'),
  actions: {
    search: async (s, q) => drpyE.irSearch(await drpyE.runSource(s.code, 'search', [q])),
    detail: async (s, item) => drpyE.irDetail(await drpyE.runSource(s.code, 'detail', [(item && (item.id || item.url)) || item])),
    play: async (s, item) => drpyE.irPlay(await drpyE.runSource(s.code, 'play',
      [(item && item.flag) || '', (item && item.id) || ''])),
  },
});

/** LX 音源（`data/music-sources.json` 里 `format === 'lx'`，39/39 都是）。 */
const lxPlugin = new EnginePlugin({
  id: 'lx', kinds: ['music'], label: 'LX 音源引擎',
  pick: (s) => !!(s && s.code && s.format === 'lx'),
  actions: {
    search: async (s, q) => lxE.irSearch(await lxE.runLX(s.code,
      lxE.searchAction(s.actions) || 'search',
      { searchKey: q, page: 1, limit: 20, type: 'music' })),
    url: async (s, item, quality) => lxE.irUrl(await lxE.runLX(s.code, 'musicUrl',
      { musicInfo: (item && (item.raw || item)) || item, type: quality || '320k' })),
    lyric: async (s, item) => lxE.irLyric(await lxE.runLX(s.code, 'lyric',
      { musicInfo: (item && (item.raw || item)) || item })),
  },
});

/** venera 漫画源。 */
const comicPlugin = new EnginePlugin({
  id: 'comic', kinds: ['comic'], label: 'venera 漫画源引擎',
  pick: (s) => !!(s && s.code && (s.format === 'comic' || s.format === 'venera')),
  actions: {
    search: async (s, q, page) => comicE.irComicList(await comicE.runSource(s.code, 'search', [q, page || 1])),
    detail: async (s, item) => comicE.irComicInfo(await comicE.runSource(s.code, 'comicInfo',
      [(item && (item.id || item.url)) || item])),
    content: async (s, item) => comicE.irPages(await comicE.runSource(s.code, 'comicPages',
      [(item && (item.id || item.chapterId)) || item])),
  },
});

/** musicfree 音源（`engine-music.js` 兼容层；目前 `data/` 里暂无实例）。 */
const musicfreePlugin = new EnginePlugin({
  id: 'musicfree', kinds: ['music'], label: 'musicfree 音源引擎',
  pick: (s) => !!(s && s.code && (s.format === 'musicfree' || s.format === 'musicfree-plugin')),
  actions: {
    search: async (s, q) => musicE.irSearch(await musicE.runPlugin(s.code, 'search', [q, 1, 'music'])),
    url: async (s, item, quality) => musicE.irUrl(await musicE.runPlugin(s.code, 'getMediaSource',
      [item, quality || 'standard'])),
    lyric: async (s, item) => musicE.irLyric(await musicE.runPlugin(s.code, 'getLyric', [item])),
  },
});

/** TVBox CMS 接口（`s.api` 直连苹果CMS json，不走沙箱）。 */
const tvboxPlugin = new EnginePlugin({
  id: 'tvbox', kinds: ['video', 'live'], label: 'TVBox CMS 接口',
  pick: (s) => !!(s && s.api),
  actions: {
    search: async (s, q) => drpyE.irSearch(await tvboxE.cmsSearch(s.api, q)),
    detail: async (s, item) => drpyE.irDetail(await tvboxE.cmsDetail(s.api,
      (item && (item.id || item.vod_id)) || item)),
    play: async (s, item) => drpyE.irPlay(tvboxE.cmsPlay((item && (item.id || item.vod_id)) || item)),
  },
});

// ═══════════════════════════════════════════════════════════════════════════
// 注册表
// ═══════════════════════════════════════════════════════════════════════════

/** 注册顺序 = 选取优先级。判别条件有交集的（drpy / musicfree 都看 `format`）靠顺序定夺。 */
const ALL = [legacyPlugin, lxPlugin, comicPlugin, tvboxPlugin, musicfreePlugin, drpyPlugin];
const BY_ID = new Map(ALL.map((p) => [p.id, p]));

const registry = {
  all: () => [...ALL],
  ids: () => ALL.map((p) => p.id),
  get: (id) => BY_ID.get(id) || null,

  /** 按内容类型挑插件。 */
  ofKind: (kind) => ALL.filter((p) => p.kinds.includes(kind)),

  /**
   * ★核心：**按源对象自动选插件**。
   * 调用方从此不用再写 `s.format === 'lx' ? … : …`；新增源格式时
   * 只要在 `ALL` 里加一个适配器，所有调用点同时生效。
   * 返回 null 表示"没有插件认领这个源"——调用方应把它当作配置错误报出来，
   * 而不是静默跳过（静默跳过正是"某些源永远搜不到"的成因）。
   */
  forSource(src, kind) {
    const cands = kind ? ALL.filter((p) => p.kinds.includes(kind)) : ALL;
    for (const p of cands) if (p.handles(src)) return p;
    for (const p of ALL) if (p.handles(src)) return p;   // kind 没写对时兜一层
    return null;
  },

  /** 一步到位：按源选插件并执行动作。 */
  async run(src, action, ...args) {
    const p = registry.forSource(src);
    if (!p) return { error: `没有插件能处理这个源（format=${src && src.format} api=${!!(src && src.api)}）` };
    return p.call(action, src, ...args);
  },

  /** 自述（管理面板 / 自检用）。 */
  describe: () => ALL.map((p) => p.describe()),
};

module.exports = { EnginePlugin, registry, plugins: registry };
