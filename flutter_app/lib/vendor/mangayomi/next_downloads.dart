// 上游: kodjodevf/mangayomi@91bda20a9235 | 许可证: Apache-2.0 | 方式: 文件移植（算法正文逐字）
// 台账: vendor/MANIFEST.json → ported[id=mangayomi_download_ahead]
// 上游路径: lib/services/download_manager/next_downloads.dart
//
// download_ahead.dart 的规则内核：从当前项之后选出指定数量的后续项，
// 已完成 / 已排队的不占名额；当前项本身未下载时不预读。
// 上游两行绝对 import（Chapter / Download 模型）合并为一行相对 import，
// 指向本地最小类型投影 chapter_download_min.dart；算法正文逐字未改。
// 本项目按页粒度复用该规则：Chapter 投影为页、Download 投影为已预热页。
import 'chapter_download_min.dart';
/// Selects the next unread entries in reading order. Completed and already
/// queued downloads do not consume a slot in the requested batch size.
List<Chapter> selectNextDownloads(
  List<Chapter> chapters, {
  required int count,
  required Iterable<Download> downloads,
}) {
  if (count <= 0) return [];
  final unavailable = downloads
      .where(
        (download) =>
            download.isDownload == true || download.isStartDownload == true,
      )
      .map((download) => download.id)
      .toSet();
  return chapters
      .where(
        (chapter) =>
            chapter.isRead != true && !unavailable.contains(chapter.id),
      )
      .take(count)
      .toList();
}

/// The chapters to download ahead while [current] is read: the next [count]
/// unread chapters after it in [readingOrder], not already downloaded or
/// queued. Nothing when [current] itself is not downloaded: reading a chapter
/// online says nothing about wanting the next ones offline.
List<Chapter> selectDownloadAhead(
  List<Chapter> readingOrder,
  Chapter current, {
  required int count,
  required Iterable<Download> downloads,
}) {
  if (count <= 0) return [];
  final currentDownloaded = downloads.any(
    (download) => download.id == current.id && download.isDownload == true,
  );
  if (!currentDownloaded) return [];
  final index = readingOrder.indexWhere((c) => c.id == current.id);
  if (index < 0) return [];
  return selectNextDownloads(
    readingOrder.sublist(index + 1),
    count: count,
    downloads: downloads,
  );
}
