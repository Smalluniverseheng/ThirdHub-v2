// 「云存储」明细的规则自检（纯 Dart VM 可跑，零 Flutter 依赖）
//
//   dart run tool/storage_usage_selfcheck.dart
//
// ─────────────────────────────────────────────────────────────────────────────
// 为什么需要这条闸门（2026-11-02，待办清单第 2 项）：
//   1. 明细的**算法**（口径、分组、合计）如果错了，界面会显示一个看起来
//      很像真的、但完全对不上的数字 —— 而"数字错了"在界面上和"数字对了"
//      长得一模一样，没有断言就只能靠人肉对账。
//   2. 更要紧的是**动态 i18n key**：`i18n_selfcheck.dart` 用正则收集
//      `tr('字面量')`，而明细行是**数据驱动**的（`tr(r.label)`），
//      那批中文 key 它一个都看不见 —— 正好绕开"6 语言必须齐全"这条铁律。
//      所以本文件独立把「明细会吐出来的每个 label / unit」逐个查一遍字典。
//
//   ★ 这是"闸门绿 ≠ 没漏"的第二次应用：上一轮 i18n_selfcheck 对
//     `Text('中文')` 全绿而 lib/ 里有 1173 条硬编码，同一个病。
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:io';

import '../lib/core/storage_usage_plan.dart';

int pass = 0, fail = 0;
void ck(String name, bool ok) {
  if (ok) {
    pass++;
  } else {
    fail++;
    print('  FAIL  $name');
  }
}

const kLocales = ['en', 'ja', 'fr', 'ru', 'es', 'ar'];

/// 明细里**动态**出现的 label / unit（`tr(r.label)` 那种）。
///
/// 与 storage_usage_plan.dart 的 UsageRow 字面量一一对应；下面 §3 会
/// 反过来断言这些词确实出现在 plan 源码里，防止这边写完就漂了。
const kDynamicLabels = <String>[
  '文件', '会话', '设置', // 分组标题
  '日志', '接收文件', '离线媒体', '离线书', '本地导入', '任务产物', '其他', // 文件行
  '聊天会话', '消息记录', '待发消息', // 会话行
  '本机设置项', // 设置行
  '项', '个', '条', // 数量单位
];

/// cloud.dart 的 `CloudTableStat.label` 会吐出来的词。
const kCloudLabels = <String>['云端设置', '书架', '阅读进度', '历史', '收藏', '设备'];

/// 解析 `<locale>: { ... }` 块，抽出 `键: 值` 对。
///
/// 简化版（相比 i18n_selfcheck 的正则+括号配对）：这里只需要"键在不在"，
/// 因此按语言块切片后直接找 `'<key>':` 即可 —— 值里出现同样的串概率极低，
/// 且误判方向是"更严格"（认为有），不会掩盖缺译。
Map<String, Set<String>> dictKeys(String src) {
  final out = <String, Set<String>>{};
  final re = RegExp(r"'([a-z]{2})'\s*:\s*(?:<[^>]*>\s*)?\{");
  for (final m in re.allMatches(src)) {
    final loc = m.group(1)!;
    if (!kLocales.contains(loc)) continue;
    final start = src.indexOf('{', m.end - 1);
    var depth = 0, i = start;
    while (i < src.length) {
      final c = src[i];
      if (c == "'" || c == '"') {
        var j = i + 1;
        while (j < src.length) {
          if (src[j] == r'\') {
            j += 2;
            continue;
          }
          if (src[j] == c) break;
          j++;
        }
        i = j + 1;
        continue;
      }
      if (c == '{') depth++;
      if (c == '}') {
        depth--;
        if (depth == 0) break;
      }
      i++;
    }
    final body = src.substring(start + 1, i);
    final keys = out.putIfAbsent(loc, () => <String>{});
    for (final k in RegExp(r"'((?:[^'\\]|\\.)*)'\s*:").allMatches(body)) {
      keys.add(k.group(1)!.replaceAll(r"\'", "'"));
    }
  }
  return out;
}

void main() {
  // ── 1. 大小格式化 ──
  print('== 1. formatSize ==');
  ck('0 → 0 B', StorageUsage.formatSize(0) == '0 B');
  ck('负数 → 0 B', StorageUsage.formatSize(-5) == '0 B');
  ck('512 → 512 B', StorageUsage.formatSize(512) == '512 B');
  ck('1024 → 1 KB', StorageUsage.formatSize(1024) == '1 KB');
  ck('1536 → 1.5 KB', StorageUsage.formatSize(1536) == '1.5 KB');
  ck('1MB → 1 MB', StorageUsage.formatSize(1024 * 1024) == '1 MB');
  ck('1.5MB → 1.5 MB',
      StorageUsage.formatSize((1.5 * 1024 * 1024).round()) == '1.5 MB');
  ck('105MB → 105 MB（≥100 不留小数，避免 104.9MB 这种看着像 bug 的数）',
      StorageUsage.formatSize(105 * 1024 * 1024) == '105 MB');
  ck('1.5GB → 1.5 GB',
      StorageUsage.formatSize((1.5 * 1024 * 1024 * 1024).round()) == '1.5 GB');

  // ── 2. compute() 口径 ──
  print('== 2. compute() 分组与合计 ==');
  final prefs = <String, dynamic>{
    // 20 个普通设置键
    for (var i = 0; i < 20; i++) 'setting_$i': 'v$i',
    'chat_sessions': ['a', 'b', 'c'], // 3 个会话
    'chat_msgs_a': ['m1', 'm2', 'm3', 'm4', 'm5'], // 5 条消息
    'chat_outbox': ['x', 'y'], // 2 条待发
  };
  final dirs = <DirStat>[
    const DirStat('日志', 1, 2048),
    const DirStat('接收文件', 3, 4096),
  ];
  final u = StorageUsage.compute(prefs: prefs, dirs: dirs);

  ck('分组顺序固定为 文件 → 会话 → 设置',
      u.groups.map((g) => g.title).join(',') == '文件,会话,设置');

  final files = u.groups[0], chats = u.groups[1], sets = u.groups[2];
  ck('文件组：条数 = 4（1 日志 + 3 接收）', files.count == 4);
  ck('文件组：字节 = 6144', files.bytes == 6144);
  ck('会话组：条数 = 3 + 5 + 2 = 10', chats.count == 10);
  ck('设置组：条数 = 20（chat_* 一律不算设置）', sets.count == 20);
  ck('设置组：3 个 chat 键没有漏进设置', sets.rows.length == 1);

  // 合计必须等于"所有 prefs 字节 + 所有目录字节"，不能多也不能少
  var prefsBytes = 0;
  prefs.forEach((k, v) {
    prefsBytes += k.length; // 合成数据全是 ASCII，utf8 长度 = 字符数
    if (v is List) {
      for (final e in v) {
        prefsBytes += '$e'.length;
      }
    } else {
      prefsBytes += '$v'.length;
    }
  });
  ck('合计 = prefs($prefsBytes) + 目录(6144)',
      u.totalBytes == prefsBytes + 6144);

  // ── 3. 空数据不许崩 ──
  print('== 3. 空数据 ==');
  final empty = StorageUsage.compute(prefs: <String, dynamic>{}, dirs: const []);
  ck('空数据：合计 0', empty.totalBytes == 0 && empty.totalItems == 0);
  ck('空数据：仍然有 3 个分组（界面不会缺块）', empty.groups.length == 3);
  ck('settingsGroup 能定位到设置组', empty.settingsGroup.title == '设置');

  // ── 4. 动态 i18n key：6 语言必须齐全 ──
  print('== 4. 明细文案 6 语言覆盖（i18n_selfcheck 看不见的那批） ==');
  final d = <String, Set<String>>{};
  for (final f in ['lib/core/i18n.dart', 'lib/core/i18n_extra.dart', 'lib/core/i18n_ui_words.dart']) {
    final src = File(f).existsSync() ? File(f).readAsStringSync() : '';
    ck('能读到 $f', src.isNotEmpty);
    final part = dictKeys(src);
    part.forEach((loc, keys) => d.putIfAbsent(loc, () => <String>{}).addAll(keys));
  }

  // plan 与 IO 层源码里必须真的出现过这些词，否则本清单就是一份过期的白名单
  // （行名分两处：文件类在 storage_usage.dart 的 _topLabels，其余在 plan 的 compute）
  final planSrc = File('lib/core/storage_usage_plan.dart').readAsStringSync() +
      File('lib/core/storage_usage.dart').readAsStringSync();
  final staleLabels =
      kDynamicLabels.where((k) => !planSrc.contains("'$k'")).toList();
  ck('清单与 plan 源码一致（plan 里找不到的：$staleLabels）', staleLabels.isEmpty);

  final cloudSrc = File('lib/core/cloud.dart').readAsStringSync();
  final staleCloud =
      kCloudLabels.where((k) => !cloudSrc.contains("return '$k';")).toList();
  ck('云端行文案与 cloud.dart 一致（对不上的：$staleCloud）', staleCloud.isEmpty);

  final all = <String>{...kDynamicLabels, ...kCloudLabels,
    '存储明细', '按类别列出存了什么、各占多少', '重新统计', '统计中…',
    '读取失败', '上次同步', '尚未同步', '不限', '云配额 {used} / {total}',
    '本机合计 {size} · {n} 项', '{n} {unit}', '云端',
    '未登录 · 登录后显示云端明细',
    '只有账号数据计入云配额；会话与文件存在本机或自己的后端，不占配额',
    '文件部分统计的是应用私有目录（含离线/导入/接收/日志）；系统相册与外部存储不在其中',
  };
  for (final loc in kLocales) {
    final miss = all.where((k) => !(d[loc]?.contains(k) ?? false)).toList()..sort();
    if (miss.isNotEmpty) print('  [$loc] 缺：${miss.join(' / ')}');
    ck('$loc 覆盖全部 ${all.length} 个明细文案', miss.isEmpty);
  }

  print('');
  print('PASS $pass   FAIL $fail');
  if (fail == 0) {
    print('\n✅ 存储明细：口径/合计/空数据/6 语言文案 全部通过');
  }
  if (fail > 0) exit(1);
}
