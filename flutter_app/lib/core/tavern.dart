// 酒馆（Tavern）—— 角色卡 + AI 扮演对话。
//
// 为什么要做这个模块（2026-11-04）：
//   网页端早有 `js/modules/tavern.js`（角色卡 / 分组 / 导入导出 / 对话），
//   App 端一直没有 —— 两端功能不对齐的典型缺口。
//   这里按 App 的既有结构重写，**不追求与网页端逐行对应**，只保证能力等价：
//   角色卡增删改、导入 SillyTavern V2 角色卡、与角色对话（流式）、会话留存。
//
// 刻意没做的：
//   · 角色分组 —— 角色少于 20 个时分组是负担，先用搜索
//   · 多分支存档（SillyTavern 的 swipe / 多会话）—— 先靠「重新生成」覆盖，
//     真有人要再多存档再说
//
// 4.81.24 补上「从 PNG 导入」：tEXt 里的 `ccv3` / `chara` 两种写法都认，
//   图片本身落进 `<文档>/tavern_avatars/` 当本地头像（见 `tavern_card_codec.dart`）。
// 4.81.25 补上消息级操作：长按气泡 → 复制 / 编辑 / 删除 / 重新生成。
//   同时把「上下文怎么裁」抽到 `tavern_context.dart`（纯 Dart）——
//   「截断后首条必须是 user」这条以前只在真机上聊够轮数才触发，现在有 CI 断言。
//
// 4.81.21 修的三处（都是首版留下的真缺陷，单轮对话复现不了）：
//   1. 「停止生成」以前只是不再刷新界面：后台那条流照旧收完，并把**完整回复**
//      写进对话。用户点了停止却看到整段答案冒出来，等于没停。
//   2. 上下文截断到最近 24 条后，首条可能是 assistant。Anthropic / Gemini 要求
//      「首条非 system 消息必须是 user」，聊到十几轮就往回 400 —— 表现为"聊久了突然报错"。
//   3. 头像字段来自 SillyTavern 卡时常常是 `xxx.png` 这种**文件名**，
//      `Image.network` 每次重建都发一次注定失败的请求。
//
// 存储：SharedPreferences（`tavern_chars` / `tavern_chats`）。
//   不做云同步是**故意的**：角色卡里常含成人向设定，未经用户明确同意不该上云。
//   后续若要同步，走 th_shared kind='tavern_char' 并单独给开关。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData, rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ai.dart';
import 'design_tokens.dart';
import 'i18n.dart';
import 'png_text.dart';
import 'tavern_card_codec.dart';
import 'tavern_context.dart';

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
        name: '${j['name'] ?? tr('未命名角色')}',
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
  ///
  /// ★模板走 trf/tr：提示词是**模型读的**，模型会用提示词的语言倾向作答 ——
  ///   界面切到法语却给中文提示词，模型就更容易回中文，用户会以为是"翻译坏了"。
  String buildSystemPrompt() {
    if (systemPrompt.trim().isNotEmpty) return systemPrompt.trim();
    final b = StringBuffer(trf('你现在扮演「{name}」。', {'name': name}));
    if (description.trim().isNotEmpty) {
      b.write('\n\n${trf('角色设定：\n{desc}', {'desc': description.trim()})}');
    }
    // ★这段必须写成**单个字面量**：`tr()` 的 key 就是它本身。写成相邻两个字面量
    //   `'…' '…'` 时 Dart 在编译期拼接，而 `tool/i18n_selfcheck.dart` 的正则只抓
    //   第一个字面量 → 它校验的是半句、运行时查的是整句 → 永远查不到译文。
    b.write('\n\n${tr('要求：始终以这个角色的身份、语气、立场说话，不要跳出角色，不要提及自己是 AI 或模型。回复用第一人称，长度自然，不要每句都加旁白动作。')}');
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

  // ── 导出（4.81.23）────────────────────────────────────────────────
  //
  // 为什么导出要做两路：
  //   · **PNG**：外壳是一张图，卡的数据在 PNG 的 tEXt 块里（关键字 `chara`）。
  //     这是社区的分发格式 —— 别人（SillyTavern 网页端、其他 App）拖进去就能用。
  //   · **JSON**：纯文本，便于备份、比对、手改，也方便粘到别处。
  //   只做其中一种都会让另一半用法落空，所以两条都出。

  /// 导出目录：`<应用文档目录>/tavern_export`。
  ///
  /// 刻意不用缓存目录 —— 系统会清缓存，"导出完过两天文件就没了"是最难解释的失败。
  static Future<Directory> exportDir() async {
    final d = Directory(
        '${(await getApplicationDocumentsDirectory()).path}${Platform.pathSeparator}tavern_export');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static Map<String, Object?> _fieldsOf(TavernChar c) => <String, Object?>{
        'id': c.id,
        'name': c.name,
        'description': c.description,
        'firstMessage': c.firstMessage,
        'systemPrompt': c.systemPrompt,
        'avatar': c.avatar,
        'tags': c.tags,
      };

  static Future<File> exportJson(TavernChar c) async {
    final d = await exportDir();
    final f = File('${d.path}${Platform.pathSeparator}${cardFileName(c.name, 'json')}');
    await f.writeAsString(cardV2Json(_fieldsOf(c)), flush: true);
    return f;
  }

  static Future<File> exportPng(TavernChar c) async {
    final carrier = await _carrierPng(c.avatar);
    final out = embedTextChunks(carrier, <String, String>{
      'chara': cardV2Base64(_fieldsOf(c)),
    });
    final d = await exportDir();
    final f = File('${d.path}${Platform.pathSeparator}${cardFileName(c.name, 'png')}');
    await f.writeAsBytes(out, flush: true);
    return f;
  }

  /// 底图选择：能拿到 PNG 头像就用它（导出的卡看起来就是这个角色），
  /// 否则退回应用图标。**只有 PNG 能当外壳** —— JPEG / WebP 没有 tEXt 块。
  static Future<Uint8List> _carrierPng(String avatar) async {
    final u = avatar.trim();
    if (u.startsWith('http://') || u.startsWith('https://')) {
      final got = await _downloadPng(u);
      if (got != null) return got;
    } else if (u.isNotEmpty) {
      // 从 PNG 卡导入的卡，头像是本地文件；再导出时要沿用它，
      // 否则"导进来的图"会在下一次导出时被应用图标替掉。
      final got = await _readLocalPng(u);
      if (got != null) return got;
    }
    final data = await rootBundle.load('assets/branding/logo.png');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  /// 本地头像文件（导入 PNG 卡时存下来的那张）。同样只认 PNG、同样 8MB 上限。
  static Future<Uint8List?> _readLocalPng(String path) async {
    try {
      final f = File(path);
      if (!await f.exists()) return null;
      if (await f.length() > 8 * 1024 * 1024) return null;
      final b = await f.readAsBytes();
      return isPng(b) ? b : null;
    } catch (_) {
      return null;
    }
  }

  /// 取头像：8 秒超时 + 8MB 上限。
  ///
  /// 放行自签证书（局域网里常见，与 tts_presets 同款做法）：这里只用来取一张图，
  /// 不参与任何鉴权，放宽不会放大风险。
  static Future<Uint8List?> _downloadPng(String url) async {
    HttpClient? cli;
    try {
      cli = HttpClient()..connectionTimeout = const Duration(seconds: 8);
      cli.badCertificateCallback = (_, __, ___) => true;
      final res = await (await cli.getUrl(Uri.parse(url)))
          .close()
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final b = BytesBuilder(copy: false);
      await for (final part in res) {
        b.add(part);
        if (b.length > 8 * 1024 * 1024) return null;
      }
      final bytes = b.toBytes();
      return isPng(bytes) ? bytes : null;
    } catch (_) {
      return null; // 头像拿不到不该让"导出"整个失败，退回应用图标
    } finally {
      cli?.close(force: true);
    }
  }

  // ── 导入（4.81.24）────────────────────────────────────────────────
  //
  // 导入是导出的逆运算，但**比导出更容易出错**：用户在文件管理器里随手点一张
  // 图，那张图可能根本不是角色卡。所以这里每条失败路径都给一句能看懂的话，
  // 而不是把 `FormatException: Unexpected character` 丢到界面上。

  /// 头像落盘目录：`<文档目录>/tavern_avatars`。
  ///
  /// 为什么要存：PNG 卡里的图就是角色头像，不存下来的话卡片数据进来了、
  /// 头像却永远是首字占位 —— 用户会以为"导入只导了一半"。
  static Future<Directory> _avatarDir() async {
    final d = Directory(
        '${(await getApplicationDocumentsDirectory()).path}${Platform.pathSeparator}tavern_avatars');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// 从一张 PNG 角色卡导入：解 tEXt → 卡片 → 图存成本地头像。
  /// 失败抛 [FormatException]，message 已是本地化文案，调用方直接显示。
  static Future<TavernChar> importPng(Uint8List bytes) async {
    if (!isPng(bytes)) throw FormatException(tr('这不是 PNG 图片'));
    final raw = cardFromPng(bytes);
    if (raw == null) throw FormatException(tr('这张图里没有角色卡数据'));
    final card = TavernChar.tryImport(raw);
    if (card == null) throw FormatException(tr('缺少角色名，或格式不认识'));
    final d = await _avatarDir();
    final f = File('${d.path}${Platform.pathSeparator}${card.id}.png');
    await f.writeAsBytes(bytes, flush: true);
    // 头像字段存**本地绝对路径**：`_Avatar` 与 `_carrierPng` 都认这个形式。
    final got = TavernChar.fromJson({...card.toJson(), 'avatar': f.path});
    await addChar(got);
    return got;
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

  /// 导入入口。三条路都有各自的真实场景，不设"默认"：
  ///   · PNG 卡 —— 社区分发的主流格式（图上就内嵌了数据）；
  ///   · JSON 文件 —— 备份、别人发给你的 `.json`；
  ///   · 粘文本 —— 从聊天窗口/网页里复制过来的一段。
  /// 以前只留了"粘文本"一条，收到一张 PNG 卡的用户在界面上完全找不到入口。
  Future<void> _importCard() async {
    final kind = await showModalBottomSheet<String>(
      context: context,
      builder: (c2) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.image_outlined),
            title: Text(tr('选择 PNG 角色卡')),
            subtitle: Text(tr('图里内嵌了卡片数据，选完直接导入')),
            onTap: () => Navigator.pop(c2, 'png'),
          ),
          ListTile(
            leading: const Icon(Icons.data_object),
            title: Text(tr('选择 JSON 文件')),
            onTap: () => Navigator.pop(c2, 'json'),
          ),
          ListTile(
            leading: const Icon(Icons.content_paste),
            title: Text(tr('粘贴 JSON 文本')),
            onTap: () => Navigator.pop(c2, 'text'),
          ),
        ]),
      ),
    );
    if (kind == null) return;
    if (kind == 'text') {
      await _importFromText();
    } else {
      await _importFromFile(pngOnly: kind == 'png');
    }
  }

  Future<void> _importFromFile({required bool pngOnly}) async {
    try {
      final r = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: pngOnly ? <String>['png'] : <String>['json', 'txt'],
        withData: true, // 安卓上 path 可能为空（内容 URI），要直接拿字节
      );
      if (r == null || r.files.isEmpty) return;
      final f = r.files.first;
      var bytes = f.bytes;
      if (bytes == null && f.path != null) bytes = await File(f.path!).readAsBytes();
      if (bytes == null) throw FormatException(tr('读不到文件内容'));
      if (bytes.length > 16 * 1024 * 1024) throw FormatException(tr('文件太大（超过 16MB）'));
      TavernChar card;
      if (pngOnly || isPng(bytes)) {
        card = await TavernStore.importPng(bytes);
      } else {
        // allowMalformed：有人导出的 JSON 带 BOM 或被截断，宁可让 JSON 解析去报错，
        // 也不要在这里先抛一个"非法 UTF-8"，那句话对用户毫无信息量。
        final raw = decodeCardJson(utf8.decode(bytes, allowMalformed: true));
        final c2 = raw == null ? null : TavernChar.tryImport(raw);
        if (c2 == null) throw FormatException(tr('缺少角色名，或格式不认识'));
        card = await TavernStore.addChar(c2);
      }
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(trf('已导入「{name}」', {'name': card.name}))));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(trf('导入失败：{e}',
              {'e': e is FormatException ? e.message : e}))));
    }
  }

  Future<void> _importFromText() async {
    final ctl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('导入角色卡')),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(
              tr('把角色卡 JSON 粘进来。支持 SillyTavern V2（含 data 字段）和扁平格式。'),
              style: const TextStyle(fontSize: 11, color: Colors.grey),
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
          TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('取消'))),
          FilledButton(
            onPressed: () => Navigator.pop(c, ctl.text),
            child: Text(tr('导入')),
          ),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty) return;
    try {
      final raw = jsonDecode(text.trim());
      final card = TavernChar.tryImport(raw);
      if (card == null) throw FormatException(tr('缺少角色名，或格式不认识'));
      await TavernStore.addChar(card);
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(trf('已导入「{name}」', {'name': card.name}))));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(trf('导入失败：{e}',
                {'e': e is FormatException ? e.message : e}))));
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

  /// 导出：先让用户挑格式（两种各有用途，默认哪个都不合适），
  /// 落盘后再调系统分享 —— 分享面板里既能存到「文件」，也能直接发微信。
  Future<void> _export(TavernChar ch) async {
    final kind = await showModalBottomSheet<String>(
      context: context,
      builder: (c2) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.image_outlined),
            title: Text(tr('PNG 角色卡（可直接导入酒馆）')),
            subtitle: Text(tr('图片外壳 + 内嵌数据；没头像时用应用图标当底图')),
            onTap: () => Navigator.pop(c2, 'png'),
          ),
          ListTile(
            leading: const Icon(Icons.data_object),
            title: Text(tr('JSON 文本（便于备份和手改）')),
            onTap: () => Navigator.pop(c2, 'json'),
          ),
        ]),
      ),
    );
    if (kind == null) return;
    try {
      final f = kind == 'png'
          ? await TavernStore.exportPng(ch)
          : await TavernStore.exportJson(ch);
      if (!mounted) return;
      final name = f.path.split(Platform.pathSeparator).last;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(trf('已导出：{name}', {'name': name}))));
      try {
        await Share.shareXFiles(<XFile>[XFile(f.path)], text: ch.name);
      } catch (_) {
        // 分享面板起不来（部分定制 ROM 会这样）不影响导出本身 —— 文件已经在
        // tavern_export 目录里，上面的提示已经把文件名告诉用户了。
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(trf('导出失败：{e}', {'e': e}))));
    }
  }

  @override
  Widget build(BuildContext c) {
    final list = _filtered;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('酒馆')),
        actions: [
          IconButton(
            tooltip: tr('导入角色卡'),
            onPressed: _importCard,
            icon: const Icon(Icons.file_download_outlined),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newChar,
        icon: const Icon(Icons.add),
        label: Text(tr('新建角色')),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.sm),
                child: TextField(
                  onChanged: (v) => setState(() => _q = v),
                  decoration: InputDecoration(
                    hintText: tr('搜角色名 / 设定 / 标签'),
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
          Text(tr('还没有角色'), style: const TextStyle(fontSize: 14)),
          const SizedBox(height: Gap.xs),
          Text(
            _q.isEmpty
                ? tr('点右下角新建一个，或从右上角导入角色卡')
                : trf('没有匹配「{q}」的角色', {'q': _q}),
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
          ch.description.isEmpty ? tr('未填写设定') : ch.description.replaceAll('\n', ' '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11.5),
        ),
        trailing: PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert, size: 18),
          onSelected: (v) async {
            if (v == 'edit') {
              await _edit(ch);
            } else if (v == 'export') {
              await _export(ch);
            } else if (v == 'clear') {
              await TavernStore.clearChat(ch.id);
              if (mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(tr('对话记录已清空'))));
              }
            } else if (v == 'del') {
              final ok = await showDialog<bool>(
                context: context,
                builder: (c2) => AlertDialog(
                  title: Text(trf('删除「{name}」？', {'name': ch.name})),
                  content: Text(tr('角色卡和它的对话记录都会删掉，不能恢复。')),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(c2, false),
                        child: Text(tr('取消'))),
                    FilledButton(
                        onPressed: () => Navigator.pop(c2, true),
                        child: Text(tr('删除'))),
                  ],
                ),
              );
              if (ok == true) {
                await TavernStore.removeChar(ch.id);
                await _load();
              }
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(value: 'edit', child: Text(tr('编辑角色'))),
            PopupMenuItem(value: 'export', child: Text(tr('导出角色卡'))),
            PopupMenuItem(value: 'clear', child: Text(tr('清空对话'))),
            PopupMenuItem(value: 'del', child: Text(tr('删除角色'))),
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
    // SillyTavern 卡里的 avatar 常是 `Seraphina.png` 这种文件名（图在卡包 zip 里），
    // 不是 URL，也不是本机路径。以前直接丢给 Image.network，每次重建都发一次注定失败的请求。
    final isUrl = url.startsWith('http://') || url.startsWith('https://');
    // 从 PNG 卡导入的卡，头像存的是本机绝对路径（含路径分隔符）。
    // 用"含分隔符"而不是"以 .png 结尾"来判：ST 的裸文件名恰好也是 .png 结尾，
    // 按扩展名判会把它们当成路径去读，每次列表重建都抛一次文件不存在。
    final isPath = !isUrl && (url.startsWith('/') || url.contains(Platform.pathSeparator));
    if (!isUrl && !isPath) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.32),
      child: isUrl
          ? Image.network(
              url,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => fallback,
            )
          : Image.file(
              File(url),
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
          .showSnackBar(SnackBar(content: Text(tr('名字必填'))));
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
        title: Text(widget.isNew ? tr('新建角色') : tr('编辑角色')),
        actions: [TextButton(onPressed: _save, child: Text(tr('保存')))],
      ),
      body: ListView(padding: const EdgeInsets.all(Gap.md), children: [
        _field(tr('名字'), _name, tr('必填')),
        _field(tr('角色设定'), _desc,
            tr('人设、外表、性格、说话方式、和你的关系…写得越具体，演得越像'),
            maxLines: 8),
        _field(tr('开场白'), _first, tr('角色说的第一句话（留空则从空对话开始）'),
            maxLines: 3),
        _field(tr('系统提示（可选）'), _sys,
            tr('留空则自动用「你是 X + 上面的设定 + 扮演规则」。填了就以你写的为准'),
            maxLines: 4),
        _field(tr('头像地址（可选）'), _avatar, tr('图片 URL；留空用名字首字'), maxLines: 1),
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

  /// 生成令牌：发送 / 停止 / 销毁时 +1，异步回调只认自己那一轮。
  /// 用它替掉原来的 `_cancel` 布尔 —— 布尔挡不住「停完立刻再发」的串台：
  /// 上一轮迟到的 delta 会写进新一轮的气泡里。
  int _seq = 0;

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
    _seq++; // 让在途的流式回调全部失效，别往已销毁的 State 里写
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: Motion.durFast, curve: Curves.easeOut);
      }
    });
  }

  /// 用户点「停止生成」：立刻结束本轮 UI，并把已经收到的部分留成一条消息。
  ///
  /// 底层那条 HTTP 流掐不断（`AiChat.chat` 没有取消句柄），它会在后台跑完；
  /// 那点 token 已经花出去了，所以不丢文本、只作废结果。
  void _stop() {
    final chat = _chat;
    final partial = _streaming.trim();
    if (chat != null && partial.isNotEmpty) {
      chat.msgs.add(TavernMsg('assistant', partial));
      TavernStore.saveChat(chat);
    }
    _seq++; // 在途回调（含 await 之后的收尾）全部作废
    setState(() {
      _sending = false;
      _streaming = '';
    });
    _toBottom();
  }

  /// 把会话消息投影给纯 Dart 层。`tavern_context.dart` 刻意不 import 本文件 ——
  /// 它一旦 import flutter，`dart run tool/tavern_context_selfcheck.dart` 就跑不起来。
  List<TavernTurn> _turns(TavernChat chat) =>
      <TavernTurn>[for (final m in chat.msgs) TavernTurn(m.role, m.text)];

  /// 发消息与「重新生成」共用的执行体。
  ///
  /// [userText] 非空 = 追加一条用户消息再请求；为空 = 用现有上下文直接请求（重新生成）。
  ///
  /// 两件事必须在**第一个 await 之前**做完，否则会出现重复发送：
  ///   · `_seq++` 立刻作废在途结果；
  ///   · `_sending = true` 立刻置位 —— `AiRegistry.lastModel()` 是异步的，
  ///     空档里再点一次会真的发两条（4.81.21 修过同一个形态，别再退回去）。
  Future<void> _start({String? userText}) async {
    final chat = _chat;
    if (chat == null || _sending) return;
    final mySeq = ++_seq;
    setState(() => _sending = true);
    final (pid, model) = await AiRegistry.lastModel();
    final provider = AiRegistry.byId(pid);
    if (provider == null) {
      if (!mounted || mySeq != _seq) return;
      // 不清空输入框：用户还得拿它去配 Key
      setState(() => _sending = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr('还没配置 AI。请到「我的 → API 密钥库」填一个 Key，再到 AI 模块选好模型'))));
      return;
    }
    if (!mounted || mySeq != _seq) return; // 期间已被「停止」，或页面已销毁

    if (userText != null) {
      _input.clear();
      chat.msgs.add(TavernMsg('user', userText));
      setState(() => _streaming = '');
      await TavernStore.saveChat(chat);
      if (!mounted || mySeq != _seq) return;
      _toBottom();
    }

    // 裁剪（最近 24 条 / 首条必须是 user）已收口到 TavernContext.build，
    // 那里由 CI 自检逐条断言 —— 这段逻辑以前内联在 State 里，只有聊够轮数才会翻车。
    final messages = TavernContext.build(
      system: widget.char.buildSystemPrompt(),
      turns: _turns(chat),
    );
    // 只剩 system = 没有任何用户输入。典型场景：新角色只有开场白就点了「重新生成」。
    // 这种请求 OpenAI 报「messages 不能为空」、Anthropic 报「至少一条 user」，
    // 报错文案长得像 Key 配错了，用户会去乱改设置。
    if (messages.length <= 1) {
      setState(() => _sending = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('先发一句话，才有内容可以重新生成'))));
      return;
    }

    setState(() => _streaming = '');
    _toBottom();

    try {
      final reply = await AiChat.chat(
        provider: provider,
        model: model,
        messages: messages,
        onDelta: (d) {
          if (mySeq != _seq) return;
          _streaming += d;
          if (mounted) setState(() {});
          _toBottom();
        },
      );
      if (mySeq != _seq) return; // 已停止 → 丢弃迟到的完整回复（部分文本已在 _stop 留存）
      final finalText = reply.trim().isEmpty ? _streaming.trim() : reply.trim();
      if (finalText.isNotEmpty) {
        chat.msgs.add(TavernMsg('assistant', finalText));
        await TavernStore.saveChat(chat);
      }
    } catch (e) {
      if (mounted && mySeq == _seq) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(trf('生成失败：{e}', {'e': e}))));
      }
    } finally {
      if (mounted && mySeq == _seq) {
        setState(() {
          _sending = false;
          _streaming = '';
        });
        _toBottom();
      }
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    await _start(userText: text);
  }

  /// 重新生成最后一条回复：先把尾部连续的 assistant 删掉，再用剩余上下文重发。
  ///
  /// 为什么必须**先删**：不删就把新回复追加在旧回复后面，上下文里会出现
  /// 「两条 assistant 连着」，模型会顺着两条的口气续写，越生成越乱。
  /// 尾部连续多条一起删的理由见 [TavernContext.regenerateCutoff]（停止过几次会堆出半截回复）。
  Future<void> _regenerate() async {
    final chat = _chat;
    if (chat == null || _sending) return;
    final cut = TavernContext.regenerateCutoff(_turns(chat));
    if (cut < 0) return; // 没有可重做的回复（只有开场白 / 末条就是用户）
    chat.msgs.removeRange(cut, chat.msgs.length);
    setState(() => _streaming = '');
    await TavernStore.saveChat(chat);
    if (!mounted) return;
    await _start();
  }

  /// 长按气泡弹出的消息操作。
  ///
  /// 为什么不用 SelectableText 自带的选择框：它把长按手势吃掉了（选区优先），
  /// 外面再包一层 GestureDetector 也收不到 —— 两者抢的是同一个手势。
  /// 取舍：把**整条复制**放进菜单（覆盖绝大多数场景），换来编辑 / 删除 / 重新生成有入口。
  void _msgMenu(int i) {
    final chat = _chat;
    if (chat == null || _sending) return; // 生成中不弹：边改上下文边收流会串台
    if (i < 0 || i >= chat.msgs.length) return;
    final m = chat.msgs[i];
    final canRegen = i == chat.msgs.length - 1 && m.role == 'assistant';
    final errColor = Theme.of(context).colorScheme.error;
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.copy_outlined, size: 20),
            title: Text(tr('复制'), style: const TextStyle(fontSize: 14)),
            onTap: () {
              Navigator.pop(ctx);
              Clipboard.setData(ClipboardData(text: m.text));
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text(tr('已复制'))));
            },
          ),
          ListTile(
            leading: const Icon(Icons.edit_outlined, size: 20),
            title: Text(tr('编辑'), style: const TextStyle(fontSize: 14)),
            onTap: () {
              Navigator.pop(ctx);
              _editMsg(i);
            },
          ),
          if (canRegen)
            ListTile(
              leading: const Icon(Icons.autorenew, size: 20),
              title: Text(tr('重新生成'), style: const TextStyle(fontSize: 14)),
              onTap: () {
                Navigator.pop(ctx);
                _regenerate();
              },
            ),
          ListTile(
            leading: Icon(Icons.delete_outline, size: 20, color: errColor),
            title: Text(tr('删除'),
                style: TextStyle(fontSize: 14, color: errColor)),
            onTap: () {
              Navigator.pop(ctx);
              _deleteMsg(i);
            },
          ),
        ]),
      ),
    );
  }

  /// 编辑单条消息的文本。改完**不重发** —— 只改历史，下次发消息时才带上。
  Future<void> _editMsg(int i) async {
    final chat = _chat;
    if (chat == null || i < 0 || i >= chat.msgs.length) return;
    final m = chat.msgs[i];
    final ctl = TextEditingController(text: m.text);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('编辑消息'), style: const TextStyle(fontSize: 16)),
        content: TextField(
          controller: ctl,
          minLines: 4,
          maxLines: 12,
          autofocus: true,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
              hintText: tr('消息内容'),
              hintStyle: const TextStyle(fontSize: 11)),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('取消'))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('保存'))),
        ],
      ),
    );
    final txt = ctl.text.trim();
    ctl.dispose();
    if (ok != true || txt.isEmpty) return;
    if (!mounted) return;
    // `TavernMsg.text` 是 final：换一个新对象而不是改字段（`at` 保留原时间戳）
    chat.msgs[i] = TavernMsg(m.role, txt, at: m.at);
    setState(() {});
    await TavernStore.saveChat(chat);
  }

  Future<void> _deleteMsg(int i) async {
    final chat = _chat;
    if (chat == null || i < 0 || i >= chat.msgs.length) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('删除这条消息？'), style: const TextStyle(fontSize: 16)),
        content: Text(tr('删除后无法恢复。'), style: const TextStyle(fontSize: 13)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('取消'))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('删除'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    chat.msgs.removeAt(i);
    setState(() {});
    await TavernStore.saveChat(chat);
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
            tooltip: tr('清空对话'),
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
                    // 长按出消息菜单（复制/编辑/删除/重新生成）。
                    //
                    // ★这里从 `SelectableText` 换成了 `Text`：SelectableText 自带的长按
                    //   选区手势会把手势竞技场里的长按吃掉，外面包 GestureDetector 收不到，
                    //   表现就是"长按没反应"。整条复制已在菜单里，代价是失去选区复制。
                    //   流式气泡（isStream）不给长按 —— 它还没有真实消息可操作。
                    return Align(
                      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                      child: GestureDetector(
                        onLongPress: isStream ? null : () => _msgMenu(i),
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
                          child: Text(text,
                              style: const TextStyle(fontSize: 13.5, height: 1.5)),
                        ),
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
                    hintText: tr('说点什么…'),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    border: OutlineInputBorder(borderRadius: Radii.lgAll),
                  ),
                ),
              ),
              const SizedBox(width: Gap.sm),
              if (_sending)
                IconButton.filledTonal(
                  tooltip: tr('停止生成'),
                  onPressed: _stop,
                  icon: const Icon(Icons.stop, size: 20),
                )
              else
                IconButton.filled(
                  tooltip: tr('发送'),
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
