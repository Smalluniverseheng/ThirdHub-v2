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
  const sandbox = {
    console, lx, globalThis: null,
    URL, URLSearchParams, TextEncoder, TextDecoder, JSON, Math, Date, RegExp, Error, Promise,
    atob: (s) => Buffer.from(s, 'base64').toString('binary'),
    btoa: (s) => Buffer.from(s, 'binary').toString('base64'),
    setTimeout, clearTimeout, setInterval, clearInterval,
  };
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(code, sandbox, { timeout: 10000 });
  // 等脚本 inited(最多5秒)
  for (let i = 0; i < 50 && !inited; i++) await new Promise(r => setTimeout(r, 100));
  if (!inited) throw new Error('音源未初始化(未调用 lx.send("inited"))');
  if (inited.status === false) throw new Error('音源初始化失败: ' + (inited.message || ''));
  if (typeof handlers.request !== 'function') throw new Error('音源未注册 request 处理器');
  return { handlers, inited };
}

// 调用: action = search | musicUrl | lyric | pic
async function runLX(code, action, data = {}) {
  try {
    const { handlers } = await loadScript(code);
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

module.exports = { runLX, irSearch, irUrl, irLyric };
