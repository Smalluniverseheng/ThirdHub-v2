// 后端 0.8.8 EXE（修正 SEA 打包方案）
//
// ★ 老脚本为什么产出的 EXE 起不来（2026-11-07 实测）：
//   它把 polyfill + _sea_deps.js + index.js 三段文本直接拼成 combined.js，
//   但 index.js 里的 `require('./package.json')` / `require('./routes-*')` 在
//   Node SEA 里走的是 embedderRequire —— **只认内置模块**，相对路径一律
//   `ERR_UNKNOWN_BUILTIN_MODULE`。实测启动 1 秒即崩：
//     Error [ERR_UNKNOWN_BUILTIN_MODULE]: No such built-in module: ./package.json
//   所以旧 ThirdHubBackend.exe 其实一直不能运行，只是"文件存在"而已。
//
// 正解：让 esbuild 把 server/index.js 连同所有本地模块与 node_modules
// **全量 bundle** 成一个 CJS 文件（4.3MB），运行时零相对 require，
// 再把这个文件作为 SEA 的 main 注入。
'use strict';
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { execFileSync } = require('child_process');

const ROOT = 'D:/ai/thirdhub-v4';
const SRC = ROOT + '/server';
const OUT = ROOT + '/build-out/_pkgsrc';
const NODE_BIN = 'C:/Users/英莉/.workbuddy/binaries/node/versions/22.22.2-6/node.exe';
const ESBUILD = 'D:/ai/_deploy-tools/esbuild-0.28.2.exe';
const POSTJECT = 'C:/Users/英莉/.workbuddy/binaries/node/workspace/node_modules/postject/dist/cli.js';
const FUSE = 'NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2';
const FINAL = ROOT + '/server/ThirdHubBackend.exe';

function run(cmd, args, opts) {
  return execFileSync(cmd, args, { encoding: 'utf8', ...opts });
}
const sha = (b) => crypto.createHash('sha256').update(b).digest('hex');

(async () => {
  fs.mkdirSync(OUT, { recursive: true });

  console.log('[1/5] esbuild 全量 bundle server/index.js（本地模块 + node_modules 全内联）');
  console.log(run(ESBUILD, [
    'index.js', '--bundle', '--platform=node', '--target=node22',
    '--format=cjs', '--outfile=' + path.join(OUT, 'combined.js'),
  ], { cwd: SRC }).trim().split('\n').slice(-3).join(' '));
  const combined = fs.readFileSync(path.join(OUT, 'combined.js'), 'utf8');
  if (combined.length < 1000000) throw new Error('bundle 太小，疑似没打进依赖：' + combined.length);
  if (/require\(["']\.\//.test(combined)) {
    throw new Error('bundle 里仍残留相对 require，SEA 会崩');
  }
  console.log('    combined.js ' + (combined.length / 1048576).toFixed(2) + ' MB，无相对 require');

  console.log('[2/5] sea-config.json');
  fs.writeFileSync(path.join(OUT, 'sea-config.json'), JSON.stringify({
    main: 'combined.js',
    output: 'sea-prep.blob',
    disableExperimentalSEAWarning: true,
    useSnapshot: false,
    useCodeCache: false,
    useLargePages: true,
  }, null, 2));

  console.log('[3/5] node --experimental-sea-config');
  console.log(run(process.execPath, ['--experimental-sea-config', 'sea-config.json'], { cwd: OUT }).trim());
  const blob = path.join(OUT, 'sea-prep.blob');
  if (!fs.existsSync(blob)) throw new Error('sea-prep.blob 没生成');
  console.log('    blob ' + fs.statSync(blob).size + ' B');

  const exe = path.join(OUT, 'ThirdHubBackend.exe');
  console.log('[4/5] 复制 Node 二进制 + postject 注入');
  fs.copyFileSync(NODE_BIN, exe);
  const before = fs.statSync(exe).size;
  console.log(run(process.execPath, [
    POSTJECT, exe, 'NODE_SEA_BLOB', blob, '--sentinel-fuse=' + FUSE,
  ], { cwd: OUT }).trim() || '    (postject 无输出)');
  const after = fs.statSync(exe).size;
  if (after <= before) throw new Error('注入后 exe 没变大');
  if (!fs.readFileSync(exe).includes(Buffer.from(FUSE))) throw new Error('找不到 SEA fuse');
  console.log('    ' + before + ' → ' + after + ' B');

  console.log('[5/5] 备份旧 EXE 后替换交付物');
  if (fs.existsSync(FINAL)) {
    const bak = FINAL + '.bad-sea-' + new Date().toISOString().slice(0, 10).replace(/-/g, '');
    fs.copyFileSync(FINAL, bak);
    console.log('    旧包已备份 ' + bak);
  }
  fs.copyFileSync(exe, FINAL);
  if (sha(fs.readFileSync(exe)) !== sha(fs.readFileSync(FINAL))) {
    throw new Error('交付物与产物 sha 不一致');
  }
  console.log('OK  ' + FINAL + '  ' + (after / 1048576).toFixed(1) + ' MB');
})().catch(e => { console.error('FATAL', e.message); process.exit(1); });
