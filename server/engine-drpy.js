// ThirdHub v4 drpy 引擎适配器: Node vm 沙箱跑 drpy2 + 源JS
// 数据流: 源JS(drpy格式) → 沙箱执行 → search/detail/play → 归一 video-IR
const vm = require('vm');
const fs = require('fs'); const path = require('path');
const VENDOR = path.join(__dirname, 'vendor', 'drpy');

let engineCode = null;
function getEngineCode() {
  if (engineCode) return engineCode;
  let code = fs.readFileSync(path.join(VENDOR, 'drpy2.min.js'), 'utf8');
  // 1) 剥 ES module import (海阔assets协议, Node无法解析, 依赖手动注入)
  code = code.replace(/^import[^;]+;?$/gm, '');
  // 2) 解决 let rule 与源 var rule 冲突: 去 let 声明改裸赋值(非严格模式自动挂全局)
  code = code.replace(/let rule\s*=/, 'rule =');
  // 3) 模板.js 依赖: 未引入, 用模板的源会报错跳过(二期)
  engineCode = code;
  return code;
}

function buildSandbox(sourceCode) {
  const sandbox = {
    console, fetch, URL, URLSearchParams, TextEncoder, TextDecoder,
    atob: (s) => Buffer.from(s, 'base64').toString('binary'),
    btoa: (s) => Buffer.from(s, 'binary').toString('base64'),
    setTimeout, clearTimeout, JSON, Math, Date, RegExp, Error, Promise,
    cheerio: null, CryptoJS: null, gbkTool: null,
    __result: null, rule: undefined
  };
  vm.createContext(sandbox);
  // 依赖: crypto-js(UMD挂全局) + gbk
  try { vm.runInContext(fs.readFileSync(path.join(VENDOR, 'crypto-js.js'), 'utf8'), sandbox, { timeout: 5000 }); } catch (e) {}
  try { vm.runInContext(fs.readFileSync(path.join(VENDOR, 'gbk2.js'), 'utf8'), sandbox, { timeout: 5000 }); } catch (e) {}
  // cheerio 注入(npm版API与浏览器版兼容)
  sandbox.cheerio = require('cheerio');
  return sandbox;
}

// 在沙箱里跑源+调方法。method: init/home/search/detail/play/category
async function runSource(sourceCode, method, args = []) {
  const sandbox = buildSandbox(sourceCode);
  try {
    vm.runInContext(getEngineCode(), sandbox, { timeout: 8000 });
  } catch (e) {
    throw new Error('引擎加载失败: ' + e.message);
  }
  // 源 + 调用入口(先让源的 var rule 生效, 再 init(rule), 再调方法)
  const entry = `
;(function(){
  try {
    if (typeof rule === 'undefined' || rule === null) { __result = { error: '源未定义rule' }; return; }
    if (typeof init === 'function') init(rule);
    if (typeof ${method} !== 'function') { __result = { error: '引擎无${method}方法' }; return; }
    __result = ${method}.apply(null, ${JSON.stringify(args)});
  } catch (e) { __result = { error: String(e && e.message || e) }; }
})();`;
  try {
    vm.runInContext(sourceCode + entry, sandbox, { timeout: 20000 });
  } catch (e) {
    return { error: '源执行失败: ' + e.message };
  }
  return sandbox.__result;
}

// ─── IR 归一(drpy原生结构 → video-IR) ───
function irSearch(result) {
  if (!result) return { items: [] };
  if (result.error) return { error: result.error };
  const list = result.list || result.vod || result.data || [];
  return { items: list.map(v => ({
    id: v.vod_id || v.id || '', name: v.vod_name || v.name || '',
    coverUrl: v.vod_pic || v.pic || '', intro: (v.vod_content || v.content || '').slice(0, 200),
    type: v.vod_type || v.type_name || '', year: v.vod_year || '', score: v.vod_score || ''
  })) };
}
function irDetail(result) {
  if (!result) return { error: '空结果' };
  if (result.error) return { error: result.error };
  const v = (result.list || [result])[0] || result;
  // 选集: vod_play_url 格式 "线路名$集名$url#集名$url##线路2$..."
  const episodes = [];
  const playUrl = v.vod_play_url || '';
  for (const line of String(playUrl).split('$$$')) {
    const parts = line.split('$');
    const lineName = parts.length > 2 ? parts[0] : '';
    const flag = lineName; // drpy play(flag, id) 的线路参数
    const eps = (parts.length > 2 ? parts.slice(1).join('$') : line).split('#');
    for (const ep of eps) {
      const si = ep.lastIndexOf('$');
      if (si > 0) episodes.push({ name: (lineName ? lineName + '·' : '') + ep.slice(0, si), url: ep.slice(si + 1), flag });
    }
  }
  return { id: v.vod_id, name: v.vod_name, coverUrl: v.vod_pic,
    intro: v.vod_content || '', episodes: episodes.filter(e => e.url) };
}
function irPlay(result) {
  if (!result) return { error: '空结果' };
  if (result.error) return { error: result.error };
  return { url: result.url || result.parse || '', type: /\.m3u8/.test(result.url || '') ? 'm3u8' : 'mp4',
    headers: result.header || {} };
}

module.exports = { runSource, irSearch, irDetail, irPlay };
