'use strict';
// 抓取用的小工具：HTTP 取件（带 SSRF 防护）+ HTML 取正文。
//
// 这两个函数是「桌面端干活」的核心动作，所以防护要写在这儿而不是散在调用点：
//   · 只允许 http/https，且**拒绝内网/回环/链路本地地址** ——
//     否则任何人拿到令牌就能让它去读 NAS 上的其它服务（SSRF）。
//   · 单文件体积上限、整体超时上限：一次任务不能把整台机器拖住。
//   · 跟随重定向最多 5 跳，且每一跳都重新做地址校验（防「公网 302 到内网」）。
const dns = require('dns').promises;
const http = require('http');
const https = require('https');
const net = require('net');
const zlib = require('zlib');

const MAX_BYTES = parseInt(process.env.TH_MAX_FETCH_BYTES || String(24 * 1024 * 1024), 10);
const TIMEOUT_MS = parseInt(process.env.TH_FETCH_TIMEOUT_MS || '25000', 10);

// ── SSRF 防护 ────────────────────────────────────────────────
function isPrivateIp(ip) {
  if (net.isIPv4(ip)) {
    const p = ip.split('.').map(Number);
    if (p[0] === 10) return true;
    if (p[0] === 127) return true;
    if (p[0] === 0) return true;
    if (p[0] === 169 && p[1] === 254) return true;         // 链路本地（云元数据）
    if (p[0] === 172 && p[1] >= 16 && p[1] <= 31) return true;
    if (p[0] === 192 && p[1] === 168) return true;
    if (p[0] === 100 && p[1] >= 64 && p[1] <= 127) return true; // CGNAT
    if (p[0] >= 224) return true;                           // 组播/保留
    return false;
  }
  if (net.isIPv6(ip)) {
    const s = ip.toLowerCase();
    if (s === '::1' || s === '::') return true;
    if (s.startsWith('fe80')) return true;                  // 链路本地
    if (s.startsWith('fc') || s.startsWith('fd')) return true; // ULA
    if (s.startsWith('::ffff:')) return isPrivateIp(s.slice(7));
    return false;
  }
  return true; // 认不出来的一律当危险
}

async function assertPublicUrl(raw) {
  let u;
  try {
    u = new URL(raw);
  } catch (_) {
    throw new Error('不是合法 URL：' + String(raw).slice(0, 80));
  }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') {
    throw new Error('只支持 http/https，收到 ' + u.protocol);
  }
  const host = u.hostname;
  if (net.isIP(host)) {
    if (isPrivateIp(host)) throw new Error('拒绝访问内网地址：' + host);
    return u;
  }
  let addrs;
  try {
    addrs = await dns.lookup(host, { all: true });
  } catch (e) {
    throw new Error('域名解析失败：' + host);
  }
  for (const a of addrs) {
    if (isPrivateIp(a.address)) throw new Error('域名指向内网地址，已拒绝：' + host);
  }
  return u;
}

// ── 取件 ─────────────────────────────────────────────────────
/**
 * @param {string} rawUrl
 * @param {{referer?: string, redirect?: number}=} opt
 * @returns {Promise<{buf: Buffer, mime: string, url: string}>}
 */
async function fetchBinary(rawUrl, opt) {
  const o = opt || {};
  const hops = o.redirect == null ? 5 : o.redirect;
  const u = await assertPublicUrl(rawUrl);

  const mod = u.protocol === 'https:' ? https : http;
  const headers = {
    'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
      '(KHTML, like Gecko) Chrome/122.0 Safari/537.36',
    Accept: '*/*',
    'Accept-Encoding': 'gzip, deflate, br',
  };
  if (o.referer) headers.Referer = o.referer;

  return new Promise((resolve, reject) => {
    const req = mod.request(
      u,
      { method: 'GET', headers, timeout: TIMEOUT_MS },
      (res) => {
        const code = res.statusCode || 0;
        if (code >= 300 && code < 400 && res.headers.location) {
          res.resume();
          if (hops <= 0) return reject(new Error('重定向次数过多'));
          const next = new URL(res.headers.location, u).toString();
          return resolve(fetchBinary(next, { ...o, redirect: hops - 1 }));
        }
        if (code < 200 || code >= 300) {
          res.resume();
          return reject(new Error('HTTP ' + code + ' · ' + u.toString().slice(0, 120)));
        }
        const enc = String(res.headers['content-encoding'] || '').toLowerCase();
        let stream = res;
        if (enc === 'gzip') stream = res.pipe(zlib.createGunzip());
        else if (enc === 'deflate') stream = res.pipe(zlib.createInflate());
        else if (enc === 'br') stream = res.pipe(zlib.createBrotliDecompress());

        const chunks = [];
        let size = 0;
        stream.on('data', (c) => {
          size += c.length;
          if (size > MAX_BYTES) {
            req.destroy();
            reject(new Error('超过单文件体积上限 ' + Math.round(MAX_BYTES / 1048576) + 'MB'));
            return;
          }
          chunks.push(c);
        });
        stream.on('end', () =>
          resolve({
            buf: Buffer.concat(chunks),
            mime: String(res.headers['content-type'] || '').split(';')[0].trim(),
            url: u.toString(),
          }),
        );
        stream.on('error', reject);
      },
    );
    req.on('timeout', () => {
      req.destroy();
      reject(new Error('请求超时（' + Math.round(TIMEOUT_MS / 1000) + 's）'));
    });
    req.on('error', reject);
    req.end();
  });
}

// ── HTML → 正文 ──────────────────────────────────────────────
const ENTITIES = {
  amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ', hellip: '…',
  mdash: '—', ndash: '–', ldquo: '“', rdquo: '”', lsquo: '‘', rsquo: '’',
  middot: '·', copy: '©', reg: '®', times: '×', divide: '÷', deg: '°',
};

function decodeEntities(s) {
  return String(s)
    .replace(/&#x([0-9a-f]+);/gi, (_, h) => safeChr(parseInt(h, 16)))
    .replace(/&#(\d+);/g, (_, d) => safeChr(parseInt(d, 10)))
    .replace(/&([a-z]+);/gi, (m, n) => {
      const v = ENTITIES[n.toLowerCase()];
      return v == null ? m : v;
    });
}

function safeChr(code) {
  try {
    return code > 0 && code < 0x110000 ? String.fromCodePoint(code) : '';
  } catch (_) {
    return '';
  }
}

/**
 * 粗糙但够用的正文提取：去掉脚本/样式/导航/页眉页脚，块级标签转换行。
 * 目标不是「完美还原排版」，而是**拿到可读的纯文本**，再交给 EPUB 重新排版。
 */
function htmlToText(html) {
  let s = String(html || '');
  s = s.replace(/<!--[\s\S]*?-->/g, '');
  s = s.replace(/<(script|style|noscript|svg|canvas|form|iframe)\b[\s\S]*?<\/\1>/gi, '');
  s = s.replace(/<(nav|header|footer|aside)\b[\s\S]*?<\/\1>/gi, '');
  // 标题保留层级感
  s = s.replace(/<h([1-6])\b[^>]*>([\s\S]*?)<\/h\1>/gi, (_, lv, inner) => `\n\n${stripTags(inner).trim()}\n\n`);
  // 段落/换行
  s = s.replace(/<br\s*\/?>/gi, '\n');
  s = s.replace(/<\/(p|div|li|tr|h[1-6]|blockquote|section|article)>/gi, '\n\n');
  s = s.replace(/<li\b[^>]*>/gi, '· ');
  s = s.replace(/<[^>]+>/g, '');
  s = decodeEntities(s);
  s = s.replace(/\r\n?/g, '\n');
  s = s.replace(/[ \t\u00a0]+/g, ' ');
  s = s.replace(/ *\n */g, '\n');
  s = s.replace(/\n{3,}/g, '\n\n');
  return s.trim();
}

function stripTags(s) {
  return decodeEntities(String(s).replace(/<[^>]+>/g, ''));
}

/** 从 HTML 里猜标题（<title> / og:title / 第一个 h1）。 */
function guessTitle(html) {
  const s = String(html || '');
  const og = s.match(/<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']+)["']/i);
  if (og) return decodeEntities(og[1]).trim();
  const h1 = s.match(/<h1\b[^>]*>([\s\S]*?)<\/h1>/i);
  if (h1) {
    const t = stripTags(h1[1]).trim();
    if (t) return t;
  }
  const t = s.match(/<title\b[^>]*>([\s\S]*?)<\/title>/i);
  if (t) return stripTags(t[1]).trim();
  return '';
}

module.exports = { fetchBinary, htmlToText, guessTitle, assertPublicUrl, isPrivateIp };
