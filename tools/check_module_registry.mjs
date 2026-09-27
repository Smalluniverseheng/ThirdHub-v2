/**
 * 共享模块注册表一致性闸门：
 * 比对 flutter_app/lib/core/module_registry.dart 与 D:/ai/deep seek/js/module-registry.js
 * 的 REGISTRY-BEGIN..REGISTRY-END 表体 —— 必须**逐字相同**（含注释）。
 *
 * 为什么：两端各存一份注册表（Dart 给 App、JS 给网页），是「并集注册表」
 * 跨仓钉一致性的唯一保障。只改一端 = 映射悄悄分叉 = 又回到「两个产物」。
 *
 * 用法: node tools/check_module_registry.mjs   # 退出码 0 = 一致，1 = 不一致
 */
import fs from 'node:fs';

const DART = 'D:/ai/thirdhub-v4/flutter_app/lib/core/module_registry.dart';
const JS = 'D:/ai/deep seek/js/module-registry.js';

function extract(file) {
  const txt = fs.readFileSync(file, 'utf8');
  const m = txt.match(/★ REGISTRY-BEGIN[\s\S]*?★ REGISTRY-END/);
  if (!m) throw new Error(`${file}: 找不到 REGISTRY-BEGIN..END 区间`);
  // 只比「表体行」：ModuleRegEntry(...) 数据行 + 分组注释。跳过两端语法不同的
  // 声明行（Dart 是 const List<...> = [...]; JS 是 function 声明 + export const [...]）。
  return m[0]
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => (l.startsWith('ModuleRegEntry(') || (l.startsWith('//') && !l.startsWith('///'))) && !l.includes('REGISTRY-END'))
    .map((l) => l.replace(/,\s*$/, ','));
}

const a = extract(DART);
const b = extract(JS);
const len = Math.max(a.length, b.length);
let bad = 0;
for (let i = 0; i < len; i++) {
  const x = a[i] ?? '<缺行>', y = b[i] ?? '<缺行>';
  if (x !== y) {
    bad++;
    console.log(`第 ${i + 1} 行不一致:\n  dart: ${x}\n  js  : ${y}`);
  }
}
if (bad) {
  console.log(`\n✗ 注册表不一致 ${bad} 处（表体 ${a.length} vs ${b.length} 行）`);
  process.exit(1);
}
const rows = a.filter((l) => l.startsWith('ModuleRegEntry(')).length;
console.log(`✓ 注册表一致：表体 ${a.length} 行 / ${rows} 条目，两端逐字相同`);

// ── 二、App 键覆盖检查：注册表 appKeys ⇄ main.dart kModules 键 必须双向无遗漏 ──
const mainDart = fs.readFileSync('D:/ai/thirdhub-v4/flutter_app/lib/main.dart', 'utf8');
const km = mainDart.match(/final Map<String, ModuleDef> kModules = \{[\s\S]*?\n\};/);
if (!km) throw new Error('main.dart: 找不到 kModules 定义');
const kKeys = new Set([...km[0].matchAll(/^\s*'([^']+)':/gm)].map((m) => m[1]));
const regKeys = new Set(
  a.filter((l) => l.startsWith('ModuleRegEntry('))
    .flatMap((l) => [...l.matchAll(/\[\]|\[('[^']*'(?:, '[^']*')*)\]/g)]
      .flatMap((m) => (m[1] ? [...m[1].matchAll(/'([^']+)'/g)].map((x) => x[1]) : [])))
);
let cov = 0;
for (const k of kKeys) if (!regKeys.has(k)) { cov++; console.log(`✗ kModules 键未登记进注册表: ${k}`); }
for (const k of regKeys) if (!kKeys.has(k)) { cov++; console.log(`✗ 注册表 App 键不在 kModules 里: ${k}`); }
if (cov) { console.log(`\n✗ App 键覆盖检查失败 ${cov} 处（kModules ${kKeys.size} 键 vs 注册表 ${regKeys.size} 键）`); process.exit(1); }
console.log(`✓ App 键覆盖：kModules ${kKeys.size} 键 ⇄ 注册表 ${regKeys.size} 键 双向无遗漏`);
