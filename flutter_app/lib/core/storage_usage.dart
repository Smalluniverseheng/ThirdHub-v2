// ═══════════════════════════════════════════════════════════════════════════
// 存储明细的**IO 层** —— 读 SharedPreferences、扫应用私有目录，然后交给
// `storage_usage_plan.dart` 的 compute() 算成明细（规则全在那边）。
//
// 为什么单独分一层：本文件必须 import Flutter 插件（path_provider /
// shared_preferences），而 `dart run` 的自检拉不起 Flutter（本机 PUB_CACHE 为空、
// CI 也只跑 `dart run`）。分层之后，规则部分能被 `tool/storage_usage_selfcheck.dart`
// 用合成数据覆盖，IO 部分靠真机/装机后肉眼核对数量级。
// ═══════════════════════════════════════════════════════════════════════════
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'storage_usage_plan.dart';

export 'storage_usage_plan.dart';

/// 应用私有目录下的顶层名 → 明细行名。
///
/// ★ 不在这里的名字**不会被丢掉**，而是汇总进「其他」—— 这样"合计"永远等于
///   真实占用。漏统计比统计错更糟：用户拿这个页面对账系统设置里的占用时，
///   差额会被当成 bug（上一次就是这么来的）。
const Map<String, String> _topLabels = <String, String>{
  'logs.jsonl': '日志',
  'ThirdHub': '接收文件',
  'offline_media': '离线媒体',
  'offline_books': '离线书',
  'local_novel': '本地导入',
  'local_comic': '本地导入',
  'local_video': '本地导入',
  'local_music': '本地导入',
  'jobs': '任务产物',
};

/// 明细的固定行序（稳定顺序比"按大小降序"更好核对：用户记得住位置）。
const List<String> _rowOrder = <String>[
  '日志',
  '接收文件',
  '离线媒体',
  '离线书',
  '本地导入',
  '任务产物',
  '其他',
];

/// 扫一次：prefs 全量快照 + 私有目录占用 → 明细。
///
/// 幂等、不写任何东西。统计失败的那一项按 0 计（不会让整页崩掉）。
Future<StorageUsage> scanStorageUsage() async {
  final SharedPreferences p = await SharedPreferences.getInstance();
  final Map<String, dynamic> prefs = <String, dynamic>{
    for (final k in p.getKeys()) k: p.get(k),
  };

  final Map<String, _Agg> agg = <String, _Agg>{};

  void add(String label, int files, int bytes) {
    final _Agg a = agg.putIfAbsent(label, () => _Agg());
    a.files += files;
    a.bytes += bytes;
  }

  try {
    final Directory docs = await getApplicationDocumentsDirectory();
    if (await docs.exists()) {
      await for (final FileSystemEntity e in docs.list(followLinks: false)) {
        final String name = _baseName(e);
        final String label = _topLabels[name] ?? '其他';
        if (e is File) {
          int len = 0;
          try {
            len = await e.length();
          } catch (_) {}
          add(label, 1, len);
        } else if (e is Directory) {
          final _Agg s = await _walk(e);
          add(label, s.files, s.bytes);
        }
      }
    }
  } catch (_) {
    // 目录不可读（权限/沙箱）时留空 —— 明细里对应行显示 0，不冒充"没有数据"以外的结论
  }

  final List<DirStat> dirs = <DirStat>[
    for (final String l in _rowOrder)
      if (agg.containsKey(l)) DirStat(l, agg[l]!.files, agg[l]!.bytes),
  ];

  return StorageUsage.compute(prefs: prefs, dirs: dirs);
}

String _baseName(FileSystemEntity e) {
  final List<String> seg = e.uri.pathSegments.where((s) => s.isNotEmpty).toList();
  return seg.isEmpty ? e.path : seg.last;
}

/// 递归统计一个目录：文件数 + 字节数。单个文件读不到就跳过，不影响整体。
Future<_Agg> _walk(Directory d) async {
  final _Agg a = _Agg();
  try {
    await for (final FileSystemEntity f in d.list(recursive: true, followLinks: false)) {
      if (f is! File) continue;
      a.files++;
      try {
        a.bytes += await f.length();
      } catch (_) {}
    }
  } catch (_) {}
  return a;
}

class _Agg {
  int files = 0;
  int bytes = 0;
}
