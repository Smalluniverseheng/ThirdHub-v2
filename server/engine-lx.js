// ThirdHub v4 落雪(LX)音源引擎: Node vm 沙箱跑 LX 音源脚本 → music-IR
// LX API: globalThis.lx.on('request', handler) / lx.send('inited') / lx.request() / lx.utils.*
const vm = require('vm');
const crypto = require('crypto');
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/126.0.0.0 Safari/537.36';

// 加载脚本: 执行 → 等 inited → 返回 {handlers, sandbox}
async function loadScript(code) {
  const handlers = {};
  let inited = null;
  const lx = {
    EVENT_NAMES: { request: 'request', inited: 'inited' },
    on: (ev, cb) => { handlers[ev] = cb; },
    send: (ev, data) => { if (ev === 'inited') inited = data || { status: true }; },
    request: (url, opts, cb) => {
      const o = opts || {};
      fetch(url, {
        method: o.method || 'GET',
        headers: { 'User-Agent': UA, ...(o.headers || {}) },
        body: o.body ? (typeof o.body === 'string' ? o.body : JSON.stringify(o.body))
              : o.form ? new URLSearchParams(o.form).toString() : undefined,
        signal: AbortSignal.timeout(15000),
      }).then(async (r) => {
        const text = await r.text();
        let body = text;
        try { body = JSON.parse(text); } catch (e) {}
        cb(null, { statusCode: r.status, body, headers: Object.fromEntries(r.headers.entries()) });
      }).catch((e) => cb(e, null));
    },
    utils: {
      buffer: {
        from: (d, enc) => Buffer.from(d, enc),
        toString: (b, enc) => Buffer.from(b).toString(enc || 'utf8'),
      },
      base64: {
        encode: (s) => Buffer.from(s, 'utf8').toString('base64'),
        decode: (s) => Buffer.from(s, 'base64').toString('utf8'),
      },
      crypto: {
        md5: (s) => crypto.createHash('md5').update(s).digest('hex'),
        sha1: (s) => crypto.createHash('sha1').update(s).digest('hex'),
        sha256: (s) => crypto.createHash('sha256').update(s).digest('hex'),
        randomBytes: (n) => crypto.randomBytes(n).toString('hex'),
        aesEncrypt: (data, key, iv) => {
          try {
            const c = crypto.createCipheriv('aes-128-cbc', Buffer.from(key), Buffer.from(iv || key));
            return Buffer.concat([c.update(String(data)), c.final()]).toString('base64');
          } catch (e) { return ''; }
        },
      },
    },
    currentScriptInfo: {},
  };
  // ★ 沙箱里的 console 不直通宿主：音源脚本普遍爱 print，直通的话
  //   服务端日志会被第三方文案淹没（实测一条源会打十几行 ASCII banner）。
  //   收进缓冲，只在需要时随错误一起带出来，另把 warn/error 转发给宿主。
  const logs = [];
  const keep = (...a) => { if (logs.length < 200) logs.push(a.map(x => (typeof x === 'string' ? x : safeStr(x))).join(' ')); };
  const sandbox = {
    console: { log: keep, info: keep, debug: keep, warn: (...a) => { keep('[warn]', ...a); }, error: (...a) => { keep('[error]', ...a); } },
    lx, globalThis: null,
    URL, URLSearchParams, TextEncoder, TextDecoder, JSON, Math, Date, RegExp, Error, Promise,
    atob: (s) => Buffer.from(s, 'base64').toString('binary'),
    btoa: (s) => Buffer.from(s, 'binary').toString('base64'),
    setTimeout, clearTimeout, setInterval, clearInterval,
    __logs: logs,
  };
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(code, sandbox, { timeout: 10000 });
  // 等脚本 inited(最多5秒)
  for (let i = 0; i < 50 && !inited; i++) await new Promise(r => setTimeout(r, 100));
  if (!inited) throw new Error('音源未初始化(未调用 lx.send("inited"))' + tail(logs));
  if (inited.status === false) throw new Error('音源初始化失败: ' + (inited.message || '') + tail(logs));
  if (typeof handlers.request !== 'function') throw new Error('音源未注册 request 处理器');
  return { handlers, inited, logs };
}

function tail(logs) {
  if (!logs || !logs.length) return '';
  return ' | 源日志: ' + logs.slice(-2).map(l => String(l).slice(0, 100)).join(' / ');
}

function safeStr(v) {
  try { const s = JSON.stringify(v); return s && s.length > 300 ? s.slice(0, 300) + '…' : String(s); } catch (_) { return String(v); }
}

// 从 init 载荷里收集该音源**声明支持的动作集**。
//
// 为什么必须读它：LX 音源在 `lx.send('inited', {sources: {wy: {actions: ['musicUrl'], qualitys: [...]}}})`
// 里显式声明自己的能力。**绝大多数自定义音源只声明 `musicUrl`**（只负责把歌曲 ID 换成播放链接），
// 搜索能力归"聚合接口"那类源。此前我们不看声明、对每个源一律调 `search`，
// 于是满屏 `仅支持musicUrl操作` / `action not support` —— 全是**误报**：
// 源没坏，是我们问错了问题。
function collectActions(inited) {
  const out = new Set();
  const srcs = (inited && inited.sources) || {};
  for (const k of Object.keys(srcs)) {
    const a = srcs[k] && srcs[k].actions;
    if (Array.isArray(a)) for (const x of a) out.add(String(x));
    else if (typeof a === 'string') out.add(a);
  }
  return out;
}

function collectPlatforms(inited) {
  const srcs = (inited && inited.sources) || {};
  return Object.keys(srcs).map(k => ({ id: k, name: (srcs[k] && srcs[k].name) || k, type: (srcs[k] && srcs[k].type) || '', actions: (srcs[k] && srcs[k].actions) || [], qualitys: (srcs[k] && srcs[k].qualitys) || [] }));
}

// 「搜索」这件事在 LX 音源里有**两个**合法动作名：`search` 和 `musicSearch`
// （社区源两种写法都有，实测本机 4 条可搜源里 2 条用 `search`、2 条用 `musicSearch`）。
// 把它收敛成唯一判断点，路由与验收共用，避免两处各写一套而漂移。
function searchAction(actions) {
  const a = Array.isArray(actions) ? actions : [];
  if (a.includes('search')) return 'search';
  if (a.includes('musicSearch')) return 'musicSearch';
  return null;
}

// 只做"装载 + 读能力声明"，不发起任何业务调用 —— 导入时用它给每条音源打能力标签。
async function getSourceInfo(code) {
  try {
    const { inited } = await loadScript(code);
    const actions = [...collectActions(inited)];
    return { ok: true, status: inited.status !== false, actions, searchAction: searchAction(actions), platforms: collectPlatforms(inited) };
  } catch (e) {
    return { ok: false, error: String(e.message || e) };
  }
}

// 调用: action = search | musicUrl | lyric | pic
async function runLX(code, action, data = {}) {
  try {
    const { handlers, inited } = await loadScript(code);
    // ★ 先按音源**自己声明的**能力挡一道。声明里没有这个 action 就直接给出
    //   人能看懂的原因（谁不支持、它支持什么），而不是让源内部抛出
    //   `仅支持musicUrl操作` 这种看起来像"引擎坏了"的字样。
    const declared = collectActions(inited);
    if (declared.size && !declared.has(action)) {
      return {
        error: '该音源未声明支持 ' + action + '（其声明: ' + [...declared].join(',') + '）',
        unsupported: true,
        actions: [...declared],
      };
    }
    const result = await Promise.race([
      Promise.resolve(handlers.request({ action, source: data.source || '', data })),
      new Promise((_, rej) => setTimeout(() => rej(new Error('调用超时')), 20000)),
    ]);
    return result;
  } catch (e) {
    return { error: String(e.message || e) };
  }
}

// ── IR 归一(与 MusicFree 引擎同一输出) ──
function irSearch(r) {
  if (!r) return { items: [] };
  if (r.error) return { error: r.error };
  const list = r.lists || r.list || r.data || [];
  return { items: list.map(m => ({
    id: m.songmid || m.id || '', name: m.name || m.title || '',
    artist: m.singer || m.artist || '', album: m.album || '',
    coverUrl: m.img || m.artwork || '', duration: m.interval || 0,
    raw: m, // musicUrl 调用时原样回传
  })), isEnd: (r.page || 1) >= (r.allPage || 1) };
}
function irUrl(r) {
  if (!r) return { error: '空结果' };
  if (r.error) return { error: r.error };
  return { url: typeof r === 'string' ? r : (r.url || ''), quality: '' };
}
function irLyric(r) {
  if (!r) return { lyric: '' };
  if (r.error) return { error: r.error };
  return { lyric: typeof r === 'string' ? r : (r.lyric || r.lrc || '') };
}

module.exports = { runLX, getSourceInfo, collectActions, collectPlatforms, searchAction, irSearch, irUrl, irLyric };
