// 酒馆（Tavern）—— 角色卡 + AI 扮演对话。
//
// 为什么要做这个模块（2026-11-04）：
//   网页端早有 `js/modules/tavern.js`（角色卡 / 分组 / 导入导出 / 对话），
//   App 端一直没有 —— 两端功能不对齐的典型缺口。
//   这里按 App 的既有结构重写，**不追求与网页端逐行对应**，只保证能力等价：
//   角色卡增删改、导入 SillyTavern V2 角色卡、与角色对话（流式）、会话留存。
//
// 刻意没做的（避免半成品）：
//   · 角色卡导出的 PNG 隐写（网页端有）—— App 端要接图像编码，另开一轮更稳
//   · 角色分组 —— 角色少于 20 个时分组是负担，先用搜索
//
// 存储：SharedPreferences（`tavern_chars` / `tavern_chats`）。
//   不做云同步是**故意的**：角色卡里常含成人向设定，未经用户明确同意不该上云。
//   后续若要同步，走 th_shared kind='tavern_char' 并单独给开关。

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ai.dart';
import 'design_tokens.dart';

// ─────────────────────────── 数据模型 ───────────────────────────

/// 一张角色卡。字段名对齐 SillyTavern V2（`data.name` / `data.description` 等），
/// 这样导入别人分享的卡不用做字段翻译。
class TavernChar {
  TavernChar({
    required this.id,
    required this.name,
    this.description = '',
    this.firstMessage = '',
    this.systemPrompt = '',
    this.avatar = '',
    this.tags = const [],
    this.createdAt = 0,
  });

  final String id;
  String name;

  /// 角色设定（人设、世界观、说话方式都写这里）
  String description;

  /// 角色说的第一句话（开场白）
  String firstMessage;

  /// 附加的系统提示（可为空 —— 为空时由 [buildSystemPrompt] 自动拼）
  String systemPrompt;

  /// 头像：URL 或本地路径；空则用首字占位
  String avatar;

  List<String> tags;
  final int createdAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'firstMessage': firstMessage,
        'systemPrompt': systemPrompt,
        'avatar': avatar,
        'tags': tags,
        'createdAt': createdAt,
      };

  static TavernChar fromJson(Map<String, dynamic> j) => TavernChar(
        id: '${j['id'] ?? DateTime.now().microsecondsSinceEpoch}',
        name: '${j['name'] ?? '未命名角色'}',
        description: '${j['description'] ?? ''}',
        firstMessage: '${j['firstMessage'] ?? ''}',
        systemPrompt: '${j['systemPrompt'] ?? ''}',
        avatar: '${j['avatar'] ?? ''}',
        tags: (j['tags'] as List?)?.map((e) => '$e').toList() ?? const [],
        createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
      );

  /// 解析外来角色卡：同时支持 SillyTavern V2（`{spec, data:{...}}`）与扁平的旧版。
  /// 解析失败返回 null —— 调用方给「这张卡格式不认识」的提示，而不是崩掉。
  static TavernChar? tryImport(Object? raw) {
    if (raw is! Map) return null;
    final m = <String, dynamic>{};
    final data = raw['data'];
    final src = data is Map ? data : raw;
    m['name'] = src['name'] ?? raw['name'] ?? '';
    m['description'] = src['description'] ?? raw['description'] ?? '';
    m['firstMessage'] = src['first_mes'] ??
        src['firstMessage'] ??
        src['first_message'] ??
        raw['first_mes'] ??
        '';
    m['systemPrompt'] =
        src['system_prompt'] ?? src['systemPrompt'] ?? raw['system_prompt'] ?? '';
    m['avatar'] = src['avatar'] ?? raw['avatar'] ?? '';
    final tags = src['tags'] ?? raw['tags'];
    m['tags'] = tags is List ? tags.map((e) => '$e').toList() : const <String>[];
    if ('${m['name']}'.trim().isEmpty) return null;
    return TavernChar.fromJson({
      ...m,
      'id': DateTime.now().microsecondsSinceEpoch.toString(),
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// 拼给模型看的 system 提示。用户填了 [systemPrompt] 就以它为准，
  /// 否则用「你是 X + 设定 + 扮演规则」的默认模板。
  String buildSystemPrompt() {
    if (systemPrompt.trim().isNotEmpty) return systemPrompt.trim();
    final b = StringBuffer('你现在扮演「$name」。');
    if (description.trim().isNotEmpty) {
      b.write('\n\n角色设定：\n${description.trim()}');
    }
    b.write('\n\n要求：始终以这个角色的身份、语气、立场说话，不要跳出角色，'
        '不要提及自己是 AI 或模型。回复用第一人称，长度自然，不要每句都加旁白动作。');
    return b.toString();
  }
}

class TavernMsg {
  TavernMsg(this.role, this.text, {int? at})
      : at = at ?? DateTime.now().millisecondsSinceEpoch;
  final String role; // user / assistant
  final String text;
  final int at;

  Map<String, dynamic> toJson() => {'role': role, 'text': text, 'at': at};
  static TavernMsg fromJson(Map<String, dynamic> j) => TavernMsg(
        '${j['role'] ?? 'user'}',
        '${j['text'] ?? ''}',
        at: (j['at'] as num?)?.toInt(),
      );
}

class TavernChat {
  TavernChat({required this.charId, List<TavernMsg>? msgs})
      : msgs = msgs ?? <TavernMsg>[];
  String charId;
  List<TavernMsg> msgs;

  Map<String, dynamic> toJson() =>
      {'charId': charId, 'msgs': msgs.map((e) => e.toJson()).toList()};
  static TavernChat fromJson(Map<String, dynamic> j) => TavernChat(
        charId: '${j['charId'] ?? ''}',
        msgs: (j['msgs'] as List?)
                ?.whereType<Map>()
                .map((e) => TavernMsg.fromJson(Map<String, dynamic>.from(e)))
                .toList() ??
            <TavernMsg>[],
      );
}

/// 角色卡与会话的本地仓库。一个角色对应一条会话（单线，和网页端一致）。
class TavernStore {
  static const _kChars = 'tavern_chars';
  static const _kChats = 'tavern_chats';

  static Future<List<TavernChar>> chars() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kChars);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return [];
      return list
          .whereType<Map>()
          .map((e) => TavernChar.fromJson(Map<String, dynamic>.from(e)))
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveChars(List<TavernChar> list) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kChars, jsonEncode(list.map((e) => e.toJson()).toList()));
  }

  static Future<TavernChar> addChar(TavernChar c) async {
    final list = await chars();
    list.add(c);
    await saveChars(list);
    return c;
  }

  static Future<void> updateChar(TavernChar c) async {
    final list = await chars();
    final i = list.indexWhere((e) => e.id == c.id);
    if (i >= 0) {
      list[i] = c;
    } else {
      list.add(c);
    }
    await saveChars(list);
  }

  static Future<void> removeChar(String id) async {
    final list = await chars();
    list.removeWhere((e) => e.id == id);
    await saveChars(list);
    final chats = await _allChats();
    chats.remove(id);
    await _saveChats(chats);
  }

  static Future<Map<String, TavernChat>> _allChats() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kChats);
    if (raw == null || raw.isEmpty) return {};
    try {
      final m = jsonDecode(raw);
      if (m is! Map) return {};
      return {
        for (final e in m.entries)
          '${e.key}': TavernChat.fromJson(Map<String, dynamic>.from(e.value as Map))
      };
    } catch (_) {
      return {};
    }
  }

  static Future<void> _saveChats(Map<String, TavernChat> m) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kChats,
        jsonEncode({for (final e in m.entries) e.key: e.value.toJson()}));
  }

  static Future<TavernChat> chatOf(String charId) async {
    final m = await _allChats();
    return m[charId] ?? TavernChat(charId: charId);
  }

  static Future<void> saveChat(TavernChat c) async {
    final m = await _allChats();
    m[c.charId] = c;
    await _saveChats(m);
  }

  static Future<void> clearChat(String charId) async {
    final m = await _allChats();
    m.remove(charId);
    await _saveChats(m);
  }
}

// ─────────────────────────── 页面 ───────────────────────────

/// 酒馆首页：角色卡列表。
class TavernPage extends StatefulWidget {
  const TavernPage({super.key});
  @override
  State<TavernPage> createState() => _TavernPageState();
}

class _TavernPageState extends State<TavernPage> {
  List<TavernChar> _chars = [];
  bool _loading = true;
  String _q = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await TavernStore.chars();
    if (!mounted) return;
    setState(() {
      _chars = list;
      _loading = false;
    });
  }

  List<TavernChar> get _filtered {
    if (_q.trim().isEmpty) return _chars;
    final q = _q.trim().toLowerCase();
    return _chars.where((c) {
      return c.name.toLowerCase().contains(q) ||
          c.description.toLowerCase().contains(q) ||
          c.tags.any((t) => t.toLowerCase().contains(q));
    }).toList();
  }

  Future<void> _importFromText() async {
    final ctl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('导入角色卡'),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text(
              '把角色卡 JSON 粘进来。支持 SillyTavern V2（含 data 字段）和扁平格式。',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
            const SizedBox(height: Gap.sm),
            TextField(
              controller: ctl,
              maxLines: 8,
              decoration: const InputDecoration(hintText: '{ "name": "...", "description": "..." }'),
              style: const TextStyle(fontSize: 12),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(c, ctl.text),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty) return;
    try {
      final raw = jsonDecode(text.trim());
      final card = TavernChar.tryImport(raw);
      if (card == null) throw const FormatException('缺少角色名，或格式不认识');
      await TavernStore.addChar(card);
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('已导入「${card.name}」')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('导入失败：${e is FormatException ? e.message : e}')));
      }
    }
  }

  Future<void> _newChar() async {
    final c = TavernChar(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: '',
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    final saved = await Navigator.push<TavernChar>(
      context,
      MaterialPageRoute(builder: (_) => TavernCharEditorPage(char: c, isNew: true)),
    );
    if (saved != null) await _load();
  }

  Future<void> _open(TavernChar c) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => TavernChatPage(char: c)));
    await _load();
  }

  Future<void> _edit(TavernChar c) async {
    final saved = await Navigator.push<TavernChar>(
      context,
      MaterialPageRoute(builder: (_) => TavernCharEditorPage(char: c, isNew: false)),
    );
    if (saved != null) await _load();
  }

  @override
  Widget build(BuildContext c) {
    final list = _filtered;
    return Scaffold(
      appBar: AppBar(
        title: const Text('酒馆'),
        actions: [
          IconButton(
            tooltip: '导入角色卡',
            onPressed: _importFromText,
            icon: const Icon(Icons.file_download_outlined),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newChar,
        icon: const Icon(Icons.add),
        label: const Text('新建角色'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.sm),
                child: TextField(
                  onChanged: (v) => setState(() => _q = v),
                  decoration: InputDecoration(
                    hintText: '搜角色名 / 设定 / 标签',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
                    border: OutlineInputBorder(borderRadius: Radii.mdAll),
                  ),
                ),
              ),
              Expanded(
                child: list.isEmpty
                    ? _empty()
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, 96),
                        itemCount: list.length,
                        itemBuilder: (c, i) => _tile(list[i]),
                      ),
              ),
            ]),
    );
  }

  Widget _empty() => Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.theater_comedy_outlined, size: 44, color: Colors.grey.withValues(alpha: 0.5)),
          const SizedBox(height: Gap.md),
          const Text('还没有角色', style: TextStyle(fontSize: 14)),
          const SizedBox(height: Gap.xs),
          Text(
            _q.isEmpty ? '点右下角新建一个，或从右上角导入角色卡' : '没有匹配「$_q」的角色',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
            textAlign: TextAlign.center,
          ),
        ]),
      );

  Widget _tile(TavernChar ch) {
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: ListTile(
        onTap: () => _open(ch),
        leading: _Avatar(name: ch.name, url: ch.avatar),
        title: Text(ch.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        subtitle: Text(
          ch.description.isEmpty ? '未填写设定' : ch.description.replaceAll('\n', ' '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11.5),
        ),
        trailing: PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert, size: 18),
          onSelected: (v) async {
            if (v == 'edit') {
              await _edit(ch);
            } else if (v == 'clear') {
              await TavernStore.clearChat(ch.id);
              if (mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('对话记录已清空')));
              }
            } else if (v == 'del') {
              final ok = await showDialog<bool>(
                context: context,
                builder: (c2) => AlertDialog(
                  title: Text('删除「${ch.name}」？'),
                  content: const Text('角色卡和它的对话记录都会删掉，不能恢复。'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('取消')),
                    FilledButton(onPressed: () => Navigator.pop(c2, true), child: const Text('删除')),
                  ],
                ),
              );
              if (ok == true) {
                await TavernStore.removeChar(ch.id);
                await _load();
              }
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'edit', child: Text('编辑角色')),
            PopupMenuItem(value: 'clear', child: Text('清空对话')),
            PopupMenuItem(value: 'del', child: Text('删除角色')),
          ],
        ),
      ),
    );
  }
}

/// 头像：有 URL 就用图，没有就用名字首字 + 皮肤主色底（比默认灰头像有辨识度）。
class _Avatar extends StatelessWidget {
  const _Avatar({required this.name, this.url = '', this.size = 44});
  final String name;
  final String url;
  final double size;

  @override
  Widget build(BuildContext c) {
    final seed = Theme.of(c).colorScheme.primary;
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: seed.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(size * 0.32),
      ),
      child: Text(
        // 不用 `name.characters.first`：String.characters 需要额外 import
        // 'package:characters/characters.dart'，而且角色名基本不会是 emoji 开头。
        // 用 runes 取第一个码位，中文也不会切坏。
        name.isEmpty ? '?' : String.fromCharCode(name.runes.first),
        style: TextStyle(fontSize: size * 0.42, color: seed, fontWeight: FontWeight.w600),
      ),
    );
    if (url.isEmpty) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.32),
      child: Image.network(
        url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => fallback,
      ),
    );
  }
}

/// 角色卡编辑页。
class TavernCharEditorPage extends StatefulWidget {
  const TavernCharEditorPage({super.key, required this.char, this.isNew = false});
  final TavernChar char;
  final bool isNew;
  @override
  State<TavernCharEditorPage> createState() => _EditorState();
}

class _EditorState extends State<TavernCharEditorPage> {
  late final TextEditingController _name;
  late final TextEditingController _desc;
  late final TextEditingController _first;
  late final TextEditingController _sys;
  late final TextEditingController _avatar;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.char.name);
    _desc = TextEditingController(text: widget.char.description);
    _first = TextEditingController(text: widget.char.firstMessage);
    _sys = TextEditingController(text: widget.char.systemPrompt);
    _avatar = TextEditingController(text: widget.char.avatar);
  }

  @override
  void dispose() {
    for (final x in [_name, _desc, _first, _sys, _avatar]) {
      x.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final n = _name.text.trim();
    if (n.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('名字必填')));
      return;
    }
    widget.char
      ..name = n
      ..description = _desc.text.trim()
      ..firstMessage = _first.text.trim()
      ..systemPrompt = _sys.text.trim()
      ..avatar = _avatar.text.trim();
    await TavernStore.updateChar(widget.char);
    if (mounted) Navigator.pop(context, widget.char);
  }

  @override
  Widget build(BuildContext c) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isNew ? '新建角色' : '编辑角色'),
        actions: [TextButton(onPressed: _save, child: const Text('保存'))],
      ),
      body: ListView(padding: const EdgeInsets.all(Gap.md), children: [
        _field('名字', _name, '必填'),
        _field('角色设定', _desc, '人设、外表、性格、说话方式、和你的关系…写得越具体，演得越像',
            maxLines: 8),
        _field('开场白', _first, '角色说的第一句话（留空则从空对话开始）', maxLines: 3),
        _field('系统提示（可选）', _sys,
            '留空则自动用「你是 X + 上面的设定 + 扮演规则」。填了就以你写的为准', maxLines: 4),
        _field('头像地址（可选）', _avatar, '图片 URL；留空用名字首字', maxLines: 1),
        const SizedBox(height: Gap.md),
      ]),
    );
  }

  Widget _field(String label, TextEditingController ctl, String hint, {int maxLines = 1}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 6),
        TextField(
          controller: ctl,
          maxLines: maxLines,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(hintText: hint, hintStyle: const TextStyle(fontSize: 11)),
        ),
      ]),
    );
  }
}

/// 与角色对话。
class TavernChatPage extends StatefulWidget {
  const TavernChatPage({super.key, required this.char});
  final TavernChar char;
  @override
  State<TavernChatPage> createState() => _ChatState();
}

class _ChatState extends State<TavernChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  TavernChat? _chat;
  bool _sending = false;
  String _streaming = '';
  bool _cancel = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final c = await TavernStore.chatOf(widget.char.id);
    // 空会话且角色有开场白 → 用它起头（不消耗 token）
    if (c.msgs.isEmpty && widget.char.firstMessage.trim().isNotEmpty) {
      c.msgs.add(TavernMsg('assistant', widget.char.firstMessage.trim()));
      await TavernStore.saveChat(c);
    }
    if (!mounted) return;
    setState(() => _chat = c);
    _toBottom();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: Motion.durFast, curve: Curves.easeOut);
      }
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending || _chat == null) return;
    final chat = _chat!;
    final (pid, model) = await AiRegistry.lastModel();
    final provider = AiRegistry.byId(pid);
    if (provider == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('还没配置 AI。请到「我的 → API 密钥库」填一个 Key，'
                '再到 AI 模块选好模型')));
      }
      return;
    }
    _input.clear();
    setState(() {
      _sending = true;
      _cancel = false;
      _streaming = '';
      chat.msgs.add(TavernMsg('user', text));
    });
    await TavernStore.saveChat(chat);
    _toBottom();

    // 只带最近 24 条，避免上下文无限膨胀把费用和延迟拉爆
    final recent = chat.msgs.length > 24
        ? chat.msgs.sublist(chat.msgs.length - 24)
        : chat.msgs;
    final messages = <Map<String, String>>[
      {'role': 'system', 'content': widget.char.buildSystemPrompt()},
      for (final m in recent) {'role': m.role, 'content': m.text},
    ];

    try {
      final reply = await AiChat.chat(
        provider: provider,
        model: model,
        messages: messages,
        onDelta: (d) {
          if (_cancel) return;
          _streaming += d;
          if (mounted) setState(() {});
          _toBottom();
        },
      );
      final finalText = reply.trim().isEmpty ? _streaming.trim() : reply.trim();
      if (finalText.isNotEmpty) {
        chat.msgs.add(TavernMsg('assistant', finalText));
        await TavernStore.saveChat(chat);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('生成失败：$e')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          _streaming = '';
        });
        _toBottom();
      }
    }
  }

  @override
  Widget build(BuildContext c) {
    final chat = _chat;
    final scheme = Theme.of(c).colorScheme;
    final msgs = chat?.msgs ?? const <TavernMsg>[];
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          _Avatar(name: widget.char.name, url: widget.char.avatar, size: 30),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(widget.char.name,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15)),
          ),
        ]),
        actions: [
          IconButton(
            tooltip: '清空对话',
            onPressed: () async {
              await TavernStore.clearChat(widget.char.id);
              await _init();
            },
            icon: const Icon(Icons.refresh, size: 20),
          ),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: chat == null
              ? const Center(child: CircularProgressIndicator())
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.sm),
                  itemCount: msgs.length + (_streaming.isNotEmpty ? 1 : 0),
                  itemBuilder: (c, i) {
                    final isStream = i >= msgs.length;
                    final m = isStream ? null : msgs[i];
                    final isUser = m?.role == 'user';
                    final text = isStream ? _streaming : m!.text;
                    return Align(
                      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.only(bottom: Gap.sm),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        constraints: BoxConstraints(
                            maxWidth: MediaQuery.sizeOf(c).width * 0.78),
                        decoration: BoxDecoration(
                          color: isUser
                              ? scheme.primary.withValues(alpha: 0.14)
                              : Theme.of(c).cardColor,
                          borderRadius: BorderRadius.only(
                            topLeft: const Radius.circular(Radii.md),
                            topRight: const Radius.circular(Radii.md),
                            bottomLeft: Radius.circular(isUser ? Radii.md : 4),
                            bottomRight: Radius.circular(isUser ? 4 : Radii.md),
                          ),
                        ),
                        child: SelectableText(text, style: const TextStyle(fontSize: 13.5, height: 1.5)),
                      ),
                    );
                  },
                ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, Gap.sm),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.newline,
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    hintText: '说点什么…',
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    border: OutlineInputBorder(borderRadius: Radii.lgAll),
                  ),
                ),
              ),
              const SizedBox(width: Gap.sm),
              if (_sending)
                IconButton.filledTonal(
                  tooltip: '停止生成',
                  onPressed: () => setState(() => _cancel = true),
                  icon: const Icon(Icons.stop, size: 20),
                )
              else
                IconButton.filled(
                  tooltip: '发送',
                  onPressed: _send,
                  icon: const Icon(Icons.arrow_upward, size: 20),
                ),
            ]),
          ),
        ),
      ]),
    );
  }
}
