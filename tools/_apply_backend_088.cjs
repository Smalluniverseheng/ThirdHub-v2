// 桌面端 0.8.8：挂数据源分层端点 + bump 版本（全盘升级 #208/#209）
'use strict';
const fs = require('fs');
const ROOT = 'D:/ai/thirdhub-v4/';
const L = (a) => a.join('\n');

function edit(file, reps) {
  const p = ROOT + file;
  let raw = fs.readFileSync(p, 'utf8');
  const crlf = raw.includes('\r\n');
  let s = crlf ? raw.replace(/\r\n/g, '\n') : raw;
  const before = s.length;
  for (const [name, old, nw] of reps) {
    const n = s.split(old).length - 1;
    if (n !== 1) throw new Error(file + ' 锚点[' + name + ']出现 ' + n + ' 次');
    s = s.replace(old, nw);
  }
  if (s.length < before - 1000 || s.length > before + 4000) {
    throw new Error(file + ' 长度安全闸：' + before + ' → ' + s.length);
  }
  const out = crlf ? s.replace(/\n/g, '\r\n') : s;
  fs.writeFileSync(p, out, 'utf8');
  console.log('OK ' + file + '  ' + before + ' → ' + s.length + ' chars');
}

edit('server/index.js', [
  ['require',
    L(["const rtAgent = require('./routes-agent');"]),
    L(["const rtAgent = require('./routes-agent');",
       "const rtDataSources = require('./routes-data-sources');"])],
  ['public endpoint',
    L(["  // 其余全需鉴权"]),
    L(["  // ── 数据源分层（免鉴权）：移动端 / 公开网页端只读官方公开清单（全盘升级 #208）──",
       "  //   ★ 必须在鉴权闸门之前：移动端还没配对时也要能拿到「哪些是官方公开接口」。",
       "  //   第三方内容源只在 /v1/admin/* 端点，且必须持配对 token（见下方）。",
       "  if (await rtDataSources.handlePublic(req, res, p, send)) return;",
       "",
       "  // 其余全需鉴权"])],
  ['admin endpoint',
    L(["  // ── 媒体路由(音乐/漫画/影视): server/routes-media.js ──",
       "  if (await media.handle(req, res, body, u, p, send, mediaCtx)) return;"]),
    L(["  // ── 数据源分层（管理后台，全盘升级 #209）：敏感源注册表 + 授权账号 ──",
       "  //   挂在 x-th-token 闸门之后 —— 只有管理员设备（或管理员授权后持配对码的设备）能读。",
       "  if ((await rtDataSources.handleAdmin(req, res, body, p, send, dataCtx)) || res.writableEnded) return;",
       "  // ── 媒体路由(音乐/漫画/影视): server/routes-media.js ──",
       "  if (await media.handle(req, res, body, u, p, send, mediaCtx)) return;"])],
]);

edit('server/package.json', [
  ['version', '  "version": "0.8.7",', '  "version": "0.8.8",'],
]);

// docker-compose 的镜像 tag 跟着后端版本走，NAS 拉取时看得出是哪一版。
edit('server/docker-compose.yml', [
  ['image tag', '    image: thirdhub-backend:0.8.7', '    image: thirdhub-backend:0.8.8'],
]);
