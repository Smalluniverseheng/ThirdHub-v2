// ThirdHub v4.40.0 进阶功能公共设施
// 设计原则: 离线优先(本地 SharedPreferences 必可用), 有后端时自动落库;
// 与 main.dart 的 Api/AppSettings 解耦(只通过 prefs 的 'base'/'token' 读连接信息),
// 避免 core/ 与 main.dart 互相 import 造成的初始化顺序问题。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ai.dart';

/// 全批次共用的 AI 调用入口(网页翻译 / 摘要 / 语义提取 / 定时 Agent 都用它)。
class ProAi {
  static Future<bool> get ready async {
    try {
      await AiRegistry.init();
      final (pid, _) = await AiRegistry.lastModel();
      final p = AiRegistry.byId(pid);
      if (p == null) return false;
      return (await AiRegistry.keyOf(pid)).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// 一问一答(流式拼成整串)。未配置厂商时抛异常, 由调用方提示。
  static Future<String> ask(String prompt,
      {String system = '', String? providerId, String? model}) async {
    await AiRegistry.init();
    final (pid, lastModel) = await AiRegistry.lastModel();
    final p = AiRegistry.byId(providerId ?? pid);
    if (p == null) throw Exception('还没有可用的 AI 厂商, 先到「AI → 厂商与密钥」里配置');
    final key = await AiRegistry.keyOf(p.id);
    if (key.isEmpty) throw Exception('${p.name} 还没填 API Key');
    final sb = StringBuffer();
    await AiChat.chat(
      provider: p,
      model: model ?? lastModel,
      messages: [
        if (system.isNotEmpty) {'role': 'system', 'content': system},
        {'role': 'user', 'content': prompt},
      ],
      onDelta: (d) => sb.write(d),
    );
    return sb.toString().trim();
  }
}

/// 本批次(4.40.0)统一的本地存储 + 后端访问入口。
class ProKit {
  static const batch = 'v4.41.0';

  static Future<SharedPreferences> prefs() => SharedPreferences.getInstance();

  static String now() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${n.year}-${two(n.month)}-${two(n.day)} ${two(n.hour)}:${two(n.minute)}';
  }

  static String day(DateTime n) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${n.year}-${two(n.month)}-${two(n.day)}';
  }

  // ── 后端连接(与 Api 同源, 均读 prefs) ──
  static Future<String> base() async => (await prefs()).getString('base') ?? '';
  static Future<String> token() async => (await prefs()).getString('token') ?? '';
  static Future<bool> get online async => (await base()).isNotEmpty;
  static bool lastOnline = false;

  static http.Client _client() {
    final c = HttpClient()..badCertificateCallback = (_, __, ___) => true;
    return IOClient(c);
  }

  /// 统一请求: 返回 {object,data} 信封; 任何异常都返回 {'ok':false,'err':...} 不抛出。
  static Future<Map<String, dynamic>> req(String method, String path,
      {Object? body, Duration timeout = const Duration(seconds: 12)}) async {
    final b = await base();
    if (b.isEmpty) return {'ok': false, 'err': 'no-backend'};
    try {
      final h = {'X-TH-Token': await token(), 'Content-Type': 'application/json'};
      final uri = Uri.parse('$b$path');
      final r = method == 'GET'
          ? await _client().get(uri, headers: h)
          : await _client().post(uri, headers: h, body: body == null ? null : jsonEncode(body));
      final txt = utf8.decode(r.bodyBytes);
      // 二进制端点(blob/图片)不解析 JSON
      if (!txt.startsWith('{') && !txt.startsWith('[')) {
        lastOnline = r.statusCode < 400;
        return {'ok': r.statusCode < 400, 'raw': txt.length, 'status': r.statusCode};
      }
      final m = jsonDecode(txt) as Map<String, dynamic>;
      lastOnline = r.statusCode < 400;
      m['ok'] = r.statusCode < 400;
      return m;
    } catch (e) {
      lastOnline = false;
      return {'ok': false, 'err': '$e'};
    }
  }

  static Future<Map<String, dynamic>> getJson(String path) => req('GET', path);
  static Future<Map<String, dynamic>> postJson(String path, Object body) => req('POST', path, body: body);

  // ── 本地列表存储 ──
  static Future<List<Map<String, String>>> listOf(String key) async {
    try {
      final p = await prefs();
      final raw = jsonDecode(p.getString(key) ?? '[]') as List;
      return [for (final e in raw) Map<String, String>.from(e as Map)];
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveList(String key, List<Map<String, String>> v) async {
    final p = await prefs();
    await p.setString(key, jsonEncode(v));
  }

  /// 列表追加(最新在前), 按 [idKey] 去重, 超出 [max] 截断。
  static Future<List<Map<String, String>>> push(String key, Map<String, String> item,
      {String idKey = 'id', int max = 500}) async {
    final l = await listOf(key);
    if (item[idKey] != null && item[idKey]!.isNotEmpty) {
      l.removeWhere((e) => e[idKey] == item[idKey]);
    }
    l.insert(0, item);
    final out = l.take(max).toList();
    await saveList(key, out);
    return out;
  }

  static Future<Map<String, String>> mapOf(String key) async {
    try {
      final p = await prefs();
      final raw = jsonDecode(p.getString(key) ?? '{}') as Map;
      return Map<String, String>.from(raw);
    } catch (_) {
      return {};
    }
  }

  static Future<void> saveMap(String key, Map<String, String> v) async {
    final p = await prefs();
    await p.setString(key, jsonEncode(v));
  }

  static Future<int> count(String key) async => (await listOf(key)).length;

  /// 简单计数+1并保存
  static Future<int> bump(String key, [int by = 1]) async {
    final p = await prefs();
    final v = (p.getInt(key) ?? 0) + by;
    await p.setInt(key, v);
    return v;
  }

  /// 二次确认(破坏性操作的统一闸门)。
  static Future<bool> confirm(BuildContext c, String title, String msg,
      {String ok = '确定'}) async {
    final r = await showDialog<bool>(
      context: c,
      builder: (c2) => AlertDialog(
        title: Text(title),
        content: Text(msg, style: const TextStyle(fontSize: 13, height: 1.5)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(c2, true), child: Text(ok)),
        ],
      ),
    );
    return r ?? false;
  }

  static Future<String?> prompt(BuildContext c, String title,
      {String hint = '', String init = '', int lines = 1}) async {
    final cc = TextEditingController(text: init);
    final r = await showDialog<String>(
      context: c,
      builder: (c2) => AlertDialog(
        title: Text(title),
        content: TextField(
            controller: cc,
            autofocus: true,
            maxLines: lines,
            decoration: InputDecoration(hintText: hint)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c2), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(c2, cc.text), child: const Text('保存')),
        ],
      ),
    );
    return (r ?? '').trim().isEmpty ? null : r!.trim();
  }
}

/// 进阶页统一 UI 组件(与 STYLE_GUIDE 一致: 卡片大圆角、素色图标、禁用 emoji)。
class ProUI {
  static void toast(BuildContext c, String msg) {
    ScaffoldMessenger.of(c).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(milliseconds: 1600)));
  }

  static Widget card(String title, List<Widget> children,
      {String sub = '', Widget? trailing}) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (title.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
            child: Row(children: [
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(title,
                        style: const TextStyle(
                            fontSize: 13.5, fontWeight: FontWeight.w700)),
                    if (sub.isNotEmpty)
                      Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(sub,
                              style: const TextStyle(
                                  fontSize: 11.5, color: Colors.grey))),
                  ])),
              if (trailing != null) trailing,
            ]),
          ),
        ...children,
      ]),
    );
  }

  static Widget row(IconData icon, String title,
      {String value = '', String sub = '', VoidCallback? onTap, Widget? trailing}) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14),
      leading: Icon(icon, size: 20),
      title: Text(title,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
      subtitle: sub.isEmpty
          ? null
          : Text(sub, style: const TextStyle(fontSize: 11.5, color: Colors.grey)),
      trailing: trailing ??
          Row(mainAxisSize: MainAxisSize.min, children: [
            if (value.isNotEmpty)
              ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 130),
                  child: Text(value,
                      textAlign: TextAlign.right,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: Colors.grey))),
            if (onTap != null) ...[
              const SizedBox(width: 2),
              const Icon(Icons.chevron_right, size: 18, color: Colors.grey),
            ],
          ]),
      onTap: onTap,
    );
  }

  static Widget sw(String title, bool v, ValueChanged<bool> onChanged,
      {String sub = '', IconData icon = Icons.tune}) {
    return SwitchListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14),
      secondary: Icon(icon, size: 20),
      title: Text(title, style: const TextStyle(fontSize: 14)),
      subtitle: sub.isEmpty
          ? null
          : Text(sub, style: const TextStyle(fontSize: 11.5, color: Colors.grey)),
      value: v,
      onChanged: onChanged,
    );
  }

  static Widget note(String text, {IconData icon = Icons.info_outline}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 14, color: Colors.grey),
        const SizedBox(width: 6),
        Expanded(
            child: Text(text,
                style: const TextStyle(
                    fontSize: 11.5, color: Colors.grey, height: 1.45))),
      ]),
    );
  }

  static Widget progress(double v) => ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: LinearProgressIndicator(value: v.clamp(0, 1), minHeight: 5));

  /// 统一的空态
  static Widget empty(String text) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child:
              Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.inbox_outlined, size: 40, color: Colors.grey.shade400),
            const SizedBox(height: 10),
            Text(text,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Colors.grey)),
          ]),
        ),
      );

  static Widget chip(String text, {Color? color}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
            color: (color ?? Colors.blueGrey).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20)),
        child: Text(text,
            style: TextStyle(
                fontSize: 11,
                color: color ?? Colors.blueGrey,
                fontWeight: FontWeight.w600)),
      );
}

/// 通用「进阶功能页」外壳: 一个大列表 + 实时刷新。
abstract class ProPage extends StatefulWidget {
  const ProPage({super.key});
}

/// 供 ProPage 子类复用的状态基类(统一 loading/刷新/异步安全 setState)。
abstract class ProPageState<T extends ProPage> extends State<T> {
  bool loading = true;

  Future<void> load();

  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    try {
      await load();
    } catch (_) {}
    if (mounted) setState(() => loading = false);
  }

  void touch([VoidCallback? fn]) {
    if (!mounted) return;
    setState(() {
      if (fn != null) fn();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(titleText)),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: refresh,
              child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 30),
                  children: buildBody(context)),
            ),
    );
  }

  String get titleText;
  List<Widget> buildBody(BuildContext context);
}
