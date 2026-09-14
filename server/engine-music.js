// ThirdHub v4 MusicFree 音源引擎: Node vm 沙箱跑音源JS(CJS格式) → music-IR
const vm = require('vm'); const fs = require('fs'); const path = require('path');
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/126.0.0.0 Safari/537.36';

async function runPlugin(code, method, args = []) {
  const sandbox = {
    console, fetch: (url, opts) => fetch(url, { ...opts, signal: AbortSignal.timeout(15000), headers: { 'User-Agent': UA, ...(opts && opts.headers || {}) } }),
    URL, URLSearchParams, TextEncoder, TextDecoder, JSON, Math, Date, RegExp, Error, Promise, Buffer,
    atob: (s) => Buffer.from(s, 'base64').toString('binary'),
    btoa: (s) => Buffer.from(s, 'binary').toString('base64'),
    setTimeout, clearTimeout, __result: null, module: { exports: {} }, exports: null
  };
  sandbox.exports = sandbox.module.exports;
  vm.createContext(sandbox);
  const entry = `
;(async function(){
  try {
    ${code}
    const plugin = module.exports;
    if (!plugin || typeof plugin !== 'object') { __result = { error: '音源未module.exports' }; return; }
    const fn = plugin[${JSON.stringify(method)}] || (plugin.default && plugin.default[${JSON.stringify(method)}]);
    if (typeof fn !== 'function') { __result = { error: '音源无此方法: ' + ${JSON.stringify(method)} }; return; }
    __result = fn.apply(plugin, ${JSON.stringify(args)});
  } catch (e) { __result = { error: String(e && e.message || e) }; }
})();`;
  try { vm.runInContext(entry, sandbox, { timeout: 20000 }); }
  catch (e) { return { error: '音源执行失败: ' + e.message }; }
  try { return await Promise.resolve(sandbox.__result); }
  catch (e) { return { error: '方法异常: ' + e.message }; }
}

// ── IR 归一 ──
function irSearch(r) {
  if (!r) return { items: [] };
  if (r.error) return { error: r.error };
  const list = r.data || r.list || [];
  return { items: list.map(m => ({ id: m.id || '', name: m.title || m.name || '',
    artist: m.artist || m.author || '', album: m.album || '', coverUrl: m.artwork || m.cover || '',
    duration: m.duration || 0, url: m.url || '' })), isEnd: r.isEnd !== false };
}
function irUrl(r) {
  if (!r) return { error: '空结果' };
  if (r.error) return { error: r.error };
  return { url: r.url || (Array.isArray(r) ? r[0] && r[0].url : '') || '', quality: r.quality || '' };
}
function irLyric(r) {
  if (!r) return { lyric: '' };
  if (r.error) return { error: r.error };
  return { lyric: r.lyric || r.lrc || (typeof r === 'string' ? r : '') };
}
module.exports = { runPlugin, irSearch, irUrl, irLyric };
