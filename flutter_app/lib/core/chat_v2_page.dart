// ThirdHub v4 聊天模块 —— 全屏版（D-F2 / D-F3 / D-F4 落地）
//
// 协议：`docs/LANCHAT-PROTOCOL.md`（局域网）与 `docs/CHAT-PROTOCOL.md`（后端）。
// 本次「大改」把原来两个互不相干的半成品合成一个入口：
//   · 旧 `ChatPage`（lab_social.dart）只有一条群发流、没有身份、没有文件、
//     没有加密，且 UI 是塞在模块 body 里的一列 —— 现在换成 [ChatHomePage]。
//   · 旧 `ChatSessionsPage`（chat.dart）是后端 CHAT/1 的会话列表，保留，
//     作为本页「会话」tab 的一部分呈现。
//
// ★ 三条不动的底线（跟协议文档对齐）：
//   1) 发现 ≠ 信任：能看见邻居只代表同一网段，不代表可以发消息；加好友必须
//      核对指纹，收文件必须用户点「接收」。所以"好友"与"在线设备"是两个区段。
//   2) 降级必须说明：明文发送时要把原因写在界面上（STYLE_GUIDE 第 2 条三段式）。
//   3) 动画不改真实位置：滑动删除只在动画走完后才真正撤回。
//
// 本文件刻意**不使用 tr()**：i18n 闸门要求每个 key 在 7 种语言里都有译文，
// 而本模块文案还在快速迭代。等文案稳定后再统一抽 key，避免现在就把半成品
// 词汇锁进 7 份字典（这也是 `chat.dart` 的既有做法）。
import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import 'app_bridge.dart';
import 'voice_msg.dart';
import 'chat.dart' show ChatApi, ChatRoomPage, ChatSession, ChatStore;
import 'chat_crypto.dart';
import 'chat_logic.dart';
import 'lab_logic.dart' show kLanPort;
import 'lan_chat.dart';
import 'motion.dart';
import 'pro_kit.dart';

// ═══════════════════════════════════════════════════════════════════════════
// 引擎初始化（幂等）
// ═══════════════════════════════════════════════════════════════════════════

Future<void>? _hubInit;

/// 初始化 [ChatHub] 并注入持久化回调。多次调用只真正跑一次。
///
/// 为什么要单独的顶层函数：路由被推入/弹出、tab 来回切，都会重新进
/// `initState`；而 UDP 端口只能绑一次，重复 `start()` 会报"地址已占用"。
Future<void> ensureLanChat() => _hubInit ??= () async {
      final p = await ProKit.prefs();
      await ChatHub.instance.init(
        loadFn: (k) async => p.getString(k),
        saveFn: (k, v) async => p.setString(k, v),
      );
    }();

/// 收到文件后统一的落盘目录。
Future<Directory> _recvDir() async {
  final d = await getApplicationDocumentsDirectory();
  final dir = Directory('${d.path}/ThirdHub/Recv');
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

/// 三段式错误提示（STYLE_GUIDE 第 2 条：现象 / 原因 / 怎么办）。
String _err3(String what, String why, String how) => '现象：$what。原因：$why。怎么办：$how。';

// ═══════════════════════════════════════════════════════════════════════════
// 引擎 tick → setState 的桥
// ═══════════════════════════════════════════════════════════════════════════

/// [ChatHub.tick] 是零 Flutter 依赖的替身（不是 `ValueListenable`），
/// 所以不能用 `ValueListenableBuilder`，只能手工订阅。
mixin _LanTickMixin<T extends StatefulWidget> on State<T> {
  @override
  void initState() {
    super.initState();
    ChatHub.instance.tick.addListener(_onLanTick);
  }

  void _onLanTick() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    ChatHub.instance.tick.removeListener(_onLanTick);
    super.dispose();
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 主页面
// ═══════════════════════════════════════════════════════════════════════════

class ChatHomePage extends StatefulWidget {
  const ChatHomePage({super.key});
  @override
  State<ChatHomePage> createState() => _ChatHomeState();
}

class _ChatHomeState extends State<ChatHomePage>
    with SingleTickerProviderStateMixin, _LanTickMixin {
  late final TabController _tab =
      TabController(length: 2, vsync: this)..addListener(_onTab);

  bool _ready = false;
  Offset _orbPos = const Offset(-1, -1); // dy < 0 = 尚未定位

  @override
  void dispose() {
    _tab.removeListener(_onTab);
    _tab.dispose();
    super.dispose();
  }

  void _onTab() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    ensureLanChat().then((_) async {
      final h = ChatHub.instance;
      await h.start();
      if (!mounted) return;
      setState(() => _ready = true);
    });
  }

  // ── 悬浮球菜单（交互动效 ⑪ 扇形展开，ThirdHub 专属） ──

  Future<void> _onOrbPick(int i) async {
    final h = ChatHub.instance;
    switch (i) {
      case 0:
        _tab.animateTo(0);
        break;
      case 1:
        _tab.animateTo(1);
        break;
      case 2:
        await showModalBottomSheet(
            context: context,
            showDragHandle: true,
            builder: (_) => const _DeviceSheet());
        break;
      case 3:
        await _showAddress();
        break;
      case 4:
        final ok = await ProKit.confirm(context, '清空局域网记录',
            '本机保存的局域网消息会被清掉，好友与身份密钥保留。对方设备上的记录不受影响。');
        if (!ok) return;
        await h.clearMessages();
        break;
    }
  }

  Future<void> _showAddress() async {
    final h = ChatHub.instance;
    final ip = await lanAddress();
    if (!mounted) return;
    if (ip.isEmpty) {
      ProUI.toast(
          context,
          _err3('没找到局域网地址', '本机没有可用的内网网卡，可能未连 WiFi 或只开了数据网络',
              '先连上同一个 WiFi 再试'));
      return;
    }
    ProUI.toast(context, '我的局域网地址 $ip · 端口 $kLanPort · 指纹 ${h.fingerprint}');
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return Scaffold(
        appBar: AppBar(title: const Text('聊天'), actions: [_menu()]),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final size = MediaQuery.of(context).size;
    if (_orbPos.dy < 0) {
      _orbPos = Offset(size.width - 62, size.height - 230);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('聊天'),
        actions: [_menu()],
        bottom: TabBar(controller: _tab, tabs: const [
          Tab(icon: Icon(Icons.forum_outlined), text: '会话'),
          Tab(icon: Icon(Icons.campaign_outlined), text: '区域频道'),
        ]),
      ),
      body: Stack(children: [
        TabBarView(controller: _tab, children: const [
          _SessionsTab(),
          _BroadcastRoom(),
        ]),
        FanMenuOrb(
          items: [
            FanItem(Icons.forum_outlined, '会话', active: _tab.index == 0),
            FanItem(Icons.campaign_outlined, '区域频道', active: _tab.index == 1),
            const FanItem(Icons.badge_outlined, '我的设备'),
            const FanItem(Icons.lan_outlined, '我的地址'),
            const FanItem(Icons.cleaning_services_outlined, '清空记录'),
          ],
          onPick: _onOrbPick,
          initialPosition: _orbPos,
          onMoved: (p) => _orbPos = p,
        ),
      ]),
    );
  }

  /// 三点菜单 = 「退出全屏」入口（D-F2）。本页是独立路由，退出全屏即返回。
  Widget _menu() => PopupMenuButton<String>(
        tooltip: '更多',
        onSelected: (v) async {
          switch (v) {
            case 'exit':
              if (mounted) Navigator.of(context).maybePop();
              break;
            case 'device':
              await showModalBottomSheet(
                  context: context,
                  showDragHandle: true,
                  builder: (_) => const _DeviceSheet());
              break;
            case 'addr':
              await _showAddress();
              break;
            case 'toggle':
              await (ChatHub.instance.running
                  ? ChatHub.instance.stop()
                  : ChatHub.instance.start());
              if (mounted) setState(() {});
              break;
          }
        },
        itemBuilder: (c) => [
          const PopupMenuItem(
              value: 'exit',
              child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.fullscreen_exit),
                  title: Text('退出全屏'))),
          const PopupMenuItem(
              value: 'device',
              child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.badge_outlined),
                  title: Text('我的设备与指纹'))),
          const PopupMenuItem(
              value: 'addr',
              child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.lan_outlined),
                  title: Text('我的局域网地址'))),
          PopupMenuItem(
              value: 'toggle',
              child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.wifi_off_outlined),
                  title: Text(
                      ChatHub.instance.running ? '暂停局域网发现' : '开启局域网发现'))),
        ],
      );
}

/// 分区标题。
class _SectionTitle extends StatelessWidget {
  final String text;
  final IconData icon;
  const _SectionTitle(this.text, this.icon);
  @override
  Widget build(BuildContext c) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 14, 2, 6),
        child: Row(children: [
          Icon(icon, size: 16, color: Theme.of(c).colorScheme.primary),
          const SizedBox(width: 6),
          Text(text,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
        ]),
      );
}

// ═══════════════════════════════════════════════════════════════════════════
// Tab 1 · 会话（好友 + 在线设备 + 后端会话）
// ═══════════════════════════════════════════════════════════════════════════

class _SessionsTab extends StatefulWidget {
  const _SessionsTab();
  @override
  State<_SessionsTab> createState() => _SessionsTabState();
}

class _SessionsTabState extends State<_SessionsTab> with _LanTickMixin {
  List<ChatSession> _sessions = [];
  bool _loading = true;
  int _pendingOut = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final local = await ChatStore.sessions();
    if (mounted) {
      setState(() {
        _sessions = local;
        _loading = false;
      });
    }
    _pendingOut = await ChatStore.outboxCount();
    final r = await ChatApi.pullSessions();
    if (r.isNotEmpty) {
      await ChatStore.saveSessions(r);
      if (mounted) setState(() => _sessions = r);
    }
    await ChatApi.flush();
    _pendingOut = await ChatStore.outboxCount();
    if (mounted) setState(() {});
  }

  Future<void> _newSession() async {
    final name = await ProKit.prompt(context, '新建会话', hint: '给这段对话起个名字');
    if (name == null) return;
    final all = await ChatStore.sessions();
    all.add(ChatSession(id: ChatStore.newId('s'), title: name));
    await ChatStore.saveSessions(all);
    if (mounted) setState(() => _sessions = all);
    await _load();
  }

  @override
  Widget build(BuildContext c) {
    final h = ChatHub.instance;
    final onlineIds = {for (final p in h.peers) p.id};
    final friends = [...h.friends]..sort((a, b) {
        final ao = onlineIds.contains(a.id) ? 0 : 1;
        final bo = onlineIds.contains(b.id) ? 0 : 1;
        if (ao != bo) return ao - bo;
        return b.lastSeen.compareTo(a.lastSeen);
      });
    final strangers =
        h.peers.where((p) => !h.friends.any((f) => f.id == p.id)).toList();
    final inbox = [...h.fileInbox];

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 130),
        children: [
          _meCard(h),
          if (!h.running && h.lastError.isNotEmpty)
            ProUI.note(h.lastError, icon: Icons.error_outline),
          if (inbox.isNotEmpty) ...[
            const _SectionTitle('待接收文件', Icons.download_outlined),
            for (final o in inbox)
              _InboxTile(offer: o, onDone: () => setState(() {})),
          ],
          if (_pendingOut > 0)
            ProUI.note('后端有 $_pendingOut 条消息尚未送达，连上家庭后端后会自动补发。'),
          const _SectionTitle('局域网好友', Icons.people_outline),
          if (friends.isEmpty)
            ProUI.note('还没有好友。先从下面的「在线设备」里认一台，跟对方核对指纹后再保存。')
          else
            for (final f in friends)
              _peerTile(
                c,
                id: f.id,
                name: f.name,
                subtitle: onlineIds.contains(f.id)
                    ? '在线 · ${f.host}'
                    : '离线 · 最近 ${_ago(f.lastSeen)}',
                online: onlineIds.contains(f.id),
                fp: f.fp,
                friend: true,
              ),
          if (strangers.isNotEmpty) ...[
            const _SectionTitle('在线设备（未加好友）', Icons.wifi_tethering),
            for (final p in strangers)
              _peerTile(
                c,
                id: p.id,
                name: p.name,
                subtitle: '${p.host} · 尚未核对身份',
                online: true,
                fp: h.peerFp[p.id] ?? '',
                friend: false,
              ),
          ],
          const _SectionTitle('家庭后端会话', Icons.cloud_outlined),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
                onPressed: _newSession,
                icon: const Icon(Icons.add_comment_outlined, size: 18),
                label: const Text('新建会话')),
          ),
          if (_loading)
            const Padding(
                padding: EdgeInsets.all(12),
                child: Center(child: CircularProgressIndicator()))
          else if (_sessions.isEmpty)
            ProUI.note('后端会话为空。局域网内不需要后端也能聊 —— 切到「区域频道」试试。')
          else
            for (final s in _sessions)
              Card(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                child: ListTile(
                  leading: CircleAvatar(
                      radius: 18,
                      child: Text(
                          s.title.isEmpty ? '?' : s.title.substring(0, 1),
                          style: const TextStyle(fontSize: 15))),
                  title: Text(s.title,
                      style: const TextStyle(
                          fontSize: 14.5, fontWeight: FontWeight.w600)),
                  subtitle: Text(
                      s.peer.isEmpty
                          ? '${s.count} 条 · 序号 ${s.lastSeq}'
                          : '${s.peer} · ${s.count} 条',
                      style:
                          const TextStyle(fontSize: 11.5, color: Colors.grey)),
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
                                  fontWeight: FontWeight.w700)))
                      : const Icon(Icons.chevron_right,
                          size: 18, color: Colors.grey),
                  onTap: () async {
                    await Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => ChatRoomPage(session: s)));
                    await _load();
                  },
                  onLongPress: () async {
                    final ok = await ProKit.confirm(context, '删除会话',
                        '「${s.title}」的本地消息会被清掉，后端记录不受影响。');
                    if (!ok) return;
                    final all = await ChatStore.sessions();
                    all.removeWhere((e) => e.id == s.id);
                    await ChatStore.saveSessions(all);
                    await ProKit.saveList('chat_msgs_${s.id}', []);
                    if (mounted) setState(() => _sessions = all);
                  },
                ),
              ),
        ],
      ),
    );
  }

  Widget _peerTile(BuildContext c,
      {required String id,
      required String name,
      required String subtitle,
      required bool online,
      required String fp,
      required bool friend}) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        leading: Stack(children: [
          CircleAvatar(
              radius: 18,
              child: Icon(friend ? Icons.person : Icons.devices, size: 18)),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: online ? Colors.green : Colors.grey,
                border: Border.all(
                    color: Theme.of(c).colorScheme.surface, width: 1.5),
              ),
            ),
          ),
        ]),
        title: Text(name,
            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle,
            style: const TextStyle(fontSize: 11.5, color: Colors.grey)),
        trailing: friend
            ? IconButton(
                icon: const Icon(Icons.more_vert, size: 20),
                onPressed: () => _friendMenu(id, fp),
              )
            : TextButton(
                onPressed: () => _addFriend(id, name, fp),
                child: const Text('加好友', style: TextStyle(fontSize: 12.5)),
              ),
        onTap: () async {
          await Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => LanRoomPage(
                      peerId: id, title: name, offline: !online)));
          if (mounted) setState(() {});
        },
      ),
    );
  }

  /// 认领一台设备为好友。**必须把指纹摆在最显眼处** —— 名字谁都能改，指纹不能。
  Future<void> _addFriend(String id, String name, String fp) async {
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('核对身份'),
        content: SingleChildScrollView(
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('设备「$name」'),
                const SizedBox(height: 10),
                const Text('公钥指纹（16 位十六进制）',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 4),
                SelectableText(fp.isEmpty ? '（还没收到，等一次设备发现再来）' : fp,
                    style: const TextStyle(
                        fontSize: 15,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),
                Text(
                  '对着对方设备上显示的同一串字符逐一核对。名字可以随便改，'
                  '这串指纹跟着设备的身份密钥走，改不了。',
                  style: TextStyle(
                      fontSize: 12, color: Colors.grey.shade700, height: 1.5),
                ),
              ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d, false), child: const Text('取消')),
          FilledButton(
              onPressed: fp.isEmpty ? null : () => Navigator.pop(d, true),
              child: const Text('指纹一致，保存')),
        ],
      ),
    );
    if (ok != true) return;
    final h = ChatHub.instance;
    final host = h.peers.where((p) => p.id == id).firstOrNull?.host ?? '';
    await h.addFriend(id, name, host, fp: fp);
  }

  Future<void> _friendMenu(String id, String fp) async {
    final h = ChatHub.instance;
    final act = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
              leading: const Icon(Icons.fingerprint),
              title: const Text('公钥指纹'),
              subtitle: Text(fp.isEmpty ? '—' : fp),
              onTap: () => Navigator.pop(sheetCtx, 'fp')),
          ListTile(
              leading: const Icon(Icons.link_off),
              title: const Text('移除好友（保留聊天记录）'),
              onTap: () => Navigator.pop(sheetCtx, 'del')),
        ]),
      ),
    );
    if (act == 'del') {
      await h.removeFriend(id);
    } else if (act == 'fp' && mounted) {
      ProUI.toast(context, '公钥指纹：${fp.isEmpty ? '—' : fp}');
    }
  }

  Widget _meCard(ChatHub h) {
    final col = Theme.of(context).colorScheme;
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: AnimatedDisclosure(
        // ⑤ 文本展开：默认收起，点开才露出身份细节
        title: h.running ? '局域网已开启 · 我是 ${h.name}' : '局域网未开启',
        initiallyOpen: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.wifi_tethering,
                  size: 18, color: h.running ? Colors.green : Colors.grey),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(
                      h.running ? '每 5 秒广播一次 · 端口 $kLanPort' : '点右侧按钮开启',
                      style: const TextStyle(fontSize: 12))),
              TextButton(
                  onPressed: () async {
                    await (h.running ? h.stop() : h.start());
                    if (mounted) setState(() {});
                  },
                  child: Text(h.running ? '关闭' : '开启')),
            ]),
            const SizedBox(height: 6),
            const Text('我的设备指纹（给对方核对用）',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 2),
            SelectableText(h.fingerprint.isEmpty ? '生成中…' : h.fingerprint,
                style: const TextStyle(
                    fontSize: 15,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 6, children: [
              ActionChip(
                  avatar: const Icon(Icons.badge_outlined, size: 16),
                  label: const Text('改昵称', style: TextStyle(fontSize: 12)),
                  onPressed: () => _rename(h)),
            ]),
            const SizedBox(height: 6),
            Text(
              '同一 WiFi 下的 ThirdHub 会自动互相发现，不经过任何服务器。'
              '发现只代表同一网段；对方不在线上时消息发不出去。',
              style: TextStyle(
                  fontSize: 11, color: Colors.grey.shade600, height: 1.5),
            ),
            if (h.running)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('本机在局域网内可见，同网段设备都能看到「${h.name}」',
                    style: TextStyle(fontSize: 11, color: col.primary)),
              ),
          ]),
        ),
      ),
    );
  }

  Future<void> _rename(ChatHub h) async {
    final v = await ProKit.prompt(context, '设备昵称', hint: '例如：客厅平板', init: h.name);
    if (v == null) return;
    await h.setName(v);
  }

  static String _ago(int ms) {
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    if (d.inDays < 1) return '${d.inHours} 小时前';
    return '${d.inDays} 天前';
  }
}

/// 待接收的文件要约卡片。
class _InboxTile extends StatefulWidget {
  final ChatFileOffer offer;
  final VoidCallback onDone;
  const _InboxTile({required this.offer, required this.onDone});
  @override
  State<_InboxTile> createState() => _InboxTileState();
}

class _InboxTileState extends State<_InboxTile> {
  bool _busy = false;
  String _err = '';

  Future<void> _accept() async {
    setState(() {
      _busy = true;
      _err = '';
    });
    final dir = await _recvDir();
    final save = '${dir.path}/${widget.offer.fileName}';
    final (path, err) = await ChatHub.instance.fetchOffer(widget.offer, save);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _err = err ?? '';
    });
    if (path != null) {
      ChatHub.instance.fileAckOk(widget.offer, path);
      ChatHub.instance.fileInbox.remove(widget.offer);
      widget.onDone();
      if (!mounted) return;
      ProUI.toast(context, '已保存到 $path');
    }
  }

  @override
  Widget build(BuildContext c) {
    final o = widget.offer;
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        leading: Icon(o.isImage
            ? Icons.image_outlined
            : o.isVideo
                ? Icons.movie_outlined
                : Icons.insert_drive_file_outlined),
        title: Text(o.fileName,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        subtitle: Text(
            '来自 ${o.peerName} · ${o.size < 0 ? '大小未知' : fmtBytes(o.size)}'
            '${_err.isEmpty ? '' : '\n$_err'}',
            style: TextStyle(
                fontSize: 11.5,
                color: _err.isEmpty ? Colors.grey : Colors.red,
                height: 1.4)),
        trailing: _busy
            ? const SizedBox(
                width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : TextButton(onPressed: _accept, child: const Text('接收')),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Tab 2 · 区域频道（广播）
// ═══════════════════════════════════════════════════════════════════════════

class _BroadcastRoom extends StatefulWidget {
  const _BroadcastRoom();
  @override
  State<_BroadcastRoom> createState() => _BroadcastRoomState();
}

class _BroadcastRoomState extends State<_BroadcastRoom> with _LanTickMixin {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  Timer? _typingThrottle;

  @override
  void dispose() {
    _typingThrottle?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _jump() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    final plan = await ChatHub.instance.sendText(text);
    _jump();
    if (!mounted) return;
    // 降级必须说明（STYLE_GUIDE 第 2 条）
    if (plan.reason != null) ProUI.toast(context, plan.reason!);
  }

  Future<void> _recall(LanMessage2 m) async {
    final ok = await ProKit.confirm(context, '撤回这条消息？',
        '只对 5 分钟内、且是你自己发的消息有效。已经在对方设备上落地的内容不保证收回。');
    if (!ok) return;
    await ChatHub.instance.recall(m.mid, to: null);
  }

  @override
  Widget build(BuildContext c) {
    final h = ChatHub.instance;
    final msgs = h.messagesOf(null);
    final typing = h.typingPeers.keys
        .map((k) => h.peers.where((p) => p.id == k).firstOrNull?.name ?? k)
        .toList();

    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: ProUI.note(
          '区域频道是广播：同一 WiFi 下所有 ThirdHub 都看得到，所以不加密。要私聊请从「会话」进好友。',
          icon: Icons.campaign_outlined,
        ),
      ),
      Expanded(
        child: msgs.isEmpty
            ? Center(
                child: Text('还没有人说话。让另一台设备也打开这个页面。',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600)))
            : ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                itemCount: msgs.length,
                itemBuilder: (c, i) =>
                    _Bubble(msg: msgs[i], onRecall: _recall),
              ),
      ),
      if (typing.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(left: 16, bottom: 4),
          child: Align(
              alignment: Alignment.centerLeft,
              child: Text('${typing.join("、")} 正在输入…',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600))),
        ),
      _Composer(
        controller: _input,
        hint: '对同一 WiFi 下的所有设备说点什么',
        onSend: _send,
        onTyping: () {
          // 节流：2 秒最多播一次"正在输入"，否则每敲一个字都发一个包
          if (_typingThrottle?.isActive ?? false) return;
          _typingThrottle = Timer(const Duration(seconds: 2), () {});
          ChatHub.instance.sendTyping(null);
        },
      ),
    ]);
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 私聊室
// ═══════════════════════════════════════════════════════════════════════════

class LanRoomPage extends StatefulWidget {
  final String peerId;
  final String title;
  final bool offline;
  const LanRoomPage(
      {super.key,
      required this.peerId,
      required this.title,
      this.offline = false});
  @override
  State<LanRoomPage> createState() => _LanRoomState();
}

class _LanRoomState extends State<LanRoomPage> with _LanTickMixin {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  Timer? _typingThrottle;

  @override
  void dispose() {
    _typingThrottle?.cancel();
    _vrec.dispose(); // 录音器持有麦克风，离开会话必须放掉
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _jump() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    final plan = await ChatHub.instance.sendText(text, to: widget.peerId);
    _jump();
    if (!mounted) return;
    if (plan.reason != null) ProUI.toast(context, plan.reason!);
  }

  Future<void> _poke() async {
    await ChatHub.instance
        .sendText('戳一戳', to: widget.peerId, kind: ChatKind.poke);
    _jump();
  }

  Future<void> _sendFile({required bool imagesOnly}) async {
    final r = await FilePicker.platform
        .pickFiles(type: imagesOnly ? FileType.image : FileType.any);
    final path = r?.files.single.path;
    if (path == null) return;
    final err = await ChatHub.instance.sendFile(path, to: widget.peerId);
    _jump();
    if (!mounted) return;
    if (err != null) {
      ProUI.toast(context, _err3('文件没能发出去', err, '确认两台设备连的是同一个 WiFi，然后重试'));
    } else {
      ProUI.toast(context, '已发起传输，等对方点「接收」。');
    }
  }

  /// 发送应用：挑一个本机已安装的 App，把它的安装包（APK）直接发过去。
  ///
  /// 用户需求(2026-10-01)：「像 QQ 那样可以提取应用然后发送 APK」。
  /// 传输完全复用 `file` 那套（offer / token / 回执 / 断点信息），
  /// 只是把种类标成 `ChatKind.app`，好让两端都显示成「应用」而不是普通文件。
  /// 对方接收后点开即触发系统安装流程（应用内已声明 REQUEST_INSTALL_PACKAGES）。
  Future<void> _sendApp() async {
    if (!AppBridge.supported) {
      ProUI.toast(context, '只有安卓端支持提取应用安装包，当前平台用不了这个功能。');
      return;
    }
    final app = await Navigator.push<InstalledApp>(
        context, MaterialPageRoute(builder: (_) => const AppPickerPage()));
    if (app == null || !mounted) return;
    final err = await ChatHub.instance
        .sendFile(app.path, to: widget.peerId, kind: ChatKind.app);
    _jump();
    if (!mounted) return;
    if (err != null) {
      ProUI.toast(context,
          _err3('应用没能发出去', err, '确认两台设备连的是同一个 WiFi，然后重试'));
    } else {
      ProUI.toast(context, '已发起传输，等对方点「接收」后即可安装。');
    }
  }

  /// 把对方发来的附件拉到本机，返回本地路径；已在本机则直接返回。
  ///
  /// 拆出来是为了让「打开文件」与「播放语音」共用同一条下载链路 ——
  /// 语音本质上也是文件消息，只是点开的方式不同（播放而不是交给系统）。
  Future<String?> _fetchLocal(LanMessage2 m) async {
    final meta = m.file;
    if (meta == null) return null;

    final local = '${meta['path'] ?? ''}';
    if (local.isNotEmpty && await File(local).exists()) return local;

    // 对方发来的：先从对方的临时 HTTP 服务上下下来
    final offer = ChatFileOffer(
        peerId: m.from,
        peerName: m.fromName,
        meta: meta,
        host: '${meta['host'] ?? ''}');
    if (!mounted) return null;
    ProUI.toast(context, '正在从对方下载…');
    final dir = await _recvDir();
    final (path, err) =
        await ChatHub.instance.fetchOffer(offer, '${dir.path}/${offer.fileName}');
    if (path == null) return null;
    ChatHub.instance.fileAckOk(offer, path); // 只是回一个回执包，同步发出，不必 await
    await ChatHub.instance.attachLocalPath(m.mid, path);
    return path;
  }

  /// 打开文件气泡：本机有的直接开；对方发来的先下载再开。
  Future<void> _open(LanMessage2 m) async {
    final meta = m.file;
    if (meta == null) return;

    final local = '${meta['path'] ?? ''}';
    if (local.isNotEmpty && !await File(local).exists()) {
      if (!mounted) return;
      ProUI.toast(context, _err3('文件打不开', '它已被移动或删除', '让对方重发一次'));
      return;
    }
    final path = await _fetchLocal(m);
    if (!mounted) return;
    if (path == null) {
      ProUI.toast(context, _err3('文件没能拿到', '未知原因', '确认两台设备仍在同一 WiFi 下，再点一次'));
      return;
    }
    await OpenFilex.open(path);
  }

  /// 语音消息：按住说话，松手发出去（走同一条文件传输链路，只是种类标成 voice）。
  final _vrec = VoiceRec();
  bool _recOn = false;

  Future<void> _voiceStart() async {
    final ok = await _vrec.start();
    if (!mounted) return;
    if (!ok) {
      ProUI.toast(context, '需要麦克风权限才能发语音，请在系统设置里放行后重试。');
      return;
    }
    setState(() => _recOn = true);
  }

  Future<void> _voiceStop() async {
    if (!_recOn) return;
    final (path, secs) = await _vrec.stop();
    if (!mounted) return;
    setState(() => _recOn = false);
    if (path == null) {
      ProUI.toast(context, '这次录音没存下来，再试一次');
      return;
    }
    // 太短的几乎都是误触，发出去只会让对方点开是空的
    if (secs < 1) {
      await _vrec.cancel();
      ProUI.toast(context, '说话时间太短，没有发出去');
      return;
    }
    final err = await ChatHub.instance
        .sendFile(path, to: widget.peerId, kind: ChatKind.voice, secs: secs);
    _jump();
    if (!mounted) return;
    if (err != null) {
      ProUI.toast(
          context, _err3('语音没能发出去', err, '确认两台设备连的是同一个 WiFi，然后重试'));
    }
  }

  @override
  Widget build(BuildContext c) {
    final h = ChatHub.instance;
    final msgs = h.messagesOf(widget.peerId);
    final online = h.peers.any((p) => p.id == widget.peerId);
    final caps = h.peerCaps[widget.peerId];
    final encOk = caps?.enc == true && h.peerKeys.containsKey(widget.peerId);
    final fp = h.peerFp[widget.peerId] ?? '';

    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.title, style: const TextStyle(fontSize: 16)),
          Text(online ? '在线' : '离线 · 消息要等对方上线',
              style: const TextStyle(fontSize: 11)),
        ]),
        actions: [
          IconButton(
              tooltip: '戳一戳',
              onPressed: _poke,
              icon: const Icon(Icons.touch_app_outlined)),
          IconButton(
              tooltip: '对方指纹',
              onPressed: () async {
                // 优先用对方**自己声明**的指纹；万一报文里没带（旧版），
                // 就用收到的公钥本地现算——两边算的是同一条 SHA-256。
                var f = fp;
                if (f.isEmpty) {
                  final pk = h.peerKeys[widget.peerId];
                  if (pk != null) f = await fingerprintOfPeer(pk);
                }
                if (!mounted) return;
                ProUI.toast(context, '对方公钥指纹：${f.isEmpty ? '还没收到' : f}');
              },
              icon: const Icon(Icons.fingerprint)),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: ProUI.note(
            encOk
                ? '端到端加密已启用：内容只有你俩能看懂（X25519 + AES-256-GCM）。'
                : '当前是明文发送：${caps == null ? "还没收到对方的能力声明" : "对方版本不支持加密"}。'
                    '同一 WiFi 下理论上可被嗅探，敏感内容等加密可用再发。',
            icon: encOk ? Icons.lock_outline : Icons.lock_open,
          ),
        ),
        Expanded(
          child: msgs.isEmpty
              ? Center(
                  child: Text('还没有消息，打个招呼吧',
                      style:
                          TextStyle(fontSize: 12, color: Colors.grey.shade600)))
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  itemCount: msgs.length,
                  itemBuilder: (c, i) => _Bubble(
                    msg: msgs[i],
                    onRecall: (m) async {
                      await ChatHub.instance.recall(m.mid, to: widget.peerId);
                    },
                    onOpen: _open,
                    onFetch: _fetchLocal,
                  ),
                ),
        ),
        _Composer(
          controller: _input,
          hint: '发给 ${widget.title}',
          onSend: _send,
          onPickImage: () => _sendFile(imagesOnly: true),
          onPickFile: () => _sendFile(imagesOnly: false),
          onPickApp: _sendApp,
          onVoiceStart: _voiceStart,
          onVoiceEnd: _voiceStop,
          recording: _recOn,
          onTyping: () {
            if (_typingThrottle?.isActive ?? false) return;
            _typingThrottle = Timer(const Duration(seconds: 2), () {});
            ChatHub.instance.sendTyping(widget.peerId);
          },
        ),
      ]),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 气泡 / 输入栏 / 设备面板
// ═══════════════════════════════════════════════════════════════════════════

class _Bubble extends StatelessWidget {
  final LanMessage2 msg;
  final void Function(LanMessage2) onRecall;
  final void Function(LanMessage2)? onOpen;

  /// 语音用：把附件拉到本机后**播放**（与"打开"共用下载链路，
  /// 但不交给系统播放器 —— 语音要在气泡里直接播）。
  final Future<String?> Function(LanMessage2)? onFetch;
  const _Bubble(
      {required this.msg, required this.onRecall, this.onOpen, this.onFetch});

  @override
  Widget build(BuildContext c) {
    final mine = msg.mine;
    final isPoke = msg.kind == ChatKind.poke;
    final isApp = msg.kind == ChatKind.app;
    final isVoice = msg.kind == ChatKind.voice;
    final isFile = msg.kind == ChatKind.file || msg.file != null;
    final col = Theme.of(c).colorScheme;

    final body = Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      constraints: BoxConstraints(maxWidth: MediaQuery.of(c).size.width * 0.72),
      decoration: BoxDecoration(
        color: isPoke
            ? col.tertiaryContainer
            : mine
                ? col.primary.withValues(alpha: 0.14)
                : col.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (!mine)
          Text(msg.fromName,
              style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
        if (isPoke)
          Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.touch_app, size: 14),
            const SizedBox(width: 6),
            Text(mine ? '你戳了对方一下' : '${msg.fromName} 戳了你一下',
                style: const TextStyle(fontSize: 13)),
          ])
        else if (isVoice)
          VoiceBubble(msg: msg, mine: mine, onFetch: onFetch)
        else if (isFile)
          InkWell(
            onTap: () => onOpen?.call(msg),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              // 应用与普通文件走同一条传输链路，这里只换图标与文案前缀，
              // 让收到的人一眼看出"这是个能装的包"。
              Icon(isApp ? Icons.android_outlined : Icons.attach_file, size: 15),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                    isApp
                        ? '应用 · ${(msg.file?['name'] as String?) ?? msg.text}'
                        : ((msg.file?['name'] as String?) ?? msg.text),
                    style: const TextStyle(fontSize: 13),
                    overflow: TextOverflow.ellipsis),
              ),
            ]),
          )
        else
          Text(msg.text, style: const TextStyle(fontSize: 13, height: 1.35)),
        const SizedBox(height: 3),
        Row(mainAxisSize: MainAxisSize.min, children: [
          if (msg.encrypted) ...[
            const Icon(Icons.lock, size: 10, color: Colors.green),
            const SizedBox(width: 3),
          ] else if (!msg.isBroadcast) ...[
            const Icon(Icons.lock_open, size: 10, color: Colors.orange),
            const SizedBox(width: 3),
          ],
          Text(_hhmm(msg.ts),
              style: TextStyle(fontSize: 9, color: Colors.grey.shade500)),
          if (mine && msg.pending) ...[
            const SizedBox(width: 4),
            Text('待送达',
                style: TextStyle(fontSize: 9, color: Colors.grey.shade500)),
          ],
        ]),
      ]),
    );

    // ⑧ 曲线删除：只在动画走完之后才真正撤回（"动画不改真实位置"）
    final wrapped = mine
        ? SwipeDeleteCard(
            onDeleted: () => onRecall(msg),
            deleteColor: col.error,
            child: body,
          )
        : body;

    return Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: wrapped);
  }

  static String _hhmm(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}

class _Composer extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final Future<void> Function() onSend;
  final VoidCallback? onTyping;
  final VoidCallback? onPickImage;
  final VoidCallback? onPickFile;

  /// 「发送应用」：列出本机已安装应用，把它的安装包（APK）发给对方。
  final VoidCallback? onPickApp;

  /// 语音：按住说话（onVoiceStart）→ 松开发送（onVoiceEnd）。
  final VoidCallback? onVoiceStart;
  final VoidCallback? onVoiceEnd;

  /// 正在录音 —— 显示提示条，否则用户不知道松手会发出去。
  final bool recording;
  const _Composer({
    required this.controller,
    required this.hint,
    required this.onSend,
    this.onTyping,
    this.onPickImage,
    this.onPickFile,
    this.onPickApp,
    this.onVoiceStart,
    this.onVoiceEnd,
    this.recording = false,
  });

  /// 快捷短语而不是 emoji —— STYLE_GUIDE 第 1 条禁用 emoji 字符。
  static const List<String> _quick = [
    '收到',
    '稍等',
    '好的',
    '在路上',
    '文件发我一下',
    '方便语音吗',
  ];

  @override
  Widget build(BuildContext c) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // ⑩ 标签挤开：点一个，邻近的让开一点，选中的放大
          if (onPickFile != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: ExpandingTagBar(
                tags: _quick,
                selected: null,
                onSelect: (v) {
                  controller.text =
                      controller.text.isEmpty ? v : '${controller.text} $v';
                  controller.selection = TextSelection.fromPosition(
                      TextPosition(offset: controller.text.length));
                },
              ),
            ),
          // 录音中提示：不加的话用户松手才知道发生了什么，
          // 会出现"我明明只是点了一下"的困惑。
          if (recording)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(mainAxisSize: MainAxisSize.min, children: const [
                Icon(Icons.mic, size: 16, color: Colors.redAccent),
                SizedBox(width: 6),
                Text('正在录音…松开发送',
                    style: TextStyle(fontSize: 12, color: Colors.redAccent)),
              ]),
            ),
          Row(children: [
            if (onVoiceStart != null)
              GestureDetector(
                onLongPressStart: (_) => onVoiceStart!(),
                onLongPressEnd: (_) => onVoiceEnd?.call(),
                child: IconButton(
                    tooltip: '按住说话',
                    // 单击不做事 —— 只有长按才录音（微信就是这个习惯）
                    onPressed: () {},
                    icon: const Icon(Icons.mic_none_outlined)),
              ),
            if (onPickApp != null)
              IconButton(
                  tooltip: '应用',
                  onPressed: onPickApp,
                  icon: const Icon(Icons.android_outlined)),
            if (onPickImage != null)
              IconButton(
                  tooltip: '图片',
                  onPressed: onPickImage,
                  icon: const Icon(Icons.image_outlined)),
            if (onPickFile != null)
              IconButton(
                  tooltip: '文件',
                  onPressed: onPickFile,
                  icon: const Icon(Icons.attach_file)),
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 4,
                style: const TextStyle(fontSize: 13),
                onChanged: (_) => onTyping?.call(),
                decoration: InputDecoration(
                    hintText: hint,
                    isDense: true,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10))),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(onPressed: onSend, icon: const Icon(Icons.send)),
          ]),
        ]),
      ),
    );
  }
}

/// 我的设备面板：改名 + 指纹 + 密钥说明。
class _DeviceSheet extends StatefulWidget {
  const _DeviceSheet();
  @override
  State<_DeviceSheet> createState() => _DeviceSheetState();
}

class _DeviceSheetState extends State<_DeviceSheet> with _LanTickMixin {
  final _name = TextEditingController();

  @override
  void initState() {
    super.initState();
    _name.text = ChatHub.instance.name;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) {
    final h = ChatHub.instance;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('我的设备',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              TextField(
                controller: _name,
                decoration: InputDecoration(
                    labelText: '昵称',
                    helperText: '同网段的设备会在列表里看到这个名字',
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10))),
              ),
              const SizedBox(height: 12),
              const Text('公钥指纹',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 2),
              SelectableText(h.fingerprint.isEmpty ? '生成中…' : h.fingerprint,
                  style: const TextStyle(
                      fontSize: 16,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(
                '指纹由设备长期身份密钥导出，重装应用才会变。'
                '对方加你为好友时会核对这串字符 —— 它对得上，才说明对面真的是这台设备。',
                style: TextStyle(
                    fontSize: 11.5, color: Colors.grey.shade600, height: 1.5),
              ),
              const SizedBox(height: 14),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                      onPressed: () => Navigator.pop(c),
                      child: const Text('取消')),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                      onPressed: () async {
                        await h.setName(_name.text);
                        if (c.mounted) Navigator.pop(c);
                      },
                      child: const Text('保存')),
                ),
              ]),
            ]),
      ),
    );
  }
}

/// 兜底：把 [ChatCrypto.fingerprint] 暴露成 UI 可直接用的语义函数。
///
/// 引擎里只存对端**声明的**指纹（`ChatHub.peerFp`），本地现算只在需要
/// 交叉验证时用；这里保留入口，避免 UI 直接 import crypto 层。
Future<String> fingerprintOfPeer(List<int> pubKey) =>
    ChatCrypto.fingerprint(pubKey);

/// 本机内网 IPv4（拿不到返回空串）。UI 与引擎用同一套判定，避免"界面说有、
/// 实际绑不上"这种自相矛盾。
Future<String> lanAddress() async {
  try {
    final ifs = await NetworkInterface.list(
        type: InternetAddressType.IPv4, includeLoopback: false);
    for (final i in ifs) {
      for (final a in i.addresses) {
        if (!a.isLoopback) return a.address;
      }
    }
  } catch (_) {}
  return '';
}
