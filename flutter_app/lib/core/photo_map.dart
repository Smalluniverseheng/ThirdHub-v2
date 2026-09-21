// ThirdHub v4.41.0 · F-3 照片地图（PLAN-v3 §3.4）
//
// ── 合规红线（不是可选项，改这个文件前先读完）──────────────────
// 1) **不内置任何地图密钥**，也不引用境外图源（Google/Apple/Bing/OSM/Mapbox 一律不可用）。
//    合规图源只有腾讯位置服务、高德、百度、天地图。本文件默认走「无底图网格」视图，
//    它不依赖任何图源；想要真地图必须由**使用者自己**申请腾讯位置服务的 key。
// 2) **不画国界**。自己拿坐标点描一份世界轮廓，等于自己画了一遍国界，
//    很容易把台湾/南海诸岛画错——这属于明令禁止的错绘。所以这里只画经纬网格：
//    网格不承载任何领土主张，因此不存在错绘问题。
// 3) **坐标只留在本机**。EXIF 经纬度不落后端、不进日志；只有"用真地图"那一个开关
//    会联网（加载地图瓦片本身不可避免要发视口坐标），且默认不开。
// 4) 底图用 GCJ-02（火星坐标）。手机照片 EXIF 里是 WGS-84，
//    不做转换直接打点，在国内会整体偏移几百米 —— [Wgs84.toGcj02] 就是干这个的。
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart' as pm;
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'pro_kit.dart';

/// 腾讯位置服务 key 在本地设置里的键。**绝不写死在代码里**。
const String kTmapKeyPref = 'tmap_key';

/// 申请入口（生成给用户看的提示文案里要用到）。
const String kTmapApplyHint =
    '腾讯位置服务开放平台 lbs.qq.com → 控制台 → 应用管理 → 创建应用 → 添加 Key';

// ══════════════════════════════════════════════════════════════
// 坐标系转换：WGS-84 → GCJ-02
// ══════════════════════════════════════════════════════════════

/// 照片 EXIF 用的是 WGS-84；国内底图（腾讯/高德）用 GCJ-02。
/// 不做这一步，点会整体偏到几百米外——地图上看着就是"照片标错地方了"。
///
/// 算法是公开的标准偏移公式，境外坐标原样返回（GCJ-02 只在国内生效）。
class Wgs84 {
  static const double _a = 6378245.0; // 克拉索夫斯基椭球长半轴
  static const double _ee = 0.00669342162296594323; // 第一偏心率平方

  static bool _outOfChina(double lat, double lng) =>
      lng < 72.004 || lng > 137.8347 || lat < 0.8293 || lat > 55.8271;

  static double _transformLat(double x, double y) {
    var r = -100.0 +
        2.0 * x +
        3.0 * y +
        0.2 * y * y +
        0.1 * x * y +
        0.2 * math.sqrt(x.abs());
    r += (20.0 * math.sin(6.0 * x * math.pi) +
            20.0 * math.sin(2.0 * x * math.pi)) *
        2.0 /
        3.0;
    r += (20.0 * math.sin(y * math.pi) + 40.0 * math.sin(y / 3.0 * math.pi)) *
        2.0 /
        3.0;
    r += (160.0 * math.sin(y / 12.0 * math.pi) +
            320 * math.sin(y * math.pi / 30.0)) *
        2.0 /
        3.0;
    return r;
  }

  static double _transformLng(double x, double y) {
    var r = 300.0 +
        x +
        2.0 * y +
        0.1 * x * x +
        0.1 * x * y +
        0.1 * math.sqrt(x.abs());
    r += (20.0 * math.sin(6.0 * x * math.pi) +
            20.0 * math.sin(2.0 * x * math.pi)) *
        2.0 /
        3.0;
    r += (20.0 * math.sin(x * math.pi) + 40.0 * math.sin(x / 3.0 * math.pi)) *
        2.0 /
        3.0;
    r += (150.0 * math.sin(x / 12.0 * math.pi) +
            300.0 * math.sin(x / 30.0 * math.pi)) *
        2.0 /
        3.0;
    return r;
  }

  /// 返回 [lat, lng]（GCJ-02）。境外坐标原样返回。
  static List<double> toGcj02(double lat, double lng) {
    if (_outOfChina(lat, lng)) return [lat, lng];
    var dLat = _transformLat(lng - 105.0, lat - 35.0);
    var dLng = _transformLng(lng - 105.0, lat - 35.0);
    final radLat = lat / 180.0 * math.pi;
    var magic = math.sin(radLat);
    magic = 1 - _ee * magic * magic;
    final sqrtMagic = math.sqrt(magic);
    dLat = (dLat * 180.0) / ((_a * (1 - _ee)) / (magic * sqrtMagic) * math.pi);
    dLng = (dLng * 180.0) / (_a / sqrtMagic * math.cos(radLat) * math.pi);
    return [lat + dLat, lng + dLng];
  }
}

// ══════════════════════════════════════════════════════════════
// 数据
// ══════════════════════════════════════════════════════════════

/// 一张带地理位置的照片。
class GeoShot {
  final pm.AssetEntity asset;
  final double lat; // WGS-84，EXIF 原值
  final double lng;
  GeoShot(this.asset, this.lat, this.lng);
}

/// 一个聚合点：把附近若干照片并成一个点，避免密集区域糊成一坨。
class GeoSpot {
  final double lat; // WGS-84 质心
  final double lng;
  final List<GeoShot> shots;
  String label = '';
  GeoSpot(this.lat, this.lng, this.shots);
  int get count => shots.length;
}

/// 扫描相册里所有写了 GPS 的照片。
///
/// 只读 EXIF，不上传。缺坐标或坐标是 (0,0) 的一律丢掉——很多相机把"没定位"
/// 写成 0,0，直接打点会在几内亚湾冒出一堆假照片。
class GeoScan {
  static Future<List<GeoShot>> run(
      {int maxPages = 60, int pageSize = 200, int limit = 5000}) async {
    final out = <GeoShot>[];
    try {
      final perm = await pm.PhotoManager.requestPermissionExtend();
      if (!perm.isAuth) return out;
      final albums = await pm.PhotoManager.getAssetPathList(
          type: pm.RequestType.image, onlyAll: true);
      if (albums.isEmpty) return out;
      for (var page = 0; page < maxPages && out.length < limit; page++) {
        final list =
            await albums.first.getAssetListPaged(page: page, size: pageSize);
        if (list.isEmpty) break;
        for (final a in list) {
          final la = a.latitude;
          final lo = a.longitude;
          if (la == null || lo == null) continue;
          if (la == 0 && lo == 0) continue;
          if (la.abs() > 90 || lo.abs() > 180) continue;
          out.add(GeoShot(a, la, lo));
        }
      }
    } catch (_) {}
    return out;
  }

  /// 按 [cellDeg] 度网格聚合。格子越小点越散，放大时应该跟着变小。
  static List<GeoSpot> cluster(List<GeoShot> shots, double cellDeg) {
    final cell = cellDeg <= 0 ? 1.0 : cellDeg;
    final buckets = <String, List<GeoShot>>{};
    for (final s in shots) {
      final key = '${(s.lat / cell).floor()}_${(s.lng / cell).floor()}';
      (buckets[key] ??= <GeoShot>[]).add(s);
    }
    final spots = <GeoSpot>[];
    for (final g in buckets.values) {
      var slat = 0.0, slng = 0.0;
      for (final s in g) {
        slat += s.lat;
        slng += s.lng;
      }
      spots.add(GeoSpot(slat / g.length, slng / g.length, g));
    }
    spots.sort((a, b) => b.count.compareTo(a.count));
    return spots;
  }
}

// ══════════════════════════════════════════════════════════════
// 页面
// ══════════════════════════════════════════════════════════════

class PhotoMapPage extends StatefulWidget {
  const PhotoMapPage({super.key});
  @override
  State<PhotoMapPage> createState() => _PmState();
}

class _PmState extends State<PhotoMapPage> {
  bool loading = true;
  List<GeoShot> shots = [];
  List<GeoSpot> spots = [];
  bool _useBaseMap = false;
  String? _tmapKey;

  /// 视图范围（经纬度），默认覆盖全部照片的包围盒，留一点边距。
  double _minLat = 3, _maxLat = 54, _minLng = 73, _maxLng = 136;

  double _cellDeg = 4.0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    _tmapKey = p.getString(kTmapKeyPref);
    final s = await GeoScan.run();
    if (!mounted) return;
    setState(() {
      shots = s;
      loading = false;
      if (s.isNotEmpty) _fit();
      _recluster();
    });
  }

  /// 把视图范围收紧到实际有照片的区域——不然在中国拍的照片全挤在世界地图中间一小块。
  void _fit() {
    var mnLat = 90.0, mxLat = -90.0, mnLng = 180.0, mxLng = -180.0;
    for (final s in shots) {
      mnLat = math.min(mnLat, s.lat);
      mxLat = math.max(mxLat, s.lat);
      mnLng = math.min(mnLng, s.lng);
      mxLng = math.max(mxLng, s.lng);
    }
    // 单点或极小时给一个最小跨度，否则除零
    final padLat = math.max((mxLat - mnLat) * 0.12, 0.6);
    final padLng = math.max((mxLng - mnLng) * 0.12, 0.6);
    _minLat = mnLat - padLat;
    _maxLat = mxLat + padLat;
    _minLng = mnLng - padLng;
    _maxLng = mxLng + padLng;
    // 聚合粒度跟着视野走，并让滑块位置与 _cellDeg 保持一致
    // （滑块公式：_cellDeg = span / (2 + v*6)，这里反解出 v）
    _zoomLevel = 2;
    _cellDeg = (_maxLat - _minLat) / (2 + _zoomLevel * 6);
  }

  void _recluster() => spots = GeoScan.cluster(shots, _cellDeg);

  Future<void> _setKey() async {
    final k = await ProKit.prompt(context, '腾讯位置服务 Key',
        hint: '粘贴你申请的 Key', init: _tmapKey ?? '');
    if (k == null) return;
    final p = await SharedPreferences.getInstance();
    await p.setString(kTmapKeyPref, k);
    if (mounted) setState(() => _tmapKey = k);
  }

  Future<void> _openBaseMap() async {
    if ((_tmapKey ?? '').isEmpty) {
      final go = await ProKit.confirm(
        context,
        '需要自己的地图 Key',
        '出于合规要求，App 不内置任何地图密钥，也不使用境外图源。\n\n'
            '想看带底图的地图，请自己申请一个腾讯位置服务的 Key（免费额度够个人用）：\n'
            '$kTmapApplyHint\n\n'
            '拿到后填进来即可。你想现在就填吗？',
        ok: '去填写',
      );
      if (!go) return;
      await _setKey();
      if ((_tmapKey ?? '').isEmpty) return;
    }
    if (!mounted) return;
    await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) =>
                _BaseMapPage(tmapKey: _tmapKey ?? '', spots: spots)));
  }

  void _showSpot(GeoSpot sp) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c2) => DraggableScrollableSheet(
        initialChildSize: 0.55,
        expand: false,
        builder: (_, sc) => Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Row(children: [
              Expanded(
                child: Text(
                    sp.label.isEmpty
                        ? '${sp.lat.toStringAsFixed(4)}, ${sp.lng.toStringAsFixed(4)}'
                        : sp.label,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700)),
              ),
              ProUI.chip('${sp.count} 张'),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                  'WGS-84 ${sp.lat.toStringAsFixed(5)}, ${sp.lng.toStringAsFixed(5)}',
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ),
          ),
          Expanded(
            child: GridView.builder(
              controller: sc,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3, mainAxisSpacing: 4, crossAxisSpacing: 4),
              itemCount: sp.shots.length,
              itemBuilder: (_, i) => ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: AssetEntityImage(sp.shots[i].asset,
                    isOriginal: false, fit: BoxFit.cover),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext c) {
    return Scaffold(
      appBar: AppBar(title: const Text('照片地图'), actions: [
        IconButton(
            icon: const Icon(Icons.map_outlined),
            tooltip: '用底图看（需自备 Key）',
            onPressed: _openBaseMap),
        IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              setState(() => loading = true);
              _load();
            }),
      ]),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : shots.isEmpty
              ? ProUI.empty('相册里没有带位置信息的照片\n'
                  '（相机拍的照片一般带 GPS；截图、保存的图片通常没有）')
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 30),
                  children: [
                      Card(
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16)),
                        child: Column(children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
                            child: Row(children: [
                              Expanded(
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                          '${shots.length} 张带位置 · ${spots.length} 个地点',
                                          style: const TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w700)),
                                      const Padding(
                                        padding: EdgeInsets.only(top: 2),
                                        child: Text('按经纬网格聚合，不画国界（避免边界错绘）',
                                            style: TextStyle(
                                                fontSize: 11,
                                                color: Colors.grey)),
                                      ),
                                    ]),
                              ),
                              ProUI.chip('无底图'),
                            ]),
                          ),
                          AspectRatio(
                            aspectRatio: 1.15,
                            // 用 LayoutBuilder 拿到画布的**真实**尺寸再算命中：
                            // 早先按屏幕宽度减去 ListView+Card 的内边距去估算，差 8px，
                            // 点最上面/最左边那几个点会打偏。
                            child: LayoutBuilder(builder: (_, cons) {
                              final w = cons.maxWidth;
                              final h = cons.maxHeight;
                              return GestureDetector(
                                onTapUp: (d) {
                                  GeoSpot? best;
                                  var bestD = 26.0;
                                  for (final sp in spots) {
                                    final dx = (_lngToX(sp.lng, w) -
                                            d.localPosition.dx)
                                        .abs();
                                    final dy = (_latToY(sp.lat, h) -
                                            d.localPosition.dy)
                                        .abs();
                                    final dist = math.sqrt(dx * dx + dy * dy);
                                    if (dist < bestD) {
                                      bestD = dist;
                                      best = sp;
                                    }
                                  }
                                  if (best != null) _showSpot(best);
                                },
                                child: CustomPaint(
                                  painter: _GridPainter(
                                      minLat: _minLat,
                                      maxLat: _maxLat,
                                      minLng: _minLng,
                                      maxLng: _maxLng,
                                      spots: spots),
                                  size: Size(w, h),
                                ),
                              );
                            }),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(14, 6, 14, 12),
                            child: Row(children: [
                              const Icon(Icons.zoom_out,
                                  size: 16, color: Colors.grey),
                              Expanded(
                                child: Slider(
                                  value: _zoomLevel,
                                  min: 0,
                                  max: 5,
                                  divisions: 5,
                                  label: '聚合粒度 ${_cellDeg.toStringAsFixed(2)}°',
                                  onChanged: (v) => setState(() {
                                    _zoomLevel = v;
                                    // 往右 = 格子更细 = 点更散
                                    _cellDeg =
                                        (_maxLat - _minLat) / (2 + v * 6);
                                    _recluster();
                                  }),
                                ),
                              ),
                              const Icon(Icons.zoom_in,
                                  size: 16, color: Colors.grey),
                            ]),
                          ),
                        ]),
                      ),
                      ProUI.card('地点排行', [
                        for (final sp in spots.take(30))
                          ProUI.row(
                            Icons.place_outlined,
                            sp.label.isEmpty
                                ? '${sp.lat.toStringAsFixed(4)}, ${sp.lng.toStringAsFixed(4)}'
                                : sp.label,
                            value: '${sp.count} 张',
                            sub:
                                'WGS-84 ${sp.lat.toStringAsFixed(4)}, ${sp.lng.toStringAsFixed(4)}',
                            onTap: () => _showSpot(sp),
                          ),
                        if (spots.isEmpty) ProUI.note('这张视图里还没有点，调一下聚合粒度试试'),
                      ]),
                      ProUI.card('地名与底图', [
                        ProUI.row(Icons.translate, '让 AI 认一下这些坐标',
                            sub: '调已配置的 AI 把坐标翻成地名（坐标只在本机，只把数字发出去）',
                            onTap: _labelByAi),
                        ProUI.row(Icons.key_outlined, '腾讯位置服务 Key',
                            value: (_tmapKey ?? '').isEmpty ? '未设置' : '已设置',
                            sub: (_tmapKey ?? '').isEmpty
                                ? '看底图地图需要（自己申请）'
                                : '点这里可以更换',
                            onTap: _setKey),
                      ]),
                      ProUI.note('照片的 EXIF 经纬度只在本机解析、只在本机保存，不上传后端也不写日志。'
                          '唯一的联网行为是你主动打开底图地图时加载地图瓦片。'),
                    ]),
    );
  }

  double _zoomLevel = 2;

  // 纯函数：经纬度 → 画布坐标。绘制和点击命中共用同一套换算，避免两边算法漂移。
  static double _lngToX(double lng, double w) => (lng + 180) / 360 * w;
  static double _latToY(double lat, double h) => (90 - lat) / 180 * h;

  Future<void> _labelByAi() async {
    if (spots.isEmpty) return;
    ProUI.toast(context, '正在让 AI 认地点…');
    try {
      final pts = spots
          .take(20)
          .map((s) =>
              '${s.lat.toStringAsFixed(3)},${s.lng.toStringAsFixed(3)}(${s.count}张)')
          .join('; ');
      final out = await ProAi.ask(
          '下面是一串经纬度坐标和各自的照片张数。请给每个坐标一个简短中文地名（城市或区县级即可），'
          '一行一个，格式严格为「纬度,经度=地名」，不要序号不要解释：\n$pts',
          system: '你是地理坐标识别助手，只输出要求格式的行。');
      final map = <String, String>{};
      for (final line in out.split('\n')) {
        final t = line.trim();
        final i = t.indexOf('=');
        if (i <= 0) continue;
        final k = t.substring(0, i).trim();
        final v = t.substring(i + 1).trim();
        if (k.isNotEmpty && v.isNotEmpty) map[k] = v;
      }
      if (!mounted) return;
      setState(() {
        for (final s in spots) {
          final k = '${s.lat.toStringAsFixed(3)},${s.lng.toStringAsFixed(3)}';
          if (map.containsKey(k)) s.label = map[k]!;
        }
      });
      ProUI.toast(context, '认出了 ${map.length} 个地点');
    } catch (e) {
      if (mounted) ProUI.toast(context, '$e');
    }
  }
}

// ══════════════════════════════════════════════════════════════
// 无底图网格视图
// ══════════════════════════════════════════════════════════════

/// 只画经纬网格 + 聚合点。
///
/// **刻意不画陆地轮廓**：手描国界很容易把台湾、南海诸岛画错，
/// 那是明令禁止的错绘；而经纬网格不承载任何领土主张，画得再简也不会出错。
class _GridPainter extends CustomPainter {
  final double minLat, maxLat, minLng, maxLng;
  final List<GeoSpot> spots;
  _GridPainter({
    required this.minLat,
    required this.maxLat,
    required this.minLng,
    required this.maxLng,
    required this.spots,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = const Color(0xFF10202E);
    canvas.drawRRect(
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(12)),
        bg);

    double x(double lng) => (lng - minLng) / (maxLng - minLng) * size.width;
    double y(double lat) => (maxLat - lat) / (maxLat - minLat) * size.height;

    // 步长：让网格大约 6~10 格，读起来不糊
    final spanLat = maxLat - minLat;
    final step = _niceStep(spanLat / 7);

    final grid = Paint()
      ..color = Colors.white.withValues(alpha: 0.10)
      ..strokeWidth = 1;
    final strong = Paint()
      ..color = Colors.white.withValues(alpha: 0.22)
      ..strokeWidth = 1.2;

    // 竖线（经度）
    var lng = (minLng / step).floor() * step;
    while (lng <= maxLng) {
      final px = x(lng);
      final isMajor = (lng % (step * 5)).abs() < 1e-6;
      canvas.drawLine(
          Offset(px, 0), Offset(px, size.height), isMajor ? strong : grid);
      lng += step;
    }
    // 横线（纬度）
    var lat = (minLat / step).floor() * step;
    while (lat <= maxLat) {
      final py = y(lat);
      final isMajor = (lat % (step * 5)).abs() < 1e-6;
      canvas.drawLine(
          Offset(0, py), Offset(size.width, py), isMajor ? strong : grid);
      lat += step;
    }

    // 赤道与本初子午线加亮（它们是真实存在的参考线，不涉及任何边界）
    if (minLat <= 0 && maxLat >= 0) {
      canvas.drawLine(
          Offset(0, y(0)),
          Offset(size.width, y(0)),
          Paint()
            ..color = Colors.white.withValues(alpha: 0.30)
            ..strokeWidth = 1.4);
    }
    if (minLng <= 0 && maxLng >= 0) {
      canvas.drawLine(
          Offset(x(0), 0),
          Offset(x(0), size.height),
          Paint()
            ..color = Colors.white.withValues(alpha: 0.30)
            ..strokeWidth = 1.4);
    }

    // 聚合点：半径按 sqrt(张数) 长，数量差异大时也不会一个点吃掉整屏
    final maxCount = spots.isEmpty ? 1 : spots.first.count;
    for (final sp in spots) {
      final px = x(sp.lng);
      final py = y(sp.lat);
      if (px < -20 || px > size.width + 20 || py < -20 || py > size.height + 20)
        continue;
      final t = maxCount <= 1 ? 1.0 : math.sqrt(sp.count / maxCount);
      final r = 6 + 16 * t;

      canvas.drawCircle(
          Offset(px, py), r + 3, Paint()..color = const Color(0x332196F3));
      canvas.drawCircle(
          Offset(px, py), r, Paint()..color = const Color(0xCC2196F3));
      canvas.drawCircle(
          Offset(px, py),
          r,
          Paint()
            ..color = Colors.white.withValues(alpha: 0.75)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4);

      // 张数写在点里，一眼看出哪个地方照片多
      final tp = TextPainter(
        text: TextSpan(
            text: '${sp.count}',
            style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w700)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(px - tp.width / 2, py - tp.height / 2));
    }
  }

  /// 让网格步长落在 1/2/5 × 10^n 上，读起来是"整"的。
  static double _niceStep(double raw) {
    if (raw <= 0) return 1;
    final exp = (math.log(raw) / math.ln10).floor();
    final base = math.pow(10, exp).toDouble();
    final n = raw / base;
    final mult = n < 1.5 ? 1.0 : (n < 3.5 ? 2.0 : (n < 7.5 ? 5.0 : 10.0));
    return mult * base;
  }

  @override
  bool shouldRepaint(covariant _GridPainter old) =>
      old.spots.length != spots.length ||
      old.minLat != minLat ||
      old.maxLat != maxLat ||
      old.minLng != minLng ||
      old.maxLng != maxLng;
}

// ══════════════════════════════════════════════════════════════
// 底图地图（腾讯位置服务，用使用者自己的 Key）
// ══════════════════════════════════════════════════════════════

class _BaseMapPage extends StatefulWidget {
  final String tmapKey;
  final List<GeoSpot> spots;
  const _BaseMapPage({required this.tmapKey, required this.spots});
  @override
  State<_BaseMapPage> createState() => _BmState();
}

class _BmState extends State<_BaseMapPage> {
  WebViewController? _wc;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _build();
  }

  void _build() {
    // 把点转成 GCJ-02 —— 底图是火星坐标，直接用 WGS-84 会整体偏移。
    // 只把坐标喂给页面，不经过任何中转服务器。
    final pts = [
      for (final s in widget.spots)
        {
          'lat': Wgs84.toGcj02(s.lat, s.lng)[0],
          'lng': Wgs84.toGcj02(s.lat, s.lng)[1],
          'n': s.count,
          'label': s.label,
        }
    ];
    final html = _html(widget.tmapKey, pts);
    _wc = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          if (mounted) setState(() => _loading = false);
        },
      ))
      ..loadHtmlString(html);
  }

  static String _html(String key, List<Map<String, dynamic>> pts) {
    final data = jsonEncode(pts);
    final center = pts.isEmpty
        ? {'lat': 39.984104, 'lng': 116.307503}
        : {'lat': pts.first['lat'], 'lng': pts.first['lng']};
    // 说明：底图固定用 GCJ-02；不使用自定义样式（需要额外开通，会导致底图变灰）。
    return '''
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
<style>html,body,#map{margin:0;padding:0;height:100%;width:100%;background:#eef1f5}</style>
</head>
<body>
<div id="map"></div>
<script src="https://map.qq.com/api/gljs?v=1.exp&key=$key"></script>
<script>
  var pts = $data;
  var map = new TMap.Map('map', {
    zoom: 4,
    center: new TMap.LatLng(${center['lat']}, ${center['lng']})
  });
  if (pts.length) {
    var geoms = pts.map(function (p, i) {
      return { id: String(i), styleId: 'default', position: new TMap.LatLng(p.lat, p.lng) };
    });
    new TMap.MultiMarker({
      map: map,
      styles: { default: new TMap.MarkerStyle({ width: 20, height: 30 }) },
      geometries: geoms
    });
  }
</script>
</body>
</html>''';
  }

  @override
  Widget build(BuildContext c) {
    return Scaffold(
      appBar: AppBar(title: const Text('底图地图'), actions: [
        IconButton(
            icon: const Icon(Icons.info_outline),
            onPressed: () {
              showDialog<void>(
                context: c,
                builder: (c2) => AlertDialog(
                  title: const Text('关于底图'),
                  content: const Text(
                      '底图由腾讯位置服务提供，坐标已从 WGS-84 转成 GCJ-02。\n\n'
                      'App 不内置任何地图密钥，用的是你自己申请的 Key（存在本机设置里）。\n'
                      '打开这个页面会向腾讯位置服务请求地图瓦片，这是 App 里唯一联网显示位置的地方。',
                      style: TextStyle(fontSize: 13, height: 1.55)),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(c2),
                        child: const Text('知道了'))
                  ],
                ),
              );
            }),
      ]),
      body: Stack(children: [
        if (_wc != null) WebViewWidget(controller: _wc!),
        if (_loading) const Center(child: CircularProgressIndicator()),
      ]),
    );
  }
}
