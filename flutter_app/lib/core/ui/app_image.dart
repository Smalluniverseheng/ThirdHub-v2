// 统一图片组件（2026-11-20 / 4.81.78）
//
// ══ 解决什么 ══
// 全库 25 处 `Image.network` 有几个共同的毛病，在真机上都能看出来：
//   ① **硬跳**：图下完了"啪"一下出现，没有渐显，翻列表时一片闪烁；
//   ② **不缓存**：`Image.network` 只有内存缓存（Flutter 的 ImageCache），
//      杀进程 / 退出页面就被回收，重进同一页要重新下载 —— 封面图尤其明显；
//   ③ **失败就空**：源站 403/超时时是一块透明，用户以为"没内容"；
//   ④ 有些源（B 站、漫画站）要求 Referer/UA，不走 headers 直接 403。
//
// 这个组件把四件事一起解决：磁盘缓存 + 内存 LRU + 渐显 + 失败占位重试。
// 零新依赖（path_provider 已在 pubspec，http 也是）。
//
// ══ 用法 ══
//   AppImage(url)                          // 普通
//   AppImage(url, radius: 12)              // 圆角
//   AppImage(url, headers: {'Referer':..}) // 需要防盗链的源
//   AppImage.avatar(url, size: 40)         // 圆形头像
//
// 刻意**不**做成 `Image.network` 的 drop-in（同名同参）：
// 参数语义不同（我们是"下载到磁盘再解本地文件"），
// 保持独立类型才不会被误以为可以直接替换。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// 内存 LRU：条目数与总字节双上限。
///
/// 为什么还要限字节：一张漫画页可能 1–3MB，只限条数会让峰值内存不可控。
class _MemCache {
  static const int maxItems = 120;
  static const int maxBytes = 36 << 20; // 36MB

  static final Map<String, Uint8List> _map = <String, Uint8List>{};
  static final List<String> _order = <String>[]; // 最近使用在尾部
  static int _bytes = 0;

  static Uint8List? get(String k) {
    final v = _map[k];
    if (v == null) return null;
    _order.remove(k);
    _order.add(k);
    return v;
  }

  static void put(String k, Uint8List b) {
    if (b.length > maxBytes) return; // 单张就超上限的，不占内存
    final old = _map[k];
    if (old != null) {
      _bytes -= old.length;
      _order.remove(k);
    }
    _map[k] = b;
    _order.add(k);
    _bytes += b.length;
    while (_order.length > maxItems || (_bytes > maxBytes && _order.length > 1)) {
      final k0 = _order.removeAt(0);
      final v0 = _map.remove(k0);
      if (v0 != null) _bytes -= v0.length;
    }
  }

  static void clear() {
    _map.clear();
    _order.clear();
    _bytes = 0;
  }
}

/// 内存 / 磁盘 / 网络三级取图，带并发去重。
class AppImageLoader {
  AppImageLoader._();

  /// 同一 URL 正在下载时复用同一个 Future —— 列表里 20 张同封面只下载一次。
  static final Map<String, Future<Uint8List?>> _inflight =
      <String, Future<Uint8List?>>{};

  static Directory? _dir;

  /// 磁盘缓存目录。拿不到就退化为纯内存（不报错）。
  static Future<Directory?> _cacheDir() async {
    if (_dir != null) return _dir;
    try {
      final base = await getTemporaryDirectory();
      final d = Directory('${base.path}/th_img');
      if (!await d.exists()) await d.create(recursive: true);
      _dir = d;
      return d;
    } catch (_) {
      return null;
    }
  }

  /// URL → 稳定文件名。FNV-1a 32 位 + 长度，避免长文件名与目录爆量。
  static String keyOf(String url, Map<String, String>? headers) {
    final seed = headers == null || headers.isEmpty
        ? url
        : url + '\u0001' + (headers.entries.map((e) => '${e.key}=${e.value}').join('&'));
    var h = 0x811c9dc5;
    for (final c in seed.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    final hex = h.toRadixString(16).padLeft(8, '0');
    // 取 hash 前两位做子目录，避免单目录几万文件（ext4/EROFS 下会明显变慢）
    return '${hex.substring(0, 2)}/$hex-${seed.length.toRadixString(16)}.img';
  }

  /// 取图。命中内存 → 立即返回；命中磁盘 → 读盘；否则下载并写盘。
  ///
  /// [retry] 为 true 时失败再试一次（源站偶发 5xx 很常见）。
  static Future<Uint8List?> load(
    String url, {
    Map<String, String>? headers,
    bool retry = true,
  }) {
    if (url.isEmpty) return Future<Uint8List?>.value(null);
    final k = keyOf(url, headers);
    final mem = _MemCache.get(k);
    if (mem != null) return Future<Uint8List?>.value(mem);

    final running = _inflight[k];
    if (running != null) return running;

    final f = _load(k, url, headers, retry).whenComplete(() => _inflight.remove(k));
    _inflight[k] = f;
    return f;
  }

  static Future<Uint8List?> _load(
      String k, String url, Map<String, String>? headers, bool retry) async {
    // ① 磁盘
    try {
      final d = await _cacheDir();
      if (d != null) {
        final f = File('${d.path}/$k');
        if (await f.exists()) {
          final b = await f.readAsBytes();
          if (b.isNotEmpty) {
            _MemCache.put(k, b);
            return b;
          }
        }
      }
    } catch (_) {}

    // ② 网络
    final b = await _fetch(url, headers, retry);
    if (b == null) return null;
    _MemCache.put(k, b);
    // ③ 写盘（失败不影响本次显示）
    try {
      final d = await _cacheDir();
      if (d != null) {
        final f = File('${d.path}/$k');
        await f.parent.create(recursive: true);
        await f.writeAsBytes(b, flush: false);
      }
    } catch (_) {}
    return b;
  }

  static Future<Uint8List?> _fetch(
      String url, Map<String, String>? headers, bool retry) async {
    for (var attempt = 0; attempt < (retry ? 2 : 1); attempt++) {
      try {
        final r = await http.get(Uri.parse(url), headers: {
          // 很多图床对空 UA 直接 403。给一个明确的客户端标识（也是 MangaDex 的合规要求）。
          'User-Agent': 'ThirdHub/4.81.78 (Android)',
          'Accept': 'image/*,*/*;q=0.8',
          ...?headers,
        }).timeout(const Duration(seconds: 15));
        if (r.statusCode == 200 && r.bodyBytes.isNotEmpty) return r.bodyBytes;
        // 4xx 不重试（重试也不会变），5xx / 429 重试
        if (r.statusCode < 500 && r.statusCode != 429) return null;
      } catch (_) {}
      if (attempt == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    }
    return null;
  }

  /// 「我的 → 存储」里清缓存用。
  static Future<int> diskUsageBytes() async {
    try {
      final d = await _cacheDir();
      if (d == null) return 0;
      var n = 0;
      await for (final e in d.list(recursive: true, followLinks: false)) {
        if (e is File) {
          try {
            n += await e.length();
          } catch (_) {}
        }
      }
      return n;
    } catch (_) {
      return 0;
    }
  }

  static Future<void> clearDisk() async {
    _MemCache.clear();
    try {
      final d = await _cacheDir();
      if (d == null) return;
      await for (final e in d.list(followLinks: false)) {
        try {
          await e.delete(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}
  }
}

/// 带占位、渐显、失败重试的图片。
class AppImage extends StatefulWidget {
  const AppImage(
    this.url, {
    super.key,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.radius = 0,
    this.headers,
    this.placeholderIcon = Icons.image_outlined,
    this.showRetryOnFail = true,
    this.fadeDuration = const Duration(milliseconds: 220),
    this.backgroundColor,
    this.onFail,
  });

  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;

  /// 圆角。0 = 不裁。避免调用方再包 SizedBox + ClipRRect。
  final double radius;
  final Map<String, String>? headers;
  final IconData placeholderIcon;

  /// 失败时是否显示"重试"按钮（列表里的小图一般不显示，占位就够）。
  final bool showRetryOnFail;
  final Duration fadeDuration;
  final Color? backgroundColor;

  /// 失败时的自定义兜底。
  ///
  /// 给 `CoverImage` 这种已经有品牌化兜底（按书名哈希取色的渐变块）的调用方用：
  /// 让"下载失败"和"本来就没有封面"长得一样，用户不会觉得是坏了。
  final Widget Function()? onFail;

  @override
  State<AppImage> createState() => _AppImageState();
}

class _AppImageState extends State<AppImage> {
  Uint8List? _bytes;
  bool _failed = false;
  bool _loading = true;
  int _nonce = 0; // 重试时强制重新取

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void didUpdateWidget(AppImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _bytes = null;
      _failed = false;
      _loading = true;
      _run();
    }
  }

  Future<void> _run() async {
    if (widget.url.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final b = await AppImageLoader.load(widget.url, headers: widget.headers);
    if (!mounted) return;
    setState(() {
      _bytes = b;
      _failed = b == null;
      _loading = false;
    });
  }

  void _retry() {
    setState(() {
      _loading = true;
      _failed = false;
      _nonce++;
    });
    // 清掉内存里的失败态：直接再取一次（loader 内部会重试并重新写盘）
    _run();
  }

  Widget _placeholder() {
    final bg = widget.backgroundColor ??
        (Theme.of(context).brightness == Brightness.dark
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.black.withValues(alpha: 0.05));
    if (_loading) {
      // 加载中：一块静止的底色 + 极淡的图标。
      // 刻意不做 shimmer —— 列表里几十张同时闪会晕，静态底其实更"稳"。
      return Container(
        color: bg,
        alignment: Alignment.center,
        child: Icon(widget.placeholderIcon,
            size: _iconSize, color: Colors.white.withValues(alpha: 0.16)),
      );
    }
    if (_failed) {
      // 自定义兜底优先：让它和"本来就没封面"长得一样，
      // 用户不会把"这张图没下下来"看成"这个内容坏了"。
      final f = widget.onFail;
      if (f != null) return f();
      if (widget.showRetryOnFail) {
        return GestureDetector(
          onTap: _retry,
          child: Container(
            color: bg,
            alignment: Alignment.center,
            child: Icon(Icons.refresh_rounded,
                size: _iconSize * 0.85,
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.7)),
          ),
        );
      }
    }
    return Container(
      color: bg,
      alignment: Alignment.center,
      child: Icon(widget.placeholderIcon,
          size: _iconSize, color: Colors.white.withValues(alpha: 0.16)),
    );
  }

  /// 占位图标尺寸跟容器走，而不是写死 24 —— 大封面上的小图标看着很廉价。
  double get _iconSize {
    final s = [widget.width ?? 0, widget.height ?? 0];
    final m = s.reduce((a, b) => a > b ? a : b);
    if (m <= 0) return 22;
    return (m * 0.28).clamp(16.0, 34.0);
  }

  @override
  Widget build(BuildContext context) {
    Widget child;
    if (_bytes != null) {
      child = Image.memory(
        _bytes!,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        gaplessPlayback: true, // 换图时不闪白
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, __, ___) => _placeholder(),
      );
    } else {
      child = _placeholder();
    }

    // 渐显：占位 → 图片的交叉淡化。用 AnimatedSwitcher 而不是给 Image 包
    // AnimatedOpacity —— 后者在 opacity 从 0 到 1 的过程中每帧重建，会重复 decode。
    child = AnimatedSwitcher(
      duration: widget.fadeDuration,
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      child: KeyedSubtree(
        key: ValueKey('${_bytes == null ? 'p' : 'i'}$_nonce'),
        child: child,
      ),
    );

    if (widget.radius > 0) {
      child = ClipRRect(
        borderRadius: BorderRadius.circular(widget.radius),
        child: child,
      );
    }
    if (widget.width != null || widget.height != null) {
      child = SizedBox(width: widget.width, height: widget.height, child: child);
    }
    return child;
  }
}

/// 圆形头像。名字里的"头像"是语义，不限制只用于用户头像。
class AppAvatar extends StatelessWidget {
  const AppAvatar(
    this.url, {
    super.key,
    this.size = 40,
    this.headers,
    this.icon = Icons.person_outline,
  });

  final String url;
  final double size;
  final Map<String, String>? headers;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: AppImage(
        url,
        width: size,
        height: size,
        headers: headers,
        placeholderIcon: icon,
        showRetryOnFail: false,
      ),
    );
  }
}
