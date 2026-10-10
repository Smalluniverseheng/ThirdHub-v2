#!/usr/bin/env node
/**
 * ios_sign_bundle.mjs —— 把签好名的 .ipa 变成「Safari 点一下就装」的分发清单
 *
 * 为什么需要它：
 *   苹果的 OTA 安装需要一个 manifest.plist，里面要写**准确的** bundle-id /
 *   版本号 / ipa 的 https 地址。手写这四样最容易错一个字符，而错了之后
 *   iPhone 只给一句"无法连接"—— 完全看不出是哪一项错了。
 *   这个脚本从 .ipa 里**读真实值**，把清单填好，并打印安装链接。
 *
 * 用法：
 *   node tools/ios_sign_bundle.mjs \
 *     --ipa downloads/ios/ThirdHub-iOS-4.66.0.ipa \
 *     --base-url https://thirdhub.pages.dev/downloads/ios \
 *     [--bundle-id com.thirdhub.app] [--name ThirdHub] [--version 4.66.0]
 *
 * 不给 --bundle-id/--version 时会尝试从 .ipa 的 Info.plist 里读。
 * 脚本**只读你的包、只写清单**，不接触证书与私钥。
 */
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import zlib from 'node:zlib';

const argv = process.argv.slice(2);
const arg = (k, d = '') => {
  const i = argv.indexOf('--' + k);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : d;
};

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')), '..');

/* ★ 出货面（downloads/ios/）在**网页端仓**里，不在 thirdhub-v4 里 —— 2026-10-10 修。
   原版把模板路径写死成 ROOT/downloads/ios/manifest.plist，于是必然报
   「缺 manifest.plist 模板」（因为 v4 仓里根本没有 downloads 目录）。
   现在按顺序找：--web 参数 > 环境变量 TH_WEB_ROOT > 常见路径。 */
function findWebRoot() {
  const cands = [];
  if (arg('web')) cands.push(arg('web'));
  if (process.env.TH_WEB_ROOT) cands.push(process.env.TH_WEB_ROOT);
  cands.push(path.resolve(ROOT, '..', 'deep seek'));   // 本机约定：与 v4 平级
  cands.push(path.resolve(ROOT, '..', 'thirdhub-web'));
  cands.push(ROOT);                                     // 兜底：就在本仓
  for (const c of cands) {
    if (c && fs.existsSync(path.join(c, 'downloads', 'ios'))) return c;
  }
  return null;
}
const WEB_ROOT = findWebRoot();
if (!WEB_ROOT) {
  console.error('[x] 找不到网页端仓（downloads/ios/ 在哪）。');
  console.error('    用 --web=<网页端根> 指定，或设环境变量 TH_WEB_ROOT。');
  process.exit(2);
}
const IOS_DIR = path.join(WEB_ROOT, 'downloads', 'ios');
const ipaRel = arg('ipa');
if (!ipaRel) {
  console.error('用法： node tools/ios_sign_bundle.mjs --ipa <path.ipa> [--base-url https://...] [--bundle-id ..] [--version ..]');
  process.exit(2);
}
// 允许相对仓库根，也允许绝对路径
const ipa = path.isAbsolute(ipaRel) ? ipaRel : path.resolve(ROOT, ipaRel);
if (!fs.existsSync(ipa)) {
  console.error('[x] 找不到 .ipa：' + ipa);
  console.error('    先按 downloads/ios/README.html 第 2~3 步在 Mac 上签好名并打包。');
  process.exit(2);
}

const baseUrl = arg('base-url', 'https://thirdhub.pages.dev/downloads/ios').replace(/\/+$/, '');
const baseName = path.basename(ipa);

/* ── 1. 校验和与体积 ── */
const buf = fs.readFileSync(ipa);
const sha = crypto.createHash('sha256').update(buf).digest('hex');
const sizeMB = (buf.length / 1048576).toFixed(2);

/* ── 2. 从 .ipa 里读 Info.plist（能读到就自动填，读不到就用参数）──
   ★ 2026-10-10：改为**纯 Node 实现**。原版用 `unzip` + `plutil` 两个外部命令，
   而 Windows 上 Git Bash 没有 unzip、也没有 plutil → 永远走到 fallback，
   表现为「明明包里有 Info.plist，脚本却说读不到」，用户只能手工敲 bundle-id。
   现在自己解析 zip（中央目录 + 解压），到哪儿都能跑。 */
function readInfoPlist() {
  let buf;
  try { buf = fs.readFileSync(ipa); } catch (e) { return null; }

  // 找 End Of Central Directory（从尾部往回扫，容忍 zip 注释）
  let eocd = -1;
  for (let i = buf.length - 22; i >= Math.max(0, buf.length - 66000); i--) {
    if (buf.readUInt32LE(i) === 0x06054b50) { eocd = i; break; }
  }
  if (eocd < 0) return null;
  const count = buf.readUInt16LE(eocd + 10);
  let off = buf.readUInt32LE(eocd + 16);

  // 遍历中央目录，找 Payload/*/Info.plist
  for (let n = 0; n < count && off + 46 <= buf.length; n++) {
    if (buf.readUInt32LE(off) !== 0x02014b50) break;
    const nameLen = buf.readUInt16LE(off + 28);
    const extraLen = buf.readUInt16LE(off + 30);
    const cmtLen = buf.readUInt16LE(off + 32);
    const lho = buf.readUInt32LE(off + 42);
    const name = buf.toString('utf8', off + 46, off + 46 + nameLen);
    if (/^Payload\/[^/]+\/Info\.plist$/.test(name)) {
      // 从本地文件头取数据
      if (buf.readUInt32LE(lho) === 0x04034b50) {
        const ln = buf.readUInt16LE(lho + 26), le = buf.readUInt16LE(lho + 28);
        const method = buf.readUInt16LE(lho + 8);
        const csize = buf.readUInt32LE(lho + 18);
        const start = lho + 30 + ln + le;
        const raw = buf.subarray(start, start + csize);
        try {
          const out = method === 8 ? zlib.inflateRawSync(raw) : raw;
          return parseXml(String(out));
        } catch (e) { return null; }
      }
    }
    off += 46 + nameLen + extraLen + cmtLen;
  }
  return null;
}

/** 从 Info.plist 的 XML 文本里取三个字段（不依赖 plutil） */
function parseXml(txt) {
  const pick = (key) => {
    const m = txt.match(new RegExp('<key>' + key + '</key>\\s*<(?:string|integer)>([^<]*)</'));
    return m ? String(m[1]).trim() : '';
  };
  return {
    bundleId: pick('CFBundleIdentifier'),
    version: pick('CFBundleShortVersionString'),
    name: pick('CFBundleDisplayName') || pick('CFBundleName'),
  };
}

const info = readInfoPlist() || {};
const bundleId = arg('bundle-id', info.bundleId || 'com.thirdhub.app');
const version = arg('version', info.version || '0.0.0');
const appName = arg('name', info.name || 'ThirdHub');

/* ── 3. 填清单 ── */
const tplPath = path.join(IOS_DIR, 'manifest.plist');
if (!fs.existsSync(tplPath)) { console.error('[x] 缺 manifest.plist 模板：' + tplPath); process.exit(2); }
let plist = fs.readFileSync(tplPath, 'utf8');
const iconUrl = arg('icon-url', baseUrl.replace(/\/downloads\/ios$/, '/icons/icon-512.png'));
plist = plist
  .replace(/\{\{IPA_URL\}\}/g, baseUrl + '/' + baseName)
  .replace(/\{\{ICON_URL\}\}/g, iconUrl)
  .replace(/\{\{BUNDLE_ID\}\}/g, bundleId)
  .replace(/\{\{APP_VERSION\}\}/g, version)
  .replace(/\{\{APP_NAME\}\}/g, appName);

const outPlist = path.join(IOS_DIR, 'manifest.plist');
fs.writeFileSync(outPlist, plist, 'utf8');

/* ── 4. 校验和文件 ── */
const sums = path.join(IOS_DIR, 'SHA256SUMS.txt');
const prev = fs.existsSync(sums) ? fs.readFileSync(sums, 'utf8') : '';
const line = sha + '  ' + baseName;
const next = prev.split('\n')
  .filter((l) => l.trim() && !l.endsWith('  ' + baseName))
  .concat(line).filter(Boolean).join('\n') + '\n';
fs.writeFileSync(sums, next, 'utf8');

/* ── 5. 打印结果 ── */
const itms = 'itms-services://?action=download-manifest&url=' + encodeURIComponent(baseUrl + '/manifest.plist');
console.log('');
console.log('=== iOS 分发清单已生成 ===');
console.log('  App 名称    : ' + appName);
console.log('  Bundle ID   : ' + bundleId + (info.bundleId ? '   (读自 .ipa)' : '   (来自参数)'));
console.log('  版本        : ' + version + (info.version ? '   (读自 .ipa)' : '   (来自参数)'));
console.log('  包体积      : ' + sizeMB + ' MB');
console.log('  SHA256      : ' + sha);
console.log('  清单        : downloads/ios/manifest.plist');
console.log('');
console.log('  ★ 前提：下列两个地址必须能通过 https 打开（http 会被 iOS 拒绝）');
console.log('      ' + baseUrl + '/' + baseName);
console.log('      ' + baseUrl + '/manifest.plist');
console.log('');
console.log('  在 iPhone 的 Safari 里打开这个链接即可安装：');
console.log('      ' + itms);
console.log('');
console.log('  或者把下面这段做成网页上的按钮：');
console.log('      <a href="' + itms + '">安装 iOS 版</a>');
console.log('');

// 自检：填完后不应残留占位符
const left = plist.match(/\{\{[A-Z_]+\}\}/g);
if (left) { console.error('[x] 清单仍有未替换占位符：' + [...new Set(left)].join(', ')); process.exit(1); }
console.log('[ok] 清单无残留占位符');
