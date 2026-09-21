// ThirdHub v4.40.0 · B 组 浏览器增强(PLAN-v3 §3.3)
//   B-2 网页翻译(调 AI) · B-4 长截图→相册 · B-5 书签云同步
//   B-7 UA 记忆 · B-8 边缘手势前进后退 · B-9 夜间模式注入
//
// 设计: 浏览器主体(core/browser_page.dart)只暴露一组回调(Host),
// 全部逻辑与 UI 都收在本文件, 避免把 400 行的页面再撑大。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart' as pm;

import 'pro_kit.dart';

class BrowserPro {
  // ═══ B-2 网页翻译 ═══
  // 分段送 AI(每段 1500 字), 避免超长上下文被截断; 段间保持空行边界。
  static List<String> chunk(String text, [int size = 1500]) {
    final out = <String>[];
    var buf = StringBuffer();
    for (final para in text.split('\n')) {
      if (buf.length + para.length > size && buf.isNotEmpty) {
        out.add(buf.toString());
        buf = StringBuffer();
      }
      buf.writeln(para);
    }
    if (buf.isNotEmpty) out.add(buf.toString());
    return out;
  }

  /// 返回译文; 出错抛异常由页面层提示。
  static Future<String> translate(String text,
      {String to = '简体中文', void Function(int done, int total)? onStep}) async {
    final parts = chunk(text);
    final sb = StringBuffer();
    for (var i = 0; i < parts.length; i++) {
      onStep?.call(i, parts.length);
      final r = await ProAi.ask(
        '把下面的网页正文翻译成$to。只输出译文, 保留段落换行, 不要解释、不要加引号:\n\n${parts[i]}',
        system: '你是网页翻译引擎。忠实翻译, 保留原文的段落结构与专有名词。',
      );
      sb.writeln(r.trim());
      if (parts.length > 1) sb.writeln();
    }
    return sb.toString().trim();
  }

  // ═══ B-4 长截图 → 系统相册 ═══
  static Future<String> savePng(Uint8List bytes, String name) async {
    try {
      final perm = await pm.PhotoManager.requestPermissionExtend();
      if (!perm.isAuth) return '没有相册权限, 请到系统设置里允许访问照片';
      final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|\s]'), '_');
      await pm.PhotoManager.editor
          .saveImage(bytes, filename: '$safe.png', title: safe);
      return '';
    } catch (e) {
      return '保存失败: $e';
    }
  }

  // ═══ B-5 书签云同步 ═══
  static Future<int> pushBookmarks(List<Map<String, String>> list) async {
    final r = await ProKit.postJson('/v1/bookmarks', {'list': list});
    return (r['ok'] == true) ? list.length : 0;
  }

  static Future<List<Map<String, String>>> pullBookmarks() async {
    final r = await ProKit.getJson('/v1/bookmarks');
    final d = r['data'];
    final raw = (d is Map) ? d['list'] : d;
    if (raw is! List) return [];
    return [for (final e in raw) Map<String, String>.from(e as Map)];
  }

  /// 以 url 为键做并集合并(本地在前, 云端补缺)
  static List<Map<String, String>> mergeBookmarks(
      List<Map<String, String>> local, List<Map<String, String>> remote) {
    final out = <Map<String, String>>[];
    final seen = <String>{};
    for (final e in [...local, ...remote]) {
      final u = e['url'] ?? '';
      if (u.isEmpty || seen.contains(u)) continue;
      seen.add(u);
      out.add(e);
    }
    return out;
  }

  // ═══ B-7 UA 记忆 ═══
  static const uaPresets = <(String, String)>[
    ('默认(跟随系统)', ''),
    ('桌面 Chrome',
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0 Safari/537.36'),
    ('桌面 Safari',
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15'),
    ('Android Chrome',
        'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0 Mobile Safari/537.36'),
    ('iPad',
        'Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1'),
  ];

  static Future<Map<String, String>> uaMap() => ProKit.mapOf('browser_ua_map');

  static String hostOf(String url) {
    try {
      return Uri.parse(url).host;
    } catch (_) {
      return '';
    }
  }

  static Future<String> uaFor(String url) async {
    if (url.isEmpty) return '';
    final m = await uaMap();
    return m[hostOf(url)] ?? '';
  }

  static Future<void> setUaFor(String url, String ua) async {
    final h = hostOf(url);
    if (h.isEmpty) return;
    final m = await uaMap();
    if (ua.isEmpty) {
      m.remove(h);
    } else {
      m[h] = ua;
    }
    await ProKit.saveMap('browser_ua_map', m);
  }

  // ═══ B-8 手势 ═══
  static Future<bool> gestureOn() async =>
      (await ProKit.prefs()).getBool('browser_gesture') ?? true;
  static Future<void> setGestureOn(bool v) async =>
      (await ProKit.prefs()).setBool('browser_gesture', v);

  // ═══ B-9 夜间模式 ═══
  static Future<bool> nightOn() async =>
      (await ProKit.prefs()).getBool('browser_night') ?? false;
  static Future<void> setNightOn(bool v) async =>
      (await ProKit.prefs()).setBool('browser_night', v);

  /// 注入式夜间: 整页反相 + 图片二次反相还原, 对任何站点都生效(不改站点本身)。
  static const jsNightOn = """(function(){
  if (document.getElementById('__th_night')) return;
  var s = document.createElement('style'); s.id = '__th_night';
  s.textContent = 'html{filter:invert(1) hue-rotate(180deg) !important;background:#111 !important;}'
    + 'img,video,canvas,svg,picture,[style*=\"background-image\"]{filter:invert(1) hue-rotate(180deg) !important;}';
  (document.head||document.documentElement).appendChild(s);
})();""";

  static const jsNightOff = """(function(){
  var s = document.getElementById('__th_night'); if (s) s.remove();
})();""";

  static String jsNight(bool on) => on ? jsNightOn : jsNightOff;

  /// 取整页高度(用于长截图分段)
  static const jsPageHeight =
      "Math.max(document.body?document.body.scrollHeight:0, document.documentElement?document.documentElement.scrollHeight:0)-window.innerHeight";
}

// ══════════════════════════════════════════════════════════════
// 浏览器主体提供的回调(Host): 页面不把 WebViewController 交出去,
// 只交出"能干什么", 逻辑仍留在本文件。
// ══════════════════════════════════════════════════════════════
class BrowserProHost {
  final String Function() url;
  final String Function() title;
  final Future<void> Function(String js) run;
  final Future<String> Function(String js) eval;
  final Future<Uint8List?> Function() shot;
  final Future<void> Function() reload;
  final Future<bool> Function() canBack;
  final Future<bool> Function() canForward;
  final Future<void> Function() goBack;
  final Future<void> Function() goForward;
  final Future<List<Map<String, String>>> Function() bookmarks;
  final Future<void> Function(List<Map<String, String>>) setBookmarks;
  final void Function(String msg) toast;
  final void Function() onChanged;

  const BrowserProHost({
    required this.url,
    required this.title,
    required this.run,
    required this.eval,
    required this.shot,
    required this.reload,
    required this.canBack,
    required this.canForward,
    required this.goBack,
    required this.goForward,
    required this.bookmarks,
    required this.setBookmarks,
    required this.toast,
    required this.onChanged,
  });
}

/// 打开「浏览器增强」面板
Future<void> showBrowserPro(BuildContext context, BrowserProHost host) async {
  bool night = await BrowserPro.nightOn();
  bool gesture = await BrowserPro.gestureOn();
  final ua = await BrowserPro.uaFor(host.url());
  if (!context.mounted) return;

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (c2) => StatefulBuilder(
      builder: (c2, setD) => SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 20),
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6),
              child: Text('浏览器增强',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 6),
            ProUI.card('B-2 网页翻译', [
              ProUI.row(Icons.translate, '提取正文并翻译',
                  sub: '调 AI 分段翻译, 结果可交给小说阅读器', onTap: () async {
                Navigator.pop(c2);
                await runTranslateFlow(context, host);
              }),
            ]),
            ProUI.card('B-4 长截图', [
              ProUI.row(Icons.photo_size_select_large, '整页分段截图 → 相册',
                  sub: '自动滚屏分段, 各段按顺序存入系统相册', onTap: () async {
                Navigator.pop(c2);
                await runLongShotFlow(context, host);
              }),
            ]),
            ProUI.card('B-5 书签云同步', [
              ProUI.row(Icons.cloud_upload_outlined, '上传本机书签',
                  onTap: () async {
                final n = await BrowserPro.pushBookmarks(await host.bookmarks());
                Navigator.pop(c2);
                host.toast(n > 0 ? '已上传 $n 条书签' : '未连接后端, 暂只存在本机');
              }),
              ProUI.row(Icons.cloud_download_outlined, '拉回并合并云端书签',
                  sub: '按网址去重, 本地在前', onTap: () async {
                final remote = await BrowserPro.pullBookmarks();
                if (remote.isEmpty) {
                  Navigator.pop(c2);
                  host.toast('云端没有书签或后端未连接');
                  return;
                }
                final local = await host.bookmarks();
                final m = BrowserPro.mergeBookmarks(local, remote);
                await host.setBookmarks(m);
                host.onChanged();
                Navigator.pop(c2);
                host.toast('已合并, 共 ${m.length} 条');
              }),
            ]),
            ProUI.card('B-7 本机标识 (UA) 记忆', [
              for (final p in BrowserPro.uaPresets)
                ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  leading: Icon(
                      ua == p.$2 ? Icons.radio_button_checked : Icons.radio_button_off,
                      size: 18,
                      color: ua == p.$2 ? Theme.of(c2).colorScheme.primary : Colors.grey),
                  title: Text(p.$1, style: const TextStyle(fontSize: 13.5)),
                  subtitle: p.$2.isEmpty
                      ? const Text('默认跟随系统',
                          style: TextStyle(fontSize: 11, color: Colors.grey))
                      : null,
                  onTap: () async {
                    await BrowserPro.setUaFor(host.url(), p.$2);
                    setD(() => ua = p.$2);
                    host.toast('已为 ${BrowserPro.hostOf(host.url())} 记住该标识, 刷新后生效');
                    await host.reload();
                  },
                ),
            ], sub: '按域名分别记忆, 桌面版网站不再乱版'),
            ProUI.card('B-8 / B-9 手势与夜间', [
              ProUI.sw('边缘滑动手势', gesture, (v) async {
                await BrowserPro.setGestureOn(v);
                setD(() => gesture = v);
                host.onChanged();
              }, sub: '从屏幕左/右边缘滑动 = 后退/前进', icon: Icons.swipe),
              ProUI.sw('夜间模式', night, (v) async {
                await BrowserPro.setNightOn(v);
                setD(() => night = v);
                await host.run(BrowserPro.jsNight(v));
              }, sub: '整页反相, 图片二次还原; 换页自动续用', icon: Icons.dark_mode_outlined),
            ]),
          ],
        ),
      ),
    ),
  );
}

Future<void> runTranslateFlow(BuildContext context, BrowserProHost host) async {
  final js = """
(() => {
  var art = document.querySelector('article') || document.querySelector('main');
  var best = art, bestLen = art ? (art.innerText || '').length : 0;
  if (bestLen < 400) {
    document.querySelectorAll('div,section').forEach(function(e){
      var tx = e.innerText || '';
      if (tx.length > bestLen && e.querySelectorAll('p').length >= 2) { best = e; bestLen = tx.length; }
    });
  }
  var text = ((best ? best.innerText : document.body.innerText) || '').trim();
  return JSON.stringify({ title: document.title || '', text: text.slice(0, 60000) });
})()""";
  String title = host.title();
  String text = '';
  try {
    var s = await host.eval(js);
    if (s.startsWith('"')) {
      try {
        s = jsonDecode(s) as String;
      } catch (_) {}
    }
    final j = jsonDecode(s) as Map;
    title = '${j['title'] ?? title}'.trim();
    text = '${j['text'] ?? ''}'.trim();
  } catch (e) {
    host.toast('正文提取失败: $e');
    return;
  }
  if (text.length < 120) {
    host.toast('这页提取不到成段正文, 无法翻译');
    return;
  }
  final ok = await ProKit.confirm(context, '翻译网页正文',
      '将提取 ${text.length} 字并分段送 AI 翻译。\n需要已在「AI → 厂商与密钥」里填好可用的 API Key。');
  if (!ok) return;
  if (!context.mounted) return;
  host.toast('翻译中…');
  try {
    final out = await BrowserPro.translate(text);
    if (!context.mounted) return;
    await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => TranslatedPage(title: title, source: text, result: out)));
    host.onChanged();
  } catch (e) {
    host.toast('翻译失败: $e');
  }
}

Future<void> runLongShotFlow(BuildContext context, BrowserProHost host) async {
  final title = host.title().isEmpty ? '网页截图' : host.title();
  final hRaw = await host.eval(BrowserPro.jsPageHeight);
  final rest = int.tryParse(hRaw.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
  final h = MediaQuery.of(context).size.height;
  final step = (h - 140).clamp(200, 2000).toDouble();
  final pages = (rest <= 0) ? 1 : ((rest / step).ceil() + 1).clamp(1, 10);
  host.toast('共 $pages 屏, 正在逐屏保存…');
  var saved = 0;
  final errs = <String>[];
  for (var i = 0; i < pages; i++) {
    if (i > 0) {
      await host.run('window.scrollTo(0, ${(step * i).round()});');
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
    final bytes = await host.shot();
    if (bytes == null) {
      errs.add('第 ${i + 1} 屏截取失败');
      continue;
    }
    final err = await BrowserPro.savePng(bytes, '${title}_${i + 1}');
    if (err.isEmpty) {
      saved++;
    } else {
      errs.add(err);
      break;
    }
  }
  await host.run('window.scrollTo(0, 0);');
  if (errs.isNotEmpty && saved == 0) {
    host.toast(errs.first);
  } else {
    host.toast('已保存 $saved 张到相册${errs.isEmpty ? '' : ' (${errs.first})'}');
  }
  host.onChanged();
}

/// 译文页: 可复制、可交给小说阅读器继续听书
class TranslatedPage extends StatelessWidget {
  final String title;
  final String source;
  final String result;
  const TranslatedPage(
      {super.key, required this.title, required this.source, required this.result});

  @override
  Widget build(BuildContext c) {
    return Scaffold(
      appBar: AppBar(
        title: Text('译文 · $title', style: const TextStyle(fontSize: 15)),
        actions: [
          IconButton(
            tooltip: '看原文',
            icon: const Icon(Icons.compare_arrows),
            onPressed: () => showDialog<void>(
              context: c,
              builder: (c2) => AlertDialog(
                title: const Text('原文'),
                content: SizedBox(
                    width: 460,
                    height: 380,
                    child: SingleChildScrollView(
                        child: SelectableText(source,
                            style: const TextStyle(fontSize: 12, height: 1.5)))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(c2), child: const Text('关闭')),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: '交给小说阅读器(可听书)',
            icon: const Icon(Icons.menu_book_outlined),
            onPressed: () => ProBrowserBridge.handToReader?.call(c, title, result),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(14),
        child: SelectableText(result, style: const TextStyle(fontSize: 14, height: 1.7)),
      ),
    );
  }
}

/// 与浏览器页/main.dart 的桥(避免本文件直接 import main.dart 造成循环依赖)
class ProBrowserBridge {
  static void Function(BuildContext c, String title, String text)? handToReader;
  static void Function(String apkUrl)? noop;
}
