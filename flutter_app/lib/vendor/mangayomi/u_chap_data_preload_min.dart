// 上游: kodjodevf/mangayomi@91bda20a9235 | 许可证: Apache-2.0 | 方式: 上游类型字段投影（适配层，非算法）
// 台账: vendor/MANIFEST.json → ported[id=mangayomi_u_chap_shim]
// 上游路径: lib/services/reader/u_chap_data_preload.dart
//
// 为什么需要这一层：ReaderPageIndexMath 用到上游的 UChapDataPreload 类型，
// 而上游那个类挂在 Chapter / PageUrl / GetChapterPagesModel / DecodedImageBudget
// 等 7 个自有包上，整套搬进移动端等于把半座书架拖进来。这里只投影索引数学
// 真正读到的 6 个字段，名字与语义和上游一致，没有任何运行逻辑；
// 算法主体在 reader_page_index_math.dart 里除首行 import 外逐字未改。
//
// 本文件零 import、零 IO、零界面文案，可在纯 Dart VM 下独立编译。
class UChapDataPreload {
  UChapDataPreload({
    this.chapter,
    this.index,
    this.isTransitionPage = false,
    this.loadedWidth,
    this.loadedHeight,
  });

  /// 章节引用；索引数学只读它的 id 来判断跨章边界。
  final UChapChapterRef? chapter;

  /// 本章内的页序（0 起）；用于页码标签。
  final int? index;

  /// 章节过渡页永远单独占一屏，不参与配对。
  final bool isTransitionPage;

  /// 解码后的真实宽高；宽页（w > h）单独占一屏。
  final double? loadedWidth;
  final double? loadedHeight;
}

/// 上游 Chapter 的最小投影：索引数学只需要 id 作分组键。
class UChapChapterRef {
  const UChapChapterRef(this.id);

  final int? id;
}
