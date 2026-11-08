// 上游: kodjodevf/mangayomi@91bda20a9235 | 许可证: Apache-2.0 | 方式: 本地最小类型投影（非上游文件）
// 台账: vendor/MANIFEST.json → ported[id=mangayomi_chapter_download_shim]
// 上游路径: lib/models/chapter.dart / lib/models/download.dart
//
// 本地最小类型投影：不是上游文件、不含任何上游运行逻辑。
// 上游 Chapter / Download 挂在 Isar 模型、riverpod provider 与 repository 上，
// 整套搬进移动端等于把半座书架拖进来；这里只投影 next_downloads.dart
// 算法实际读到的 5 个字段，字段名与语义与上游保持一致。

class Chapter {
  const Chapter({required this.id, this.isRead});

  final String id;
  final bool? isRead;
}

class Download {
  const Download({required this.id, this.isDownload, this.isStartDownload});

  final String id;
  final bool? isDownload;
  final bool? isStartDownload;
}
