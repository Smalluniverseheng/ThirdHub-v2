'use strict';
/**
 * B 站下载：把 NAS 上的 bilidown 服务包装成 App 能直接用的接口
 *
 * 为什么要有这一层：
 *   1. bilidown 的 createTask 要求客户端自己提交 audio/video 的**签名直链**，
 *      而选清晰度、挑 codecid、补 https、解析 b23 短链这些活儿适合在服务端做一次。
 *   2. App 只连 9527 一个地址（局域网 / 公网 IPv6 / Tailscale 都能用），
 *      不用再记一个 8098 端口，也不会把内网地址暴露给客户端。
 *   3. 封面有防盗链（Referer 必须是 bilibili.com），由后端补头并转出去。
 *
 * 上游接口（bilidown，前缀 /api）：
 *   GET  /checkLogin                    登录态
 *   GET  /getQRInfo                     二维码 {key, image(base64)}
 *   GET  /getQRStatus?key=              扫码状态
 *   GET  /getRedirectedLocation?url=    短链展开
 *   GET  /getVideoInfo?bvid=            视频信息
 *   GET  /getSeasonInfo?epid=|ssid=     番剧信息
 *   GET  /getPlayInfo?bvid=&cid=        dash 流
 *   POST /createTask  [{bvid,cid,format,title,owner,cover,audio,video,duration,downloadType}]
 *   GET  /getTaskList?page=&pageSize=   历史任务
 *   GET  /getActiveTask                 进行中任务（含进度）
 *   POST /deleteTask  id=               删除
 *   GET  /downloadVideo?id=             取文件（支持 Range）
 */

const fs = require('fs');
const path = require('path');
const http = require('http');

const DATA = path.join(__dirname, 'data');

// 允许的清晰度码（与上游 util.IsValidFormatCode 完全一致，少一个 createTask 就拒收）
const ALLOWED_FORMATS = [6, 16, 32, 64, 74, 80, 112, 116, 120, 125, 126, 127];

// 清晰度码 → 人话（B 站约定，上游 support_formats 里也带，这里做兜底）
const FORMAT_LABEL = {
  6: '240P', 16: '360P', 32: '480P', 64: '720P', 74: '720P60',
  80: '1080P', 112: '1080P+', 116: '1080P60', 120: '4K',
  125: 'HDR', 126: '杜比视界', 127: '8K',
};

// B 站频道 tid 常量表（web 端 newlist/ranking 共用；写死即可，B 站多年不变）
const BILI_PARTITIONS = [
  { rid: 0, name: '全站' },
  { rid: 1, name: '动画' },
  { rid: 13, name: '番剧' },
  { rid: 167, name: '国创' },
  { rid: 177, name: '纪录片' },
  { rid: 23, name: '电影' },
  { rid: 11, name: '电视剧' },
  { rid: 129, name: '舞蹈' },
  { rid: 4, name: '游戏' },
  { rid: 36, name: '知识' },
  { rid: 188, name: '科技' },
  { rid: 234, name: '运动' },
  { rid: 223, name: '汽车' },
  { rid: 160, name: '生活' },
  { rid: 211, name: '美食' },
  { rid: 217, name: '动物圈' },
  { rid: 119, name: '鬼畜' },
  { rid: 155, name: '时尚' },
  { rid: 5, name: '娱乐' },
  { rid: 181, name: '影视' },
  { rid: 3, name: '音乐' },
];

/**
 * 给单个 (bvid,cid) 造一个 createTask 任务体。
 * 与 addTask 同一套选流规则（codecid AVC→HEVC→AV1、flac 优先、默认 1080P）。
 */
async function taskBodyFor(bvid, cid, meta, wantedFormat) {
  const pi = await up('/getPlayInfo?bvid=' + encodeURIComponent(bvid) + '&cid=' + encodeURIComponent(cid));
  if (!pi || !pi.success || !pi.data) return { error: '取播放地址失败，稍后再试' };
  const dash = pi.data.dash;
  if (!dash) return { error: '这个分P没有可下载的流' };
  const opts = formatOptions(pi.data);
  const want = Number(wantedFormat) || 0;
  let fmt = want;
  if (!fmt || !opts.some((o) => o.id === fmt)) {
    fmt = opts.some((o) => o.id === 80) ? 80 : (opts[0] ? opts[0].id : 0);
  }
  if (!fmt) return { error: '没有可用的清晰度' };
  const videoUrl = pickVideo(dash, fmt);
  const audioUrl = pickAudio(dash);
  if (!videoUrl) return { error: '取不到视频流地址' };
  return { ok: true, format: fmt, body: {
    bvid: String(bvid),
    cid: Number(cid) || 0,
    format: fmt,
    title: String(meta.title || ''),
    owner: String(meta.owner || ''),
    cover: fixUrl(meta.cover),
    audio: fixUrl(audioUrl),
    video: fixUrl(videoUrl),
    duration: Number(meta.duration) || 0,
    downloadType: audioUrl ? 'merge' : 'video',
  } };
}

function biliBase() {
  if (process.env.BILIDOWN_URL) return String(process.env.BILIDOWN_URL).replace(/\/+$/, '');
  try {
    const cfg = JSON.parse(fs.readFileSync(path.join(DATA, 'bili.json'), 'utf8'));
    if (cfg && cfg.url) return String(cfg.url).replace(/\/+$/, '');
  } catch (e) {}
  // 兜底：本机（容器用 host 网络或同机部署时可用）
  return 'http://127.0.0.1:8098';
}

/** 上游 GET，返回解析后的 JSON（失败给 null，不抛） */
function up(pathAndQuery, timeoutMs = 20000) {
  const url = biliBase() + '/api' + pathAndQuery;
  return new Promise((resolve) => {
    let done = false;
    const finish = (v) => { if (!done) { done = true; resolve(v); } };
    const req = http.request(url, {
      method: 'GET',
      timeout: timeoutMs,
      headers: { 'user-agent': 'ThirdHub/1.0' },
    }, (r) => {
      const cs = [];
      r.on('data', (d) => cs.push(d));
      r.on('end', () => {
        const text = Buffer.concat(cs).toString('utf8');
        try { finish(JSON.parse(text)); } catch (e) { finish(null); }
      });
    });
    req.on('timeout', () => { try { req.destroy(); } catch (e) {} finish(null); });
    req.on('error', () => finish(null));
    req.end();
  });
}

/** 上游 POST JSON，返回解析后的 JSON */
function upPost(pathAndQuery, body, timeoutMs = 25000) {
  const url = biliBase() + '/api' + pathAndQuery;
  const payload = Buffer.from(JSON.stringify(body), 'utf8');
  return new Promise((resolve) => {
    let done = false;
    const finish = (v) => { if (!done) { done = true; resolve(v); } };
    const u = new URL(url);
    const req = http.request({
      hostname: u.hostname, port: u.port, path: u.pathname + u.search, method: 'POST',
      timeout: timeoutMs,
      headers: {
        'content-type': 'application/json',
        'content-length': payload.length,
        'user-agent': 'ThirdHub/1.0',
      },
    }, (r) => {
      const cs = [];
      r.on('data', (d) => cs.push(d));
      r.on('end', () => {
        const text = Buffer.concat(cs).toString('utf8');
        try { finish(JSON.parse(text)); } catch (e) { finish(null); }
      });
    });
    req.on('timeout', () => { try { req.destroy(); } catch (e) {} finish(null); });
    req.on('error', () => finish(null));
    req.end(payload);
  });
}

function fixUrl(u) {
  if (!u) return '';
  let s = String(u).trim();
  if (s.startsWith('//')) s = 'https:' + s;
  return s;
}

/**
 * 从用户粘贴的内容里取出可用的 ID。
 * 支持：
 *   · 完整链接 https://www.bilibili.com/video/BV1xx/?p=2
 *   · 手机分享 https://b23.tv/xxxxx（需要展开）
 *   · 分享文本「【标题】 https://b23.tv/xxx」← nas.4 上游支持，我们这里也自己提
 *   · 直接贴 BV 号
 */
function extractId(raw) {
  const text = String(raw || '').trim();
  if (!text) return { kind: '', value: '' };
  // 纯 BV 号
  const bvDirect = text.match(/^(BV1[a-zA-Z0-9]{9,})$/);
  if (bvDirect) return { kind: 'video', value: bvDirect[1] };
  // 任意位置的 BV 号（含链接与分享文本）
  const bv = text.match(/BV1[a-zA-Z0-9]{9,}/);
  if (bv && /bilibili\.com|b23\.tv/i.test(text)) return { kind: 'video', value: bv[0] };
  // 番剧 ep / ss
  const ep = text.match(/\/bangumi\/play\/ep(\d+)/i);
  if (ep) return { kind: 'ep', value: ep[1] };
  const ss = text.match(/\/bangumi\/play\/ss(\d+)/i);
  if (ss) return { kind: 'ss', value: ss[1] };
  // 短链：交给上游展开
  const short = text.match(/https?:\/\/(?:b23\.tv|bili2233\.cn)\/[A-Za-z0-9]+/);
  if (short) return { kind: 'short', value: short[0] };
  // 其它 bilibili 链接
  const anyUrl = text.match(/https?:\/\/[^\s"'）)】]+/);
  if (anyUrl) return { kind: 'url', value: anyUrl[0] };
  if (bv) return { kind: 'video', value: bv[0] };
  return { kind: '', value: '' };
}

/** 把任意输入解析成 { bvid, page } */
async function resolveToBvid(input) {
  let { kind, value } = extractId(input);
  if (kind === 'short' || kind === 'url') {
    const r = await up('/getRedirectedLocation?url=' + encodeURIComponent(value));
    const loc = r && r.success && r.data ? String(r.data) : '';
    if (loc) {
      const bv = loc.match(/BV1[a-zA-Z0-9]{9,}/);
      if (bv) return { bvid: bv[0], page: pageOf(loc) };
      const ep = loc.match(/\/bangumi\/play\/ep(\d+)/i);
      if (ep) return { kind: 'ep', value: ep[1] };
      const ss = loc.match(/\/bangumi\/play\/ss(\d+)/i);
      if (ss) return { kind: 'ss', value: ss[1] };
    }
    // 展开失败但原文里有 b23 短码，按失败处理
    if (kind === 'short') return { error: '短链解析失败，请用完整链接（含 BV 号）' };
    const bv2 = value.match(/BV1[a-zA-Z0-9]{9,}/);
    if (bv2) return { bvid: bv2[0], page: pageOf(value) };
    return { error: '这个链接里没有找到 BV 号' };
  }
  if (kind === 'video') return { bvid: value, page: pageOf(input) };
  if (kind === 'ep' || kind === 'ss') return { kind, value };
  return { error: '没识别出链接，粘贴 B 站视频链接或 BV 号即可' };
}

function pageOf(text) {
  const m = String(text || '').match(/[?&]p=(\d+)/);
  return m ? Math.max(1, parseInt(m[1], 10)) : 1;
}

/** 复刻上游 GetVideoURL：codecid 优先 AVC(12) → HEVC(7) → AV1(13) */
function pickVideo(dash, fmt) {
  const vids = (dash && dash.video) || [];
  for (const code of [12, 7, 13]) {
    const hit = vids.find((v) => Number(v.id) === Number(fmt) && Number(v.codecid) === code);
    if (hit && hit.baseUrl) return hit.baseUrl;
  }
  // 该清晰度没有任何我们认的编码：退一步取同清晰度任意编码，再退一步取最高清晰度
  const same = vids.find((v) => Number(v.id) === Number(fmt));
  if (same && same.baseUrl) return same.baseUrl;
  let best = null;
  for (const v of vids) {
    if (!v.baseUrl) continue;
    if (!best || Number(v.id) > Number(best.id)) best = v;
  }
  return best ? best.baseUrl : '';
}

/** 复刻上游 GetAudioURL：有 flac 用 flac，否则取 id 最大的 */
function pickAudio(dash) {
  if (dash && dash.flac && dash.flac.audio && dash.flac.audio.baseUrl) return dash.flac.audio.baseUrl;
  let best = null;
  for (const a of (dash && dash.audio) || []) {
    if (!a.baseUrl) continue;
    if (!best || Number(a.id) > Number(best.id)) best = a;
  }
  return best ? best.baseUrl : '';
}

/** 从 support_formats 生成可选清晰度列表，只用后端允许的码 */
function formatOptions(playInfo) {
  const seen = new Set();
  const out = [];
  const push = (id, label) => {
    const n = Number(id);
    if (!ALLOWED_FORMATS.includes(n) || seen.has(n)) return;
    seen.add(n);
    out.push({ id: n, label: label || FORMAT_LABEL[n] || String(n) });
  };
  for (const f of (playInfo && playInfo.support_formats) || []) {
    push(f.quality, f.new_description);
  }
  for (const q of (playInfo && playInfo.accept_quality) || []) push(q);
  out.sort((a, b) => b.id - a.id);
  return out;
}

/** 解析链接 → 视频信息 + 可选清晰度（不创建任务） */
async function parseOne(input) {
  const r = await resolveToBvid(input);
  if (r.error) return { error: r.error };
  if (r.kind === 'ep' || r.kind === 'ss') {
    return { error: '番剧链接暂时只支持单集 BV 号，打开那一集复制它的链接即可' };
  }
  const bvid = r.bvid;
  if (!/^BV1[a-zA-Z0-9]{9,}$/.test(bvid)) return { error: 'BV 号格式不对' };

  const info = await up('/getVideoInfo?bvid=' + encodeURIComponent(bvid));
  if (!info) return { error: '连不上 B 站下载服务' };
  if (!info.success) {
    const msg = String(info.message || '');
    if (/未登录|登录/.test(msg)) return { error: '还没登录 B 站，先在下方扫码登录', needLogin: true };
    return { error: msg || '取视频信息失败' };
  }
  const d = info.data || {};
  const pages = Array.isArray(d.pages) ? d.pages : [];
  const pageIdx = Math.min(Math.max(1, r.page || 1), Math.max(1, pages.length)) - 1;
  const pg = pages[pageIdx] || {};
  const cid = Number(pg.cid) || 0;

  let playInfo = null;
  if (cid) {
    const pi = await up('/getPlayInfo?bvid=' + encodeURIComponent(bvid) + '&cid=' + cid);
    if (pi && pi.success) playInfo = pi.data;
  }

  return {
    bvid,
    cid,
    page: pageIdx + 1,
    pages: pages.map((p, i) => ({ index: i + 1, cid: Number(p.cid) || 0, title: p.part || '' })),
    title: String(d.title || ''),
    cover: fixUrl(d.pic),
    owner: String((d.owner && d.owner.name) || ''),
    duration: Number(d.duration) || 0,
    desc: String(d.desc || '').slice(0, 300),
    formats: formatOptions(playInfo),
    canDownload: !!cid,
    error: cid ? '' : '这个视频没有可用分集，无法下载',
  };
}

/** 提交下载任务 */
async function addTask(input, wantedFormat) {
  const p = await parseOne(input);
  if (p.error && !p.cid) return { error: p.error, needLogin: p.needLogin };

  // 再取一次 dash 用来选流（parseOne 里没有把 dash 带出来，避免大对象进内存）
  const pi = await up('/getPlayInfo?bvid=' + encodeURIComponent(p.bvid) + '&cid=' + p.cid);
  if (!pi || !pi.success || !pi.data) return { error: '取播放地址失败，稍后再试' };
  const dash = pi.data.dash;
  if (!dash) return { error: '这个视频没有可下载的流（可能是直播回放或付费内容）' };

  const opts = formatOptions(pi.data);
  const want = Number(wantedFormat) || 0;
  let fmt = want;
  if (!fmt || !opts.some((o) => o.id === fmt)) {
    // 默认 1080P，没有再取最高可用
    fmt = opts.some((o) => o.id === 80) ? 80 : (opts[0] ? opts[0].id : 0);
  }
  if (!fmt) return { error: '没有可用的清晰度' };

  const videoUrl = pickVideo(dash, fmt);
  const audioUrl = pickAudio(dash);
  if (!videoUrl) return { error: '取不到视频流地址' };

  const body = [{
    bvid: p.bvid,
    cid: p.cid,
    format: fmt,
    title: p.title,
    owner: p.owner,
    cover: fixUrl(p.cover),
    audio: fixUrl(audioUrl),
    video: fixUrl(videoUrl),
    duration: p.duration,
    downloadType: audioUrl ? 'merge' : 'video',
  }];
  const r = await upPost('/createTask', body);
  if (!r) return { error: '提交任务失败（服务无响应）' };
  if (!r.success) return { error: String(r.message || '提交任务失败') };
  return { ok: true, title: p.title, format: fmt, formatLabel: FORMAT_LABEL[fmt] || String(fmt), bvid: p.bvid };
}

/**
 * 把进行中的进度合并到历史列表里。
 * 上游 getTaskList 只给库里状态，进度在 getActiveTask（内存快照）里。
 */
function mergeProgress(list, active) {
  const byId = new Map();
  for (const a of active || []) {
    if (a && a.id != null) byId.set(String(a.id), a);
  }
  return (list || []).map((t) => {
    const a = byId.get(String(t.id));
    if (!a) return t;
    return Object.assign({}, t, {
      status: a.status || t.status,
      audioProgress: a.audioProgress,
      videoProgress: a.videoProgress,
      mergeProgress: a.mergeProgress,
    });
  });
}

// ───────────────────────── 路由 ─────────────────────────

function send(res, code, obj) {
  const body = Buffer.from(JSON.stringify(obj), 'utf8');
  res.writeHead(code, { 'content-type': 'application/json; charset=utf-8', 'content-length': body.length });
  res.end(body);
}

/** 封面代理：B 站图床校验 Referer，直接给客户端会 403 */
function proxyCover(res, u) {
  let target;
  try { target = new URL(fixUrl(u)); } catch (e) { send(res, 400, { ok: false, error: '封面地址不合法' }); return; }
  if (!/^https?:$/.test(target.protocol) || !/(hdslb\.com|bilivideo\.com|bilibili\.com)$/.test(target.hostname.replace(/^[a-z0-9-]+\./, '')) && !/hdslb\.com|bilivideo\.com/.test(target.hostname)) {
    send(res, 400, { ok: false, error: '只允许 B 站图床' }); return;
  }
  const req = http.request({
    hostname: target.hostname, port: target.port || 80, path: target.pathname + target.search,
    method: 'GET', timeout: 15000,
    headers: { referer: 'https://www.bilibili.com/', 'user-agent': 'Mozilla/5.0', accept: 'image/*,*/*' },
  }, (r) => {
    if (r.statusCode && r.statusCode >= 400) {
      r.resume();
      send(res, 404, { ok: false, error: '封面不存在' });
      return;
    }
    res.writeHead(200, {
      'content-type': r.headers['content-type'] || 'image/jpeg',
      'cache-control': 'public, max-age=86400',
    });
    r.pipe(res);
  });
  req.on('timeout', () => { try { req.destroy(); } catch (e) {} send(res, 504, { ok: false, error: '封面超时' }); });
  req.on('error', () => send(res, 502, { ok: false, error: '封面取不到' }));
  req.end();
}

/** 媒体文件代理：原样透传 Range，App 才能拖动进度、边下边播 */
function proxyFile(res, req, id) {
  const n = parseInt(id, 10);
  if (!n || n <= 0) { send(res, 400, { ok: false, error: '任务 ID 不对' }); return; }
  const base = new URL(biliBase());
  const headers = { 'user-agent': 'ThirdHub/1.0' };
  if (req.headers.range) headers.range = String(req.headers.range);
  const r2 = http.request({
    hostname: base.hostname, port: base.port || 80,
    path: '/api/downloadVideo?id=' + n, method: 'GET', timeout: 30000, headers,
  }, (up2) => {
    const h = {};
    for (const k of ['content-type', 'content-length', 'content-range', 'accept-ranges', 'last-modified', 'etag']) {
      if (up2.headers[k]) h[k] = up2.headers[k];
    }
    res.writeHead(up2.statusCode || 200, h);
    up2.pipe(res);
  });
  r2.on('timeout', () => { try { r2.destroy(); } catch (e) {} if (!res.headersSent) send(res, 504, { ok: false, error: '取文件超时' }); });
  r2.on('error', () => { if (!res.headersSent) send(res, 502, { ok: false, error: '取文件失败' }); });
  r2.end();
}

// ─────────────────────────────────────────────────────────────
// B 站网页接口（浏览 / 播放用，不走 bilidown 那个下载器）
//
// 为什么要这一层：
//   ① B 站 web 接口对 UA + Referer 敏感，不给就 -412 或空；
//   ② 视频直链（upos-*.bilivideo.com）**必须带 Referer: https://www.bilibili.com/**，
//      手机播放器带不了 → 一律包成我们的媒体代理（9548? 实为 9528/thp/stream）。
// 接口路径参照开源文档 bilibili-API-collect（SocialSisterYi），不自己猜。
const WEB_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
const WEB_REF = 'https://www.bilibili.com/';

function mediaProxyBase() {
  const lan = (process.env.TH_LAN_URL || '').trim();
  let host = '127.0.0.1';
  try { if (lan) host = new URL(lan).hostname; } catch (e) {}
  return 'http://' + host + ':' + (process.env.TH_MEDIA_PORT || '9528');
}

function biliStream(u) {
  if (!u) return '';
  return mediaProxyBase() + '/thp/stream?u=' + encodeURIComponent(u) + '&r=' + encodeURIComponent(WEB_REF);
}

async function webApi(path, timeoutMs = 15000, ref) {
  const headers = {
    'user-agent': WEB_UA, referer: ref || WEB_REF, accept: 'application/json,text/plain,*/*',
    'accept-language': 'zh-CN,zh;q=0.9',
  };
  if (biliCookie) headers.cookie = biliCookie;
  const r = await fetch('https://api.bilibili.com' + path, { headers, signal: AbortSignal.timeout(timeoutMs) });
  const t = await r.text();
  try { return JSON.parse(t); } catch (e) { return { code: -1, message: '返回非 JSON: ' + t.slice(0, 60) }; }
}

// ★ 搜索接口要 cookie（buvid3），否则 -412 request was banned。
//   做法：先访问一次首页把 Set-Cookie 收下来，缓存 30 分钟。
let biliCookie = '';
let biliCookieAt = 0;

async function ensureCookie(force) {
  if (!force && biliCookie && Date.now() - biliCookieAt < 30 * 60 * 1000) return biliCookie;
  const jar = {};
  // ① 首页 Set-Cookie（buvid3 等）
  try {
    const r = await fetch('https://www.bilibili.com/', {
      headers: { 'user-agent': WEB_UA, accept: 'text/html,application/xhtml+xml' },
      signal: AbortSignal.timeout(15000),
    });
    const raw = typeof r.headers.getSetCookie === 'function' ? r.headers.getSetCookie() : [];
    for (const c of raw) {
      const kv = String(c).split(';')[0];
      const i = kv.indexOf('=');
      if (i > 0) jar[kv.slice(0, i)] = kv.slice(i + 1);
    }
  } catch (e) { /* 忽略，下面用 spi 兜底 */ }
  // ② 官方 spi 接口直接给 buvid3/buvid4（比首页稳，个别环境首页只回 2 项）
  try {
    const r = await fetch('https://api.bilibili.com/x/frontend/finger/spi', {
      headers: { 'user-agent': WEB_UA, referer: WEB_REF },
      signal: AbortSignal.timeout(12000),
    });
    const j = await r.json();
    const d = (j && j.data) || {};
    if (d.b_3) jar.buvid3 = d.b_3;
    if (d.b_4) jar.buvid4 = d.b_4;
  } catch (e) { /* 忽略 */ }
  const pairs = Object.entries(jar).map(([k, v]) => k + '=' + v);
  if (pairs.length) {
    biliCookie = pairs.join('; ');
    biliCookieAt = Date.now();
    console.log('[bili] cookie 已获取，' + pairs.length + ' 项');
  }
  return biliCookie;
}

/** 热门/推荐列表 → 统一结构 */
function feedItem(v) {
  const bvid = v.bvid || '';
  return {
    bvid,
    title: v.title || '',
    cover: v.pic ? '/v1/bili/cover?u=' + encodeURIComponent(v.pic.startsWith('//') ? 'https:' + v.pic : v.pic) : '',
    coverRaw: v.pic || '',
    owner: (v.owner && v.owner.name) || v.author || '',
    duration: v.duration || 0,
    play: (v.stat && (v.stat.view || v.stat.vv)) || 0,
    danmaku: (v.stat && v.stat.danmaku) || 0,
    pubdate: v.pubdate || v.ctime || 0,
    desc: v.desc || '',
  };
}

/**
 * 返回值 true 表示这个请求已经处理完（调用方不要再往下走）
 * p 形如 /v1/bili/status
 */
async function handle(req, res, body, u, p) {
  if (!p.startsWith('/v1/bili')) return false;
  if (p !== '/v1/bili' && !p.startsWith('/v1/bili/')) return false;

  const op = p.slice('/v1/bili'.length).replace(/^\//, '');

  // 状态：顺带告诉 App 下载目录在哪，方便提示用户
  if (op === '' || op === 'status') {
    const [login, info] = await Promise.all([up('/checkLogin'), up('/getServerInfo')]);
    const d = (info && info.data) || {};
    send(res, 200, {
      ok: true,
      login: !!(login && login.success),
      downloadFolder: d.downloadFolder || '/downloads',
      downloadHostPath: d.downloadHostPath || '',
      base: biliBase(),
    });
    return true;
  }

  if (op === 'qr') {
    const r = await up('/getQRInfo', 25000);
    if (!r || !r.success || !r.data) { send(res, 502, { ok: false, error: '取二维码失败，检查 B 站下载服务是否在跑' }); return true; }
    send(res, 200, { ok: true, key: r.data.key || '', image: r.data.image || '' });
    return true;
  }

  if (op === 'qr/status') {
    const key = u.searchParams.get('key') || '';
    if (!key) { send(res, 400, { ok: false, error: '缺少 key' }); return true; }
    const r = await up('/getQRStatus?key=' + encodeURIComponent(key), 15000);
    // 上游语义：success=true 才算「扫码并确认成功」（此时后端已落库 sessdata）；
    // 否则 message 是「二维码未扫描 / 已扫描等待确认 / 二维码已失效」这类提示。
    send(res, 200, {
      ok: true,
      login: !!(r && r.success),
      message: (r && r.message) || '',
      raw: (r && r.data) || null,
    });
    return true;
  }

  if (op === 'parse') {
    const input = u.searchParams.get('url') || '';
    if (!input) { send(res, 400, { ok: false, error: '缺少 url' }); return true; }
    const r = await parseOne(input);
    send(res, r.error && !r.cid ? 400 : 200, Object.assign({ ok: !(r.error && !r.cid) }, r));
    return true;
  }

  if (op === 'add') {
    let payload = {};
    try { payload = body ? JSON.parse(body) : {}; } catch (e) { payload = {}; }
    const input = payload.url || u.searchParams.get('url') || '';
    const fmt = payload.format || u.searchParams.get('format') || '';
    if (!input) { send(res, 400, { ok: false, error: '缺少 url' }); return true; }
    const r = await addTask(input, fmt);
    send(res, r.ok ? 200 : 400, Object.assign({ ok: !!r.ok }, r));
    return true;
  }

  if (op === 'tasks') {
    const page = u.searchParams.get('page') || '0';
    const size = u.searchParams.get('pageSize') || '60';
    const [list, act] = await Promise.all([
      up('/getTaskList?page=' + encodeURIComponent(page) + '&pageSize=' + encodeURIComponent(size)),
      up('/getActiveTask'),
    ]);
    const items = (list && list.success && Array.isArray(list.data)) ? list.data : [];
    const active = (act && act.success && Array.isArray(act.data)) ? act.data : [];
    const merged = mergeProgress(items, active);
    // 正在下载的排前面，然后按创建时间倒序
    merged.sort((a, b) => {
      const ra = a.status === 'running' || a.status === 'waiting' ? 1 : 0;
      const rb = b.status === 'running' || b.status === 'waiting' ? 1 : 0;
      if (ra !== rb) return rb - ra;
      return String(b.createAt || '').localeCompare(String(a.createAt || ''));
    });
    send(res, 200, { ok: true, items: merged, count: merged.length });
    return true;
  }

  if (op === 'del') {
    let payload = {};
    try { payload = body ? JSON.parse(body) : {}; } catch (e) { payload = {}; }
    const id = String(payload.id || u.searchParams.get('id') || '');
    if (!id) { send(res, 400, { ok: false, error: '缺少 id' }); return true; }
    const qs = 'id=' + encodeURIComponent(id);
    const r = await new Promise((resolve) => {
      const url = biliBase() + '/api/deleteTask?' + qs;
      const ru = new URL(url);
      const rq = http.request({
        hostname: ru.hostname, port: ru.port || 80, path: ru.pathname + ru.search, method: 'POST',
        timeout: 15000, headers: { 'content-length': 0, 'user-agent': 'ThirdHub/1.0' },
      }, (rr) => {
        const cs = []; rr.on('data', (d) => cs.push(d));
        rr.on('end', () => { try { resolve(JSON.parse(Buffer.concat(cs).toString('utf8'))); } catch (e) { resolve(null); } });
      });
      rq.on('timeout', () => { try { rq.destroy(); } catch (e) {} resolve(null); });
      rq.on('error', () => resolve(null));
      rq.end();
    });
    send(res, 200, { ok: !!(r && r.success), message: (r && r.message) || '' });
    return true;
  }

  if (op === 'play') {
    proxyFile(res, req, u.searchParams.get('id') || '');
    return true;
  }

  if (op === 'cover') {
    proxyCover(res, u.searchParams.get('u') || '');
    return true;
  }

  if (op === 'logout') {
    const r = await up('/logout', 15000);
    send(res, 200, { ok: !!(r && r.success) });
    return true;
  }

  // ── 浏览：热门 / 推荐 ──
  if (op === 'feed') {
    const kind = u.searchParams.get('type') || 'popular';
    const pn = u.searchParams.get('pn') || '1';
    const ps = u.searchParams.get('ps') || '20';
    await ensureCookie();
    let j = kind === 'recommend'
      ? await webApi('/x/web-interface/index/top/rcmd?ps=' + ps + '&fresh_idx=' + pn)
      : await webApi('/x/web-interface/popular?ps=' + ps + '&pn=' + pn);
    if (j.code === -412) {
      await ensureCookie(true);
      j = kind === 'recommend'
        ? await webApi('/x/web-interface/index/top/rcmd?ps=' + ps + '&fresh_idx=' + pn)
        : await webApi('/x/web-interface/popular?ps=' + ps + '&pn=' + pn);
    }
    const list = ((j.data && (j.data.list || j.data.item)) || []).map(feedItem);
    send(res, 200, { ok: j.code === 0, code: j.code, items: list,
      hasMore: !!(j.data && j.data.no_more) === false, message: j.message || '' });
    return true;
  }

  // ── 浏览：搜索 ──
  if (op === 'search') {
    const q = u.searchParams.get('q') || '';
    const pn = u.searchParams.get('pn') || '1';
    if (!q) { send(res, 400, { ok: false, error: '缺少 q' }); return true; }
    await ensureCookie();
    let j = await webApi('/x/web-interface/search/type?search_type=video&keyword='
      + encodeURIComponent(q) + '&page=' + pn, 15000, 'https://search.bilibili.com/');
    if (j.code === -412) {                     // cookie 过期 → 强制换一次再试
      await ensureCookie(true);
      j = await webApi('/x/web-interface/search/type?search_type=video&keyword='
        + encodeURIComponent(q) + '&page=' + pn, 15000, 'https://search.bilibili.com/');
    }
    const raw = (j.data && j.data.result) || [];
    const items = raw.map((v) => {
      const it = feedItem(v);
      it.title = String(it.title || '').replace(/<[^>]+>/g, '');   // 搜索结果标题带 <em> 高亮
      if (typeof v.duration === 'string') {
        const parts = v.duration.split(':').map(Number).reverse();
        it.duration = (parts[0] || 0) + (parts[1] || 0) * 60 + (parts[2] || 0) * 3600;
      }
      return it;
    });
    send(res, 200, { ok: j.code === 0, code: j.code, items, message: j.message || '' });
    return true;
  }

  // ── 分P列表（拿 cid 用；这个接口不吃风控，比 view 稳）──
  if (op === 'pages') {
    const bvid = u.searchParams.get('bvid') || '';
    if (!bvid) { send(res, 400, { ok: false, error: '缺少 bvid' }); return true; }
    const j = await webApi('/x/player/pagelist?bvid=' + encodeURIComponent(bvid));
    const pages = (j.data || []).map((p) => ({ cid: p.cid, page: p.page, part: p.part, duration: p.duration }));
    send(res, 200, { ok: j.code === 0 && pages.length > 0, code: j.code, pages, message: j.message || '' });
    return true;
  }

  // ── 浏览：视频详情（含分P）──
  if (op === 'view') {
    const bvid = u.searchParams.get('bvid') || '';
    if (!bvid) { send(res, 400, { ok: false, error: '缺少 bvid' }); return true; }
    await ensureCookie();
    let j = await webApi('/x/web-interface/view?bvid=' + encodeURIComponent(bvid));
    if (j.code === -412) {
      await ensureCookie(true);
      j = await webApi('/x/web-interface/view?bvid=' + encodeURIComponent(bvid));
    }
    if (j.code !== 0) { send(res, 200, { ok: false, code: j.code, message: j.message || '取详情失败' }); return true; }
    const d = j.data || {};
    send(res, 200, {
      ok: true,
      data: {
        bvid: d.bvid, aid: d.aid, title: d.title, desc: d.desc || '',
        cover: d.pic ? '/v1/bili/cover?u=' + encodeURIComponent(d.pic) : '',
        owner: (d.owner && d.owner.name) || '', duration: d.duration || 0,
        stat: d.stat || {},
        pages: (d.pages || []).map((p) => ({ cid: p.cid, page: p.page, part: p.part, duration: p.duration })),
      },
    });
    return true;
  }

  // ── 播放：拿直链（免签名，最高 720P；够手机看，且不依赖 B 站登录）──
  if (op === 'playurl') {
    const bvid = u.searchParams.get('bvid') || '';
    const cid = u.searchParams.get('cid') || '';
    const qn = u.searchParams.get('qn') || '64';
    if (!bvid || !cid) { send(res, 400, { ok: false, error: '缺少 bvid 或 cid' }); return true; }
    const j = await webApi('/x/player/playurl?bvid=' + encodeURIComponent(bvid)
      + '&cid=' + encodeURIComponent(cid) + '&fnval=1&qn=' + qn + '&platform=html5&high_quality=1');
    if (j.code !== 0) { send(res, 200, { ok: false, code: j.code, message: j.message || '取播放地址失败' }); return true; }
    const d = j.data || {};
    const durl = d.durl || [];
    const first = durl[0] || {};
    // 直链必须带 Referer → 一律过媒体代理
    const url = biliStream(first.url || '');
    send(res, 200, {
      ok: !!url, url, quality: d.quality || 0,
      acceptQuality: d.accept_quality || [], acceptDesc: d.accept_description || [],
      length: d.timelength || first.length || 0, size: first.size || 0,
      segments: durl.map((x) => biliStream(x.url || '')),
    });
    return true;
  }

  // ── 分区列表（服务端常量）──
  if (op === 'partitions') {
    send(res, 200, { ok: true, items: BILI_PARTITIONS });
    return true;
  }

  // ── 排行榜（按频道 rid，rid=0 全站）──
  if (op === 'rank') {
    const rid = u.searchParams.get('rid') || '0';
    await ensureCookie();
    let j = await webApi('/x/web-interface/ranking/v2?rid=' + encodeURIComponent(rid) + '&type=all');
    if (j.code === -412) {
      await ensureCookie(true);
      j = await webApi('/x/web-interface/ranking/v2?rid=' + encodeURIComponent(rid) + '&type=all');
    }
    const list = ((j.data && j.data.list) || []).map(feedItem);
    send(res, 200, { ok: j.code === 0, code: j.code, items: list, message: j.message || '' });
    return true;
  }

  // ── 分区最新（newlist；dynamic/region 已被 B 站下线，-404）──
  if (op === 'region') {
    const rid = u.searchParams.get('rid') || '1';
    const pn = u.searchParams.get('pn') || '1';
    const ps = u.searchParams.get('ps') || '20';
    const j = await webApi('/x/web-interface/newlist?rid=' + encodeURIComponent(rid)
      + '&ps=' + encodeURIComponent(ps) + '&pn=' + encodeURIComponent(pn) + '&type=0');
    const list = ((j.data && j.data.archives) || []).map(feedItem);
    send(res, 200, { ok: j.code === 0, code: j.code, items: list, message: j.message || '' });
    return true;
  }

  // ── 整季/整 P 批量下载：一个 BV 的所有分P一次全提交 ──
  if (op === 'addall') {
    let payload = {};
    try { payload = body ? JSON.parse(body) : {}; } catch (e) { payload = {}; }
    const bvid = String(payload.bvid || u.searchParams.get('bvid') || '');
    const fmt = payload.format || u.searchParams.get('format') || '';
    if (!/^BV1[a-zA-Z0-9]{9,}$/.test(bvid)) { send(res, 400, { ok: false, error: '缺少 bvid' }); return true; }
    const info = await up('/getVideoInfo?bvid=' + encodeURIComponent(bvid));
    if (!info || !info.success || !info.data) {
      send(res, 400, { ok: false, error: (info && info.message) || '取视频信息失败（B 站下载服务可能未登录）' });
      return true;
    }
    const d = info.data;
    const pages = Array.isArray(d.pages) ? d.pages : [];
    if (!pages.length) { send(res, 400, { ok: false, error: '没有分P信息' }); return true; }
    const MAX = 120;                       // 上限防呆：超过的截断并告知
    const todo = pages.slice(0, MAX);
    const meta = {
      title: String(d.title || ''),
      owner: String((d.owner && d.owner.name) || ''),
      cover: fixUrl(d.pic),
    };
    const bodies = [];
    const errors = [];
    let idx = 0;
    // 3 路并发逐 P 取流（每 P 都要自己的 getPlayInfo 签名直链，省不了）
    const workers = Array.from({ length: 3 }, async () => {
      while (idx < todo.length) {
        const i = idx++;
        const p = todo[i];
        const r = await taskBodyFor(bvid, Number(p.cid) || 0, meta, fmt);
        if (r.ok) {
          r.body.title = meta.title
            + (todo.length > 1 ? ' P' + (i + 1) : '')
            + (p.part ? ' ' + String(p.part).slice(0, 40) : '');
          r.body.duration = Number(p.duration) || 0;
          bodies.push(r.body);
        } else {
          errors.push('P' + (i + 1) + ':' + r.error);
        }
      }
    });
    await Promise.all(workers);
    if (!bodies.length) { send(res, 400, { ok: false, error: errors[0] || '所有分P都取流失败' }); return true; }
    const r = await upPost('/createTask', bodies, 180000);
    send(res, r && r.success ? 200 : 400, {
      ok: !!(r && r.success),
      added: bodies.length,
      total: pages.length,
      truncated: pages.length > MAX,
      message: (r && r.message) || '',
      errors: errors.slice(0, 5),
    });
    return true;
  }

  send(res, 404, { ok: false, error: '未知操作：' + op });
  return true;
}

module.exports = { handle, biliBase };