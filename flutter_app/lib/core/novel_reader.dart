// 番茄小说风格的专业阅读器: 点按出菜单(目录/夜间/设置), 设置面板含
// 亮度/护眼/字号/字体/字色/背景/翻页(仿真/覆盖/平移/上下/无动画)/间距
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'reader_fonts.dart';
import 'package:volume_watcher/volume_watcher.dart';
import 'tts.dart';
import 'ai.dart';

// ── 背景预设(背景色, 默认字色) ──
const kReaderBgs = <(Color, Color, String)>[
  (Color(0xFF121212), Color(0xFFE0E0E0), '夜间'),
  (Color(0xFFFFFFFF), Color(0xFF333333), '日间'),
  (Color(0xFFF5F0E1), Color(0xFF4A3F30), '纸书'),
  (Color(0xFFCCE8CF), Color(0xFF2E4A32), '护眼绿'),
  (Color(0xFFFAF3DE), Color(0xFF5B4636), '米黄'),
  (Color(0xFF0F1B2D), Color(0xFFB8C4D9), '墨蓝'),
];
// ── 字色候选 ──
const kReaderTextColors = <int>[0xFFE0E0E0, 0xFF333333, 0xFF4A3F30, 0xFF2E4A32, 0xFF5B4636, 0xFF000000];

class ReaderCfg {
  // 从 SharedPreferences 读取(键与 AppSettings 一致, 避免循环依赖)
  static SharedPreferences? _p;
  static Future<void> init() async { _p ??= await SharedPreferences.getInstance(); }
  static SharedPreferences get p => _p!;
  static double get fontSize => p.getDouble('fontSize') ?? 18.0;
  static int get bg => p.getInt('reader_bg') ?? 2;
  static int get textColor => p.getInt('reader_text') ?? 0;
  static double get lineH => p.getDouble('line_height') ?? 1.8;
  static double get paraSpace => p.getDouble('para_space') ?? 8.0;
  static double get margin => p.getDouble('reader_margin') ?? 16.0;
  static String get flip => p.getString('flip_mode') ?? 'slide';
  static bool get eyeCare => p.getBool('eye_care') ?? false;
  static bool get volTurn => p.getBool('vol_turn') ?? true; // 音量键翻页(默认开)
  static double get bright => p.getDouble('reader_brightness') ?? 1.0;
  static Color get bgColor => kReaderBgs[bg.clamp(0, kReaderBgs.length - 1)].$1;
  static Color get fgColor => textColor != 0 ? Color(textColor) : kReaderBgs[bg.clamp(0, kReaderBgs.length - 1)].$2;
}

/// 专业阅读页(网络书籍): 预加载/进度记忆/番茄式菜单
class NovelReaderPage extends StatefulWidget {
  final String sourceId, bookName, bookUrl;
  final List chapters; final int index;
  final Future<Map<String, dynamic>> Function(String sourceId, String url) fetchContent;
  final Future<void> Function(int index, String chapterName)? onProgress;
  const NovelReaderPage({super.key, required this.sourceId, required this.chapters, required this.index,
    required this.bookName, required this.bookUrl, required this.fetchContent, this.onProgress});
  @override State<NovelReaderPage> createState() => _NovelReaderState();
}

class _NovelReaderState extends State<NovelReaderPage> {
  String text = ''; List<String> images = []; bool loading = true;
  bool chrome = false; // 菜单显隐
  String? fontFamily;
  final Map<int, Map<String, dynamic>> chapCache = {};
  final GlobalKey<_FlipPagerState> _pagerKey = GlobalKey<_FlipPagerState>();
  int? _volId; double? _lastVol; DateTime _lastVolAt = DateTime.fromMillisecondsSinceEpoch(0);
  int get idx => widget.index;
  Map<String, dynamic> get chapter => widget.chapters[idx];
  bool get hasPrev => idx > 0;
  bool get hasNext => idx < widget.chapters.length - 1;

  @override void initState() { super.initState(); _initTts(); _boot(); }
  Future<void> _boot() async {
    await ReaderCfg.init();
    _initVolumeKeys();
    fontFamily = await FontManager.currentFamily();
    await load();
  }

  // ── 听书 ──
  StreamSubscription? _ttsSub;
  void _initTts() { _ttsSub = TtsManager.onState.listen((_) { if (mounted) setState(() {}); }); }
  @override void dispose() { _ttsSub?.cancel(); VolumeWatcher.removeListener(_volId); TtsManager.stop(); super.dispose(); }

  // 音量键翻页: 监听系统音量变化方向(上=上一页/上一章, 下=下一页/下一章)
  void _initVolumeKeys() {
    _volId = VolumeWatcher.addListener((v) {
      if (!mounted || !ReaderCfg.volTurn || v is! double) return;
      final now = DateTime.now();
      if (_lastVol == null) { _lastVol = v; return; }
      final old = _lastVol!;
      if ((v - old).abs() < 0.001) return;
      _lastVol = v;
      if (now.difference(_lastVolAt).inMilliseconds < 320) return;
      _lastVolAt = now;
      _volumeTurn(v < old); // 音量减=下一页(右手拇指自然向下), 音量加=上一页
    });
  }

  void _volumeTurn(bool next) {
    if (loading) return;
    if (images.isNotEmpty || ReaderCfg.flip == 'vertical') {
      if (next && hasNext) goChapter(idx + 1);
      if (!next && hasPrev) goChapter(idx - 1);
      return;
    }
    final st = _pagerKey.currentState;
    if (st == null) {
      if (next && hasNext) goChapter(idx + 1);
      if (!next && hasPrev) goChapter(idx - 1);
      return;
    }
    st.turn(next);
  }

  void _ttsSheet() {
    showModalBottomSheet(context: context, isScrollControlled: true, builder: (c2) => StatefulBuilder(builder: (c2, setD) {
      final playing = TtsManager.state == TtsState.playing;
      final paused = TtsManager.state == TtsState.paused;
      final active = playing || paused;
      return SafeArea(child: Padding(padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [ const Icon(Icons.headphones, size: 20), const SizedBox(width: 8),
          Text(active ? '听书 · ${TtsManager.chunkIdx + 1}/${TtsManager.chunkTotal} 段' : '听书', style: const TextStyle(fontWeight: FontWeight.bold)) ]),
        const SizedBox(height: 16),
        if (active) Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          IconButton(icon: const Icon(Icons.skip_previous), tooltip: '上一段', onPressed: () async { await TtsManager.prevChunk(); setD(() {}); }),
          IconButton(iconSize: 44, icon: Icon(playing ? Icons.pause_circle : Icons.play_circle),
            onPressed: () async { playing ? await TtsManager.pause() : await TtsManager.resume(); setD(() {}); }),
          IconButton(icon: const Icon(Icons.skip_next), tooltip: '下一段', onPressed: () async { await TtsManager.nextChunk(); setD(() {}); }),
          IconButton(icon: const Icon(Icons.stop, color: Colors.redAccent), tooltip: '停止',
            onPressed: () async { await TtsManager.stop(); setD(() {}); if (c2.mounted) Navigator.pop(c2); }),
        ]),
        if (active) const SizedBox(height: 8),
        if (!active) FilledButton.icon(icon: const Icon(Icons.play_arrow), label: const Text('朗读本章'),
          onPressed: () async { await TtsManager.speak(text); if (c2.mounted) setD(() {}); }),
        const Divider(height: 24),
        Row(children: [ const Text('语速', style: TextStyle(fontSize: 13)),
          Expanded(child: FutureBuilder<double>(future: TtsManager.rate(), builder: (_, snap) => Slider(
            value: snap.data ?? 0.5, min: 0.1, max: 1.0, divisions: 9,
            label: '${((snap.data ?? 0.5) * 2).toStringAsFixed(1)}x',
            onChanged: (v) { TtsManager.setRate(v); setD(() {}); }))) ]),
        const SizedBox(height: 8),
        const Align(alignment: Alignment.centerLeft, child: Text('朗读引擎', style: TextStyle(fontSize: 13))),
        const SizedBox(height: 8),
        FutureBuilder<String>(future: TtsManager.engine(), builder: (_, snap) {
          final cur = snap.data ?? 'system';
          final ttsProviders = AiRegistry.providers.where((p) => p.models.any((m) => m.contains('tts') || m.contains('speech'))).toList();
          return Wrap(spacing: 8, runSpacing: 8, children: [
            ChoiceChip(label: const Text('系统离线朗读'), selected: cur == 'system',
              onSelected: (_) { TtsManager.setEngine('system'); setD(() {}); }),
            for (final p in ttsProviders)
              ChoiceChip(label: Text(p.name), selected: cur == p.id,
                onSelected: (_) { TtsManager.setEngine(p.id); setD(() {}); }),
          ]);
        }),
        const SizedBox(height: 6),
        const Text('系统朗读离线免费; 在线引擎需在 AI 模块配置对应厂商的 API Key', style: TextStyle(fontSize: 10, color: Colors.grey)),
      ])));
    }));
  }

  Future<void> preload(int i) async {    if (i < 0 || i >= widget.chapters.length || chapCache.containsKey(i)) return;
    try {
      final d = await widget.fetchContent(widget.sourceId, widget.chapters[i]['url'] ?? '');
      chapCache[i] = d;
    } catch (_) {}
  }

  Future<void> load() async {
    setState(() => loading = true);
    try {
      Map<String, dynamic> d;
      if (chapCache.containsKey(idx)) { d = chapCache[idx]!; }
      else { d = await widget.fetchContent(widget.sourceId, chapter['url'] ?? ''); chapCache[idx] = d; }
      text = d['text'] as String? ?? ''; images = List<String>.from(d['images'] ?? []);
      if (text.isEmpty && images.isEmpty) text = '本章无内容';
      final p = await SharedPreferences.getInstance();
      await p.setInt('progress_${widget.bookUrl}', idx);
      try { await widget.onProgress?.call(idx, chapter['name'] ?? ''); } catch (_) {}
      preload(idx + 1); preload(idx - 1);
    } catch (e) { text = '错误: $e'; }
    if (mounted) setState(() => loading = false);
  }

  void goChapter(int i) => Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => NovelReaderPage(
    sourceId: widget.sourceId, chapters: widget.chapters, index: i,
    bookName: widget.bookName, bookUrl: widget.bookUrl,
    fetchContent: widget.fetchContent, onProgress: widget.onProgress)));

  // ── 分页: 按估算行字数切块 ──
  List<String> _paginate(String t, BoxConstraints box) {
    if (t.isEmpty) return const [''];
    final w = box.maxWidth - ReaderCfg.margin * 2;
    final h = box.maxHeight - 40;
    final perLine = math.max(8, (w / ReaderCfg.fontSize).floor());
    final lines = math.max(4, (h / (ReaderCfg.fontSize * ReaderCfg.lineH)).floor());
    final per = perLine * lines;
    final out = <String>[];
    for (var i = 0; i < t.length; i += per) {
      out.add(t.substring(i, math.min(i + per, t.length)));
    }
    return out;
  }

  TextStyle get _textStyle => TextStyle(
    fontSize: ReaderCfg.fontSize, height: ReaderCfg.lineH,
    color: ReaderCfg.fgColor, fontFamily: fontFamily);

  Widget _paragraphs(String t) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    for (final para in t.split('\n'))
      Padding(padding: EdgeInsets.only(bottom: ReaderCfg.paraSpace),
        child: Text(para, style: _textStyle)),
  ]);

  // ── 翻页模式渲染 ──
  Widget _body(BoxConstraints box) {
    if (images.isNotEmpty) {
      return ListView.builder(itemCount: images.length, itemBuilder: (_, i) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: InteractiveViewer(child: Image.network(images[i], fit: BoxFit.fitWidth,
          errorBuilder: (_, __, ___) => const SizedBox(height: 120, child: Center(child: Icon(Icons.broken_image, color: Colors.grey)))))));
    }
    final mode = ReaderCfg.flip;
    if (mode == 'vertical') {
      return SingleChildScrollView(padding: EdgeInsets.all(ReaderCfg.margin), child: _paragraphs(text));
    }
    final pages = _paginate(text, box);
    return _FlipPager(key: _pagerKey, mode: mode, pages: pages, margin: ReaderCfg.margin,
      bg: ReaderCfg.bgColor, hasPrev: hasPrev, hasNext: hasNext,
      onPrevChapter: hasPrev ? () => goChapter(idx - 1) : null,
      onNextChapter: hasNext ? () => goChapter(idx + 1) : null,
      pageBuilder: (t) => _paragraphs(t));
  }

  // ── 番茄式设置面板 ──
  void _settingsSheet() {
    showModalBottomSheet(context: context, isScrollControlled: true,
      backgroundColor: const Color(0xFFF7F3EA),
      builder: (c2) => StatefulBuilder(builder: (c2, setD) {
        final p = ReaderCfg.p;
        void save() { setState(() {}); setD(() {}); }
        Widget rowLabel(String t) => SizedBox(width: 52, child: Text(t, style: const TextStyle(fontSize: 13, color: Color(0xFF6B5D4F))));
        return SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 10), child: Column(mainAxisSize: MainAxisSize.min, children: [
          // 亮度 + 护眼
          Row(children: [ rowLabel('亮度'),
            Expanded(child: Slider(value: ReaderCfg.bright, min: 0.2, max: 1.0, activeColor: const Color(0xFFB59A6C),
              onChanged: (v) { p.setDouble('reader_brightness', v); save(); })),
            const Text('护眼模式', style: TextStyle(fontSize: 12, color: Color(0xFF6B5D4F))),
            Switch(value: ReaderCfg.eyeCare, activeColor: const Color(0xFFB59A6C),
              onChanged: (v) { p.setBool('eye_care', v); save(); }),
          ]),
          // 字号 + 字体
          Row(children: [ rowLabel('字号'),
            _roundBtn('A−', () { p.setDouble('fontSize', (ReaderCfg.fontSize - 1).clamp(12, 32)); save(); }),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text('${ReaderCfg.fontSize.toInt()}', style: const TextStyle(fontSize: 14))),
            _roundBtn('A＋', () { p.setDouble('fontSize', (ReaderCfg.fontSize + 1).clamp(12, 32)); save(); }),
            const Spacer(),
            GestureDetector(onTap: () { Navigator.pop(c2); _fontSheet(); },
              child: Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(FontManager.byId(p.getString('reader_font') ?? 'default').name,
                    style: const TextStyle(fontSize: 12, color: Color(0xFF6B5D4F)), overflow: TextOverflow.ellipsis),
                  const Icon(Icons.chevron_right, size: 16, color: Color(0xFF6B5D4F)),
                ]))),
          ]),
          const SizedBox(height: 12),
          // 字色
          Row(children: [ rowLabel('颜色'),
            for (final col in kReaderTextColors)
              GestureDetector(onTap: () { p.setInt('reader_text', col); save(); },
                child: Container(width: 30, height: 30, margin: const EdgeInsets.only(right: 10),
                  decoration: BoxDecoration(color: Color(col), shape: BoxShape.circle,
                    border: Border.all(color: ReaderCfg.textColor == col ? const Color(0xFFB59A6C) : Colors.grey.shade300,
                      width: ReaderCfg.textColor == col ? 2.5 : 1)))),
          ]),
          const SizedBox(height: 12),
          // 背景
          Row(children: [ rowLabel('背景'),
            Expanded(child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
              for (var i = 0; i < kReaderBgs.length; i++)
                GestureDetector(onTap: () { p.setInt('reader_bg', i); p.setInt('reader_text', 0); save(); },
                  child: Container(width: 44, height: 30, margin: const EdgeInsets.only(right: 8),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: kReaderBgs[i].$1, borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: ReaderCfg.bg == i ? const Color(0xFFB59A6C) : Colors.grey.shade300,
                        width: ReaderCfg.bg == i ? 2 : 0.8)),
                    child: Text('Aa', style: TextStyle(fontSize: 10, color: kReaderBgs[i].$2)))),
            ]))),
          ]),
          const SizedBox(height: 12),
          // 翻页
          Row(children: [ rowLabel('翻页'),
            for (final m in [('sim', '仿真'), ('cover', '覆盖'), ('slide', '平移'), ('vertical', '上下'), ('none', '无动画')])
              Padding(padding: const EdgeInsets.only(right: 8), child: ChoiceChip(
                label: Text(m.$2, style: const TextStyle(fontSize: 12)),
                selected: ReaderCfg.flip == m.$1,
                selectedColor: const Color(0xFFEBDCC0),
                onSelected: (_) { p.setString('flip_mode', m.$1); save(); })),
          ]),
          const SizedBox(height: 8),
          // 其他: 间距
          Row(children: [ rowLabel('其他'),
            TextButton(onPressed: () { Navigator.pop(c2); _spacingSheet(); },
              child: const Text('间距设置', style: TextStyle(fontSize: 13, color: Color(0xFF6B5D4F)))),
          ]),
          Row(children: [ rowLabel('按键'),
            const Text('音量键翻页', style: TextStyle(fontSize: 13, color: Color(0xFF6B5D4F))),
            const Spacer(),
            Switch(value: ReaderCfg.volTurn, activeColor: const Color(0xFFB59A6C),
              onChanged: (v) { p.setBool('vol_turn', v); save(); }),
          ]),
        ])));
      }));
  }

  Widget _roundBtn(String t, VoidCallback onTap) => GestureDetector(onTap: onTap,
    child: Container(width: 40, height: 28, alignment: Alignment.center,
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
      child: Text(t, style: const TextStyle(fontSize: 13, color: Color(0xFF6B5D4F)))));

  // ── 字体选择(含在线下载) ──
  void _fontSheet() {
    showModalBottomSheet(context: context, builder: (c2) => StatefulBuilder(builder: (c2, setD) {
      StreamSubscription? sub;
      sub ??= FontManager.onChange.listen((_) { if (c2.mounted) setD(() {}); });
      final cur = ReaderCfg.p.getString('reader_font') ?? 'default';
      return SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Padding(padding: EdgeInsets.all(12), child: Text('阅读字体', style: TextStyle(fontWeight: FontWeight.bold))),
        for (final f in FontManager.fonts)
          ListTile(dense: true,
            title: Text(f.name, style: TextStyle(fontSize: 14, fontFamily: f.family)),
            subtitle: f.downloadable ? Text(
              FontManager.downloading[f.id] == -1 ? '下载失败, 点右侧重试'
              : (FontManager.downloading[f.id] != null && FontManager.downloading[f.id]! < 1) ? '下载中 ${((FontManager.downloading[f.id] ?? 0) * 100).toStringAsFixed(0)}%'
              : '开源字体 · 首次使用需下载', style: const TextStyle(fontSize: 11)) : null,
            trailing: cur == f.id ? const Icon(Icons.check, color: Colors.blueAccent)
              : f.downloadable ? FutureBuilder<bool>(future: FontManager.isDownloaded(f), builder: (_, s) {
                  if (s.data == true) return const Icon(Icons.font_download, size: 18, color: Colors.grey);
                  final prog = FontManager.downloading[f.id];
                  if (prog != null && prog >= 0 && prog < 1) {
                    return SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, value: prog > 0 ? prog : null));
                  }
                  return IconButton(icon: const Icon(Icons.download, size: 18), onPressed: () => FontManager.download(f));
                }) : null,
            onTap: () async {
              if (f.downloadable) {
                final ok = await FontManager.ensure(f);
                if (!ok) { await FontManager.download(f); }
              }
              if (f.downloadable && !await FontManager.ensure(f)) return;
              await ReaderCfg.p.setString('reader_font', f.id);
              fontFamily = await FontManager.currentFamily();
              if (mounted) setState(() {});
              if (c2.mounted) Navigator.pop(c2);
            }),
        const SizedBox(height: 8),
      ]));
    }));
  }

  // ── 间距设置 ──
  void _spacingSheet() {
    showModalBottomSheet(context: context, builder: (c2) => StatefulBuilder(builder: (c2, setD) {
      final p = ReaderCfg.p;
      void save() { setState(() {}); setD(() {}); }
      Widget s(String label, double v, double min, double max, void Function(double) set) =>
        Row(children: [ SizedBox(width: 64, child: Text(label, style: const TextStyle(fontSize: 13))),
          Expanded(child: Slider(value: v, min: min, max: max, onChanged: (x) { set(x); save(); })),
          Text(v.toStringAsFixed(1), style: const TextStyle(fontSize: 12)) ]);
      return SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 20), child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('间距设置', style: TextStyle(fontWeight: FontWeight.bold)),
        s('行距', ReaderCfg.lineH, 1.2, 2.6, (x) => p.setDouble('line_height', x)),
        s('段间距', ReaderCfg.paraSpace, 0, 24, (x) => p.setDouble('para_space', x)),
        s('页边距', ReaderCfg.margin, 4, 40, (x) => p.setDouble('reader_margin', x)),
      ])));
    }));
  }

  // ── 目录 ──
  void _tocSheet() {
    showModalBottomSheet(context: context, isScrollControlled: true, builder: (c2) => DraggableScrollableSheet(
      initialChildSize: 0.65, expand: false, builder: (_, sc) => Column(children: [
        Padding(padding: const EdgeInsets.all(12), child: Text('目录 · 共${widget.chapters.length}章', style: const TextStyle(fontWeight: FontWeight.bold))),
        Expanded(child: ListView.builder(controller: sc, itemCount: widget.chapters.length,
          itemBuilder: (_, i) => ListTile(dense: true, selected: i == idx,
            title: Text(widget.chapters[i]['name'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
            onTap: () { Navigator.pop(c2); goChapter(i); }))),
      ])));
  }

  void _toggleNight() {
    final p = ReaderCfg.p;
    final night = ReaderCfg.bg == 0;
    p.setInt('reader_bg', night ? 2 : 0);
    p.setInt('reader_text', 0);
    setState(() {});
  }

  @override Widget build(BuildContext c) {
    final bg = ReaderCfg.bgColor;
    final content = Scaffold(
      backgroundColor: bg,
      body: GestureDetector(
        onTapUp: (d) {
          final w = MediaQuery.of(c).size.width;
          final x = d.globalPosition.dx;
          if (x > w * 0.3 && x < w * 0.7) { setState(() => chrome = !chrome); }
          else if (ReaderCfg.flip == 'none' || ReaderCfg.flip == 'vertical') {
            if (x <= w * 0.3 && hasPrev) goChapter(idx - 1);
            if (x >= w * 0.7 && hasNext) goChapter(idx + 1);
          }
        },
        child: SafeArea(child: Stack(children: [
          Positioned.fill(child: loading ? const Center(child: CircularProgressIndicator())
            : LayoutBuilder(builder: (_, box) => _body(box))),
          // 护眼暖色罩
          if (ReaderCfg.eyeCare) IgnorePointer(child: Container(color: const Color(0x14FFB74D))),
          if (ReaderCfg.bright < 1) IgnorePointer(child: Container(color: Colors.black.withValues(alpha: (1 - ReaderCfg.bright) * 0.55))),
          // 顶栏
          if (chrome) Positioned(top: 0, left: 0, right: 0, child: Container(
            color: const Color(0xFFF7F3EA),
            child: Row(children: [
              IconButton(icon: const Icon(Icons.arrow_back, color: Color(0xFF6B5D4F)), onPressed: () => Navigator.pop(c)),
              Expanded(child: Text('${chapter['name'] ?? ''}  (${idx + 1}/${widget.chapters.length})',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, color: Color(0xFF4A3F30)))),
            ]))),
          // 底栏: 目录/夜间/设置
          if (chrome) Positioned(bottom: 0, left: 0, right: 0, child: Container(
            color: const Color(0xFFF7F3EA),
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              _barItem(Icons.list, '目录', _tocSheet),
              _barItem(Icons.headphones, TtsManager.state == TtsState.idle ? '听书' : '听书中', _ttsSheet),
              _barItem(Icons.nightlight_round, '夜间', _toggleNight),
              _barItem(Icons.settings_outlined, '设置', _settingsSheet),
              _barItem(Icons.skip_previous, '上一章', hasPrev ? () => goChapter(idx - 1) : null),
              _barItem(Icons.skip_next, '下一章', hasNext ? () => goChapter(idx + 1) : null),
            ]))),
        ]))));
    return content;
  }

  Widget _barItem(IconData ic, String t, VoidCallback? onTap) => GestureDetector(onTap: onTap,
    child: Opacity(opacity: onTap == null ? 0.35 : 1, child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(ic, size: 20, color: const Color(0xFF6B5D4F)),
      Text(t, style: const TextStyle(fontSize: 10, color: Color(0xFF6B5D4F))),
    ])));
}

// ── 翻页器: 仿真/覆盖/平移/无动画 ──
class _FlipPager extends StatefulWidget {
  final String mode; final List<String> pages; final double margin; final Color bg;
  final bool hasPrev, hasNext;
  final VoidCallback? onPrevChapter, onNextChapter;
  final Widget Function(String) pageBuilder;
  const _FlipPager({super.key, required this.mode, required this.pages, required this.margin, required this.bg,
    required this.hasPrev, required this.hasNext, this.onPrevChapter, this.onNextChapter, required this.pageBuilder});
  @override State<_FlipPager> createState() => _FlipPagerState();
}

class _FlipPagerState extends State<_FlipPager> {
  late final PageController ctrl = PageController();
  double page = 0;
  @override void initState() { super.initState(); ctrl.addListener(() { if (mounted) setState(() => page = ctrl.page ?? 0); }); }
  @override void dispose() { ctrl.dispose(); super.dispose(); }

  // 音量键翻页入口: 优先翻页, 到边界再翻章
  void turn(bool next) {
    final cur = ctrl.page?.round() ?? 0;
    if (next) {
      if (cur < widget.pages.length) { ctrl.nextPage(duration: const Duration(milliseconds: 180), curve: Curves.easeOut); }
      else { widget.onNextChapter?.call(); }
    } else {
      if (cur > 0) { ctrl.previousPage(duration: const Duration(milliseconds: 180), curve: Curves.easeOut); }
      else { widget.onPrevChapter?.call(); }
    }
  }

  @override Widget build(BuildContext c) {
    final n = widget.pages.length + 1; // 最后一页=章节导航页
    if (widget.mode == 'none') {
      return PageView.builder(controller: ctrl, itemCount: n, physics: const NeverScrollableScrollPhysics(),
        itemBuilder: (_, i) => _page(i));
    }
    return PageView.builder(controller: ctrl, itemCount: n,
      itemBuilder: (_, i) => AnimatedBuilder(animation: ctrl, builder: (_, child) {
        final delta = i - page;
        if (widget.mode == 'cover') {
          // 覆盖: 新页从右侧滑入盖住旧页
          final dx = delta <= 0 ? 0.0 : delta;
          return Transform.translate(offset: Offset(dx * MediaQuery.of(c).size.width, 0), child: child);
        }
        if (widget.mode == 'sim') {
          // 仿真: 翻页透视+阴影
          final angle = delta.clamp(-1.0, 1.0) * -0.5;
          return Transform(alignment: delta >= 0 ? Alignment.centerLeft : Alignment.centerRight,
            transform: Matrix4.identity()..setEntry(3, 2, 0.001)..rotateY(angle),
            child: Container(color: widget.bg, child: child));
        }
        return child!; // slide 平移: 默认
      }, child: _page(i)));
  }

  Widget _page(int i) {
    if (i >= widget.pages.length) {
      return Container(color: widget.bg, child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('本章完', style: TextStyle(color: Colors.grey)),
        const SizedBox(height: 16),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          if (widget.onPrevChapter != null) TextButton(onPressed: widget.onPrevChapter, child: const Text('上一章')),
          if (widget.onNextChapter != null) FilledButton.tonal(onPressed: widget.onNextChapter, child: const Text('下一章')),
        ]),
      ])));
    }
    return Container(color: widget.bg,
      padding: EdgeInsets.all(widget.margin),
      child: SingleChildScrollView(physics: const NeverScrollableScrollPhysics(),
        child: widget.pageBuilder(widget.pages[i])));
  }
}
