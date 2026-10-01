// 统一的封面/缩略图渲染层（**依赖 Flutter**，规格数值见 `cover_spec.dart`）
//
// 设计要点：兜底不是"记得写就写"，而是**在 API 层强制**。
//   全仓 20+ 处 `Image.network` 此前各写各的：
//     · 有的 `loadingBuilder` + `errorBuilder` 都写；
//     · 有的只写一个；
//     · 有的**一个都没写**（断网时就是一片空白，用户以为界面坏了）。
//   收进 `CoverImage` 之后，占位与兜底由构造过程统一注入，
//   **调用者连"忘记写兜底"这个选项都没有了**。

import 'package:flutter/material.dart';

import 'cover_spec.dart';

// 调用方只需 `import 'ui_cover.dart'` 就能同时拿到 CoverKind/CoverSpec 与组件
export 'cover_spec.dart';

/// 统一的网络封面图。
class CoverImage extends StatelessWidget {
  const CoverImage(
    this.url, {
    super.key,
    this.headers,
    this.fit = BoxFit.cover,
    this.radius = CoverSpec.radius,
    this.fallbackText = '',
    this.fallbackIcon = Icons.image_outlined,
    this.width,
    this.height,
    this.clip = true,
  });

  /// 图片地址。**允许为空串/null** —— 此时直接走兜底，不产生请求。
  final String? url;

  /// 需要鉴权的封面（如家庭后端的相册文件）带 `X-TH-Token`。
  final Map<String, String>? headers;

  final BoxFit fit;

  /// 圆角。外层已有 `ClipRRect` 时传 `clip: false`，避免圆角套圆角。
  final double radius;

  /// 失败兜底上显示的字（一般传书名/标题），取**首字**。空则显示图标。
  final String fallbackText;

  final IconData fallbackIcon;

  final double? width;
  final double? height;

  /// 是否由本组件做圆角裁剪。
  final bool clip;

  bool get _empty => (url ?? '').trim().isEmpty;

  double get _markSize {
    final w = width;
    if (w != null && w > 0) return (w * 0.34).clamp(14.0, 96.0);
    return 28;
  }

  @override
  Widget build(BuildContext context) {
    final img = _empty ? _fallback(context) : _network(context);
    if (!clip) return img;
    return ClipRRect(
        borderRadius: BorderRadius.circular(radius), child: img);
  }

  Widget _network(BuildContext context) => Image.network(
        url!,
        headers: headers,
        fit: fit,
        width: width,
        height: height,
        // 列表滚动/翻页时避免"闪白重载"
        gaplessPlayback: true,
        loadingBuilder: (c, child, p) =>
            p == null ? child : _skeleton(context, p),
        errorBuilder: (_, __, ___) => _fallback(context),
      );

  /// 加载骨架：低透明底色 + 细进度环（进度未知时不显示百分比，避免闪动的假数字）。
  Widget _skeleton(BuildContext context, ImageChunkEvent p) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: width,
      height: height,
      color: cs.primary.withValues(alpha: 0.08),
      alignment: Alignment.center,
      child: SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(
            strokeWidth: 2, color: cs.primary.withValues(alpha: 0.45)),
      ),
    );
  }

  /// 失败/未填 URL 的兜底。
  ///
  /// 采用**按名字哈希取色**的六色调色板（这套视觉原先只长在小说书架的
  /// `_coverFallback` 里，其余 20 处断网时是灰块/裂图/空白）——
  /// 现在收归一处，全书架、各搜索结果、各图墙的失败态**长得一样**。
  Widget _fallback(BuildContext context) => CoverFallback(
        name: fallbackText,
        icon: fallbackIcon,
        width: width,
        height: height,
        fontSize: _markSize,
      );
}

/// 统一的失败/空 URL 兜底：按名字哈希取一组渐变色 + 名字首字（无名字则显示图标）。
class CoverFallback extends StatelessWidget {
  const CoverFallback({
    super.key,
    this.name = '',
    this.icon = Icons.image_outlined,
    this.width,
    this.height,
    this.fontSize = 30,
  });

  final String name;
  final IconData icon;
  final double? width;
  final double? height;
  final double fontSize;

  /// 6 组渐变：同一本书每次进来颜色一致（哈希稳定），不同书颜色分散。
  static const List<List<int>> palette = [
    [0xFF5B7FFF, 0xFF8E5BFF],
    [0xFFFF7A59, 0xFFFFB347],
    [0xFF2EBD85, 0xFF56C6A9],
    [0xFFF06292, 0xFFBA68C8],
    [0xFF4DD0E1, 0xFF5B7FFF],
    [0xFFFFB74D, 0xFFFF8A65],
  ];

  /// 名字 → 调色板下标（自检可断言"同名字恒定、不同名字分散"）。
  static int paletteIndex(String n) {
    if (n.isEmpty) return 0;
    final h = n.codeUnits.fold<int>(0, (a, e) => (a + e) & 0x7fffffff);
    return h % palette.length;
  }

  /// 取首"字"（按码点，**不会把 emoji/代理对切成半个字符**）。
  static String initialOf(String n) {
    final t = n.trim();
    if (t.isEmpty) return '';
    return String.fromCharCodes(t.runes.take(1));
  }

  @override
  Widget build(BuildContext context) {
    final pair = palette[paletteIndex(name)];
    final ch = initialOf(name);
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(pair[0]), Color(pair[1])],
        ),
      ),
      alignment: Alignment.center,
      child: ch.isEmpty
          ? Icon(icon, size: fontSize, color: Colors.white70)
          : Text(
              ch,
              maxLines: 1,
              style: TextStyle(
                  fontSize: fontSize,
                  fontWeight: FontWeight.w600,
                  color: Colors.white),
            ),
    );
  }
}

/// 列表行内的小缩略图（书目/剧集列表左侧 40×56）。
/// 此前这段 `ClipRRect(4) + Image.network(40×56, errorBuilder→SizedBox)`
/// 在 `main.dart` 里**被复制了 5 遍**（收藏/历史/小说搜索/漫画搜索/影视搜索），
/// 抽出来后尺寸与兜底口径只有一处。
class CoverThumb extends StatelessWidget {
  const CoverThumb(
    this.url, {
    super.key,
    this.headers,
    this.fallbackText = '',
    this.width = CoverSpec.thumbWidth,
    this.height = CoverSpec.thumbHeight,
    this.fallbackIcon = Icons.menu_book_outlined,
  });

  final String? url;
  final Map<String, String>? headers;
  final String fallbackText;
  final double width;
  final double height;
  final IconData fallbackIcon;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: width,
        height: height,
        child: CoverImage(
          url,
          headers: headers,
          radius: CoverSpec.thumbRadius,
          fallbackText: fallbackText,
          fallbackIcon: fallbackIcon,
        ),
      );
}

/// 统一的网格代理。调用处只写"这是哪种网格"，不再各自填四个数字。
SliverGridDelegate coverDelegate(
  String kind, {
  int? columns,
  double? aspect,
  double? gap,
}) =>
    SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: columns ?? CoverSpec.columnsOf(kind),
      childAspectRatio: aspect ?? CoverSpec.aspectOf(kind),
      mainAxisSpacing: gap ?? CoverSpec.gap,
      crossAxisSpacing: gap ?? CoverSpec.gap,
    );

/// 网格统一外边距。
EdgeInsets get coverPad => const EdgeInsets.all(CoverSpec.pad);
