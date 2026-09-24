// ThirdHub v4 书源引擎 M1: 解析 Legado 格式书源(Legado JSON + 链式规则 + XPath子集 + @js沙箱)
// 依赖: cheerio (npm i)
const cheerio = require('cheerio');
const vm = require('vm');

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
      const idxMatch = sel.match(/^(.*)\.(\d+)$/); // 末尾数字=eq
      const idx = idxMatch ? parseInt(idxMatch[2]) : null;
      if (idxMatch) sel = idxMatch[1];
      let alt = null;                                  // 裸名的兼容解释（见下）
      if (sel.startsWith('class.')) sel = '.' + sel.slice(6);
      else if (sel.startsWith('id.')) sel = '#' + sel.slice(3);
      else if (sel.startsWith('tag.')) sel = sel.slice(4);
      else if (sel.startsWith('.') || sel.startsWith('#')) { /* 保持 */ }
      else if (/^[\w-]+$/.test(sel)) alt = '.' + sel;
      ops.push({ op: 'sel', sel, idx, alt });
    }
  }
  return ops;
}

// ─── JSONPath 迷你: $.a.b[0] ───
function miniJsonPath(obj, path) {
  if (!path) return null;
  let p = path.trim();
  if (p.startsWith('$.')) p = p.slice(2);
  else if (p.startsWith('$')) p = p.slice(1);
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
        let n = cur.find(o.sel);
        // ★2026-09-25 裸名双解：Legado 的链式规则里，裸段是**选择器**（裸名即标签名），
        //   本引擎原来把它一律当 class（`a`→`.a`、`h2`→`.h2`），于是形如
        //   `.bookdesc@a@href` / `.bookdesc@h2@text` 这种极常见写法永远取空 ——
        //   而 `search()` 末尾 `filter(b => b.name && b.bookUrl)` 会把它们全丢掉，
        //   表现就是「站点 200、页面里明明有关键词、引擎却 0 条」。
        //   这里改成「先按标签名找，找不到再退回 class」：严格是超集，
        //   原本靠 class 命中的源不受影响（标签名找不到时会退回原行为）。
        if (!n.length && o.alt) n = cur.find(o.alt);
        // ★2026-09-25 首段自匹配：真实源常把 bookList 的选择器在字段规则里**再写一遍**
        //   （bookList=`class.tui_1_item`，name=`class.tui_1_item@a@text`）。
        //   而 find() 只搜**后代**，行元素自身符合时取空 → 字段全空 → 被 filter 丢掉 → 0 条。
        //   XPath 分支本来就有这个兜底，链式分支漏了，这里补齐。
        if (!n.length && oi === 0 && cur.is) {
          if (cur.is(o.sel) || (o.alt && cur.is(o.alt))) n = cur.first();
        }
        if (o.idx != null && n.length) n = n.eq(o.idx);
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
  // 失败重试1次(仅网络错误/5xx, 4xx不重试)
  for (let attempt = 0; attempt < 2; attempt++) {
    const r = await tryFetch(url, headers, method, body);
    if (r.ok || (r.status && r.status < 500)) return r;
  }
  return { ok: false, url, html: '', json: null };
}

async function tryFetch(url, headers, method, body) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), 12000);
  try {
    const opts = { headers, signal: ctrl.signal, redirect: 'follow' };
    if (method === 'POST') { opts.method = 'POST'; opts.body = body || ''; }
    const resp = await fetch(url, opts);
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
  } finally { clearTimeout(timer); }
}

function absUrl(url, base) {
  if (!url) return null;
  try { return new URL(url, base).href; } catch (e) { return url; }
}

// ═══ 书源生命周期 ═══

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
  list.each((i, el) => {
    const $el = $(el);
    const pick = (k) => { const r = rget(rule, k); return r ? applyRule($, $el, r, ctx) : null; };
    books.push({
      name: pick('name'), author: pick('author') || '',
      coverUrl: absUrl(pick('coverUrl') || pick('cover'), source.bookSourceUrl),
      intro: pick('intro') || '', kind: pick('kind') || '',
      bookUrl: absUrl(pick('bookUrl'), finalUrl) || finalUrl,
      sourceId: source.bookSourceUrl
    });
  });
  return books.filter(b => b.name && b.bookUrl);
}

// 统一列表解析: XPath 子集 或 Legado 链式(多段 sel 链)
function resolveList($, listRule) {
  if (!listRule) return $();
  const lr = String(listRule).trim();
  if (lr.startsWith('/')) { const { selector } = xpathToCheerio(lr); return $(selector); }
  let cur = $.root();
  for (const o of parseChain(lr)) {
    if (o.op === 'sel') {
      let n = cur.find(o.sel);
      if (!n.length && o.alt) n = cur.find(o.alt);        // 裸名双解，与规则链同一语义
      if (o.idx != null && n.length) n = n.eq(o.idx);
      cur = n;
    }
    else if (o.op === 'js') { /* 列表级 js 暂不应用, 元素级在 pick 里 */ }
    else break; // text/attr 不该出现在 bookList
  }
  return cur && cur.each ? cur : $();
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
    if (listRule && listRule.startsWith('/')) {
      const xp = xpathToCheerio(listRule);
      $(xp.selector).each((i, el) => {
        const $el = $(el);
        const name = rget(rule, 'chapterName') ? applyRule($, $el, rget(rule, 'chapterName'), ctx) : $el.text().trim();
        const chUrl = rget(rule, 'chapterUrl') ? applyRule($, $el, rget(rule, 'chapterUrl'), ctx) : $el.attr('href');
        chapters.push({ name, url: absUrl(chUrl, url) });
      });
    } else {
      const ops = parseChain(listRule);
      const sel0 = ops && ops[0];
      if (sel0) $(sel0.sel).each((i, el) => {
        const $el = $(el);
        const name = rget(rule, 'chapterName') ? applyRule($, $el, rget(rule, 'chapterName'), ctx) : $el.text().trim();
        const chUrl = rget(rule, 'chapterUrl') ? applyRule($, $el, rget(rule, 'chapterUrl'), ctx) : $el.attr('href');
        chapters.push({ name, url: absUrl(chUrl, url) });
      });
    }
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
    if (!text) {
      let best = ''; let bestLen = 0;
      $('div,p,section,article').each((i, el) => {
        const t = $(el).text().trim();
        if (t.length > bestLen) { bestLen = t.length; best = t; }
      });
      text = best;
    }
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
    const $clean = cheerio.load('<div>' + htmlStr + '</div>');
    $clean('script,style,iframe,noscript,ins,svg').remove();
    $clean('div[class*=ad],div[id*=ad],p[class*=ad]').remove();
    const $cd = $clean('div');
    let paras = $cd.find('p').length
      ? $cd.find('p').map((i, el) => $clean(el).text().trim()).get().filter(Boolean)
      : $cd.text().split(/\n{2,}|\r\n{2,}/).map(s => s.trim()).filter(Boolean);
    paras = paras.filter(p => p.length > 1 && !/chaptererror|请收藏|天才一秒记住|www\.\w+\.\w{2,}$/i.test(p));
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

module.exports = { search, detail, catalog, content };
