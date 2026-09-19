// ═══════════════════════════════════════════════════════════════════════════
// 实验室三件套: 聊天 / 社区 / 论坛 —— 此前都是「敬请期待」空页, 这里全部做实
//
// · 聊天: 真·局域网聊天。UDP 广播做设备发现 + 消息投递, 不经过任何服务器,
//         同一 WiFi/热点下的设备能互相看到并对话(需要的只是系统允许 UDP 广播)。
// · 社区: 规则/源/心得分享板(本地优先)。发帖 · 标签 · 搜索 · 导出 JSON · 导入合并。
//         它承担"我在别的站看到一条好规则, 存下来给引擎用"的真实需求。
// · 论坛: 板块 → 主题 → 回帖 的三层讨论板, 本地持久化, 可导出/导入。
//
// 三者都不含任何内置内容源, 数据全部是本机产生、本机存储。
// ═══════════════════════════════════════════════════════════════════════════
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'lab_logic.dart';

// ═══════════════════════════════════════════════════════════════════════════
// A. 局域网聊天
//
// kLanPort / lanEncode / lanDecode / LanPeer / prunePeers / LanMessage
// 都在 lab_logic.dart(唯一实现)。这里只保留真正需要 socket 的 LanChat。
// ═══════════════════════════════════════════════════════════════════════════

/// 局域网聊天引擎: 广播发现 + 群发/单发消息
class LanChat {
  static final LanChat instance = LanChat._();
  LanChat._();

  RawDatagramSocket? _sock;
  Timer? _beat;
  String id = '';
  String name = '我';
  bool running = false;
  String lastError = '';
  final List<LanPeer> peers = [];
  final List<LanMessage> messages = [];
  final ValueNotifier<int> tick = ValueNotifier(0);

  static const String _kName = 'lan_chat_name';
  static const String _kId = 'lan_chat_id';
  static const String _kMsgs = 'lan_chat_msgs';

  Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    name = p.getString(_kName) ?? '';
    id = p.getString(_kId) ?? '';
    if (id.isEmpty) {
      id = 'dev-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
      await p.setString(_kId, id);
    }
    if (name.isEmpty) name = '设备${id.substring(id.length - 4)}';
    try {
      messages.addAll([for (final e in (jsonDecode(p.getString(_kMsgs) ?? '[]') as List))
        LanMessage.from(Map<String, dynamic>.from(e))]);
    } catch (_) { messages.clear(); }
    tick.value++;
  }

  Future<void> setName(String n) async {
    name = n.trim().isEmpty ? name : n.trim();
    await (await SharedPreferences.getInstance()).setString(_kName, name);
    tick.value++;
  }

  Future<void> _saveMsgs() async {
    final tail = messages.length > 200 ? messages.sublist(messages.length - 200) : messages;
    await (await SharedPreferences.getInstance())
      .setString(_kMsgs, jsonEncode([for (final m in tail) m.toJson()]));
  }

  Future<void> start() async {
    if (running) return;
    try {
      _sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, kLanPort, reuseAddress: true);
      _sock!.broadcastEnabled = true;
      _sock!.listen(_onEvent, onError: (e) { lastError = '$e'; tick.value++; });
      running = true;
      lastError = '';
      _announce();
      _beat = Timer.periodic(const Duration(seconds: 5), (_) {
        _announce();
        final before = peers.length;
        peers.removeWhere((p) => p.stale);
        if (peers.length != before) tick.value++;
      });
    } catch (e) {
      running = false;
      lastError = '无法绑定 UDP 端口 $kLanPort: $e';
    }
    tick.value++;
  }

  void stop() {
    _beat?.cancel(); _beat = null;
    try { _sock?.close(); } catch (_) {}
    _sock = null; running = false; tick.value++;
  }

  void _announce() => _send({'t': 'hi', 'id': id, 'name': name});

  void _send(Map<String, dynamic> m, {String? toHost}) {
    final s = _sock;
    if (s == null) return;
    try {
      final data = utf8.encode(lanEncode(m));
      if (toHost == null) {
        s.send(data, InternetAddress('255.255.255.255'), kLanPort);
      } else {
        s.send(data, InternetAddress(toHost), kLanPort);
      }
    } catch (e) { lastError = '$e'; tick.value++; }
  }

  void _onEvent(RawSocketEvent e) {
    if (e != RawSocketEvent.read) return;
    final dg = _sock?.receive();
    if (dg == null) return;
    final m = lanDecode(utf8.decode(dg.data, allowMalformed: true));
    if (m == null) return;
    final fromId = '${m['id'] ?? dg.address.address}';
    if (fromId == id) return; // 自己的广播
    final host = dg.address.address;
    // 设备表
    final i = peers.indexWhere((p) => p.id == fromId);
    if (i >= 0) { peers[i].seen = DateTime.now(); peers[i].name = '${m['name'] ?? peers[i].name}'; }
    else { peers.add(LanPeer(id: fromId, name: '${m['name'] ?? '设备'}', host: host)); }
    // 收到别人打招呼 → 回一个, 加速互相发现
    if (m['t'] == 'hi') { _send({'t': 'hi', 'id': id, 'name': name}, toHost: host); }
    if (m['t'] == 'msg') {
      messages.add(LanMessage(from: fromId, name: '${m['name'] ?? '对方'}',
        text: '${m['text'] ?? ''}', mine: false, toAll: m['toAll'] != false));
      _saveMsgs();
    }
    tick.value++;
  }

  /// 群发(局域网内所有 ThirdHub 设备)
  void sendAll(String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    _send({'t': 'msg', 'id': id, 'name': name, 'text': t, 'toAll': true});
    messages.add(LanMessage(from: id, name: name, text: t, mine: true, toAll: true));
    _saveMsgs(); tick.value++;
  }

  /// 单发(点某个设备私聊) —— 同端口, 对端凭 id 区分
  void sendTo(LanPeer p, String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    _send({'t': 'msg', 'id': id, 'name': name, 'text': t, 'toAll': false, 'to': p.id}, toHost: p.host);
    messages.add(LanMessage(from: id, name: name, text: '$t  (→ ${p.name})', mine: true, toAll: false));
    _saveMsgs(); tick.value++;
  }

  Future<void> clear() async {
    messages.clear();
    await _saveMsgs();
    tick.value++;
  }
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});
  @override State<ChatPage> createState() => _ChatState();
}

class _ChatState extends State<ChatPage> {
  final _ctl = TextEditingController();
  bool _ready = false;
  LanPeer? _target;

  @override void initState() {
    super.initState();
    LanChat.instance.init().then((_) async {
      await LanChat.instance.start();
      if (mounted) setState(() => _ready = true);
    });
  }

  @override void dispose() { _ctl.dispose(); super.dispose(); }

  @override Widget build(BuildContext c) {
    if (!_ready) return const Center(child: CircularProgressIndicator());
    final L = LanChat.instance;
    return ValueListenableBuilder<int>(
      valueListenable: L.tick,
      builder: (c, _, __) => Column(children: [
        Card(margin: const EdgeInsets.fromLTRB(12, 12, 12, 6), child: Padding(padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.wifi_tethering, size: 18, color: L.running ? Colors.green : Colors.grey),
              const SizedBox(width: 8),
              Expanded(child: Text(L.running ? '局域网广播已开启 · 端口 $kLanPort' : '未开启', style: const TextStyle(fontSize: 12))),
              Text('我是 ${L.name}', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
            ]),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 6, children: [
              ActionChip(
                avatar: const Icon(Icons.badge_outlined, size: 16),
                label: const Text('改昵称', style: TextStyle(fontSize: 12)),
                onPressed: () => _editName(c)),
              if (!L.running) ActionChip(
                avatar: const Icon(Icons.play_arrow, size: 16), label: const Text('开启', style: TextStyle(fontSize: 12)),
                onPressed: () async { await L.start(); })
              else ActionChip(
                avatar: const Icon(Icons.stop, size: 16), label: const Text('关闭', style: TextStyle(fontSize: 12)),
                onPressed: () => L.stop()),
              ActionChip(
                avatar: const Icon(Icons.cleaning_services_outlined, size: 16),
                label: const Text('清空记录', style: TextStyle(fontSize: 12)),
                onPressed: () => L.clear()),
            ]),
            if (L.lastError.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6),
              child: Text(L.lastError, style: const TextStyle(fontSize: 11, color: Colors.red))),
            Padding(padding: const EdgeInsets.only(top: 6), child: Text(
              '同一 WiFi/热点下的 ThirdHub 会自动互相发现(每 5 秒广播一次)。不经过任何服务器, 也看不到局域网外的设备。',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600, height: 1.5))),
            const SizedBox(height: 8),
            Text('在线设备 ${L.peers.length}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            if (L.peers.isEmpty) Padding(padding: const EdgeInsets.only(top: 4),
              child: Text('还没有发现其他设备。让另一台设备也打开这个页面。',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600)))
            else Wrap(spacing: 6, runSpacing: 6, children: [
              for (final p in L.peers)
                ChoiceChip(
                  selected: _target?.id == p.id,
                  label: Text(p.name, style: const TextStyle(fontSize: 12)),
                  avatar: const Icon(Icons.smartphone, size: 15),
                  onSelected: (v) => setState(() => _target = v ? p : null)),
            ]),
            Padding(padding: const EdgeInsets.only(top: 6), child: Text(
              _target == null ? '当前: 群发到所有设备' : '当前: 只发给 ${_target!.name}(再点一次取消私聊)',
              style: TextStyle(fontSize: 11, color: _target == null ? Colors.grey.shade600 : Colors.blue))),
          ]))),
        Expanded(child: L.messages.isEmpty
          ? Center(child: Text('还没有消息', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)))
          : ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: L.messages.length,
              itemBuilder: (c, i) {
                final m = L.messages[i];
                final mine = m.mine;
                return Align(alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 3),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    constraints: BoxConstraints(maxWidth: MediaQuery.of(c).size.width * 0.72),
                    decoration: BoxDecoration(
                      color: mine ? Theme.of(c).colorScheme.primary.withValues(alpha: 0.14) : Theme.of(c).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12)),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      if (!mine) Text(m.name, style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
                      Text(m.text, style: const TextStyle(fontSize: 13)),
                      Text('${m.ts.hour.toString().padLeft(2, '0')}:${m.ts.minute.toString().padLeft(2, '0')}',
                        style: TextStyle(fontSize: 9, color: Colors.grey.shade500)),
                    ]),
                  ));
              })),
        SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(12, 6, 12, 10), child: Row(children: [
          Expanded(child: TextField(controller: _ctl, minLines: 1, maxLines: 4,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(hintText: '说点什么…', isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10))))),
          const SizedBox(width: 8),
          IconButton.filled(
            onPressed: () {
              final t = _ctl.text;
              if (t.trim().isEmpty) return;
              final target = _target;
              if (target == null) { L.sendAll(t); } else { L.sendTo(target, t); }
              _ctl.clear();
            },
            icon: const Icon(Icons.send)),
        ]))),
      ]));
  }

  Future<void> _editName(BuildContext c) async {
    final ctl = TextEditingController(text: LanChat.instance.name);
    final r = await showDialog<String>(context: c, builder: (d) => AlertDialog(
      title: const Text('设备昵称'),
      content: TextField(controller: ctl, autofocus: true, decoration: const InputDecoration(hintText: '例如: 客厅平板')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('取消')),
        TextButton(onPressed: () => Navigator.pop(d, ctl.text), child: const Text('保存')),
      ]));
    final v = r;
    ctl.dispose();
    if (v != null) await LanChat.instance.setName(v);
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// B. 社区 —— 规则/源/心得分享板(本地优先)
//
// CommunityPost / mergePosts / kPostKinds 都在 lab_logic.dart(唯一实现)。
// ═══════════════════════════════════════════════════════════════════════════

class CommunityStore {
  static const String key = 'community_posts';
  static final List<CommunityPost> posts = [];
  static bool loaded = false;

  static Future<void> load() async {
    if (loaded) return;
    loaded = true;
    final p = await SharedPreferences.getInstance();
    try {
      posts.addAll([for (final e in (jsonDecode(p.getString(key) ?? '[]') as List))
        CommunityPost.from(Map<String, dynamic>.from(e))]);
    } catch (_) { posts.clear(); }
  }

  static Future<void> _save() async {
    await (await SharedPreferences.getInstance())
      .setString(key, jsonEncode([for (final p in posts) p.toJson()]));
  }

  static Future<void> add(CommunityPost p) async { posts.insert(0, p); await _save(); }
  static Future<void> update(CommunityPost p) async {
    final i = posts.indexWhere((e) => e.id == p.id);
    if (i >= 0) { posts[i] = p; await _save(); }
  }
  static Future<void> remove(String id) async { posts.removeWhere((e) => e.id == id); await _save(); }
  static Future<void> like(String id) async {
    for (final p in posts) { if (p.id == id) { p.likes++; } }
    await _save();
  }
  /// 导入一段 JSON 文本(数组或单对象), 返回新增条数
  static Future<int> importJson(String text) async {
    final j = jsonDecode(text);
    final list = j is List ? j : [j];
    final incoming = [for (final e in list) CommunityPost.from(Map<String, dynamic>.from(e as Map))];
    final add = mergePosts(posts, incoming);
    posts.addAll(add);
    await _save();
    return add.length;
  }
  static String exportJson() => const JsonEncoder.withIndent('  ')
    .convert({'app': 'thirdhub', 'kind': 'community', 'exportedAt': DateTime.now().toIso8601String(),
      'posts': [for (final p in posts) p.toJson()]});
}

class CommunityPage extends StatefulWidget {
  const CommunityPage({super.key});
  @override State<CommunityPage> createState() => _CommunityState();
}

class _CommunityState extends State<CommunityPage> {
  bool _ready = false;
  String _q = '';
  String _kind = '全部';
  static const kinds = kPostKinds;

  @override void initState() {
    super.initState();
    CommunityStore.load().then((_) { if (mounted) setState(() => _ready = true); });
  }

  List<CommunityPost> get _shown => [
    for (final p in CommunityStore.posts)
      if ((_kind == '全部' || p.kind == _kind) &&
          (_q.isEmpty || p.title.contains(_q) || p.body.contains(_q) || p.tags.any((t) => t.contains(_q)))) p
  ];

  @override Widget build(BuildContext c) {
    if (!_ready) return const Center(child: CircularProgressIndicator());
    final shown = _shown;
    // 顶层模块页直接嵌在 RootNav 的 PageView 里(外层已有 Scaffold), 这里不再自带 Scaffold
    return ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 90), children: [
        Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('规则/源/心得 分享板', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('把你在别处看到的好规则、好源配置、踩坑经验存下来。存的是本机, 导出成 JSON 就能带走或分享给家人。',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600, height: 1.5)),
          const SizedBox(height: 8),
          TextField(onChanged: (v) => setState(() => _q = v.trim()), style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(hintText: '搜索标题 / 正文 / 标签', isDense: true, prefixIcon: Icon(Icons.search, size: 18),
              border: OutlineInputBorder())),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final k in kinds)
              ChoiceChip(selected: _kind == k, label: Text(k, style: const TextStyle(fontSize: 11)),
                onSelected: (_) => setState(() => _kind = k)),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            FilledButton.icon(onPressed: () => _edit(c, null), icon: const Icon(Icons.add, size: 18), label: const Text('发帖')),
            const SizedBox(width: 8),
            TextButton.icon(onPressed: () => _export(c), icon: const Icon(Icons.ios_share, size: 16), label: const Text('导出')),
            TextButton.icon(onPressed: () => _import(c), icon: const Icon(Icons.download, size: 16), label: const Text('导入')),
          ]),
        ]))),
        const SizedBox(height: 8),
        if (shown.isEmpty) Card(child: Padding(padding: const EdgeInsets.symmetric(vertical: 30),
          child: Center(child: Text('这里还没有内容', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)))))
        else for (final p in shown) Card(margin: const EdgeInsets.only(bottom: 8), child: Padding(
          padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(color: Theme.of(c).colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6)),
                child: Text(p.kind, style: TextStyle(fontSize: 10, color: Theme.of(c).colorScheme.primary))),
              const SizedBox(width: 8),
              Expanded(child: Text(p.title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600))),
            ]),
            if (p.body.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6),
              child: SelectableText(p.body, maxLines: 6, style: const TextStyle(fontSize: 12, height: 1.5))),
            if (p.tags.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6),
              child: Wrap(spacing: 5, runSpacing: 5, children: [
                for (final t in p.tags) Text('#$t', style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
              ])),
            const SizedBox(height: 4),
            Row(children: [
              IconButton(onPressed: () => setState(() => CommunityStore.like(p.id)),
                icon: const Icon(Icons.thumb_up_alt_outlined, size: 16), tooltip: '有用'),
              Text('${p.likes}', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
              const Spacer(),
              IconButton(onPressed: () { Clipboard.setData(ClipboardData(text: p.body)); _toast(c, '正文已复制'); },
                icon: const Icon(Icons.copy, size: 16), tooltip: '复制正文'),
              IconButton(onPressed: () => _edit(c, p), icon: const Icon(Icons.edit_outlined, size: 16)),
              IconButton(onPressed: () async { await CommunityStore.remove(p.id); setState(() {}); },
                icon: const Icon(Icons.delete_outline, size: 16)),
            ]),
          ]))),
      ]);
  }

  void _toast(BuildContext c, String m) => ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _edit(BuildContext c, CommunityPost? p) async {
    final t = TextEditingController(text: p?.title ?? '');
    final b = TextEditingController(text: p?.body ?? '');
    final g = TextEditingController(text: p?.tags.join(' ') ?? '');
    var kind = p?.kind ?? '规则';
    final ok = await showDialog<bool>(context: c, builder: (d) => StatefulBuilder(
      builder: (d, set) => AlertDialog(
        title: Text(p == null ? '发布到分享板' : '编辑'),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Wrap(spacing: 6, children: [
            for (final k in kinds) if (k != '全部')
              ChoiceChip(selected: kind == k, label: Text(k, style: const TextStyle(fontSize: 11)),
                onSelected: (_) => set(() => kind = k)),
          ]),
          const SizedBox(height: 8),
          TextField(controller: t, decoration: const InputDecoration(labelText: '标题', isDense: true)),
          const SizedBox(height: 8),
          TextField(controller: b, minLines: 4, maxLines: 10,
            decoration: const InputDecoration(labelText: '正文 / 规则内容 / 链接', isDense: true, border: OutlineInputBorder())),
          const SizedBox(height: 8),
          TextField(controller: g, decoration: const InputDecoration(labelText: '标签(空格分隔)', isDense: true)),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('保存')),
        ])));
    final title = t.text.trim(), body = b.text, tags = [for (final s in g.text.split(RegExp(r'\s+'))) if (s.isNotEmpty) s];
    t.dispose(); b.dispose(); g.dispose();
    if (ok != true) return;
    if (title.isEmpty) { _toast(c, '标题不能为空'); return; }
    if (p == null) {
      await CommunityStore.add(CommunityPost(
        id: 'p-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
        title: title, body: body, kind: kind, tags: tags, ts: DateTime.now().millisecondsSinceEpoch));
    } else {
      await CommunityStore.update(CommunityPost(id: p.id, title: title, body: body,
        kind: kind, tags: tags, ts: p.ts, likes: p.likes));
    }
    setState(() {});
  }

  Future<void> _export(BuildContext c) async {
    final json = CommunityStore.exportJson();
    await Clipboard.setData(ClipboardData(text: json));
    _toast(c, '已复制导出内容(${CommunityStore.posts.length} 帖)到剪贴板');
    await showDialog<void>(context: c, builder: (d) => AlertDialog(
      title: const Text('导出完成'),
      content: SingleChildScrollView(child: SelectableText(json, style: const TextStyle(fontSize: 11, fontFamily: 'monospace'))),
      actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('好'))]));
  }

  Future<void> _import(BuildContext c) async {
    final ctl = TextEditingController();
    final ok = await showDialog<bool>(context: c, builder: (d) => AlertDialog(
      title: const Text('导入分享内容'),
      content: TextField(controller: ctl, minLines: 5, maxLines: 12,
        decoration: const InputDecoration(hintText: '把导出的 JSON 粘在这里', isDense: true, border: OutlineInputBorder())),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')),
        TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('导入')),
      ]));
    final text = ctl.text;
    ctl.dispose();
    if (ok != true) return;
    try {
      final n = await CommunityStore.importJson(text);
      setState(() {});
      _toast(c, n == 0 ? '没有新内容(全部已存在)' : '新增 $n 帖');
    } catch (e) { _toast(c, 'JSON 解析失败: $e'); }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// C. 论坛 —— 板块 / 主题 / 回帖 三层讨论板
//
// ForumReply / ForumTopic / mergeTopics / kForumBoards 都在 lab_logic.dart(唯一实现)。
// ═══════════════════════════════════════════════════════════════════════════

class ForumStore {
  static const String key = 'forum_topics';
  static const List<String> boards = kForumBoards;
  static final List<ForumTopic> topics = [];
  static bool loaded = false;

  static Future<void> load() async {
    if (loaded) return;
    loaded = true;
    final p = await SharedPreferences.getInstance();
    try {
      topics.addAll([for (final e in (jsonDecode(p.getString(key) ?? '[]') as List))
        ForumTopic.from(Map<String, dynamic>.from(e))]);
    } catch (_) { topics.clear(); }
  }

  static Future<void> _save() async {
    await (await SharedPreferences.getInstance())
      .setString(key, jsonEncode([for (final t in topics) t.toJson()]));
  }

  static Future<void> add(ForumTopic t) async { topics.insert(0, t); await _save(); }
  static Future<void> remove(String id) async { topics.removeWhere((e) => e.id == id); await _save(); }
  static Future<void> reply(String id, ForumReply r) async {
    for (final t in topics) { if (t.id == id) { t.replies.add(r); } }
    await _save();
  }
  static int countIn(String board) => topics.where((t) => t.board == board).length;
  static String exportJson() => const JsonEncoder.withIndent('  ')
    .convert({'app': 'thirdhub', 'kind': 'forum', 'exportedAt': DateTime.now().toIso8601String(),
      'topics': [for (final t in topics) t.toJson()]});
  static Future<int> importJson(String text) async {
    final j = jsonDecode(text);
    final list = j is Map && j['topics'] is List ? j['topics'] as List : (j is List ? j : [j]);
    final incoming = [for (final e in list) ForumTopic.from(Map<String, dynamic>.from(e as Map))];
    final add = mergeTopics(topics, incoming);
    topics.addAll(add);
    await _save();
    return add.length;
  }
}

class ForumPage extends StatefulWidget {
  const ForumPage({super.key});
  @override State<ForumPage> createState() => _ForumState();
}

class _ForumState extends State<ForumPage> {
  bool _ready = false;
  String _board = '综合';

  @override void initState() {
    super.initState();
    ForumStore.load().then((_) { if (mounted) setState(() => _ready = true); });
  }

  @override Widget build(BuildContext c) {
    if (!_ready) return const Center(child: CircularProgressIndicator());
    final shown = [for (final t in ForumStore.topics) if (t.board == _board) t];
    // 顶层模块页不自带 Scaffold(由 RootNav 提供), 主题详情页 ForumTopicPage 才需要
    return ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 90), children: [
        Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('论坛', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('按板块组织的长文讨论区(和「社区」的分工: 社区放短平快的规则与链接, 论坛放需要来回讨论的主题)。',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600, height: 1.5)),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final b in ForumStore.boards)
              ChoiceChip(selected: _board == b, onSelected: (_) => setState(() => _board = b),
                label: Text('$b (${ForumStore.countIn(b)})', style: const TextStyle(fontSize: 11))),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            FilledButton.icon(onPressed: () => _compose(c), icon: const Icon(Icons.edit, size: 18), label: const Text('发主题')),
            const SizedBox(width: 8),
            TextButton.icon(onPressed: () => _transfer(c), icon: const Icon(Icons.swap_vert, size: 16), label: const Text('导入/导出')),
          ]),
        ]))),
        const SizedBox(height: 8),
        if (shown.isEmpty) Card(child: Padding(padding: const EdgeInsets.symmetric(vertical: 30),
          child: Center(child: Text('「$_board」板块还没有主题', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)))))
        else for (final t in shown) Card(margin: const EdgeInsets.only(bottom: 8), child: ListTile(
          title: Text(t.title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          subtitle: Text('${t.replies.length} 回复 · ${_ago(t.ts)}${t.body.isNotEmpty ? '\n${t.body}' : ''}',
            maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
          isThreeLine: t.body.isNotEmpty,
          onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => ForumTopicPage(topicId: t.id)))
            .then((_) => setState(() {})),
          trailing: IconButton(onPressed: () async { await ForumStore.remove(t.id); setState(() {}); },
            icon: const Icon(Icons.delete_outline, size: 18)),
        )),
      ]);
  }

  String _ago(int ts) {
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ts));
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    if (d.inDays < 1) return '${d.inHours} 小时前';
    return '${d.inDays} 天前';
  }

  Future<void> _compose(BuildContext c) async {
    final t = TextEditingController();
    final b = TextEditingController();
    final ok = await showDialog<bool>(context: c, builder: (d) => AlertDialog(
      title: Text('在「$_board」发主题'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: t, decoration: const InputDecoration(labelText: '标题', isDense: true)),
        const SizedBox(height: 8),
        TextField(controller: b, minLines: 4, maxLines: 10,
          decoration: const InputDecoration(labelText: '正文', isDense: true, border: OutlineInputBorder())),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')),
        TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('发布')),
      ]));
    final title = t.text.trim(), body = b.text;
    t.dispose(); b.dispose();
    if (ok != true || title.isEmpty) return;
    await ForumStore.add(ForumTopic(
      id: 't-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
      board: _board, title: title, body: body, ts: DateTime.now().millisecondsSinceEpoch));
    setState(() {});
  }

  Future<void> _transfer(BuildContext c) async {
    final ctl = TextEditingController(text: ForumStore.exportJson());
    await showDialog<void>(context: c, builder: (d) => AlertDialog(
      title: const Text('导入 / 导出'),
      content: SizedBox(width: 460, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Align(alignment: Alignment.centerLeft, child: Text('下面是当前全部主题的 JSON, 可直接复制走。把它粘回来再点"导入"即可合并。',
          style: TextStyle(fontSize: 11, color: Colors.grey))),
        const SizedBox(height: 8),
        TextField(controller: ctl, minLines: 6, maxLines: 14, style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
          decoration: const InputDecoration(isDense: true, border: OutlineInputBorder())),
      ]))),
      actions: [
        TextButton(onPressed: () { Clipboard.setData(ClipboardData(text: ctl.text)); }, child: const Text('复制')),
        TextButton(onPressed: () async {
          try {
            final n = await ForumStore.importJson(ctl.text);
            if (d.mounted) Navigator.pop(d);
            setState(() {});
            if (mounted) ScaffoldMessenger.of(this.context).showSnackBar(SnackBar(content: Text('新增 $n 个主题')));
          } catch (e) {
            if (mounted) ScaffoldMessenger.of(this.context).showSnackBar(SnackBar(content: Text('解析失败: $e')));
          }
        }, child: const Text('导入')),
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('关闭')),
      ]));
    ctl.dispose();
  }
}

class ForumTopicPage extends StatefulWidget {
  final String topicId;
  const ForumTopicPage({super.key, required this.topicId});
  @override State<ForumTopicPage> createState() => _ForumTopicState();
}

class _ForumTopicState extends State<ForumTopicPage> {
  final _ctl = TextEditingController();

  @override void dispose() { _ctl.dispose(); super.dispose(); }

  @override Widget build(BuildContext c) {
    ForumTopic? t;
    for (final e in ForumStore.topics) { if (e.id == widget.topicId) t = e; }
    if (t == null) return Scaffold(appBar: AppBar(title: const Text('主题')), body: const Center(child: Text('主题已被删除')));
    final topic = t;
    return Scaffold(
      appBar: AppBar(title: Text(topic.title)),
      body: Column(children: [
        Expanded(child: ListView(padding: const EdgeInsets.all(12), children: [
          Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Chip(label: Text(topic.board, style: const TextStyle(fontSize: 10)), visualDensity: VisualDensity.compact),
              const Spacer(),
              Text(DateTime.fromMillisecondsSinceEpoch(topic.ts).toString().split('.').first,
                style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
            ]),
            const SizedBox(height: 6),
            SelectableText(topic.body.isEmpty ? '(无正文)' : topic.body, style: const TextStyle(fontSize: 13, height: 1.6)),
          ]))),
          const SizedBox(height: 8),
          Text('${topic.replies.length} 条回复', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          for (final r in topic.replies) Card(margin: const EdgeInsets.only(bottom: 6), child: Padding(
            padding: const EdgeInsets.all(10), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(r.by, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                const SizedBox(width: 8),
                Text('${r.ts}', style: TextStyle(fontSize: 9, color: Colors.grey.shade500)),
              ]),
              const SizedBox(height: 4),
              SelectableText(r.text, style: const TextStyle(fontSize: 12, height: 1.5)),
            ]))),
        ])),
        SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(12, 4, 12, 10), child: Row(children: [
          Expanded(child: TextField(controller: _ctl, style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(hintText: '回复…', isDense: true, border: OutlineInputBorder()))),
          const SizedBox(width: 8),
          IconButton.filled(onPressed: () async {
            final text = _ctl.text.trim();
            if (text.isEmpty) return;
            await ForumStore.reply(topic.id, ForumReply(by: '我', text: text, ts: DateTime.now().millisecondsSinceEpoch));
            _ctl.clear();
            if (mounted) setState(() {});
          }, icon: const Icon(Icons.send)),
        ]))),
      ]),
    );
  }
}
