// 番茄小说风格的专业阅读器(★4.52.0 对齐番茄的菜单结构):
//   · 点按屏幕中央出菜单; 底栏只留高频 5 项: 目录 / 书签 / 搜索 / 夜间 / 更多
//   · 次要项一律收进「更多」面板: 上一章·下一章 / 阅读设置 / 字体 / 间距 / 听书
//     / 自动阅读(含翻页间隔) / 护眼 / 横屏 / 音量键翻页
//   · 「听书」从底栏一格改为**可四处拖动的悬浮球**(位置持久化, 松手贴边)
//   · 「阅读设置」面板含 亮度/护眼/字号/字体/字色/背景/翻页(仿真/覆盖/平移/上下/无动画)/皮肤
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'reader_fonts.dart';
import 'read_stats.dart';
import 'tts.dart';
import 'tts_presets.dart';
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
  static bool get landscape => p.getBool('reader_landscape') ?? false;
  static String get bgImage => p.getString('reader_bg_img') ?? '';
  static double get bgImageAlpha => p.getDouble('reader_bg_img_alpha') ?? 0.25;
  static bool get autoRead => p.getBool('reader_auto') ?? false;
  static double get autoReadSec => p.getDouble('reader_auto_sec') ?? 6.0;
  // ── 听书悬浮球位置(★番茄式可四处拖动) ──
  // 存**归一化**坐标(0~1)而不是像素: 换设备/旋转/换字号后仍停在相对同一位置,
  // 不会因为屏幕宽度变了把球甩到屏幕外。
  static double get ballX => (p.getDouble('reader_ball_x') ?? 1.0).clamp(0.0, 1.0);
  static double get ballY => (p.getDouble('reader_ball_y') ?? 0.58).clamp(0.0, 1.0);

  // ── 书签(按书) ──
  static List<Map<String, dynamic>> bookmarks(String bookUrl) {
    try {
      return (jsonDecode(p.getString('bm_$bookUrl') ?? '[]') as List).cast<Map<String, dynamic>>();
    } catch (_) { return []; }
  }
  static Future<void> addBookmark(String bookUrl, int chapter, String name) async {
    final l = bookmarks(bookUrl);
    l.removeWhere((e) => e['chapter'] == chapter);
    l.insert(0, {'chapter': chapter, 'name': name, 'at': DateTime.now().toString().substring(0, 16)});
    await p.setString('bm_$bookUrl', jsonEncode(l.take(200).toList()));
  }
  static Future<void> removeBookmark(String bookUrl, int chapter) async {
    final l = bookmarks(bookUrl)..removeWhere((e) => e['chapter'] == chapter);
    await p.setString('bm_$bookUrl', jsonEncode(l));
  }
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
  static const _volChan = MethodChannel('thirdhub/volume_keys');
  // 阅读统计(规划 R-1): 每 30 秒记一次时长
  Timer? _statTimer;
  DateTime _lastVolAt = DateTime.fromMillisecondsSinceEpoch(0);
  int get idx => widget.index;
  Map<String, dynamic> get chapter => widget.chapters[idx];
  bool get hasPrev => idx > 0;
  bool get hasNext => idx < widget.chapters.length - 1;

  @override void initState() { super.initState(); _initTts(); _boot();
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncAutoRead());
    // 阅读统计(规划 R-1): 每 30 秒记一次时长
    _statTimer = Timer.periodic(const Duration(seconds: 30), (_) => ReadStats.tick(sec: 30));
  }
  void _applyOrientation() {
    SystemChrome.setPreferredOrientations(ReaderCfg.landscape
      ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
      : [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
  }
  // ★ P0 根因修复(2026-09-19): ReaderCfg._p 是 `_p!`，只有 _boot() 里的
  //   `await ReaderCfg.init()` 完成后才不为空。旧代码在 initState 里**同步**调
  //   `_applyOrientation()`(读 ReaderCfg.landscape)、在 build() 里读
  //   ReaderCfg.bgColor/bgImage —— 两者都跑在 init 完成之前 → Null check 抛错。
  //   initState 抛错在 release 模式下 = **整页灰屏、无任何提示**，这正是"导入
  //   本地小说后点进去灰蒙蒙一片"的根因。
  //   修法: init 完成前 build 只画加载态(不碰 ReaderCfg)；方向设置挪到 init 之后。
  bool _cfgReady = false;
  Future<void> _boot() async {
    await ReaderCfg.init();
    _applyOrientation();
    if (!mounted) return;
    _cfgReady = true;
    _initVolumeKeys();
    fontFamily = await FontManager.currentFamily();
    await load();
  }

  // ── 听书 ──
  StreamSubscription? _ttsSub;
  void _initTts() { _ttsSub = TtsManager.onState.listen((_) { if (mounted) setState(() {}); }); }
  @override void dispose() { _ttsSub?.cancel(); _autoTimer?.cancel(); _statTimer?.cancel(); _vScroll.dispose(); _volChan.setMethodCallHandler(null); _volChan.invokeMethod('enable', false); TtsManager.stop();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values); super.dispose(); }

  // 音量键翻页: MainActivity 原生拦截音量键并回传(只在阅读页启用, 不改变系统音量)
  void _initVolumeKeys() {
    _volChan.invokeMethod('enable', true);
    _volChan.setMethodCallHandler((call) async {
      if (!mounted || !ReaderCfg.volTurn || call.method != 'press') return;
      final now = DateTime.now();
      if (now.difference(_lastVolAt).inMilliseconds < 280) return;
      _lastVolAt = now;
      _volumeTurn(call.arguments == 'down'); // 音量减=下一页/下一章, 音量加=上一页/上一章
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
            if (TtsBackend.available)
              ChoiceChip(label: const Text('后端合成'), avatar: const Icon(Icons.dns_outlined, size: 16), selected: cur == 'backend',
                onSelected: (_) { TtsManager.setEngine('backend'); setD(() {}); }),
            for (final p in ttsProviders)
              ChoiceChip(label: Text(p.name), selected: cur == p.id,
                onSelected: (_) { TtsManager.setEngine(p.id); setD(() {}); }),
          ]);
        }),
        if (TtsManager.backendError.isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 6),
            child: Text('后端合成失败已降级系统朗读: ${TtsManager.backendError}', style: const TextStyle(fontSize: 10, color: Colors.orange))),
        const SizedBox(height: 6),
        GestureDetector(onTap: () => showModalBottomSheet(context: context, builder: (c3) => SafeArea(child: ListView(shrinkWrap: true, children: [
          const Padding(padding: EdgeInsets.all(12), child: Text('在线 TTS 厂商预设', style: TextStyle(fontWeight: FontWeight.bold))),
          for (final tp in kTtsPresets)
            ListTile(dense: true, leading: const Icon(Icons.record_voice_over_outlined, size: 20),
              title: Text(tp.name, style: const TextStyle(fontSize: 13)),
              subtitle: Text('${tp.base}\n${tp.note}', style: const TextStyle(fontSize: 10)),
              trailing: const Icon(Icons.chevron_right, size: 16),
              onTap: () { Navigator.pop(c3);
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('到 AI 模块配置 ${tp.name} 的 API Key 后即可选用'))); }),
          for (final n in kTtsNotes) Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text(n, style: const TextStyle(fontSize: 11, color: Colors.grey))),
          const SizedBox(height: 12),
        ]))),
          child: const Row(children: [ Icon(Icons.hub_outlined, size: 14, color: Colors.grey), SizedBox(width: 4),
            Text('查看 TTS 厂商预设 / 开源引擎接入指引', style: TextStyle(fontSize: 11, color: Colors.grey)) ])),
        const SizedBox(height: 6),
        const Text('系统朗读离线免费; 后端合成走自己的后端(piper离线/edge-tts在线); 在线引擎需在 AI 模块配置对应厂商的 API Key', style: TextStyle(fontSize: 10, color: Colors.grey)),
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
      ReadStats.tick(chars: text.length); // 阅读统计: 按章记字数
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
        child: GestureDetector(
          onLongPress: para.trim().isEmpty ? null : () => _paraMenu(para),
          child: Text(para, style: _textStyle))),
  ]);

  // ── 长按段落菜单(番茄式) ──
  void _paraMenu(String para) {
    HapticFeedback.mediumImpact();
    showModalBottomSheet(context: context, builder: (c2) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Container(margin: const EdgeInsets.fromLTRB(16, 12, 16, 4), padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: Theme.of(c2).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8)),
        constraints: const BoxConstraints(maxHeight: 100),
        child: SingleChildScrollView(child: Text(para.trim(), style: const TextStyle(fontSize: 12, color: Colors.grey)))),
      ListTile(dense: true, leading: const Icon(Icons.copy, size: 20), title: const Text('复制本段'),
        onTap: () { Clipboard.setData(ClipboardData(text: para.trim())); Navigator.pop(c2);
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制'), duration: Duration(seconds: 1))); }),
      ListTile(dense: true, leading: const Icon(Icons.headphones, size: 20), title: const Text('朗读本段'),
        onTap: () { Navigator.pop(c2); TtsManager.speak(para.trim()); }),
      ListTile(dense: true, leading: const Icon(Icons.play_circle_outline, size: 20), title: const Text('从此段开始听书'),
        onTap: () { Navigator.pop(c2);
          final pos = text.indexOf(para);
          TtsManager.speak(pos >= 0 ? text.substring(pos) : para.trim()); }),
      ListTile(dense: true, leading: const Icon(Icons.bookmark_add_outlined, size: 20), title: const Text('本章加入书签'),
        onTap: () { Navigator.pop(c2); _addBookmark(); }),
      const SizedBox(height: 8),
    ])));
  }

  // ── 书签 ──
  // ── 自动阅读: 翻页模式定时翻页 / 上下模式平滑滚动 ──
  Timer? _autoTimer;
  final ScrollController _vScroll = ScrollController();
  void _syncAutoRead() {
    _autoTimer?.cancel();
    if (!ReaderCfg.autoRead) return;
    _autoTimer = Timer.periodic(const Duration(milliseconds: 60), (_) {
      if (!mounted || loading) return;
      if (ReaderCfg.flip == 'vertical') {
        if (!_vScroll.hasClients) return;
        final max = _vScroll.position.maxScrollExtent;
        // 速度: 秒数越大越慢 — 每帧前进 (每屏高度/sec) 的 1/60
        final step = MediaQuery.of(context).size.height / (ReaderCfg.autoReadSec * 60);
        final next = _vScroll.offset + step;
        if (next >= max) { if (hasNext) { goChapter(idx + 1); } else { _autoTimer?.cancel(); } }
        else _vScroll.jumpTo(next);
      }
    });
    if (ReaderCfg.flip != 'vertical') {
      // 翻页模式: 每 autoReadSec 秒翻一页
      _autoTimer = Timer.periodic(Duration(milliseconds: (ReaderCfg.autoReadSec * 1000).round()), (_) {
        if (!mounted || loading) return;
        _pagerKey.currentState?.turn(true);
      });
    }
  }

  // ── 本章搜索 ──
  void _searchSheet() {
    final ctrl = TextEditingController();
    showModalBottomSheet(context: context, isScrollControlled: true,
      builder: (c2) => StatefulBuilder(builder: (c2, setD) {
        final q = ctrl.text.trim();
        final hits = <int>[];
        if (q.isNotEmpty) {
          var from = 0;
          while (hits.length < 100) {
            final i = text.indexOf(q, from);
            if (i < 0) break;
            hits.add(i); from = i + q.length;
          }
        }
        return Padding(padding: EdgeInsets.only(bottom: MediaQuery.of(c2).viewInsets.bottom),
          child: SafeArea(child: SizedBox(height: 420, child: Column(children: [
            Padding(padding: const EdgeInsets.all(10), child: TextField(controller: ctrl, autofocus: true,
              decoration: InputDecoration(hintText: '搜索本章内容', isDense: true, filled: true,
                prefixIcon: const Icon(Icons.search, size: 18),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none)),
              onChanged: (_) => setD(() {}))),
            Expanded(child: q.isEmpty ? const Center(child: Text('输入关键词', style: TextStyle(color: Colors.grey)))
              : hits.isEmpty ? const Center(child: Text('本章未找到', style: TextStyle(color: Colors.grey)))
              : ListView(children: [ for (final h in hits)
                  ListTile(dense: true,
                    title: Text(text.substring((h - 18).clamp(0, text.length), (h + q.length + 18).clamp(0, text.length)).replaceAll('\n', ' '),
                      maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                    onTap: () { Navigator.pop(c2); _jumpToChar(h); }) ])),
          ]))));
      }));
  }

  // 跳到字符位置: 翻页模式→跳到对应页; 上下模式→按比例滚动
  void _jumpToChar(int charIdx) {
    HapticFeedback.selectionClick();
    if (ReaderCfg.flip == 'vertical') {
      if (_vScroll.hasClients && text.isNotEmpty) {
        _vScroll.jumpTo((_vScroll.position.maxScrollExtent * charIdx / text.length).clamp(0, double.infinity));
      }
    } else {
      _pagerKey.currentState?.jumpToChar(charIdx);
    }
  }

  DateTime _lastBmAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _bmCooling() {
    final now = DateTime.now();
    if (now.difference(_lastBmAt).inSeconds < 3) return true;
    _lastBmAt = now;
    return false;
  }

  Future<void> _addBookmark() async {
    await ReaderCfg.addBookmark(widget.bookUrl, idx, chapter['name'] ?? '第${idx + 1}章');
    HapticFeedback.lightImpact();
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已添加书签'), duration: Duration(seconds: 1)));
  }

  void _bookmarkSheet() {
    final list = ReaderCfg.bookmarks(widget.bookUrl);
    showModalBottomSheet(context: context, builder: (c2) => SafeArea(child: SizedBox(height: 380, child: Column(children: [
      const Padding(padding: EdgeInsets.all(12), child: Text('书签', style: TextStyle(fontWeight: FontWeight.bold))),
      Expanded(child: list.isEmpty ? const Center(child: Text('暂无书签\n下拉页面顶部或长按段落可添加', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)))
        : ListView(children: [ for (final b in list) ListTile(dense: true,
            leading: const Icon(Icons.bookmark, size: 18, color: Colors.amber),
            title: Text(b['name'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
            subtitle: Text(b['at'] ?? '', style: const TextStyle(fontSize: 10, color: Colors.grey)),
            trailing: IconButton(icon: const Icon(Icons.delete_outline, size: 18),
              onPressed: () async { await ReaderCfg.removeBookmark(widget.bookUrl, b['chapter'] ?? 0); if (c2.mounted) Navigator.pop(c2); }),
            onTap: () { Navigator.pop(c2); goChapter(b['chapter'] ?? 0); }) ])),
    ]))));
  }

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
      return NotificationListener<ScrollNotification>(
        onNotification: (n) {
          // 下拉过头(在顶部继续下拉) -> 添加书签
          if (n is OverscrollNotification && n.overscroll < -40 && !_bmCooling()) {
            _addBookmark();
          }
          return false;
        },
        child: SingleChildScrollView(controller: _vScroll, physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.all(ReaderCfg.margin), child: _paragraphs(text)));
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
          // 自定义皮肤(背景图导入)
          Row(children: [ rowLabel('皮肤'),
            TextButton.icon(icon: const Icon(Icons.image_outlined, size: 16, color: Color(0xFF6B5D4F)),
              label: Text(ReaderCfg.bgImage.isEmpty ? '导入背景图' : '更换背景图',
                style: const TextStyle(fontSize: 13, color: Color(0xFF6B5D4F))),
              onPressed: () async {
                final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1600);
                if (x == null) return;
                await p.setString('reader_bg_img', x.path);
                save();
              }),
            if (ReaderCfg.bgImage.isNotEmpty) ...[
              Expanded(child: Slider(value: ReaderCfg.bgImageAlpha, min: 0.05, max: 0.8,
                activeColor: const Color(0xFFB59A6C),
                onChanged: (v) { p.setDouble('reader_bg_img_alpha', v); save(); })),
              GestureDetector(onTap: () { p.remove('reader_bg_img'); save(); },
                child: const Icon(Icons.close, size: 18, color: Color(0xFF6B5D4F))),
            ] else
              const Expanded(child: Text('自定义图片做阅读背景', style: TextStyle(fontSize: 10, color: Colors.grey))),
          ]),
          // ★ 间距 / 自动阅读 / 横屏 / 音量键 已统一移到「更多」面板(单一入口, 不两处各放一份)
          const SizedBox(height: 4),
          const Align(alignment: Alignment.centerLeft, child: Text(
            '间距 / 自动阅读 / 横屏 / 音量键翻页 → 底栏「更多」',
            style: TextStyle(fontSize: 10, color: Colors.grey))),
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

  // ── 听书悬浮球(★番茄式: 可四处拖动) ──────────────────────────────
  // 为什么用悬浮球而不是底栏一格: 听书是**长时状态**(可能听半小时), 期间用户
  // 还要翻页/调设置 —— 占着底栏一格不如浮一颗球, 且能拖到不挡字的地方。
  // 位置持久化(归一化坐标), 松手自动贴到最近的左/右边缘。
  static const double _ballD = 46;
  bool _ballDrag = false;

  Offset _ballPos(Size size) {
    final d = _ballD;
    final maxX = math.max(0.0, size.width - d - 16);
    final maxY = math.max(0.0, size.height - d - 16);
    return Offset(8 + ReaderCfg.ballX * maxX, 8 + ReaderCfg.ballY * maxY);
  }

  Widget _ttsBall(BuildContext c) {
    final size = MediaQuery.of(c).size;
    final pos = _ballPos(size);
    final st = TtsManager.state;
    final active = st != TtsState.idle;
    final playing = st == TtsState.playing;
    const d = _ballD;
    return Positioned(left: pos.dx, top: pos.dy, child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => setState(() => _ballDrag = true),
      onPanUpdate: (e) {
        final maxX = math.max(1.0, size.width - d - 16);
        final maxY = math.max(1.0, size.height - d - 16);
        final x = (pos.dx + e.delta.dx - 8).clamp(0.0, maxX);
        final y = (pos.dy + e.delta.dy - 8).clamp(0.0, maxY);
        ReaderCfg.p.setDouble('reader_ball_x', x / maxX);
        ReaderCfg.p.setDouble('reader_ball_y', y / maxY);
        setState(() {});
      },
      onPanEnd: (_) {
        ReaderCfg.p.setDouble('reader_ball_x', ReaderCfg.ballX < 0.5 ? 0.0 : 1.0);
        setState(() => _ballDrag = false);
      },
      onTap: _ttsSheet,
      child: AnimatedOpacity(duration: const Duration(milliseconds: 180),
        opacity: _ballDrag ? 1.0 : (active ? 1.0 : (chrome ? 0.95 : 0.5)),
        child: Container(width: d, height: d, alignment: Alignment.center,
          decoration: BoxDecoration(color: const Color(0xF2F7F3EA), shape: BoxShape.circle,
            border: Border.all(color: active ? const Color(0xFFB59A6C) : const Color(0x66B59A6C),
              width: active ? 1.6 : 1.0),
            boxShadow: const [BoxShadow(color: Color(0x2E000000), blurRadius: 8, offset: Offset(0, 2))]),
          child: Icon(playing ? Icons.graphic_eq : (active ? Icons.pause : Icons.headphones),
            size: 22, color: const Color(0xFF6B5D4F))),
      ),
    ));
  }

  // ── 「更多」面板(★番茄式: 底栏只留高频项, 次要项一律收进这里) ──
  // 收纳原则: 一次性调完就不再动的(字体/间距/皮肤/横屏/音量键)进「更多」;
  // 阅读中反复用的(目录/书签/搜索/夜间/听书)留在底栏或悬浮球上。
  void _moreSheet() {
    showModalBottomSheet(context: context, isScrollControlled: true,
      backgroundColor: const Color(0xFFF7F3EA),
      builder: (c2) => StatefulBuilder(builder: (c2, setD) {
        final p = ReaderCfg.p;
        void save() { setState(() {}); setD(() {}); }
        void go(VoidCallback f) { Navigator.pop(c2); f(); }
        Widget cell(IconData ic, String t, VoidCallback onTap) => GestureDetector(onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: SizedBox(width: 78, child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(ic, size: 24, color: const Color(0xFF6B5D4F)),
            const SizedBox(height: 6),
            Text(t, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Color(0xFF6B5D4F))),
          ])));
        Widget sw(String label, bool v, ValueChanged<bool> on) => SizedBox(height: 44,
          child: Row(children: [
            Expanded(child: Text(label, style: const TextStyle(fontSize: 13, color: Color(0xFF6B5D4F)))),
            Switch(value: v, activeColor: const Color(0xFFB59A6C), onChanged: on),
          ]));
        return SafeArea(child: SingleChildScrollView(child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12), child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [ const Icon(Icons.more_horiz, size: 20, color: Color(0xFF6B5D4F)), const SizedBox(width: 8),
            Expanded(child: Text('更多 · 第 ${idx + 1}/${widget.chapters.length} 章',
              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold))) ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: OutlinedButton.icon(icon: const Icon(Icons.skip_previous, size: 18),
              label: const Text('上一章'), onPressed: hasPrev ? () => go(() => goChapter(idx - 1)) : null)),
            const SizedBox(width: 10),
            Expanded(child: OutlinedButton.icon(icon: const Icon(Icons.skip_next, size: 18),
              label: const Text('下一章'), onPressed: hasNext ? () => go(() => goChapter(idx + 1)) : null)),
          ]),
          const Divider(height: 26),
          Wrap(spacing: 4, runSpacing: 14, alignment: WrapAlignment.spaceEvenly, children: [
            cell(Icons.text_fields, '阅读设置', () => go(_settingsSheet)),
            cell(Icons.font_download_outlined, '字体', () => go(_fontSheet)),
            cell(Icons.format_line_spacing, '间距', () => go(_spacingSheet)),
            cell(Icons.headphones, TtsManager.state == TtsState.idle ? '听书' : '听书中', () => go(_ttsSheet)),
          ]),
          const SizedBox(height: 10),
          const Divider(height: 1),
          sw('自动阅读', ReaderCfg.autoRead, (v) { p.setBool('reader_auto', v); _syncAutoRead(); save(); }),
          if (ReaderCfg.autoRead) Row(children: [
            const SizedBox(width: 62, child: Text('翻页间隔', style: TextStyle(fontSize: 12, color: Color(0xFF6B5D4F)))),
            Expanded(child: Slider(value: ReaderCfg.autoReadSec, min: 2, max: 20, activeColor: const Color(0xFFB59A6C),
              label: '${ReaderCfg.autoReadSec.toInt()} 秒',
              onChanged: (v) { p.setDouble('reader_auto_sec', v); _syncAutoRead(); save(); })),
          ]),
          sw('护眼模式', ReaderCfg.eyeCare, (v) { p.setBool('eye_care', v); save(); }),
          sw('横屏阅读', ReaderCfg.landscape, (v) { p.setBool('reader_landscape', v); _applyOrientation(); save(); }),
          sw('音量键翻页', ReaderCfg.volTurn, (v) { p.setBool('vol_turn', v); save(); }),
          const SizedBox(height: 6),
          const Align(alignment: Alignment.centerLeft,
            child: Text('提示: 听书是屏幕上的圆形悬浮球, 按住可拖到任意位置, 点一下打开听书面板',
              style: TextStyle(fontSize: 10, color: Colors.grey))),
        ]))));
      }));
  }

  @override Widget build(BuildContext c) {
    // init 未完成前绝不碰 ReaderCfg（_p! 会抛 → release 下整页灰屏）
    if (!_cfgReady) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final bg = ReaderCfg.bgColor;
    final hasBgImg = ReaderCfg.bgImage.isNotEmpty && File(ReaderCfg.bgImage).existsSync();
    final content = Scaffold(
      backgroundColor: bg,
      body: hasBgImg ? Container(decoration: BoxDecoration(
        image: DecorationImage(image: FileImage(File(ReaderCfg.bgImage)), fit: BoxFit.cover,
          colorFilter: ColorFilter.mode(bg.withValues(alpha: 1 - ReaderCfg.bgImageAlpha), BlendMode.srcOver))),
        child: _readerBody(c)) : _readerBody(c),
    );
    return content;
  }

  Widget _readerBody(BuildContext c) {
    final bg = ReaderCfg.bgColor;
    return Scaffold(
      backgroundColor: Colors.transparent,
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
          // 听书悬浮球(可四处拖动) —— 不受 chrome 显隐影响, 但隐藏菜单时会半透明
          _ttsBall(c),
          // 底栏: 只留阅读中反复用的高频项(★次要项一律收进「更多」)
          if (chrome) Positioned(bottom: 0, left: 0, right: 0, child: Container(
            color: const Color(0xFFF7F3EA),
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              _barItem(Icons.list, '目录', _tocSheet),
              _barItem(Icons.bookmark_border, '书签', _bookmarkSheet),
              _barItem(Icons.search, '搜索', _searchSheet),
              _barItem(Icons.nightlight_round, ReaderCfg.bg == 0 ? '日间' : '夜间', _toggleNight),
              _barItem(Icons.more_horiz, '更多', _moreSheet),
            ]))),
        ]))));
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

  // 搜索跳转: 按字符位置估算页码
  void jumpToChar(int charIdx) {
    if (widget.pages.isEmpty) return;
    final total = widget.pages.fold<int>(0, (s, p) => s + p.length);
    if (total == 0) return;
    final per = total / widget.pages.length;
    final page = (charIdx / per).floor().clamp(0, widget.pages.length - 1);
    ctrl.jumpToPage(page);
  }

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
