// ThirdHub v4 书源引擎 M1: 解析 Legado 格式书源(Legado JSON + 链式规则 + XPath子集 + @js沙箱)
// 依赖: cheerio (npm i)
const cheerio = require('cheerio');
const vm = require('vm');
// ★第十六轮：书源规则里的 URL 是**外部输入**（导入的书源 JSON），
// 所以引擎这一层也必须过出站地址准入 —— 否则一个恶意书源就能让后端去摸
// `http://127.0.0.1:...` 或云元数据。见 ssrf-guard.js 顶部说明。
const ssrf = require('./ssrf-guard.js');

// ─── 迷你XPath → cheerio 选择器 ───
function xpathToCheerio(xp) {
  let s = xp.trim();
  // 取尾部 /text() /@attr 先剥掉
  let take = null;
  let m = s.match(/\/(text\(\)|html\(\)|@[\w-]+)$/);
  if (m) { take = m[1]; s = s.slice(0, -m[0].length); }
  // 去掉绝对路径前缀
  s = s.replace(/^\/+(html\/)?(body\/)?/i, '');
  // //tag[@attr='v'] → tag[attr=v]
  s = s.replace(/\/\/?([\w*]+)\[@([\w-]+)=['"]([^'"]*)['"]\]/g, (mm, tag, attr, val) => {
    tag = tag === '*' ? '' : tag;
    return ` ${tag}[${attr}='${val}']`;
  });
  // ★2026-11-13 `//a[text()='全文阅读']`：按文本选节点，Legado 书源里很常见
  //   （飞速小说网的 tocUrl 就是它）。原样丢给 cheerio 会报
  //   `Attribute selector didn't terminate` —— 这个异常还会把整本书的详情接口打成 500。
  //   cheerio 没有 text() 伪类，用 :contains() 近似（取第一个包含该文本的节点）。
  s = s.replace(/\[\s*text\(\)\s*=\s*['"]([^'"]+)['"]\s*\]/g, (mm, v) => `:contains('${v}')`);
  s = s.replace(/\[\s*contains\(\s*text\(\)\s*,\s*['"]([^'"]+)['"]\s*\)\s*\]/g, (mm, v) => `:contains('${v}')`);
  // //tag[1] → tag 第一个(记录索引)
  s = s.replace(/\/\/?([\w*]+)\[(\d+)\]/g, (mm, tag, idx) => ` __IDX_${tag}_${idx} `);
  // //tag → tag
  s = s.replace(/\/\/?([\w*]+)/g, ' $1 ');
  // //*[@class='x'] 已在上面处理; 单独 //classXxx 类名简写 (Legado xpath 常用 //div.class 或 //xxx)
  s = s.replace(/\s([a-zA-Z][\w-]*)\.([\w-]+)/g, ' $1.$2');
  // 清理
  s = s.trim().replace(/\s+/g, ' ').replace(/__/g, '__');
  return { selector: s, take };
}

// ─── Legado 链式规则解析: "class.list@tag.a.0@text" / "id.content@html" ───
function parseChain(rule) {
  if (!rule) return null;
  rule = String(rule).trim();
  // ★2026-11-09：`||` 是 Legado 的「或」分隔符 —— 多个候选规则任取一个成功的。
  //   旧代码直接在整条规则上 split('@')，于是 `class.novelslist2@ul@li||class.l@li`
  //   被切成 `li||class.l` 当作一个 CSS 选择器丢给 cheerio，
  //   直接抛 `Column combinators are not yet supported by css-select`，
  //   整个源搜出 0 条（乐文小说① 就是这种）。
  //   这里只取第一个非空分支（绝大多数源第一分支就是对的，第二分支是改版备份）；
  //   真正的「逐个回退」由调用方 pickByRule 负责，不在语法层做。
  if (rule.includes('||')) {
    const first = rule.split('||').map((x) => x.trim()).filter(Boolean)[0];
    if (first) rule = first;
  }
  // ★2026-11-13 `&&` 是 Legado 的「并且」：多段规则都算命中，结果合并。
  //   本引擎原来完全不认，于是 `xxx && .book-tag` 会被当成**一个**选择器丢给 cheerio，
  //   报 `Unmatched selector: &&.book-tag`，整个字段取值抛异常 → 源废掉
  //   （轻之文库就是这种）。这里退化为「取第一个非空分支」，先保证不崩、能出值。
  if (rule.includes('&&')) {
    const parts = rule.split('&&').map((x) => x.trim()).filter(Boolean);
    if (parts.length > 1) rule = parts[0];
  }
  // `@css:` / `css:` 前缀（Legado 显式声明用 CSS 选择器）不是选择器的一部分
  rule = rule.replace(/^@?css:/, '');
  const segs = rule.split('@').map(s => s.trim());
  const ops = [];
  for (const seg of segs) {
    if (seg === 'text' || seg === 'text()') ops.push({ op: 'text' });
    else if (seg === 'html' || seg === 'html()') ops.push({ op: 'html' });
    else if (seg === 'textNodes' || seg === 'textNodes()') ops.push({ op: 'textNodes' });
    else if (seg.startsWith('attr.')) ops.push({ op: 'attr', name: seg.slice(5) });
    else if (/^(href|src|alt|title)$/.test(seg)) ops.push({ op: 'attr', name: seg });
    else if (seg.startsWith('js:') || seg.startsWith('@js:')) ops.push({ op: 'js', code: seg.replace(/^@?js:/, '') });
    else {
      // 选择段: tag.a.0 | class.xxx | id.xxx | .xxx | 裸名
      let sel = seg;
      let idx = null;      // 取第 n 个
      let ridx = null;     // 反向索引（[-1] = 最后一个）
      let excl = null;     // 排除区间 [起, 止]

      // ★2026-11-13 Legado 的**索引/排除语法**。真实书源里极常见，本引擎原来完全不认，
      //   于是 `li!0` 被当成一个叫 `li!0` 的 CSS 选择器丢给 cheerio → 非法选择器 →
      //   要么抛异常要么 0 命中 → 整个源永远 0 条。
      //   实例：飞速小说网的 bookList 是 `div.novelslist3@ul@li!0`
      //   （页面里明明有 50 条结果，引擎却 0 条），就是死在这一行。
      //   语义（对齐 Legado）：
      //     li!0     排除第 0 个        li!0:-1   排除第 0 个和最后一个
      //     li[n]    取第 n 个          li[-1]   取最后一个
      //     li[!0]   排除第 0 个        li.1:3   取第 1~3 个（区间）
      let mm;
      let rangeSel = null;
      let exclList = null;
      if ((mm = sel.match(/^(.*?)\[\s*!\s*(-?\d+(?::\s*-?\d+)*)\s*\]$/))) {
        sel = mm[1]; exclList = String(mm[2]).split(':').map(Number);
      } else if ((mm = sel.match(/^(.*?)\[\s*(-?\d+)\s*\]$/))) {
        sel = mm[1];
        const v = Number(mm[2]);
        if (v < 0) ridx = v; else idx = v;
      } else if ((mm = sel.match(/^(.*?)!\s*(-?\d+(?::\s*-?\d+)*)$/))) {
        sel = mm[1]; exclList = String(mm[2]).split(':').map(Number);
      } else if ((mm = sel.match(/^(.*?)\.(-?\d+(?::\s*-?\d+)*)$/))) {
        sel = mm[1];
        const ps = String(mm[2]).split(':').map(Number);
        if (ps.length === 1) { if (ps[0] < 0) ridx = ps[0]; else idx = ps[0]; }
        else rangeSel = [Math.min.apply(null, ps), Math.max.apply(null, ps)];
      }

      let alt = null;                                  // 裸名的兼容解释（见下）
      if (sel.startsWith('class.')) sel = '.' + sel.slice(6);
      else if (sel.startsWith('id.')) sel = '#' + sel.slice(3);
      else if (sel.startsWith('tag.')) sel = sel.slice(4);
      else if (sel.startsWith('.') || sel.startsWith('#')) { /* 保持 */ }
      else if (/^[\w-]+$/.test(sel)) alt = '.' + sel;
      ops.push({ op: 'sel', sel, idx, ridx, excl: exclList, range: rangeSel, alt });
    }
  }
  return ops;
}

// ─── JSONPath 迷你: $.a.b[0]，并支持 Legado 常见的递归写法 `$..key[*]` ───
function miniJsonPath(obj, path) {
  if (!path) return null;
  let p = String(path).trim();
  if (p.startsWith('$')) p = p.slice(1);
  // ★2026-11-09：`$..list[*]` 这类「递归下降」在真实书源里非常常见
  //   （9x阅读器 的 bookList 就是它）。旧实现只会按键名逐层走，遇到 `..` 直接返回 null，
  //   于是整个源永远 0 条。这里在整棵树上收集所有同名 key 的值并展平。
  if (p.startsWith('..')) {
    const key = p.slice(2).replace(/\[.*?\]/g, '').split(/[.[]/).filter(Boolean)[0];
    if (!key) return null;
    const out = [];
    const walk = (v) => {
      if (v == null) return;
      if (Array.isArray(v)) { for (const x of v) walk(x); return; }
      if (typeof v === 'object') {
        for (const [k, vv] of Object.entries(v)) {
          if (k === key) out.push(vv);
          walk(vv);
        }
      }
    };
    walk(obj);
    const flat = out.flat();
    return flat.length ? flat : null;
  }
  const keys = p.replace(/\[(\d+)\]/g, '.$1').split('.').filter(Boolean);
  let cur = obj;
  for (const k of keys) {
    if (cur == null) return null;
    cur = cur[/^\d+$/.test(k) ? Number(k) : k];
  }
  return cur;
}

// ─── ## 后处理（Legado 规则语义）───
// 规则形如 `选择器##正则`     → 先按前置规则取值，再用正则**删除**匹配部分
//          `选择器##正则###替换` → 把匹配部分替换为指定内容
// ★2026-09-25 补上：此前 engine.js **完全没有 ## 语义**，于是形如
//   `h2@text##.*_|【.*】` 的规则会被整条当成「一个叫 `text##.*_|【.*】` 的 class 选择器」，
//   cheerio 直接抛 `Expected name, found ##...`；or 即使不抛也永远取不到值。
//   实测：29 条「健康源」里有 **22 条**用了 ## —— 也就是说**大多数真实源在这个引擎上
//   根本走不完规则**（不是源站挂了，也不是源选得不对）。这是内容线「搜不到」的头号机械成因。
function splitPost(rule) {
  const s = String(rule);
  if (s.indexOf('##') < 0) return { body: s, posts: [] };
  // `###` 是「替换」分隔符，不能被 `##` 拆散 → 先占位再拆
  const SE = '\u0001';
  const parts = s.replace(/###/g, SE).split('##').map((p) => p.split(SE).join('###'));
  return { body: parts[0], posts: parts.slice(1) };
}

function applyPost(v, post) {
  if (v == null) return v;
  const p = String(post);
  if (!p || p.startsWith('{')) return v;              // `##{...}` 是配置段，不是替换
  if (/^\$\d+$/.test(p.trim())) return v;             // 孤立的 `$n` 不是可用正则：跳过，不猜语义
  let re = p, rep = '';
  const h = p.indexOf('###');
  if (h >= 0) { re = p.slice(0, h); rep = p.slice(h + 3); }
  try { return String(v).replace(new RegExp(re, 'g'), rep); } catch (e) { return v; }
}

/// 把 `##` 之后的所有段依次作用到 v 上（顺序即写法顺序）
function applyPosts(v, parts) {
  for (const p of parts) v = applyPost(v, p);
  return v;
}

// ─── 在一组 cheerio 元素上执行规则链 ───
function applyRuleRaw($root, elements, rule, context) {
  // 兜底：规则里任何解析异常（非法选择器 / 正则写错 / js 抛错）
  // 都只让「这个字段取不到值」，绝不让整个书籍详情/目录接口 500。
  try { return applyRuleRawUnsafe($root, elements, rule, context); } catch (e) { return null; }
}

function applyRuleRawUnsafe($root, elements, rule, context) {
  if (rule == null) return null;
  const rs = String(rule).trim();
  // XPath 规则: 直接换算选择器
  if (rs.startsWith('/')) {
    const xp = xpathToCheerio(rs);
    const scope = elements && elements.find ? elements : $root.root();
    if (!xp.selector) return null;
    let found = scope.find(xp.selector);
    if (!found.length && elements && elements.is && elements.is(xp.selector)) found = elements;
    if (!found.length) return null;
    const first = found.first();
    if (xp.take === 'text()') return first.text().trim();
    if (xp.take === 'html()') return first.html();
    if (xp.take && xp.take.startsWith('@')) return first.attr(xp.take.slice(1)) || null;
    return first.text().trim();
  }
  const ops = Array.isArray(rule) ? rule : parseChain(rule);
  if (!ops) return null;
  let cur = elements;
  for (let oi = 0; oi < ops.length; oi++) {
    const o = ops[oi];
    if (cur == null) return null;
    if (o.op === 'sel') {
      if (cur && cur.find) {
        let n = safeFind(cur, o.sel) || cur.find('__none__');
        // ★2026-09-25 裸名双解：Legado 的链式规则里，裸段是**选择器**（裸名即标签名），
        //   本引擎原来把它一律当 class（`a`→`.a`、`h2`→`.h2`），于是形如
        //   `.bookdesc@a@href` / `.bookdesc@h2@text` 这种极常见写法永远取空 ——
        //   而 `search()` 末尾 `filter(b => b.name && b.bookUrl)` 会把它们全丢掉，
        //   表现就是「站点 200、页面里明明有关键词、引擎却 0 条」。
        //   这里改成「先按标签名找，找不到再退回 class」：严格是超集，
        //   原本靠 class 命中的源不受影响（标签名找不到时会退回原行为）。
        if (!n.length && o.alt) n = safeFind(cur, o.alt) || n;
        // ★2026-09-25 首段自匹配：真实源常把 bookList 的选择器在字段规则里**再写一遍**
        //   （bookList=`class.tui_1_item`，name=`class.tui_1_item@a@text`）。
        //   而 find() 只搜**后代**，行元素自身符合时取空 → 字段全空 → 被 filter 丢掉 → 0 条。
        //   XPath 分支本来就有这个兜底，链式分支漏了，这里补齐。
        if (!n.length && oi === 0 && cur.is) {
          if (cur.is(o.sel) || (o.alt && cur.is(o.alt))) n = cur.first();
        }
        if (o.idx != null && n.length) n = n.eq(o.idx);
        // 反向索引（[-1] 等）：Legado 里常用来取「最后一个」
        if (o.ridx != null && n.length) {
          const k = o.ridx < 0 ? n.length + o.ridx : o.ridx;
          n = k >= 0 && k < n.length ? n.eq(k) : n.slice(0, 0);
        }
        // 区间（li.1:3）：取第 a~b 个（含两端）
        if (o.range && n.length) n = n.slice(o.range[0], o.range[1] + 1);
        // 排除（!0 / !0:-1）：剔除指定下标，负数按「倒数」解释
        if (o.excl && n.length) {
          const len = n.length;
          const drop = new Set();
          for (const t of o.excl) { const k = t < 0 ? len + t : t; if (k >= 0 && k < len) drop.add(k); }
          if (drop.size) n = n.filter((i) => !drop.has(i));
        }
        cur = n;
      } else return null;
    } else if (o.op === 'text') {
      if (cur == null) return null;
      if (cur.text) return cur.text().trim();
      return String(cur).trim();
    } else if (o.op === 'html') {
      return cur && cur.html ? cur.html() : null;
    } else if (o.op === 'textNodes') {
      // Legado 的 textNodes：只取**直接文本节点**（不含子元素文字），多段以换行连接。
      // 此前未支持 → 段名 'textNodes' 被当成 class 名 → 静默取空（不报错，最难查）。
      if (cur == null || !cur.contents) return null;
      const tns = cur.contents().toArray().filter((el) => el.type === 'text')
        .map((el) => String(el.data || '').trim()).filter(Boolean);
      return tns.length ? tns.join('\n') : null;
    } else if (o.op === 'attr') {
      if (cur == null || !cur.attr) return null;
      const v = cur.attr(o.name);
      return typeof v === 'string' ? v : null;
    } else if (o.op === 'js') {
      try {
        const sandbox = {
          result: cur && cur.text ? cur.text() : cur,
          $: cur, source: context.source, baseUrl: context.baseUrl,
          key: context.key || '', java: {
            ajax: () => '', base64: (s) => Buffer.from(s).toString('base64'),
            base64Decode: (s) => Buffer.from(s, 'base64').toString(),
            get: (o, k) => o ? o[k] : null
          },
          console
        };
        vm.createContext(sandbox);
        return vm.runInContext(o.code, sandbox, { timeout: 2000 });
      } catch (e) { return null; }
    }
  }
  if (cur && cur.text) return cur.text().trim();
  return cur;
}

// ─── 规则入口：先剥 ## 后处理，再走原链，最后把后处理按顺序作用到结果上 ───
//（数组形态的规则是内部调用，不含 ## 语义，直接透传）
function applyRule($root, elements, rule, context) {
  if (rule == null) return null;
  if (Array.isArray(rule)) return applyRuleRaw($root, elements, rule, context);
  const { body, posts } = splitPost(rule);
  let v;
  if (String(body).trim() === '') {
    // 规则以 ## 开头（如 `##作者.([^<\s]+)##$1###`）：Legado 语义是「先取当前元素自身文本」
    v = (elements && elements.text) ? elements.text().trim() : null;
  } else {
    v = applyRuleRaw($root, elements, body, context);
  }
  return posts.length ? applyPosts(v, posts) : v;
}

// ─── 统一取规则(兼容 ruleSearch.name 等字段; 支持 put(key, rule) 简化忽略) ───
function rget(ruleObj, key) {
  if (!ruleObj) return null;
  const v = ruleObj[key];
  return v != null ? v : null;
}

// ─── HTTP 抓取(伪装UA, 超时) ───
async function fetchPage(url, source, method, body) {
  const headers = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
    'Accept': 'text/html,application/xhtml+xml,*/*;q=0.8',
    'Accept-Language': 'zh-CN,zh;q=0.9'
  };
  // 书源自定义header(可为JSON字符串或"Key: Value"多行)
  const h = source && source.header;
  if (h) {
    try { if (h.trim().startsWith('{')) Object.assign(headers, JSON.parse(h)); } catch (e) {}
    if (h.includes(':') && !h.trim().startsWith('{')) {
      for (const line of h.split('\n')) {
        const i = line.indexOf(':');
        if (i > 0) headers[line.slice(0, i).trim()] = line.slice(i + 1).trim();
      }
    }
    // header里若单独给了UA则覆盖
    if (headers['User-Agent'] || headers['user-agent'])
      headers['User-Agent'] = headers['User-Agent'] || headers['user-agent'];
  }
  // 失败重试(仅网络错误/5xx, 4xx不重试)
  // ★2026-11-13 次数与单次超时都改为可配：批量探测要跑 2000+ 个源，
  //   "12s × 2 次 = 单源最坏 24s" 会让全量探测永远跑不完。
  const maxTry = Math.max(1, Number(process.env.TH_FETCH_RETRY) || 2);
  for (let attempt = 0; attempt < maxTry; attempt++) {
    const r = await tryFetch(url, headers, method, body);
    // 被地址准入门拦下的**不重试**：这是策略判定，不是网络抖动，重试只会白等 12s
    if (r.blocked) return r;
    if (r.ok || (r.status && r.status < 500)) return r;
  }
  return { ok: false, url, html: '', json: null };
}

async function tryFetch(url, headers, method, body) {
  // ★第十六轮：改成 ssrf.safeFetch —— 它把 `redirect` 从 `follow` 换成**手动逐跳**，
  // 每一跳都重新跑地址准入。只判初始 URL 是不够的：源站回一个
  // `302 Location: http://169.254.169.254/` 就能绕过（SSRF 最常见的绕过手法）。
  // 超时仍由 safeFetch 的 timeoutMs 统一负责，故这里不再需要 AbortController。
  try {
    const opts = { headers, timeoutMs: Math.max(3000, Number(process.env.TH_FETCH_TIMEOUT) || 12000), maxRedirects: 5 };
    if (method === 'POST') { opts.method = 'POST'; opts.body = body || ''; }
    const resp = await ssrf.safeFetch(url, opts);
    const buf = await resp.arrayBuffer();
    let text = new TextDecoder('utf-8').decode(buf);
    const m = text.match(/charset=["']?([\w-]+)/i);
    if (m && !/utf-?8/i.test(m[1])) {
      try { text = new TextDecoder(m[1]).decode(buf); } catch (e) {}
    }
    // JSON自动探测(书源JSON接口)
    let json = null;
    try { json = JSON.parse(text); } catch (e) {}
    return { ok: resp.ok, url: resp.url, html: text, json };
  } catch (e) {
    // 被地址准入门拦掉：**不让它冒泡**，而是当成"这一条源失败"返回。
    // 理由：一个恶意/写错的源不该让整次聚合搜索 500，它只该被记一次失败、
    // 然后在健康度里被摘掉（这条链路见 routes-search.js 的 health 记账）。
    return { ok: false, url, html: '', json: null,
      blocked: ssrf.isSsrfBlocked(e), error: String((e && e.message) || e) };
  }
}

function absUrl(url, base) {
  if (!url) return null;
  try { return new URL(url, base).href; } catch (e) { return url; }
}

// ─── 安全查找 ───
// 真实书源的规则里经常带**非法 CSS**（改版残留、写错的属性选择器、旧语法）。
// cheerio 遇到就抛（例如 `Attribute selector didn't terminate`），
// 而调用链没有一层接住 → 整个 /v1/book 详情接口变成 500，
// 表现成「搜到了书，点开却报错」。这里把「单条规则写坏」降级成「这条取不到值」，
// 而不是让整个请求失败。
function safeFind(cur, sel) {
  if (!cur || !cur.find || !sel) return null;
  try { return cur.find(sel); } catch (e) {
    try { return cur.slice(0, 0); } catch (e2) { return null; }
  }
}

// ═══ 书源生命周期 ═══

// ─── 自动识别引擎（兜底）：不依赖书源里写死的选择器 ───
//
// 为什么需要它：书源里的 bookList/name/bookUrl 是对着**某个年代的页面结构**写的。
// 站点一改版（换域名、改模板、加 SSR 壳），选择器就全部失效 —— 但站点本身活得好好的。
// 实测：飞速小说网页面里有 50 条搜索结果，书源规则只因为写了 `li!0` 就整源 0 条；
// 书荒部落/话本小说则是站点自己返回「0 条结果」。
// 靠「逐个人工修选择器」不可能覆盖 2000+ 源，所以这里做一层**结构无关**的兜底：
//
//   锚点 = 关键词本身。搜索结果里的书名几乎必然包含搜索词（搜"斗罗大陆"→"斗罗大陆IV终极斗罗"）。
//   于是：找出页面上所有**文本命中关键词**的链接 → 按父容器签名分组 → 取最大的一组当结果列表。
//
// 这样即使站点大改版，只要结果还显示在页面上，就能抓出来。
function searchAuto($, key, baseUrl) {
  const k = String(key || '').replace(/\s+/g, '').trim();
  if (k.length < 2) return [];
  // 关键词的前缀（去掉末字），用于匹配「斗罗大陆之…」「斗罗大陆IV…」这类衍生标题
  const pre = k.length >= 3 ? k.slice(0, k.length - 1) : k;

  const cands = [];
  $('a').each((i, a) => {
    const $a = $(a);
    const t = $a.text().replace(/\s+/g, ' ').trim();
    if (t.length < 2 || t.length > 70) return;
    const tk = t.replace(/\s+/g, '');
    if (!tk.includes(k) && !tk.includes(pre)) return;
    const href = $a.attr('href');
    if (!href || /^javascript:/i.test(href) || href === '#' || href === '/') return;
    // 排除「搜索/首页」这类导航链接（它们的文本偶尔也带关键词）
    if (/^(搜索|搜|首页|登录|注册|书架|分类|排行|更多|全部)$/.test(t)) return;
    const p = $a.parent()[0];
    const sig = p ? p.tagName + '|' + ((p.attribs && p.attribs.class) || '') : 'root';
    cands.push({ t, href, sig, $a });
  });
  if (!cands.length) return [];

  // 同一父容器签名的链接聚成一组，取元素最多的那组当列表
  const groups = new Map();
  for (const c of cands) {
    const arr = groups.get(c.sig) || [];
    arr.push(c);
    groups.set(c.sig, arr);
  }
  let best = [];
  for (const arr of groups.values()) if (arr.length > best.length) best = arr;
  if (!best.length) return [];

  const seen = new Set();
  const out = [];
  for (const c of best) {
    let url;
    try { url = new URL(c.href, baseUrl).href; } catch (e) { continue; }
    if (seen.has(url)) continue;
    seen.add(url);
    // 作者/简介：从最近的「行级容器」里找，取不到不影响书名和链接
    let rowText = '';
    try {
      const row = c.$a.closest('li,tr,dl,dd,div,p,article,section').first();
      if (row && row.length) rowText = row.text().replace(/\s+/g, ' ').trim();
    } catch (e) {}
    const am = rowText.match(/作\s*者[:：]?\s*([^\s|，,、/]{2,14})/);
    const cover = (() => {
      try {
        const img = c.$a.find('img').first();
        return img.length ? img.attr('src') || img.attr('data-src') || null : null;
      } catch (e) { return null; }
    })();
    out.push({
      name: c.t,
      author: am ? am[1] : '',
      coverUrl: cover ? absUrl(cover, baseUrl) : null,
      intro: rowText.slice(0, 160),
      kind: '',
      bookUrl: url,
      sourceId: baseUrl,
    });
  }
  return out.slice(0, 40);
}

async function search(source, key) {
  const rule = source.ruleSearch || {};
  let urlTpl = source.searchUrl || '';
  if (!urlTpl) return [];
  // POST配置: "url,{"method":"POST","body":"key={{key}}"}" 格式
  let method = 'GET', bodyTpl = null;
  const ci = urlTpl.indexOf(',{');
  if (ci > -1) {
    try {
      const conf = JSON.parse(urlTpl.slice(ci + 1));
      method = conf.method || 'GET'; bodyTpl = conf.body || null; urlTpl = urlTpl.slice(0, ci);
    } catch (e) {}
  }
  // ★2026-09-25 补齐搜索地址占位与尾部配置：
  //   此前只认 {{key}}/%s —— 而真实源里 {{page}} / {{pageIndex}} / {{pageSize}} /
  //   {{keyword}} / $keyword / $page 都是常见写法，不填就会带着字面量 `{{page}}` 去请求，
  //   站点按无效参数处理 → 返回空页 → 表现成「源明明是活的，引擎却永远 0 条」。
  //   另外 `url##{"charset":"gbk"}` 这种尾部配置也不是 URL 的一部分，必须剥掉再请求。
  urlTpl = urlTpl.replace(/##\{[\s\S]*\}\s*$/, '');
  const fillTpl = (t) => String(t)
    .replace(/\{\{key\}\}|\{\{keyword\}\}|%s|\$keyword/gi, encodeURIComponent(key))
    .replace(/\{\{page\}\}|\{\{pageIndex\}\}|\$page\b/gi, '1')
    .replace(/\{\{pageSize\}\}/gi, '20');
  let searchUrl = absUrl(fillTpl(urlTpl), source.bookSourceUrl);
  let body = bodyTpl ? fillTpl(bodyTpl) : undefined;
  if (bodyTpl && method === 'GET') method = 'POST';
  const resp = await fetchPage(searchUrl, source, method, body);
  const { html, url: finalUrl, json } = resp;
  const ctx = { source, baseUrl: source.bookSourceUrl, key };
  // JSON模式: bookList规则以$.开头
  const listRuleRaw = rget(rule, 'bookList');
  if (listRuleRaw && String(listRuleRaw).startsWith('$.')) {
    const list = miniJsonPath(json, listRuleRaw);
    if (!Array.isArray(list)) return [];
    const jpick = (item, k) => { const r = rget(rule, k); if (!r) return null;
      return String(r).startsWith('$.') ? miniJsonPath(item, r) : r; };
    return list.map(item => ({
      name: jpick(item, 'name'), author: jpick(item, 'author') || '',
      coverUrl: absUrl(jpick(item, 'coverUrl') || jpick(item, 'cover'), source.bookSourceUrl),
      intro: jpick(item, 'intro') || '', kind: jpick(item, 'kind') || '',
      bookUrl: absUrl(jpick(item, 'bookUrl'), source.bookSourceUrl),
      sourceId: source.bookSourceUrl
    })).filter(b => b.name && b.bookUrl);
  }
  const $ = cheerio.load(html);
  const list = resolveList($, listRuleRaw);
  const books = [];
  // 表头/非书籍文本黑名单：很多站的结果表格首行是「作品名称 最新章节 作者 更新时间 状态」，
  // `!0` 只能排除一行，thead+tbody 结构下会漏进来，表现成"第一条结果是作品名称"。
  const HEADER_RE = /^(作品名称|书名|小说名|书\s*名|作者|最新章节|更新时间|状态|阅读|分类|类别|操作|封面|简介|点击|推荐票|最新更新)$/;
  list.each((i, el) => {
    const $el = $(el);
    const pick = (k) => { const r = rget(rule, k); return r ? applyRule($, $el, r, ctx) : null; };
    const nm = pick('name');
    if (!nm || HEADER_RE.test(String(nm).trim())) return;
    // bookUrl 兜底顺序：规则值 → 行内第一个 a 的 href → 当前搜索页。
    // 注意**不能**无条件退回搜索页：那会让每一行都指向同一个 URL，
    // 点击后回到搜索结果（飞速小说网的表头行就是这样混进 50 条里的）。
    const rawUrl = pick('bookUrl');
    let bookUrl = absUrl(rawUrl, finalUrl);
    if (!bookUrl || bookUrl === finalUrl || bookUrl === searchUrl) {
      const inner = $el.find('a[href]').first().attr('href');
      bookUrl = inner ? absUrl(inner, finalUrl) : null;
    }
    if (!bookUrl) return;
    books.push({
      name: String(nm).trim(), author: pick('author') || '',
      coverUrl: absUrl(pick('coverUrl') || pick('cover'), source.bookSourceUrl),
      intro: pick('intro') || '', kind: pick('kind') || '',
      bookUrl,
      sourceId: source.bookSourceUrl
    });
  });
  return (() => {
    const cleaned = books.filter(b => b.name && b.bookUrl);
    if (cleaned.length) return cleaned;
    // 规则一条都没取到 —— 站点改版 / 选择器过期 / 结果在别处。
    // 走「关键词锚定」的自动识别，只要页面上还显示着结果就能抓到。
    const auto = searchAuto($, key, finalUrl || source.bookSourceUrl);
    return auto.length ? auto : cleaned;
  })();
}

// 统一列表解析: XPath 子集 或 Legado 链式(多段 sel 链)
function resolveList($, listRule) {
  try { return resolveListUnsafe($, listRule); } catch (e) { try { return $(); } catch (e2) { return null; } }
}

function resolveListUnsafe($, listRule) {
  if (!listRule) return $();
  const lr = String(listRule).trim();
  if (lr.startsWith('/')) { const { selector } = xpathToCheerio(lr); return $(selector); }
  let cur = $.root();
  for (const o of parseChain(lr)) {
    if (o.op === 'sel') {
      let n = safeFind(cur, o.sel) || cur.find('__none__');
      if (!n.length && o.alt) n = safeFind(cur, o.alt) || n;   // 裸名双解，与规则链同一语义
      // ★2026-09-25 自身匹配兜底：真实源常把同一选择器写两遍
      //   （chapterList=`class.hide@tag.a`，而 `<a>` 自己就带 class `hide`），
      //   这时 find() 只会搜后代 → 取空。这里退化成「在**当前这批元素里**筛出符合的」，
      //   保留全部命中项（不是只取第一个 —— 列表场景丢元素就等于丢章节）。
      if (!n.length) { const f = cur.filter ? cur.filter(o.sel) : null;
        if (f && f.length) n = f; else if (o.alt && cur.filter) { const f2 = cur.filter(o.alt); if (f2.length) n = f2; } }
      if (o.idx != null && n.length) n = n.eq(o.idx);
      if (o.ridx != null && n.length) {
        const k = o.ridx < 0 ? n.length + o.ridx : o.ridx;
        n = k >= 0 && k < n.length ? n.eq(k) : n.slice(0, 0);
      }
      if (o.range && n.length) n = n.slice(o.range[0], o.range[1] + 1);
      if (o.excl && n.length) {
        const l2 = n.length; const d2 = new Set();
        for (const t of o.excl) { const k = t < 0 ? l2 + t : t; if (k >= 0 && k < l2) d2.add(k); }
        if (d2.size) n = n.filter((i) => !d2.has(i));
      }
      cur = n;
    }
    else if (o.op === 'js') { /* 列表级 js 暂不应用, 元素级在 pick 里 */ }
    else break; // text/attr 不该出现在 bookList
  }
  return cur && cur.each ? cur : $();
}

// ─── 正文段落抽取（可单测的纯函数）───
// ★2026-09-25 修（阅读逐页 P1）：Legado 语义里 `<br>` 就是**换行**。
//   此前不做转换 → 用 `<br>` 分段的站点整章被切成 **1 段**（实测 365小说网：3707 字 / 段数 1），
//   端内渲染成一坨没有段落的文字墙（「能看但没法看」）。
//   另：`textNodes` 取到的多段文本本身以 `\n` 相连，也必须按**单换行**切。
function extractParas(htmlStr) {
  const htmlNorm = String(htmlStr).replace(/<br\s*\/?>/gi, '\n');
  const $clean = cheerio.load('<div>' + htmlNorm + '</div>');
  $clean('script,style,iframe,noscript,ins,svg').remove();
  $clean('div[class*=ad],div[id*=ad],p[class*=ad]').remove();
  const $cd = $clean('div');
  const paras = $cd.find('p').length
    ? $cd.find('p').map((i, el) => $clean(el).text().trim()).get().filter(Boolean)
    : $cd.text().split(/\n+/).map(s => s.trim()).filter(Boolean);
  return paras.filter(p => p.length > 1 && !/chaptererror|请收藏|天才一秒记住|www\.\w+\.\w{2,}$/i.test(p));
}

// ─── 正文兜底：取「最长的像正文的块」（可单测的纯函数）───
// ★2026-09-25 修：原来是在**未清洗**的文档上取最长文本块，于是
//   ① 页面内联 `<script>` 往往最长 → 取回一坨 JS 当正文（实测 酸奶漫画）；
//   ② 规则失效的源会兜底出**一整页导航**（实测 笔趣阁：4 万字全是「玄幻奇幻/修真武侠…」）。
//   现在先剥脚本，再要求候选块链接稀疏（`<a>` < 8）——正文容器链接极少，导航/目录动辄几十上百。
function largestProseBlock($) {
  $('script,style,iframe,noscript,ins,svg').remove();
  let best = ''; let bestLen = 0;
  $('div,p,section,article').each((i, el) => {
    const $el = $(el);
    if ($el.find('a').length >= 8) return;
    const t = $el.text().trim();
    if (t.length > bestLen) { bestLen = t.length; best = t; }
  });
  return best;
}

const detailCache = new Map();
async function detail(source, bookUrl) {
  const ck = source.bookSourceUrl + '|' + bookUrl;
  const cached = detailCache.get(ck);
  if (cached && Date.now() - cached.at < 300000) return cached.data;
  const data = await detailImpl(source, bookUrl);
  detailCache.set(ck, { at: Date.now(), data });
  return data;
}
async function detailImpl(source, bookUrl) {
  const rule = source.ruleBookInfo || {};
  const { html, url } = await fetchPage(bookUrl, source);
  const $ = cheerio.load(html);
  const ctx = { source, baseUrl: source.bookSourceUrl };
  const pick = (k) => { const r = rget(rule, k); return r ? applyRule($, $.root(), r, ctx) : null; };
  const tocUrl = absUrl(pick('tocUrl'), url);
  return {
    name: pick('name'), author: pick('author') || '', coverUrl: absUrl(pick('coverUrl'), url),
    intro: pick('intro') || '', kind: pick('kind') || '',
    tocUrl: tocUrl || bookUrl, sourceId: source.bookSourceUrl
  };
}

async function catalog(source, bookUrl) {
  const info = await detail(source, bookUrl);
  let chapters = [];
  let curUrl = info.tocUrl;
  const rule = source.ruleToc || {};
  const ctx = { source, baseUrl: source.bookSourceUrl };
  const nextRule = rget(rule, 'nextTocUrl');
  // 目录分页: 有 nextTocUrl 规则时循环抓下一页(上限10页防死循环)
  for (let page = 0; page < 10; page++) {
    const { html, url } = await fetchPage(curUrl, source);
    const $ = cheerio.load(html);
    const listRule = rget(rule, 'chapterList') || rget(rule, 'chapterlist');
    // ★2026-09-25 修（阅读逐页 P0）：这里原来只取选择器链的**第一段**（`parseChain(listRule)[0].sel`），
    //   把 `@` 之后的所有段整段丢掉。而真实源的 chapterList **绝大多数是链式**：
    //     `.box_con@dd` / `ul.detail-list-select@li` / `class.list@li@tag.a` / `#content@.page`
    //   → 拿容器当条目 → **整本目录只剩 1 条**，且「章节名」是全部子链接文本的**拼接**
    //   （实测：365小说网 的目录名 = "第一章…第二章…第三章…" 一整串，章节数 = 1）。
    //   改用与 bookList 同一个 resolveList（链式语义一致），XPath 分支也由它统一处理。
    const rows = listRule ? resolveList($, listRule) : $();
    rows.each((i, el) => {
      const $el = $(el);
      const name = rget(rule, 'chapterName') ? applyRule($, $el, rget(rule, 'chapterName'), ctx) : $el.text().trim();
      const chUrl = rget(rule, 'chapterUrl') ? applyRule($, $el, rget(rule, 'chapterUrl'), ctx) : $el.attr('href');
      chapters.push({ name, url: absUrl(chUrl, url) });
    });
    // 下一页?
    if (!nextRule) break;
    const nextUrl = applyRule($, $.root(), nextRule, ctx);
    if (!nextUrl) break;
    const abs = absUrl(nextUrl, url);
    if (!abs || abs === curUrl) break;
    curUrl = abs;
  }
  return chapters.filter(c => c.name && c.url);
}

async function content(source, chapterUrl) {
  const rule = source.ruleContent || {};
  const nextRule = rget(rule, 'nextContentUrl');
  const ctx = { source, baseUrl: source.bookSourceUrl };
  let allParas = []; let allImgs = []; let finalUrl = chapterUrl;

  // 正文翻页: 有 nextContentUrl 规则时循环抓下一页拼接(上限10页)
  let curUrl = chapterUrl;
  for (let page = 0; page < 10; page++) {
    const { html, url } = await fetchPage(curUrl, source);
    finalUrl = url;
    const $ = cheerio.load(html);
    let text = null;
    const r = rget(rule, 'content') || rget(rule, 'contentStr');
    if (r && String(r).startsWith('/')) {
      const xp = xpathToCheerio(String(r));
      text = $(xp.selector).first().html() || '';
    } else if (r) {
      text = applyRule($, $.root(), r, ctx);
    }
    if (!text) text = largestProseBlock($);
    const htmlStr = String(text);
    // 图片收集
    if (/<img[\s>]/i.test(htmlStr)) {
      const $c = cheerio.load('<div>' + htmlStr + '</div>');
      $c('img').each((i, el) => {
        const s = $c(el).attr('src') || $c(el).attr('data-src');
        if (s && !/loading|blank|spacer/i.test(s)) allImgs.push(absUrl(s, url));
      });
    }
    // 净化分段
    const paras = extractParas(htmlStr);
    allParas = allParas.concat(paras);
    // 下一页?
    if (!nextRule) break;
    const nextUrl = applyRule($, $.root(), nextRule, ctx);
    if (!nextUrl) break;
    const abs = absUrl(nextUrl, url);
    if (!abs || abs === curUrl) break;
    curUrl = abs;
  }

  if (allImgs.length >= 1 && allParas.length < 3)
    return { text: '', images: allImgs, chapterUrl: finalUrl };
  return { text: allParas.join('\n\n'), paragraphs: allParas.length, chapterUrl: finalUrl };
}

module.exports = { search, detail, catalog, content, extractParas, largestProseBlock };
