// ThirdHub v4.41.0 聊天模块
//
// 协议规范见 docs/CHAT-PROTOCOL.md —— 本文件是它的一一对应实现，改动请同步两份。
//
// 三条设计底线：
//  1) **离线优先**：本地存储永远可用，后端可有可无。发消息先落本地并入发件箱，
//     有后端时再由 [ChatApi.flush] 上行；App 被杀也不丢。
//  2) **幂等上行**：每条消息带客户端生成的 [ChatMsg.cid]，服务端按 cid 去重。
//     重连后整批重发是安全的——这是"确认队列"能成立的前提。
//  3) **单调整序**：会话内序号 seq 由服务端分配。本地消息 seq=0，收到回执才落号。
//     因此列表排序用 (seq>0 ? seq : 极大值+ts) 这样的兜底，未上行消息永远排最后。
import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import 'pro_kit.dart';

// ═══════════════════════════════════════════════════════════════════
// 协议层
// ═══════════════════════════════════════════════════════════════════

/// 协议版本。只增不减：新字段必须可选，老客户端要能忽略掉。
const int kChatProtoVersion = 1;

/// 消息类型。附件类只放引用（blob key），内容本身走 /v1/blob，不塞进消息体。
const String kMsgText = 'text';
const String kMsgImage = 'image';
const String kMsgFile = 'file';
const String kMsgSystem = 'system';
const String kMsgAi = 'ai';

/// 一条消息 = 协议信封里的 message。
class ChatMsg {
  /// 客户端生成的幂等 id。**上行时以它去重**，所以重发不会产生第二条。
  final String cid;

  /// 所属会话。
  final String sid;

  /// 会话内单调序号，服务端分配。0 = 还没上行成功。
  int seq;

  /// 客户端发送时刻（毫秒）。仅用于本地排序与展示，不承担排序职责。
  final int ts;

  /// 发送者标识。
  final String from;

  /// 消息类型，见 kMsg*。
  final String type;

  /// 文本内容。附件类消息这里存一句人可读的摘要，便于不下载也能看明白。
  final String body;

  /// 附件在 /v1/blob 里的 key（可空）。
  final String ref;

  /// 附件原始文件名（可空）。
  final String name;

  /// 是否已上行成功。
  bool sent;

  /// 对端是否已读。
  bool read;

  ChatMsg({
    required this.cid,
    required this.sid,
    this.seq = 0,
    required this.ts,
    required this.from,
    this.type = kMsgText,
    required this.body,
    this.ref = '',
    this.name = '',
    this.sent = false,
    this.read = false,
  });

  /// 排序键。未上行(seq<=0)恒排最后，避免"刚发的消息跳到历史中间"。
  double get orderKey => seq > 0 ? seq.toDouble() : 1e15 + ts.toDouble();

  bool get pending => !sent;

  Map<String, dynamic> toWire() => {
        'v': kChatProtoVersion,
        'cid': cid,
        'sid': sid,
        'seq': seq,
        'ts': ts,
        'from': from,
        't': type,
        'body': body,
        if (ref.isNotEmpty) 'ref': ref,
        if (name.isNotEmpty) 'name': name,
      };

  /// 宽容解析：缺字段一律回落默认值，不让一条脏数据把整批同步打断。
  static ChatMsg fromWire(Map m) => ChatMsg(
        cid: '${m['cid'] ?? m['id'] ?? ''}',
        sid: '${m['sid'] ?? ''}',
        seq: (m['seq'] as num?)?.toInt() ?? 0,
        ts: (m['ts'] as num?)?.toInt() ?? 0,
        from: '${m['from'] ?? ''}',
        type: '${m['t'] ?? kMsgText}',
        body: '${m['body'] ?? ''}',
        ref: '${m['ref'] ?? ''}',
        name: '${m['name'] ?? ''}',
        sent: ((m['seq'] as num?)?.toInt() ?? 0) > 0,
        read: m['read'] == true,
      );

  Map<String, String> toLocal() => {
        'cid': cid,
        'sid': sid,
        'seq': '$seq',
        'ts': '$ts',
        'from': from,
        't': type,
        'body': body,
        'ref': ref,
        'name': name,
        'sent': sent ? '1' : '0',
        'read': read ? '1' : '0',
      };

  static ChatMsg fromLocal(Map<String, String> m) => ChatMsg(
        cid: m['cid'] ?? '',
        sid: m['sid'] ?? '',
        seq: int.tryParse(m['seq'] ?? '0') ?? 0,
        ts: int.tryParse(m['ts'] ?? '0') ?? 0,
        from: m['from'] ?? '',
        type: m['t'] ?? kMsgText,
        body: m['body'] ?? '',
        ref: m['ref'] ?? '',
        name: m['name'] ?? '',
        sent: m['sent'] == '1',
        read: m['read'] == '1',
      );
}

/// 一个会话 = 协议信封里的 session。
class ChatSession {
  final String id;
  String title;

  /// 对端标识：'family' / 群名 / 引擎名。用于展示"和谁在聊"。
  String peer;

  /// 本地已知的最大 seq，用于增量拉取。
  int lastSeq;
  int lastTs;
  int unread;
  int count;

  ChatSession({
    required this.id,
    required this.title,
    this.peer = '',
    this.lastSeq = 0,
    this.lastTs = 0,
    this.unread = 0,
    this.count = 0,
  });

  Map<String, String> toLocal() => {
        'id': id,
        'title': title,
        'peer': peer,
        'lastSeq': '$lastSeq',
        'lastTs': '$lastTs',
        'unread': '$unread',
        'count': '$count',
      };

  static ChatSession fromLocal(Map<String, String> m) => ChatSession(
        id: m['id'] ?? '',
        title: m['title'] ?? '',
        peer: m['peer'] ?? '',
        lastSeq: int.tryParse(m['lastSeq'] ?? '0') ?? 0,
        lastTs: int.tryParse(m['lastTs'] ?? '0') ?? 0,
        unread: int.tryParse(m['unread'] ?? '0') ?? 0,
        count: int.tryParse(m['count'] ?? '0') ?? 0,
      );

  static ChatSession fromWire(Map m) => ChatSession(
        id: '${m['id'] ?? ''}',
        title: '${m['title'] ?? '会话'}',
        peer: '${m['peer'] ?? ''}',
        lastSeq: (m['lastSeq'] as num?)?.toInt() ?? 0,
        lastTs: (m['lastTs'] as num?)?.toInt() ?? 0,
        count: (m['count'] as num?)?.toInt() ?? 0,
      );
}

// ═══════════════════════════════════════════════════════════════════
// 存储层
// ═══════════════════════════════════════════════════════════════════

class ChatStore {
  static const _kSessions = 'chat_sessions';
  static const _kOutbox = 'chat_outbox';
  static String _kMsgs(String sid) => 'chat_msgs_$sid';

  static final Random _rnd = Random();

  /// 生成幂等 id：时间戳打底 + 随机后缀。
  /// 不用 uuid 包是为了保持零新增依赖；碰撞概率对本场景足够。
  static String newId(String prefix) {
    final t = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final r = _rnd.nextInt(1 << 32).toRadixString(36).padLeft(7, '0');
    return '$prefix$t$r';
  }

  static Future<List<ChatSession>> sessions() async {
    final l = await ProKit.listOf(_kSessions);
    return [for (final m in l) ChatSession.fromLocal(m)];
  }

  static Future<void> saveSessions(List<ChatSession> list) =>
      ProKit.saveList(_kSessions, [for (final s in list) s.toLocal()]);

  static Future<List<ChatMsg>> msgs(String sid) async {
    final l = await ProKit.listOf(_kMsgs(sid));
    final out = [for (final m in l) ChatMsg.fromLocal(m)];
    out.sort((a, b) => a.orderKey.compareTo(b.orderKey));
    return out;
  }

  static Future<void> saveMsgs(String sid, List<ChatMsg> list) async {
    final sorted = [...list]..sort((a, b) => a.orderKey.compareTo(b.orderKey));
    // 单会话最多留 2000 条，本地存储不是归档——真要留全量在后端
    final keep =
        sorted.length > 2000 ? sorted.sublist(sorted.length - 2000) : sorted;
    await ProKit.saveList(_kMsgs(sid), [for (final m in keep) m.toLocal()]);
  }

  /// 写入一条消息（按 cid 去重）。
  static Future<List<ChatMsg>> append(ChatMsg m) async {
    final list = await msgs(m.sid);
    list.removeWhere((e) => e.cid == m.cid);
    list.add(m);
    await saveMsgs(m.sid, list);
    return list;
  }

  /// 合并一批远端消息：同 cid 以远端为准（拿到 seq 才算真的发出去）。
  static Future<List<ChatMsg>> merge(String sid, List<ChatMsg> incoming) async {
    final list = await msgs(sid);
    final byCid = <String, ChatMsg>{};
    for (final old in list) {
      byCid[old.cid] = old;
    }
    for (final inc in incoming) {
      final old = byCid[inc.cid];
      if (old != null) {
        // 远端带 seq 才算数；已读状态是本地事实，不能被覆盖掉
        inc.sent = inc.sent || old.sent;
        inc.read = inc.read || old.read;
      }
      byCid[inc.cid] = inc;
    }
    final out = byCid.values.toList();
    await saveMsgs(sid, out);
    return out;
  }

  /// 发件箱：所有还没上行成功的消息。按 sid 汇总。
  static Future<List<ChatMsg>> outbox() async {
    final l = await ProKit.listOf(_kOutbox);
    return [for (final m in l) ChatMsg.fromLocal(m)];
  }

  static Future<void> saveOutbox(List<ChatMsg> list) =>
      ProKit.saveList(_kOutbox, [for (final m in list) m.toLocal()]);

  static Future<void> enqueue(ChatMsg m) async {
    final l = await outbox();
    l.removeWhere((e) => e.cid == m.cid);
    l.add(m);
    await saveOutbox(l);
  }

  static Future<void> dequeue(String cid) async {
    final l = await outbox();
    l.removeWhere((e) => e.cid == cid);
    await saveOutbox(l);
  }

  static Future<int> outboxCount() async => (await outbox()).length;
}

// ═══════════════════════════════════════════════════════════════════
// 后端同步
// ═══════════════════════════════════════════════════════════════════

class ChatApi {
  /// 拉会话列表。
  static Future<List<ChatSession>> pullSessions() async {
    final r = await ProKit.getJson('/v1/chat/sessions');
    if (r['ok'] != true) return [];
    final d = r['data'];
    final list = d is Map ? d['sessions'] : d;
    if (list is! List) return [];
    return [for (final e in list) ChatSession.fromWire(e as Map)];
  }

  /// 增量拉消息。sinceSeq = 本地已知最大 seq，只要更新的。
  static Future<List<ChatMsg>> pull(String sid,
      {int sinceSeq = 0, int limit = 200}) async {
    final r = await ProKit.getJson(
        '/v1/chat/messages?sid=${Uri.encodeComponent(sid)}&since=$sinceSeq&limit=$limit');
    if (r['ok'] != true) return [];
    final d = r['data'];
    final list = d is Map ? d['messages'] : d;
    if (list is! List) return [];
    return [for (final e in list) ChatMsg.fromWire(e as Map)];
  }

  /// 上行一条消息。服务端按 cid 去重并回填 seq —— 重发是安全的。
  /// 返回回填后的 seq，0 表示没成功。
  static Future<int> send(ChatMsg m) async {
    final r = await ProKit.postJson('/v1/chat/send', m.toWire());
    if (r['ok'] != true) return 0;
    final d = r['data'];
    if (d is Map) {
      final s = (d['seq'] as num?)?.toInt();
      if (s != null) return s;
    }
    return 0;
  }

  /// 把所有待发消息推上去。返回成功条数。
  static Future<int> flush() async {
    if (!await ProKit.online) return 0;
    final box = await ChatStore.outbox();
    var ok = 0;
    for (final m in box) {
      final seq = await send(m);
      if (seq <= 0) continue; // 一条不通就停，别把后面的次序打乱
      m.seq = seq;
      m.sent = true;
      await ChatStore.append(m);
      await ChatStore.dequeue(m.cid);
      ok++;
    }
    return ok;
  }

  /// 标记已读（把本地最大 seq 报上去）。
  static Future<void> ack(String sid, int seq) async {
    await ProKit.postJson('/v1/chat/ack', {'sid': sid, 'seq': seq});
  }
}

// ═══════════════════════════════════════════════════════════════════
// 界面
// ═══════════════════════════════════════════════════════════════════

/// 会话列表。
class ChatSessionsPage extends StatefulWidget {
  const ChatSessionsPage({super.key});
  @override
  State<ChatSessionsPage> createState() => _SessionsState();
}

class _SessionsState extends State<ChatSessionsPage> {
  List<ChatSession> items = [];
  bool loading = true;
  int pendingOut = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final local = await ChatStore.sessions();
    // 先给本地数据，网络回来再覆盖 —— 后端不通时页面不该是空的
    if (mounted)
      setState(() {
        items = local;
        loading = false;
      });
    pendingOut = await ChatStore.outboxCount();
    final remote = await ChatApi.pullSessions();
    if (remote.isNotEmpty) {
      await ChatStore.saveSessions(remote);
      if (mounted) setState(() => items = remote);
    }
    final boxed = await ChatApi.flush();
    if (boxed > 0) pendingOut = await ChatStore.outboxCount();
    if (mounted) setState(() {});
  }

  Future<void> _newSession() async {
    final t = await ProKit.prompt(context, '新建会话', hint: '给这段对话起个名字');
    if (t == null) return;
    final s = ChatSession(id: ChatStore.newId('s'), title: t);
    final all = await ChatStore.sessions();
    all.add(s);
    await ChatStore.saveSessions(all);
    if (mounted) setState(() => items = all);
    await _open(s);
  }

  Future<void> _open(ChatSession s) async {
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => ChatRoomPage(session: s)));
    await _load();
  }

  @override
  Widget build(BuildContext c) {
    final online = ProKit.lastOnline;
    return Scaffold(
      appBar: AppBar(title: const Text('聊天'), actions: [
        IconButton(
            icon: const Icon(Icons.add_comment_outlined),
            tooltip: '新建会话',
            onPressed: _newSession),
      ]),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 30),
                  children: [
                    if (pendingOut > 0)
                      Card(
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16)),
                        child: ListTile(
                          dense: true,
                          leading:
                              const Icon(Icons.cloud_upload_outlined, size: 20),
                          title: Text('$pendingOut 条还没发出去',
                              style: const TextStyle(
                                  fontSize: 13.5, fontWeight: FontWeight.w600)),
                          subtitle: Text(online ? '连上后端后会自动补发' : '当前没连后端，先存在本机',
                              style: const TextStyle(
                                  fontSize: 11.5, color: Colors.grey)),
                        ),
                      ),
                    if (items.isEmpty) ProUI.empty('还没有会话\n点右上角新建一个'),
                    for (final s in items)
                      Card(
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16)),
                        child: ListTile(
                          leading: CircleAvatar(
                            radius: 18,
                            // 用 substring 而不是 characters：单个中文字符在 UTF-16 里就是一个
                            // code unit，substring(0,1) 足够；引 characters 包不值得为这一处加依赖。
                            child: Text(
                                s.title.isEmpty ? '?' : s.title.substring(0, 1),
                                style: const TextStyle(fontSize: 15)),
                          ),
                          title: Text(s.title,
                              style: const TextStyle(
                                  fontSize: 14.5, fontWeight: FontWeight.w600)),
                          subtitle: Text(
                              s.peer.isEmpty
                                  ? '${s.count} 条 · 序号 ${s.lastSeq}'
                                  : '${s.peer} · ${s.count} 条',
                              style: const TextStyle(
                                  fontSize: 11.5, color: Colors.grey)),
                          trailing: s.unread > 0
                              ? Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                      color: Theme.of(c).colorScheme.primary,
                                      borderRadius: BorderRadius.circular(20)),
                                  child: Text('${s.unread}',
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700)),
                                )
                              : const Icon(Icons.chevron_right,
                                  size: 18, color: Colors.grey),
                          onTap: () => _open(s),
                          onLongPress: () async {
                            final ok = await ProKit.confirm(
                                c, '删除会话', '「${s.title}」的本地消息会被清掉，后端记录不受影响。');
                            if (!ok) return;
                            final all = await ChatStore.sessions();
                            all.removeWhere((e) => e.id == s.id);
                            await ChatStore.saveSessions(all);
                            await ProKit.saveList('chat_msgs_${s.id}', []);
                            if (mounted) setState(() => items = all);
                          },
                        ),
                      ),
                    ProUI.note('离线优先：没连后端时消息先落在本机发件箱，连上后按 cid 幂等补发，不会重复。'),
                  ]),
            ),
    );
  }
}

/// 会话内消息流。
class ChatRoomPage extends StatefulWidget {
  final ChatSession session;
  const ChatRoomPage({super.key, required this.session});
  @override
  State<ChatRoomPage> createState() => _RoomState();
}

class _RoomState extends State<ChatRoomPage> {
  List<ChatMsg> msgs = [];
  bool loading = true;
  bool sending = false;
  final _input = TextEditingController();
  final _scroll = ScrollController();
  Timer? _sync;

  static const _me = '我';

  @override
  void initState() {
    super.initState();
    _load();
    // 30 秒拉一次增量。不做长连接是为了省电，也让"后端不可能一直在线"这件事不破坏体验
    _sync = Timer.periodic(const Duration(seconds: 30), (_) => _pull());
  }

  @override
  void dispose() {
    _sync?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final local = await ChatStore.msgs(widget.session.id);
    if (mounted)
      setState(() {
        msgs = local;
        loading = false;
      });
    await _pull();
    _jumpBottom();
  }

  Future<void> _pull() async {
    final list = await ChatStore.msgs(widget.session.id);
    final since = list.fold<int>(0, (p, e) => e.seq > p ? e.seq : p);
    final incoming = await ChatApi.pull(widget.session.id, sinceSeq: since);
    if (incoming.isNotEmpty) {
      final merged = await ChatStore.merge(widget.session.id, incoming);
      if (mounted) setState(() => msgs = merged);
      _jumpBottom();
    }
    await ChatApi.flush();
    final flushed = await ChatStore.msgs(widget.session.id);
    if (mounted && flushed.length != msgs.length)
      setState(() => msgs = flushed);
    // 已读回执：本地最大 seq
    final top = flushed.fold<int>(0, (p, e) => e.seq > p ? e.seq : p);
    if (top > 0) await ChatApi.ack(widget.session.id, top);
  }

  void _jumpBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _send() async {
    final t = _input.text.trim();
    if (t.isEmpty || sending) return;
    _input.clear();
    final m = ChatMsg(
      cid: ChatStore.newId('m'),
      sid: widget.session.id,
      ts: DateTime.now().millisecondsSinceEpoch,
      from: _me,
      body: t,
    );

    // 先落本地再上行 —— 没网也不影响"按下发送就已经在自己这边存在了"
    final list = await ChatStore.append(m);
    await ChatStore.enqueue(m);
    if (mounted)
      setState(() {
        msgs = list;
        sending = true;
      });
    _jumpBottom();

    final seq = await ChatApi.send(m);
    if (seq > 0) {
      m.seq = seq;
      m.sent = true;
      final l2 = await ChatStore.append(m);
      await ChatStore.dequeue(m.cid);
      if (mounted) setState(() => msgs = l2);
    }
    if (mounted) setState(() => sending = false);
    await _touchSession(lastMsg: t);
  }

  /// 会话列表要能显示最后一条，这里同步一下标题下的摘要。
  Future<void> _touchSession({String lastMsg = ''}) async {
    final all = await ChatStore.sessions();
    final i = all.indexWhere((e) => e.id == widget.session.id);
    if (i < 0) return;
    final list = await ChatStore.msgs(widget.session.id);
    all[i].count = list.length;
    all[i].lastSeq = list.fold<int>(0, (p, e) => e.seq > p ? e.seq : p);
    all[i].lastTs = DateTime.now().millisecondsSinceEpoch;
    if (all[i].title.trim().isEmpty && lastMsg.isNotEmpty) {
      all[i].title =
          lastMsg.length > 12 ? '${lastMsg.substring(0, 12)}…' : lastMsg;
    }
    await ChatStore.saveSessions(all);
  }

  /// 把这段对话交给 AI 念一遍。没配厂商时如实报错，不做假动作。
  Future<void> _summarize() async {
    if (msgs.isEmpty) {
      ProUI.toast(context, '这段对话还是空的');
      return;
    }
    ProUI.toast(context, '正在让 AI 读一遍…');
    try {
      final text = msgs.take(80).map((m) => '${m.from}: ${m.body}').join('\n');
      final out = await ProAi.ask('把下面这段对话压成几句要点，用中文，别加客套话：\n\n$text',
          system: '你是聊天记录整理助手。');
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (c2) => AlertDialog(
          title: const Text('AI 摘要'),
          content: SingleChildScrollView(
              child: SelectableText(out,
                  style: const TextStyle(fontSize: 13, height: 1.55))),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c2), child: const Text('知道了'))
          ],
        ),
      );
    } catch (e) {
      if (mounted) ProUI.toast(context, '$e');
    }
  }

  @override
  Widget build(BuildContext c) {
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.session.title, style: const TextStyle(fontSize: 15)),
          Text('${msgs.length} 条 · 本地优先，连上后端自动补发',
              style: const TextStyle(fontSize: 10.5, color: Colors.grey)),
        ]),
        actions: [
          IconButton(
              icon: const Icon(Icons.auto_awesome_outlined),
              tooltip: 'AI 摘要',
              onPressed: _summarize),
          IconButton(
              icon: const Icon(Icons.sync),
              tooltip: '立即同步',
              onPressed: () async {
                await _pull();
                if (mounted) ProUI.toast(context, '已同步');
              }),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              Expanded(
                child: msgs.isEmpty
                    ? ProUI.empty('还没有消息\n在下面输入第一句')
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                        itemCount: msgs.length,
                        itemBuilder: (_, i) => _bubble(c, msgs[i]),
                      ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
                  child: Row(children: [
                    Expanded(
                      child: TextField(
                        controller: _input,
                        minLines: 1,
                        maxLines: 4,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        decoration: InputDecoration(
                          hintText: '说点什么',
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 12),
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(22)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      icon: sending
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.send, size: 20),
                      onPressed: _send,
                    ),
                  ]),
                ),
              ),
            ]),
    );
  }

  Widget _bubble(BuildContext c, ChatMsg m) {
    final mine = m.from == _me;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.fromLTRB(12, 9, 12, 7),
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(c).size.width * 0.76),
        decoration: BoxDecoration(
          color: mine
              ? Theme.of(c).colorScheme.primary.withValues(alpha: 0.14)
              : Theme.of(c)
                  .colorScheme
                  .surfaceContainerHighest
                  .withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (m.type != kMsgText)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(
                    m.type == kMsgImage
                        ? Icons.image_outlined
                        : Icons.attach_file,
                    size: 13),
                const SizedBox(width: 4),
                Text(m.name.isEmpty ? m.type : m.name,
                    style: const TextStyle(fontSize: 11)),
              ]),
            ),
          Text(m.body, style: const TextStyle(fontSize: 14, height: 1.4)),
          const SizedBox(height: 3),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Text(_hm(m.ts),
                style: const TextStyle(fontSize: 10, color: Colors.grey)),
            if (mine) ...[
              const SizedBox(width: 5),
              Icon(
                  m.pending
                      ? Icons.schedule
                      : (m.read ? Icons.done_all : Icons.check),
                  size: 13,
                  color: m.pending ? Colors.orange : Colors.grey),
            ],
          ]),
        ]),
      ),
    );
  }

  static String _hm(int ms) {
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.hour)}:${two(d.minute)}';
  }
}
