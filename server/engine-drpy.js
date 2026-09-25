// ThirdHub v4 drpy 引擎适配器: Node vm 沙箱跑 drpy2 + 源JS
// 数据流: 源JS(drpy格式) → 沙箱执行 → search/detail/play → 归一 video-IR
const vm = require('vm');
const fs = require('fs'); const path = require('path');
const VENDOR = path.join(__dirname, 'vendor', 'drpy');
const drpyHost = require('./drpy-host.js');

let engineCode = null;
function getEngineCode() {
  if (engineCode) return engineCode;
  let code = fs.readFileSync(path.join(VENDOR, 'drpy2.min.js'), 'utf8');
  // 1) 剥 ES module import (海阔assets协议, Node无法解析, 依赖手动注入)
  //
  // ★第十六轮修掉的真 P0 —— **影视引擎从来没加载成功过**：
  //   旧写法是 `/^import[^;]+;?$/gm`，要求每条 import **独占一行且行尾即语句结束**。
  //   而 `drpy2.min.js` 是**压缩过的单行文件**，5 条 import 全挤在第 1 行：
  //     import cheerio from"assets://js/lib/cheerio.min.js";import"assets://js/lib/crypto-js.js";
  //     import"./jsencrypt.js";import 模板 from"../js/模板.js";import{gbkTool}from"./gbk.js";
  //   于是那条正则**一条都没剥掉** → `vm.runInContext` 直接抛
  //   `Cannot use import statement outside a module` → `runSource` 返回「引擎加载失败」。
  //   表现就是：影视模块页面、源、引擎全都在，**点进去永远搜不到东西**，
  //   而这跟"源烂了"看起来一模一样，所以长期被误判成源的问题。
  //
  //   新正则按**语句边界**剥离：`import` 必须出现在 行首 / `;` / `}` / 空白 之后，
  //   到最近的引号字符串结尾为止。这样单行压缩、多行、带中文标识符（`import 模板 from`）、
  //   以及无 from 的副作用导入（`import"./x.js";`）都能覆盖。
  //   注意：必须**循环剥到不动**。因为 `String.replace(/g)` 扫过一处后 lastIndex 停在
  //   该处之后，而前一条 import 连同它前面的分隔符被删掉后，**后一条就贴到了文件开头** ——
  //   同一个 pass 不会再回头扫它。第一版只跑一次，结果剩了个 `import"assets://…"`
  //   没剥掉（被守卫当场逮住），正是这个原因。
  const IMPORT_RE = /(^|[;}\s])import\b[^;]*?["'][^"']+["']\s*;/g;
  for (let i = 0; i < 20; i++) {
    const next = code.replace(IMPORT_RE, '$1');
    if (next === code) break;
    code = next;
  }
  // 兜底：万一还有残留 import，宁可在这里就报清楚，也别让它以"加载失败"的面目糊到上层
  if (/(^|[;}\s])import\b/.test(code)) {
    const m = code.match(/(^|[;}\s])(import\b[^;]{0,120})/);
    throw new Error('drpy 引擎仍残留未剥离的 import 语句: ' + (m ? m[2] : '(未知)'));
  }
  // 1b) 剥 `export`。drpy2 末尾是一句 `export default{init:init,home:home,...}`。
  //
  //   为什么不直接删掉：删掉之后剩下的是裸的 `{init:init, play:play, search:search}`，
  //   它会被当成**块语句**解析，而 `play:play,search:search` 在块里是"标签语句 + 逗号表达式"，
  //   直接语法错误（比原来的报错更难查）。所以改成赋给一个普通变量 ——
  //   既保留原对象（不改变行为），又是合法语句。
  code = code.replace(/\bexport\s+default\s*/g, 'var __drpy_exports = ');
  code = code.replace(/\bexport\s*(\{[^}]*\})\s*;?/g, 'var __drpy_exports = $1;');
  code = code.replace(/\bexport\s+(function|const|let|var|class)\b/g, '$1');
  if (/(^|[;}\s])export\b/.test(code)) {
    const m = code.match(/(^|[;}\s])(export\b[^;]{0,120})/);
    throw new Error('drpy 引擎仍残留未剥离的 export 语句: ' + (m ? m[2] : '(未知)'));
  }

  // 2) 解决 let rule 与源 var rule 冲突: 去 let 声明改裸赋值(非严格模式自动挂全局)
  code = code.replace(/let rule\s*=/, 'rule =');
  // 3) 模板.js 依赖: 未引入, 用模板的源会报错跳过(二期)
  engineCode = code;
  return code;
}

// 短字符串化：源里 print 的东西可能是任意对象，别把整个 DOM 灌进日志
function brief(v) {
  try {
    if (typeof v === 'string') return v.length > 400 ? v.slice(0, 400) + '…' : v;
    const s = JSON.stringify(v);
    return s && s.length > 400 ? s.slice(0, 400) + '…' : String(s);
  } catch (_) { return String(v); }
}

// ── 模板.js（drpy 的"规则模板字典"模块）─────────────────────────────────────
//
// ★ 第三层真 P0，也是三层里最狠的一层：`init_test发生错误:模板 is not defined`
//
//   drpy2.min.js 里 **引擎自己的 init()** 第一句就是：
//       function init(ext){ console.log("init"); try{ let muban=模板.getMubans(); ...
//   而 `模板` 来自被我们剥掉的那条 ES import：
//       import 模板 from"../js/模板.js";
//   ⇒ 剥完 import 之后 `模板` 成了**未定义标识符**，于是
//   **任何源**——哪怕它自己一行模板都不用——在 init 阶段就全灭。
//   这条和"源烂了"长得一模一样（都表现为搜不出东西），所以最容易被误判。
//
//   修法：把 `模板.js` 一起 vendor 进来（存成 ASCII 文件名 `muban.js`，避开
//   Windows/Git 对非 ASCII 文件名的编码坑），同样剥掉它的 `export default`，
//   求值成模块对象后挂到沙箱全局 `模板` 上。
let mubanCode = null;
function getMubanCode() {
  if (mubanCode) return mubanCode;
  const p = path.join(VENDOR, 'muban.js');
  if (!fs.existsSync(p)) {
    throw new Error('缺少 vendor/drpy/muban.js（drpy 模板.js）——引擎 init() 会因 `模板 is not defined` 全线失败');
  }
  let code = fs.readFileSync(p, 'utf8');
  code = code.replace(/\bexport\s+default\s*/g, 'var __muban_exports = ');
  code = code.replace(/\bexport\s*(\{[^}]*\})\s*;?/g, 'var __muban_exports = $1;');
  code = code.replace(/\bexport\s+(function|const|let|var|class)\b/g, '$1');
  mubanCode = code;
  return code;
}

function buildSandbox() {
  // ★ 第二层真 P0 —— `pdfh is not defined`：
  //   `drpy2.min.js` 里 `const defaultParser={pdfh:pdfh,pdfa:pdfa,pd:pd}` 引用的这三个函数，
  //   在原版 drpy 里是**宿主 App 侧 JNI 提供的原生 DOM 解析能力**，引擎文件内**从未定义**
  //   （只有 `var _pdfh; var _pdfa; var _pd;` 三个空声明等着被赋值）。
  //   于是这句 const 求值时就抛 ReferenceError → **影视引擎依然一行都跑不了**。
  //   这里用 `drpy-host.js`（cheerio 版）把 pdfh/pdfa/pd 以及 print/log 补齐注入。
  //
  //   注入顺序是安全的：引擎里 `var fetch; var print; var log;` 都是**无初始化声明**，
  //   按规范不会覆盖已存在的全局属性，所以注入值能活下来。
  const logs = [];
  const pushLog = (...a) => { if (logs.length < 200) logs.push(a.map(brief).join(' ')); };
  const sandbox = {
    console: { log: pushLog, warn: pushLog, error: pushLog, info: pushLog, debug: pushLog },
    fetch, URL, URLSearchParams, TextEncoder, TextDecoder,
    atob: (s) => Buffer.from(s, 'base64').toString('binary'),
    btoa: (s) => Buffer.from(s, 'binary').toString('base64'),
    setTimeout, clearTimeout, JSON, Math, Date, RegExp, Error, Promise,
    cheerio: null, CryptoJS: null, gbkTool: null,
    muban: null, 模板: null,
    __result: null, __logs: logs, rule: undefined
  };
  Object.assign(sandbox, drpyHost.hostGlobals({
    log: pushLog,
    httpTimeoutMs: Number(process.env.TH_DRPY_HTTP_TIMEOUT_MS) || 12000,
    localStorePath: path.join(__dirname, 'data', 'drpy-local.json'),
  }));
  vm.createContext(sandbox);
  // 依赖: crypto-js(UMD挂全局) + gbk
  try { vm.runInContext(fs.readFileSync(path.join(VENDOR, 'crypto-js.js'), 'utf8'), sandbox, { timeout: 5000 }); } catch (e) {}
  try { vm.runInContext(fs.readFileSync(path.join(VENDOR, 'gbk2.js'), 'utf8'), sandbox, { timeout: 5000 }); } catch (e) {}
  // 模板.js → 沙箱全局 `模板`（引擎 init() 硬依赖，见上方注释）
  //   它用 `Object.assign` 等 ES5 特性做字典合并，本身自带 polyfill；
  //   求值后取 `__muban_exports`（由 export default 改写而来）挂到两个名字上：
  //   `模板` 给引擎 init()，`muban` 兼容少数源里直接写 `muban` 的写法。
  try {
    vm.runInContext(getMubanCode(), sandbox, { timeout: 5000 });
    const ex = sandbox.__muban_exports;
    if (!ex || typeof ex.getMubans !== 'function') {
      throw new Error('muban.js 未导出 getMubans()');
    }
    sandbox.模板 = ex;
    sandbox.muban = ex;
  } catch (e) {
    throw new Error('drpy 模板模块加载失败: ' + e.message);
  }
  // cheerio 注入(npm版API与浏览器版兼容)
  // ★ 关键：drpy 用的是 App 内**改造过的 cheerio**，它在 cheerio 对象上额外挂了
  //   `jinja2()` 模板渲染器，引擎里 `cheerio.jinja2(rule.homeUrl,{rule})` 和
  //   `cheerio.jinja2(url,{fl})` 都直接调它。npm 的原版 cheerio 没有这个属性 →
  //   `cheerio.jinja2 is not a function`（同样是 init 阶段就死，每个源都踩）。
  sandbox.cheerio = Object.assign({}, require('cheerio'), { jinja2: drpyHost.jinja2 });
  return sandbox;
}

// 在沙箱里跑源+调方法。method: init/home/search/detail/play/category
//
// ★ 默认走**一次性子进程**（`drpy-runner.js`），原因见那个文件的文件头：
//   ① drpy 的 `req()` 是同步 HTTP，实现它要阻塞线程 —— 在主进程里跑会把
//      整个后端的请求处理冻住；
//   ② 第三方源里逃逸的异步异常会直接结束 Node 进程 —— 实测被源打断过。
//   子进程里出任何事，都只是"这一条源失败"。
//   设 `TH_DRPY_INPROC=1` 可回到进程内执行（子进程自己用这个开关，
//   另外也方便本地调试单条源）。
async function runSource(sourceCode, method, args = []) {
  if (process.env.TH_DRPY_INPROC === '1') return runSourceInProc(sourceCode, method, args);
  const timeoutMs = Number(process.env.TH_DRPY_RUN_TIMEOUT_MS) || 30000;
  return runInChild({ code: sourceCode, method, args }, timeoutMs);
}

// 把作业丢给一次性子进程，拿回 JSON 结果。父进程全程只等回调，不阻塞事件循环。
function runInChild(job, timeoutMs) {
  const { spawn } = require('child_process');
  return new Promise((resolve) => {
    let child;
    try {
      child = spawn(process.execPath, [path.join(__dirname, 'drpy-runner.js')], {
        stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true,
      });
    } catch (e) {
      return resolve({ error: 'drpy 子进程启动失败: ' + e.message });
    }
    let out = '', err = '', done = false;
    const finish = (v) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      try { child.kill(); } catch (_) { }
      resolve(v);
    };
    const timer = setTimeout(() => finish({ error: 'drpy 源执行超时(' + timeoutMs + 'ms)' }), timeoutMs);
    child.stdout.on('data', (d) => { out += d; });
    child.stderr.on('data', (d) => { err += d; });
    child.on('error', (e) => finish({ error: 'drpy 子进程错误: ' + e.message }));
    child.on('close', (code) => {
      const line = out.trim().split('\n').filter(Boolean).pop();
      if (!line) {
        return finish({ error: `drpy 子进程无输出(exit ${code})` + (err ? ' | stderr: ' + err.slice(-200) : '') });
      }
      try {
        const j = JSON.parse(line);
        finish(j.ok === false ? { error: j.error } : j.result);
      } catch (_) {
        finish({ error: 'drpy 子进程输出非 JSON: ' + line.slice(0, 160) });
      }
    });
    child.stdin.on('error', () => { });
    child.stdin.end(JSON.stringify(job));
  });
}

/**
 * ★ 引擎侧的「词法降级」补丁 —— 修 `Identifier 'd' has already been declared`
 *
 * 现场：UrleBird / Anime1 这类源报这条错，**但它们的源代码里根本没有 `let d`**。
 * 真因在引擎：`searchParse()` 自己写着 `let d=[];`，随后对源脚本的 `js:` 规则做
 * **直接 eval**（`eval(p.replace("js:",""))`），而那条 js 规则里写的是 `var d=[];`。
 * 按规范，直接 eval 里的 `var` 声明要落进**外层函数的变量环境**，
 * 与同一函数里已存在的**词法声明** `let d` 冲突 → 整个脚本在解析阶段就 SyntaxError。
 *
 * 也就是说：这是**引擎的命名太随意**污染了源脚本的命名空间，跟源质量无关。
 * 修法是在引擎代码里把冲突的那个 `let/const X = ` 降级成 `var X = ` ——
 * 对引擎自身语义无影响（这些 `d` 本来就是函数级使用，不在块内共享），
 * 但 eval 进来的 `var d` 就能与它合并成同一个绑定，冲突消失。
 *
 * 做成自适应：捕获到错误再从错误信息里取出标识符名、打补丁、重建沙箱重试，
 * 这样不用预先枚举引擎里所有短名，也不会为了没冲突的源付出代价。
 */
const lexicalPatches = new Set();
function patchEngineLexical(name) {
  const id = String(name).replace(/[^A-Za-z0-9_$]/g, '');
  if (!id || lexicalPatches.has(id)) return false;
  const before = getEngineCode();
  const re = new RegExp('\\b(let|const)(\\s+)' + id + '(\\s*=)', 'g');
  const after = before.replace(re, 'var$2' + id + '$3');
  if (after === before) return false;
  engineCode = after;          // 覆盖缓存，后续沙箱都用打过补丁的引擎
  lexicalPatches.add(id);
  return true;
}
function lexicalPatchNames() { return [...lexicalPatches]; }

/** 进程内执行路径（只在子进程里或显式 TH_DRPY_INPROC=1 时使用）。 */
async function runSourceInProc(sourceCode, method, args = []) {
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

  let sandbox = null;
  for (let attempt = 0; attempt < 4; attempt++) {
    sandbox = buildSandbox();
    try {
      vm.runInContext(getEngineCode(), sandbox, { timeout: 8000 });
    } catch (e) {
      throw new Error('引擎加载失败: ' + e.message);
    }
    try {
      vm.runInContext(sourceCode + entry, sandbox, { timeout: 20000 });
      break;
    } catch (e) {
      const m = /Identifier '([^']+)' has already been declared/.exec(String(e.message || ''));
      // 命中「引擎 `let` 与源脚本 eval 里的 `var` 撞名」→ 给引擎降级一格后重建重试
      if (m && patchEngineLexical(m[1])) continue;
      return { error: '源执行失败: ' + e.message, logs: sandbox.__logs.slice(-20) };
    }
  }
  let r = sandbox.__result;
  // drpy 的 search/detail 多是 async → __result 是 Promise，等它落地；
  // 并给 Promise 挂超时兜底，别让一个卡死的源把整条搜索拖住。
  if (r && typeof r.then === 'function') {
    r = await Promise.race([
      r.then(v => v, e => ({ error: String((e && e.message) || e) })),
      new Promise(res => setTimeout(() => res({ error: '源执行超时(20s)', logs: sandbox.__logs.slice(-20) }), 20000)),
    ]);
  }
  // ★ drpy 的引擎方法**统一返回 JSON 字符串**（`searchParse` 里就是 `return "{}"`，
  //   正常分支也是 `JSON.stringify(...)`）。不在这里解开，下游 `irSearch` 拿到的是
  //   一个字符串，`result.list` 恒 undefined → **每条搜索都"成功但 0 条"**，
  //   看起来像"源烂了/没结果"，其实是我们没读懂契约。
  if (typeof r === 'string') {
    const t = r.trim();
    if (t.startsWith('{') || t.startsWith('[')) {
      try { r = JSON.parse(t); } catch (_) { /* 保持原样，交给下游报错 */ }
    }
  }
  if (r && typeof r === 'object' && r.error) {
    r = { ...r, logs: sandbox.__logs.slice(-20) };
  }
  // 排障开关：`TH_DRPY_VERBOSE=1` 时把源日志一并带出来。
  // 为什么需要：源"成功但 0 条"（返回 `{}`）时看不出是没发请求还是解析没命中，
  // 而这两者的修法完全不同 —— 只有把沙箱日志摊开才能区分。
  if (process.env.TH_DRPY_VERBOSE && r && typeof r === 'object') {
    r = { ...r, logs: sandbox.__logs.slice(-40) };
  }
  return r;
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
