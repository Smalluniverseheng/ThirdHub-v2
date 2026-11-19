'use strict';
/**
 * 安装包分发（★2026-11-19）
 *
 * 目的：App 更新不再只依赖云端（Supabase 1GB 限额、外网慢），
 * 局域网内直接从 NAS 拿包，秒装。
 *
 * 路由：
 *   GET /v1/dl/app                → 可用安装包清单
 *   GET /v1/dl/app/latest.apk     → 最新安装包（流式，支持 Range）
 *   GET /v1/dl/app/<name>.apk     → 指定版本
 *
 * 目录：/app/data/apk（宿主机 /vol1/docker/thirdhub/data/apk）
 * 安全：只认白名单文件名（thirdhub-app-*.apk / thirdhub-app.apk），拒绝路径穿越。
 */
const fs = require('fs');
const path = require('path');

const APK_DIR = process.env.TH_APK_DIR || path.join(__dirname, 'data', 'apk');
const NAME_RE = /^thirdhub-app(-[0-9.]+)?\.apk$/;

function send(res, code, obj) {
  const body = Buffer.from(JSON.stringify(obj), 'utf8');
  res.writeHead(code, { 'content-type': 'application/json; charset=utf-8', 'content-length': body.length });
  res.end(body);
}

function listApks() {
  let names = [];
  try { names = fs.readdirSync(APK_DIR); } catch (e) { return []; }
  return names
    .filter((n) => NAME_RE.test(n))
    .map((n) => {
      const st = fs.statSync(path.join(APK_DIR, n));
      return { name: n, size: st.size, mtime: st.mtimeMs };
    })
    .sort((a, b) => b.mtime - a.mtime);
}

/** 最新 = 优先 thirdhub-app.apk 别名，否则取 mtime 最新的版本包 */
function latestName() {
  const all = listApks();
  if (!all.length) return '';
  const alias = all.find((x) => x.name === 'thirdhub-app.apk');
  return alias ? alias.name : all[0].name;
}

function streamFile(req, res, file) {
  let st;
  try { st = fs.statSync(file); } catch (e) { send(res, 404, { ok: false, error: '没有这个安装包' }); return; }
  const range = req.headers.range;
  const headers = {
    'content-type': 'application/vnd.android.package-archive',
    'accept-ranges': 'bytes',
    'cache-control': 'no-store',
  };
  if (range) {
    const m = /bytes=(\d*)-(\d*)/.exec(range);
    if (m) {
      const start = m[1] ? parseInt(m[1], 10) : 0;
      const end = m[2] ? Math.min(parseInt(m[2], 10), st.size - 1) : st.size - 1;
      if (start >= st.size || end < start) {
        res.writeHead(416, { 'content-range': 'bytes */' + st.size });
        res.end();
        return;
      }
      headers['content-range'] = 'bytes ' + start + '-' + end + '/' + st.size;
      headers['content-length'] = end - start + 1;
      res.writeHead(206, headers);
      fs.createReadStream(file, { start, end }).pipe(res);
      return;
    }
  }
  headers['content-length'] = st.size;
  res.writeHead(200, headers);
  fs.createReadStream(file).pipe(res);
}

/**
 * 由 index.js 调用。返回 true = 已处理。
 */
function handle(req, res, u, p) {
  if (p === '/v1/dl/app' || p === '/v1/dl/app/') {
    const items = listApks();
    send(res, 200, {
      ok: true,
      latest: latestName(),
      items,
      dir: APK_DIR,
    });
    return true;
  }
  if (p.startsWith('/v1/dl/app/')) {
    const name = decodeURIComponent(p.slice('/v1/dl/app/'.length));
    // latest.apk 是别名，先放行（它不在 NAME_RE 里）
    if (name === 'latest.apk') { streamFile(req, res, path.join(APK_DIR, latestName())); return true; }
    if (!NAME_RE.test(name)) { send(res, 400, { ok: false, error: '文件名不合法' }); return true; }
    streamFile(req, res, path.join(APK_DIR, name));
    return true;
  }
  send(res, 404, { ok: false, error: '未知操作' });
  return true;
}

module.exports = { handle, APK_DIR, listApks, latestName };
