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
import 'tts_engines_page.dart';
import 'tts_online.dart';
import 'tts_settings_page.dart';
import 'tts_vendors.dart';
import 'ai.dart';
import 'motion.dart';
// ★2026-10-03：正文失败要「说清哪个源坏了 + 给换源出口」，这两件事分别用到
//   既有 R-2 的源健康度统计与 i18n。**复用，不另造一套**。
import 'i18n.dart';
import 'pro_reading.dart';

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

  /// ★2026-10-03 新增：这本书来自哪个源（显示名）。
  /// 正文失败时用它做两件事：① 告诉用户「哪个来源坏了」而不是干巴巴一句"获取失败"；
  /// ② 往 [SourceHealth] 记一笔成败，供自动换源排序用（复用既有 R-2 能力，不另造一套）。
  final String sourceName;

  /// ★换一批结果重搜：正文取不到时的**主出口**。由调用方实现（要按书名重新搜索、
  /// 挑一个同名但不同源的结果并重开本书）—— 阅读器本身不知道引擎/书源怎么用，
  /// 所以这里只留一个回调，保持它对引擎的零依赖（本地书、离线书同样能用这个界面）。
  final Future<void> Function()? onSwapSource;

  const NovelReaderPage({super.key, required this.sourceId, required this.chapters, required this.index,
    required this.bookName, required this.bookUrl, required this.fetchContent, this.onProgress,
    this.sourceName = '', this.onSwapSource});
  @override State<NovelReaderPage> createState() => _NovelReaderState();
}

class _NovelReaderState extends State<NovelReaderPage> {
  String text = ''; List<String> images = []; bool loading = true;

  // ★2026-10-03 正文取不到时的**结构化失败态**（旧实现只有 `text = '错误: $e'`）。
  //
  // 为什么要结构化：用户报的是「搜得到、有封面简介、点进去提示正文未加载」。
  // 根因实测（模拟器 10 本样本）：**目录正常、正文为空**，引擎抛
  // `ContentEmptyException: 内容为空` —— 即**某些源的正文规则已经失效**；
  // 而同一本书换个源就能读（实测 7 个源里 4 个能读出正文）。
  // 旧实现把异常字符串当正文显示，用户既不知道哪个源坏了、也没有任何出口，
  // 只能退出去重搜 —— 而重搜还会搜到同一个坏源。→ 必须给「原因 + 换源出口」。
  String? _failKind;   // source_empty | source_missing | chapter_gone | engine_down | unknown
  String? _failMsg;
  bool _swapping = false;

  /// 把引擎/网络抛来的东西归类成人能懂的失败原因。
  ///
  /// ★两层判据，新旧通吃：
  ///   第一层认引擎 1.13.0 起给的**稳定标记** `[SOURCE_EMPTY]` / `[NEED_REGISTRATION]`
  ///   （引擎侧在 `BookController.getBookContent` 里打的，语义稳定、不会随文案改动而失效）；
  ///   第二层退回字符串兜底，兼容 1.13.0 之前的引擎（它们只会吐
  ///   `ContentEmptyException: 内容为空` 这类带异常名的文本）。
  static String _classifyFail(Object e) {
    final t = '$e';
    if (t.contains('SOURCE_EMPTY') || t.contains('ContentEmpty') || t.contains('内容为空')) {
      return 'source_empty';
    }
    if (t.contains('NEED_REGISTRATION') || t.contains('未找到书源') || t.contains('未在数据库找到')) {
      return 'source_missing';
    }
    if (t.contains('章节不存在') || t.contains('HTTP 404')) return 'chapter_gone';
    if (t.contains('未连接引擎') || t.contains('CLEARTEXT') || t.contains('未发现引擎')) {
      return 'engine_down';
    }
    return 'unknown';
  }

  static String _failTitle(String k) => switch (k) {
        'source_empty' => tr('来源抓不到正文'),
        'source_missing' => tr('来源已失效'),
        'chapter_gone' => tr('这一章不存在'),
        'engine_down' => tr('连不上资料库'),
        _ => tr('正文没拿到'),
      };

  /// 失败原因的人话说明。
  ///
  /// ★只用**两种**提示：源坏了 vs 其它故障。
  /// 分类标题已说明"是哪一类"，这里只补"接下来该干什么"，而不同类的
  /// **下一步动作其实是同一个** —— 换一批结果重搜或重试。键越少越不容易漏翻译
  /// （每多一个键 ×6 语言就是一份长期维护债）。
  ///
  /// ★不要把源名插进这句话：插值拼出来的字符串**不在 tr() 里**，
  ///   英文界面就会整段露中文。源名单独一行显示（见 [_failView]）。
  static String _failHint(String k) => switch (k) {
        'source_empty' || 'source_missing' => tr(
            '这个来源没能返回这一章的内容。同一本书在别的来源通常能读，点「换一批结果重搜」会自动用书名重搜并进入能读的那一份。'),
        _ => tr('暂时取不到这一章。可以先重试；不行就换一批结果重搜。'),
      };

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
        FutureBuilder<({String cur, List<TtsVendor> ready})>(
          future: () async {
            final cur = await TtsManager.engine();
            final vs = await TtsOnline.allVendors();
            final ready = <TtsVendor>[];
            for (final v in vs) {
              if ((await TtsOnline.configOf(v.id)).readyFor(v)) ready.add(v);
            }
            return (cur: cur, ready: ready);
          }(),
          builder: (_, snap) {
          final cur = snap.data?.cur ?? 'system';
          // ★ 厂商列表来自 **TTS 自己的注册表**（内置 + 用户自定义）。
          //   旧实现是从 AI 厂商表里筛"模型名带 tts 的" —— 只能捞到
          //   OpenAI 兼容的那几家，而且要求用户先去「AI 模块」把它配成一个
          //   AI 厂商才能在这里出现，配的地方和用的地方不在一处。
          final ready = snap.data?.ready ?? const <TtsVendor>[];
          final curMissing = cur != 'system' &&
              cur != 'backend' &&
              cur != 'opensource' &&
              !ready.any((v) => v.id == cur);
          return Wrap(spacing: 8, runSpacing: 8, children: [
            ChoiceChip(label: const Text('系统离线朗读'), selected: cur == 'system',
              onSelected: (_) { TtsManager.setEngine('system'); setD(() {}); }),
            if (TtsBackend.available)
              ChoiceChip(label: const Text('后端合成'), avatar: const Icon(Icons.dns_outlined, size: 16), selected: cur == 'backend',
                onSelected: (_) { TtsManager.setEngine('backend'); setD(() {}); }),
            // 开源引擎直连（D-C3）。★ 没配地址时**不要装作能选** ——
            //   选了却不合成、只是静默降级，用户会以为"听书坏了"。
            //   所以未配置时这一项直接把人送到引导页。
            ChoiceChip(
              label: Text(cur == 'opensource' ? '开源引擎 · 已选' : '开源引擎'),
              avatar: const Icon(Icons.memory, size: 16),
              selected: cur == 'opensource',
              onSelected: (_) async {
                final p = await SharedPreferences.getInstance();
                final u = p.getString('tts_os_url') ?? '';
                if (u.isEmpty) {
                  if (context.mounted) {
                    await Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const TtsEnginesPage()));
                  }
                  return;
                }
                TtsManager.setEngine('opensource');
                setD(() {});
              }),
            // 只列**已经配好 Key / 地址**的在线厂商：没配的摆出来也点不动，
            // 反而让人以为"这些都能用"。想接新的走下面的「语音厂商设置」。
            if (curMissing)
              ChoiceChip(
                label: Text('$cur（未配置）'),
                selected: true, onSelected: (_) {}),
            for (final v in ready)
              ChoiceChip(label: Text(v.name), selected: cur == v.id,
                onSelected: (_) { TtsManager.setEngine(v.id); setD(() {}); }),
            ActionChip(
              avatar: const Icon(Icons.settings_outlined, size: 16),
              label: const Text('语音厂商设置'),
              onPressed: () async {
                if (c2.mounted) Navigator.pop(c2);
                if (context.mounted) {
                  await Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const TtsSettingsPage()));
                }
              }),
          ]);
        }),
        if (TtsManager.backendError.isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 6),
            child: Text('后端合成失败已降级系统朗读: ${TtsManager.backendError}', style: const TextStyle(fontSize: 10, color: Colors.orange))),
        if (TtsManager.openSourceError.isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 6),
            child: Text('开源引擎不可用已降级系统朗读: ${TtsManager.openSourceError}', style: const TextStyle(fontSize: 10, color: Colors.orange))),
        // 在线厂商失败也要说出来。全句来自 TtsOnline.synthesize 抛出的可读文案
        // （Key 被拒 / 返回结构变了 / 连不上），比"朗读失败"四个字有用得多。
        if (TtsManager.onlineError.isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 6),
            child: Text('在线语音不可用已降级系统朗读:\n${TtsManager.onlineError}',
              style: const TextStyle(fontSize: 10, color: Colors.orange))),
        const SizedBox(height: 6),
        GestureDetector(
          onTap: () async {
            if (c2.mounted) Navigator.pop(c2);
            if (context.mounted) {
              await Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const TtsSettingsPage()));
            }
          },
          child: Row(children: [
            const Icon(Icons.hub_outlined, size: 14, color: Colors.grey),
            const SizedBox(width: 4),
            // 旧文案写的是「查看 TTS 厂商预设」，而那张表里的地址有一半是错的
            // （阿里/火山/MiniMax 都不对），点进去也只是提示"去 AI 模块配置"。
            // 现在直接把人送到真正能填 Key 的那一页。
            Expanded(
                child: Text(
                    '语音厂商设置 · 内置 ${kTtsVendors.length} 家可填 Key 即用 / 自定义接口 / 开源引擎指引',
                    style: const TextStyle(fontSize: 11, color: Colors.grey))),
            const Icon(Icons.chevron_right, size: 14, color: Colors.grey),
          ]),
        ),
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
    setState(() { loading = true; _failKind = null; _failMsg = null; });
    final t0 = DateTime.now();
    try {
      Map<String, dynamic> d;
      if (chapCache.containsKey(idx)) { d = chapCache[idx]!; }
      else { d = await widget.fetchContent(widget.sourceId, chapter['url'] ?? ''); chapCache[idx] = d; }
      text = d['text'] as String? ?? ''; images = List<String>.from(d['images'] ?? []);
      // ★「HTTP 200 但正文是空的」与「抛异常」是**同一类问题**（源没给内容），
      //   旧实现只把前者显示成一句「本章无内容」，用户同样没有出口。归到失败态一起处理。
      if (text.trim().isEmpty && images.isEmpty) {
        _recordHealth(true, DateTime.now().difference(t0).inMilliseconds);
        _failKind = 'source_empty';
        _failMsg = '引擎返回了这一章，但内容是空的。';
        text = '';
      } else {
        _recordHealth(true, DateTime.now().difference(t0).inMilliseconds);
        ReadStats.tick(chars: text.length); // 阅读统计: 按章记字数
      }
      final p = await SharedPreferences.getInstance();
      await p.setInt('progress_${widget.bookUrl}', idx);
      try { await widget.onProgress?.call(idx, chapter['name'] ?? ''); } catch (_) {}
      preload(idx + 1); preload(idx - 1);
    } catch (e) {
      // ★失败也要记账：源健康度是「自动换源」排序的依据（复用既有 R-2 的 SourceHealth）。
      //   旧实现只把异常显示出来，全项目**没有任何地方统计过章节抓取成败**，
      //   于是 R-2 那套换源能力在引擎直连这条路上其实是**空转的**。
      _recordHealth(false, DateTime.now().difference(t0).inMilliseconds);
      chapCache.remove(idx); // 别把失败的缓存留下，否则「重试」永远拿到同一份坏数据
      text = '';
      _failKind = _classifyFail(e);
      _failMsg = '$e';
    }
    if (mounted) setState(() => loading = false);
  }

  /// 把这一章的成败记进源健康度（失败原因已分类，`unknown` 不记 —— 那是网络抖动不是源坏）。
  void _recordHealth(bool ok, int ms) {
    final src = widget.sourceName.trim();
    if (src.isEmpty) return;
    if (!ok && _failKind == 'unknown') return;
    // 复用既有 R-2 能力，不另造一套统计
    SourceHealth.record(src, ok: ok, ms: ms);
  }

  /// 换一批结果重搜：委托调用方实现（阅读器不知道引擎/书源怎么用，保持零依赖）。
  Future<void> _swapSource() async {
    if (_swapping) return;
    setState(() => _swapping = true);
    try {
      await widget.onSwapSource?.call();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('换源失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _swapping = false);
    }
  }

  void goChapter(int i) => Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => NovelReaderPage(
    sourceId: widget.sourceId, chapters: widget.chapters, index: i,
    bookName: widget.bookName, bookUrl: widget.bookUrl,
    // ★把「源名 + 换源出口」一起带走：换章后如果这个源也坏了，
    //   新页面照样能说清是哪个源、照样能换源 —— 旧实现这两个参数只在本页有效，
    //   翻一页就退回到「一句 错误: ...」，等于换源能力只对第一章生效。
    sourceName: widget.sourceName, onSwapSource: widget.onSwapSource,
    fetchContent: widget.fetchContent, onProgress: widget.onProgress)));

  // ── 分页: TextPainter 真实测量（canvas 预分页）──
  //
  // 旧实现按「估算每行字数 × 估算行数」硬切：字号/字体改变、中英混排、标点
  // 宽度差异都会让实际换行与估算不符 → 页尾出现半行空档或末行被裁掉。
  // 这里改用 TextPainter 做真实 layout，二分定位该页能容纳的字符数，再往
  // 换行处微调切点（避免把标点孤零零留在页首）。
  List<String> _paginate(String t, BoxConstraints box) {
    if (t.isEmpty) return const [''];
    return TextPaginator.paginate(
      text: t,
      style: _textStyle,
      maxWidth: box.maxWidth - ReaderCfg.margin * 2,
      maxHeight: box.maxHeight - 40,
      paraSpace: ReaderCfg.paraSpace,
    );
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
    // ★正文取不到时**整页早退**成可操作的失败页，而不是把异常当正文显示。
    //   早退而不是就地替换：失败页要能给出「换一批结果重搜」这个跨页动作，
    //   留在阅读器正文流里会让用户以为是自己翻错了页。
    if (_failKind != null) return _failView(c);
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

  /// 正文失败的整页出口（原因 + 三个动作）。
  ///
  /// ★设计取舍：按钮只给三个，多了反而让人不知道该点哪个 ——
  ///   「重试本章」   网络抖动、临时抽风时用（不换书，最快）
  ///   「换一批结果重搜」   源坏了时用（**主按钮**，自动以书名重搜并进入能读的那一份）
  ///   「返回」       回到目录/详情
  Widget _failView(BuildContext c) {
    final k = _failKind!;
    final src = widget.sourceName.trim();
    return Scaffold(
      backgroundColor: ReaderCfg.bgColor,
      appBar: AppBar(
        backgroundColor: ReaderCfg.bgColor,
        foregroundColor: ReaderCfg.fgColor,
        elevation: 0,
        leading: IconButton(
            icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.pop(c)),
        title: Text(tr('正文没拿到'), style: TextStyle(color: ReaderCfg.fgColor, fontSize: 15)),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(28, 20, 28, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(Icons.menu_book_outlined, size: 52, color: ReaderCfg.fgColor.withValues(alpha: 0.35)),
              const SizedBox(height: 14),
              Text(_failTitle(k),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600, color: ReaderCfg.fgColor)),
              const SizedBox(height: 8),
              // 源名单独一行：它是「换个源」这件事的判断依据，必须让用户看见。
              if (src.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: ReaderCfg.fgColor.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(src,
                      style: TextStyle(
                          fontSize: 12, color: ReaderCfg.fgColor.withValues(alpha: 0.7))),
                ),
              const SizedBox(height: 10),
              Text(
                // ★单条完整文案走 tr()；不要用插值拼句子里（那会绕过翻译表）。
                _failHint(k),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, height: 1.6, color: ReaderCfg.fgColor.withValues(alpha: 0.75)),
              ),
              const SizedBox(height: 8),
              // 原始报错折叠：技术细节给排查用，不糊在主视图上
              if ((_failMsg ?? '').isNotEmpty)
                Theme(
                  data: Theme.of(c).copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: EdgeInsets.zero,
                    title: Text(tr('技术细节'),
                        style: TextStyle(fontSize: 12, color: ReaderCfg.fgColor.withValues(alpha: 0.55))),
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text(_failMsg!,
                            style: TextStyle(fontSize: 11,
                                color: ReaderCfg.fgColor.withValues(alpha: 0.5))),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: _swapping ? null : _swapSource,
                    icon: _swapping
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.swap_horiz, size: 18),
                    label: Text(_swapping ? tr('正在换一批结果…') : tr('换一批结果重搜')),
                  ),
                  OutlinedButton.icon(
                    onPressed: () { chapCache.remove(idx); load(); },
                    icon: const Icon(Icons.refresh, size: 18),
                    label: Text(tr('重试本章')),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(c),
                    child: Text(tr('返回')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
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
  /// 当前页索引（最后一屏 = 「本章完」章节导航页，索引 == pages.length）。
  ///
  /// ★ 为什么不再用 PageController：仿真/覆盖要的是「三屏承载 + 跟手卷曲」，
  ///   PageView 只能做到整页平移，做不出折痕锚点、卷边阴影与背面。改为自持
  ///   索引后，翻页动画由 PageCurlView 负责，**动画走完才改这个索引**——
  ///   于是"动画不得改变真实章节位置"这条约束天然成立。
  int _idx = 0;

  int get _last => widget.pages.length;

  void _go(int i) {
    final n = _last + 1;
    setState(() => _idx = i.clamp(0, n - 1));
  }

  // 搜索跳转: 按真实分页结果把字偏移映射到页
  void jumpToChar(int charIdx) =>
      _go(TextPaginator.pageOfIndex(widget.pages, charIdx));

  // 音量键/点按翻页入口: 优先翻页, 到边界再翻章
  void turn(bool next) {
    if (next) {
      if (_idx < _last) {
        _go(_idx + 1);
      } else {
        widget.onNextChapter?.call();
      }
    } else {
      if (_idx > 0) {
        _go(_idx - 1);
      } else {
        widget.onPrevChapter?.call();
      }
    }
  }

  @override
  Widget build(BuildContext c) {
    final n = _last + 1;
    if (widget.mode == 'none') return _page(_idx); // 无动画: 直接换页

    final style = widget.mode == 'cover'
        ? PageTurnStyle.cover
        : widget.mode == 'slide'
            ? PageTurnStyle.slide
            : PageTurnStyle.curl; // sim / 其余 → 纸张卷曲

    // 背面取同色系略深/略浅一档，看起来才像同一张纸翻过来
    final back = shadeOf(widget.bg,
        widget.bg.computeLuminance() > 0.5 ? -0.09 : 0.10);

    return PageCurlView(
      style: style,
      bgColor: widget.bg,
      backColor: back,
      current: _page(_idx),
      previous: _idx > 0 ? _page(_idx - 1) : null,
      next: _idx < n - 1 ? _page(_idx + 1) : null,
      // ★ 翻页动画 completion 后才回写索引
      onTurn: (fwd) => _go(_idx + (fwd ? 1 : -1)),
    );
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
