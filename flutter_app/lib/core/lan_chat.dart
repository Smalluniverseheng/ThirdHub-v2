// ═══════════════════════════════════════════════════════════════════════════
// 局域网聊天引擎 v2（ChatHub）
//
// 对应 `docs/LANCHAT-PROTOCOL.md`。在旧的 `LanChat`（lab_social.dart）之上，
// 补齐协议里定义而旧实现没有的能力：
//   · 设备身份密钥（X25519）+ 公钥指纹广播
//   · 私聊端到端加密（AES-256-GCM），广播明文但**显式标注**
//   · 文件 / 图片 / 视频收发（临时 HTTP 服务 + 一次性令牌 + SHA-256 校验）
//   · (from,mid) 幂等去重 —— 避免广播+单播双到达显示成两条
//   · 好友（含指纹）本地持久化
//
// ★ 兼容：旧版设备的 v1 报文仍被接受，只是降级为明文（协议 §4.3）。
//   升级不能让同网段的老设备"突然看不见我"。
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'chat_crypto.dart';
import 'chat_logic.dart';
import 'lab_logic.dart' show kLanPort, LanPeer, prunePeers;

/// 文件传输服务的空闲自动关闭时间（协议 §5.2）。
const Duration kFileServerIdle = Duration(seconds: 90);

/// 单播消息等待对端回执的时间；超时判"可能不在线"并转入待同步（协议 §6）。
const Duration kUnicastAckTimeout = Duration(seconds: 8);

class ChatHub {
  static final ChatHub instance = ChatHub._();
  ChatHub._();

  // ── 网络 ──
  RawDatagramSocket? _sock;
  HttpServer? _fileSrv;
  Timer? _beat;
  Timer? _fileIdle;
  DateTime _lastFileHit = DateTime.now();

  // ── 身份 ──
  String id = '';
  String name = '我';
  List<int> _seed = const [];
  List<int> _pub = const [];
  String fingerprint = '';

  // ── 状态 ──
  bool running = false;
  String lastError = '';
  final List<LanPeer> peers = [];
  final List<ChatFriend> friends = [];
  final List<LanMessage2> messages = [];

  /// 对端公钥：peerId → pub bytes（收到 hi 后填）
  final Map<String, List<int>> peerKeys = {};

  /// 对端能力：peerId → ChatCaps
  final Map<String, ChatCaps> peerCaps = {};

  /// 对端**自己声明的**指纹：peerId → hex。
  ///
  /// 存对方声明的值而不是本地现算——用户核对的是"对方屏幕上显示的那串"，
  /// 两边必须逐字相同才有核对意义。
  final Map<String, String> peerFp = {};

  /// 正在输入的对端：peerId → 过期时间
  final Map<String, DateTime> typingPeers = {};

  /// 已收到的消息 id（幂等）。key = "from\u0000mid"
  final Set<String> _seen = {};

  final ValueNotifierLike tick = ValueNotifierLike();

  /// 由外部注入的持久化回调（本文件不直接依赖 shared_preferences，
  /// 便于纯 Dart 自检时替换成内存实现）。
  Future<String?> Function(String key)? load;
  Future<void> Function(String key, String value)? save;

  // ═════════════════════════════════════════════════════════════════
  // 生命周期
  // ═════════════════════════════════════════════════════════════════

  Future<void> init({
    required Future<String?> Function(String) loadFn,
    required Future<void> Function(String, String) saveFn,
  }) async {
    load = loadFn;
    save = saveFn;

    id = await _str('lan_chat_id') ??
        'dev-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    await _put('lan_chat_id', id);

    name = await _str('lan_chat_name') ?? '设备${id.substring(id.length - 4)}';

    // 身份密钥：seed 持久化 → 指纹跨会话稳定（协议 §4.1）
    final seedB64 = await _str('lan_chat_seed');
    final existing = seedB64 == null ? null : ChatCrypto.unb64(seedB64);
    final (pub, seed) = await ChatCrypto.identity(existing);
    _pub = pub;
    _seed = seed;
    if (existing == null) await _put('lan_chat_seed', ChatCrypto.b64(seed));
    fingerprint = await ChatCrypto.fingerprint(pub);

    await _loadFriends();
    await _loadMessages();
    tick.bump();
  }

  Future<String?> _str(String k) async => load?.call(k);
  Future<void> _put(String k, String v) async => save?.call(k, v);

  Future<void> _loadFriends() async {
    friends.clear();
    final raw = await _str('lan_chat_friends');
    if (raw == null) return;
    try {
      for (final e in jsonDecode(raw) as List) {
        if (e is Map) {
          friends.add(ChatFriend.from(Map<String, dynamic>.from(e)));
        }
      }
    } catch (_) {
      friends.clear();
    }
  }

  Future<void> _saveFriends() async {
    await _put('lan_chat_friends', jsonEncode([for (final f in friends) f.toJson()]));
  }

  Future<void> _loadMessages() async {
    messages.clear();
    final raw = await _str('lan_chat_msgs_v2');
    if (raw == null) return;
    try {
      for (final e in jsonDecode(raw) as List) {
        if (e is Map) {
          final m = LanMessage2.from(Map<String, dynamic>.from(e));
          messages.add(m);
          _seen.add('${m.from}\u0000${m.mid}');
        }
      }
    } catch (_) {
      messages.clear();
    }
  }

  Future<void> _saveMessages() async {
    final sorted = trimMessages(normalizeMessages(messages));
    messages
      ..clear()
      ..addAll(sorted);
    await _put('lan_chat_msgs_v2',
        jsonEncode([for (final m in sorted) m.toJson()]));
  }

  Future<void> setName(String n) async {
    name = n.trim().isEmpty ? name : n.trim();
    await _put('lan_chat_name', name);
    tick.bump();
  }

  // ═════════════════════════════════════════════════════════════════
  // 收发
  // ═════════════════════════════════════════════════════════════════

  Future<void> start() async {
    if (running) return;
    try {
      _sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, kLanPort,
          reuseAddress: true);
      _sock!.broadcastEnabled = true;
      _sock!.listen(_onEvent, onError: (e) {
        lastError = '$e';
        tick.bump();
      });
      running = true;
      lastError = '';
      _announce();
      _beat = Timer.periodic(const Duration(seconds: 5), (_) {
        _announce();
        final before = peers.length;
        peers
          ..clear()
          ..addAll(prunePeers(peers));
        _expireTyping();
        if (peers.length != before) tick.bump();
      });
    } catch (e) {
      running = false;
      lastError = '无法绑定 UDP 端口 $kLanPort: $e';
    }
    tick.bump();
  }

  Future<void> stop() async {
    _beat?.cancel();
    _beat = null;
    try {
      _sock?.close();
    } catch (_) {}
    _sock = null;
    running = false;
    await _stopFileServer();
    tick.bump();
  }

  void _announce() => _sendRaw({
        't': ChatT.hi,
        'id': id,
        'name': name,
        'pk': ChatCrypto.b64(_pub),
        'fp': fingerprint,
        'cap': const ChatCaps().toList(),
      });

  /// 主动下线：加速对端移除（不必等 45 秒超时）。
  void sayBye() => _sendRaw({'t': ChatT.bye, 'id': id, 'name': name});

  void _sendRaw(Map<String, dynamic> m, {String? toHost}) {
    final s = _sock;
    if (s == null) return;
    try {
      final data = utf8.encode(encodeV2(m));
      if (toHost == null) {
        s.send(data, InternetAddress('255.255.255.255'), kLanPort);
      } else {
        s.send(data, InternetAddress(toHost), kLanPort);
      }
    } catch (e) {
      lastError = '$e';
      tick.bump();
    }
  }

  void _expireTyping() {
    final now = DateTime.now();
    final dead = typingPeers.entries
        .where((e) => e.value.isBefore(now))
        .map((e) => e.key)
        .toList();
    for (final k in dead) {
      typingPeers.remove(k);
    }
  }

  void _onEvent(RawSocketEvent e) {
    if (e != RawSocketEvent.read) return;
    final dg = _sock?.receive();
    if (dg == null) return;
    final m = decodeV2(utf8.decode(dg.data, allowMalformed: true));
    if (m == null) return; // 公网上什么包都有，解析层不崩

    final fromId = '${m['id'] ?? dg.address.address}';
    if (fromId == id) return; // 自己的广播
    final host = dg.address.address;
    final legacy = isLegacyEnvelope(m);

    // ── 设备表 ──
    final i = peers.indexWhere((p) => p.id == fromId);
    if (i >= 0) {
      peers[i].seen = DateTime.now();
      peers[i].name = '${m['name'] ?? peers[i].name}';
    } else {
      peers.add(LanPeer(
          id: fromId, name: '${m['name'] ?? '设备'}', host: host));
    }

    // ── 公钥 / 指纹 / 能力（legacy 报文没有）──
    final pk = ChatCrypto.unb64(m['pk'] as String?);
    if (pk != null && pk.length == 32) {
      peerKeys[fromId] = pk;
      // 好友的指纹同步刷新（对方换了设备/重装 → 指纹变化必须让用户看见）
      final f = friends.where((x) => x.id == fromId).firstOrNull;
      if (f != null && '${m['fp'] ?? ''}'.isNotEmpty) {
        f.fp = '${m['fp']}';
        f.host = host;
        f.lastSeen = DateTime.now().millisecondsSinceEpoch;
      }
    }
    if ('${m['fp'] ?? ''}'.isNotEmpty) peerFp[fromId] = '${m['fp']}';
    if (m['cap'] != null) peerCaps[fromId] = ChatCaps.parse(m['cap']);

    switch (m['t']) {
      case ChatT.hi:
        // 回一个 hi 加速双向发现；但 3 秒内刚回过就不回，避免回包风暴
        if (!_recentlyGreeted(fromId)) _sendRaw({
            't': ChatT.hi,
            'id': id,
            'name': name,
            'pk': ChatCrypto.b64(_pub),
            'fp': fingerprint,
            'cap': const ChatCaps().toList(),
          }, toHost: host);
        break;

      case ChatT.bye:
        peers.removeWhere((p) => p.id == fromId);
        break;

      case ChatT.typing:
        typingPeers[fromId] = DateTime.now().add(const Duration(seconds: 4));
        break;

      case ChatT.msg:
        _onMsg(m, fromId, host, legacy);
        break;

      case ChatT.recall:
        _onRecall(m, fromId);
        break;

      case ChatT.file:
        fileInbox.add(ChatFileOffer(
          peerId: fromId,
          peerName: '${m['name'] ?? fromId}',
          meta: Map<String, dynamic>.from(m['file'] as Map? ?? {}),
          host: host,
        ));
        break;

      case ChatT.fileAck:
        lastFileAck = Map<String, dynamic>.from(m);
        break;
    }
    tick.bump();
  }

  final Map<String, DateTime> _greeted = {};
  bool _recentlyGreeted(String peerId) {
    final now = DateTime.now();
    final last = _greeted[peerId];
    if (last != null && now.difference(last).inSeconds < 3) return true;
    _greeted[peerId] = now;
    return false;
  }

  Future<void> _onMsg(Map<String, dynamic> m, String fromId, String host,
      bool legacy) async {
    final mid = '${m['mid'] ?? newMid(m['ts'] as int?)}';
    final key = '$fromId\u0000$mid';
    if (!_seen.add(key)) return; // 幂等：广播+单播双到达只留一条

    final ts = (m['ts'] as num?)?.toInt() ??
        DateTime.now().millisecondsSinceEpoch;
    final enc = legacy ? ChatEnc.none : '${m['enc'] ?? ChatEnc.none}';
    var text = '${m['text'] ?? ''}';

    if (enc == ChatEnc.x25519AesGcm) {
      final peerPub = peerKeys[fromId];
      if (peerPub == null) {
        text = '（无法解密：尚未收到对方公钥）';
      } else {
        try {
          final sk = await ChatCrypto.sessionKey(
            mySeed: _seed,
            myPub: _pub,
            peerPub: peerPub,
          );
          final clear =
              await ChatCrypto.decryptText(m, sk, mid: mid, ts: ts);
          // ★ 解密失败绝不显示乱码，给明确可操作提示（协议 §4.3 红线）
          text = clear ?? '（无法解密：密钥可能已变化，请重新配对）';
        } catch (_) {
          text = '（无法解密：密钥可能已变化，请重新配对）';
        }
      }
    }

    messages.add(LanMessage2(
      mid: mid,
      from: fromId,
      fromName: '${m['name'] ?? fromId}',
      to: '${m['to'] ?? '*'}',
      toAll: m['toAll'] != false,
      kind: '${m['kind'] ?? ChatKind.text}',
      text: text,
      enc: enc,
      ts: ts,
      mine: false,
      delivered: true,
      file: m['file'] is Map ? Map<String, dynamic>.from(m['file']) : null,
    ));
    await _saveMessages();
  }

  Future<void> _onRecall(Map<String, dynamic> m, String fromId) async {
    final mid = '${m['mid'] ?? ''}';
    if (mid.isEmpty) return;
    // 只允许撤回自己发的、且 5 分钟内的（协议 §2.4）
    final deadline =
        DateTime.now().subtract(const Duration(minutes: 5)).millisecondsSinceEpoch;
    messages.removeWhere((x) =>
        x.mid == mid && x.from == fromId && x.ts >= deadline);
    _seen.remove('$fromId\u0000$mid');
    await _saveMessages();
  }

  // ═════════════════════════════════════════════════════════════════
  // 发送
  // ═════════════════════════════════════════════════════════════════

  /// 发送文本。`to == null` 表示区域频道广播。
  ///
  /// [kind] 允许复用文本通道发「戳一戳」这类只有提示意义的消息（默认 text）。
  Future<SendPlan> sendText(String text, {String? to, String kind = ChatKind.text}) async {
    final (body, truncated) = clampText(text.trim());
    if (body.isEmpty) return const SendPlan(ChatEnc.none);

    final broadcast = to == null;
    final caps = broadcast ? const ChatCaps() : (peerCaps[to] ?? const ChatCaps(text: true, file: false, enc: false));
    final plan = planSend(
      broadcast: broadcast,
      peerSupportsEnc: caps.enc,
      havePeerKey: peerKeys.containsKey(to),
    );

    final mid = newMid();
    final ts = DateTime.now().millisecondsSinceEpoch;
    Map<String, dynamic> payload = {
      't': ChatT.msg,
      'mid': mid,
      'id': id,
      'name': name,
      'to': to ?? '*',
      'toAll': broadcast,
      'kind': kind,
      'ts': ts,
      'enc': plan.enc,
    };

    if (plan.encrypted) {
      final sk = await ChatCrypto.sessionKey(
        mySeed: _seed,
        myPub: _pub,
        peerPub: peerKeys[to]!,
      );
      final c = await ChatCrypto.encryptText(body, sk, mid: mid, ts: ts);
      payload['ct'] = c['ct'];
      payload['iv'] = c['iv'];
      payload['pk'] = ChatCrypto.b64(_pub);
    } else {
      payload['text'] = body;
      payload['pk'] = ChatCrypto.b64(_pub);
    }

    final host = broadcast ? null : peers.where((p) => p.id == to).firstOrNull?.host;
    _sendRaw(payload, toHost: host);

    _seen.add('$id\u0000$mid');
    messages.add(LanMessage2(
      mid: mid,
      from: id,
      fromName: name,
      to: to ?? '*',
      toAll: broadcast,
      kind: kind,
      text: kind == ChatKind.poke
          ? '戳了你一下'
          : (truncated ? '$body…（已截断到 $kChatTextMaxChars 字）' : body),
      enc: plan.enc,
      ts: ts,
      mine: true,
      delivered: broadcast, // 单播要等回执才算送达
      pending: !broadcast && host == null,
    ));
    await _saveMessages();
    tick.bump();

    // 单播且没找到 host（对端此刻不在网段）→ 标记待同步走后端通道（协议 §6）
    if (!broadcast && host == null) {
      lastError = '';
    }
    return plan;
  }

  /// 撤回自己 5 分钟内发的一条消息。
  Future<void> recall(String mid, {String? to}) async {
    _sendRaw({'t': ChatT.recall, 'id': id, 'to': to ?? '*', 'mid': mid});
    messages.removeWhere((m) => m.mid == mid && m.mine);
    _seen.remove('$id\u0000$mid');
    await _saveMessages();
    tick.bump();
  }

  /// 告知对端"我正在输入"（协议 §2.4：不进历史）。
  void sendTyping(String? to) => _sendRaw({
        't': ChatT.typing,
        'id': id,
        'to': to ?? '*',
        'on': true,
      }, toHost: to == null ? null : peers.where((p) => p.id == to).firstOrNull?.host);

  // ═════════════════════════════════════════════════════════════════
  // 文件传输（协议 §5）
  // ═════════════════════════════════════════════════════════════════

  /// 待接收的文件要约（UI 弹确认）。
  final List<ChatFileOffer> fileInbox = [];

  /// 最近一次收到的 file_ack（UI 用来给发送方反馈）。
  Map<String, dynamic>? lastFileAck;

  /// 本机内网 IPv4（**只绑它，不绑 0.0.0.0**，避免把文件暴露给公网）。
  Future<InternetAddress?> _lanAddress() async {
    try {
      final ifs = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false);
      for (final i in ifs) {
        for (final a in i.addresses) {
          if (!a.isLoopback) return a;
        }
      }
    } catch (_) {}
    return null;
  }

  /// 起临时文件服务（随机端口 + 一次性令牌）。
  Future<bool> _ensureFileServer() async {
    if (_fileSrv != null) {
      _lastFileHit = DateTime.now();
      return true;
    }
    final addr = await _lanAddress();
    if (addr == null) return false;
    try {
      final srv = await HttpServer.bind(addr, 0);
      _fileSrv = srv;
      _lastFileHit = DateTime.now();
      srv.listen((req) async {
        _lastFileHit = DateTime.now();
        final token = req.uri.pathSegments.isNotEmpty ? req.uri.pathSegments.last : '';
        final f = _served[token];
        if (f == null) {
          req.response.statusCode = HttpStatus.notFound;
          await req.response.close();
          return;
        }
        try {
          final file = File(f.path);
          if (!await file.exists()) {
            req.response.statusCode = HttpStatus.gone;
            await req.response.close();
            return;
          }
          req.response.headers.contentType = ContentType.binary;
          req.response.headers.contentLength = await file.length();
          await req.response.addStream(file.openRead());
          await req.response.close();
        } catch (e) {
          try {
            req.response.statusCode = HttpStatus.internalServerError;
            await req.response.close();
          } catch (_) {}
        }
      });
      // 空闲自动关闭（协议 §5.2）
      _fileIdle?.cancel();
      _fileIdle = Timer.periodic(const Duration(seconds: 15), (_) {
        if (DateTime.now().difference(_lastFileHit) > kFileServerIdle) {
          _stopFileServer();
        }
      });
      return true;
    } catch (e) {
      lastError = '文件服务启动失败: $e';
      return false;
    }
  }

  final Map<String, File> _served = {};

  Future<void> _stopFileServer() async {
    _fileIdle?.cancel();
    _fileIdle = null;
    try {
      await _fileSrv?.close(force: true);
    } catch (_) {}
    _fileSrv = null;
    _served.clear();
  }

  /// 发送文件。返回 null 表示成功，否则返回错误说明（三段式里的"怎么办"）。
  /// 发送一个本机文件。传输链路与种类无关 —— `kind` 只决定两端怎么显示
  /// （普通文件 / 应用安装包），以及接收端"待接收"列表里的图标。
  Future<String?> sendFile(String path,
      {required String to, String kind = ChatKind.file}) async {
    final file = File(path);
    if (!await file.exists()) return '文件不存在或已被移动，请重新选择';
    final size = await file.length();
    if (size > kChatFileMaxBytes) {
      return '文件 ${fmtBytes(size)} 超过 2 GB 上限，请改用「文件互传」模块发送';
    }

    final caps = peerCaps[to];
    if (caps != null && !caps.file) return '对方版本不支持文件接收，请让对方升级后再试';

    if (!await _ensureFileServer()) {
      return '未找到可用的局域网地址（请确认已连上 WiFi），无法开始传输';
    }

    final token = _randomToken();
    _served[token] = file;
    final addr = _fileSrv!.address.address;
    final port = _fileSrv!.port;

    // ★ mid 只生成一次：报文里的 mid 与本地记录必须是同一个，
    //   否则撤回 / 回执按 mid 找都对不上（这是纯手工对拍才能发现的坑）。
    final mid = newMid();
    final ts = DateTime.now().millisecondsSinceEpoch;

    _sendRaw({
      't': ChatT.file,
      'mid': mid,
      'id': id,
      'name': name,
      'to': to,
      'toAll': false,
      'file': {
        'name': file.uri.pathSegments.last,
        'size': size,
        'mime': _mimeOf(file.uri.pathSegments.last),
        'token': token,
        'host': addr,
        'port': port,
        'sha256': await _sha256Of(file),
        // 种类随报文一起走：接收端据此区分「应用」与普通文件。
        // 老版本会忽略这个字段、仍按文件处理（协议只增不减，不会丢消息）。
        'kind': kind,
      },
      'ts': ts,
    }, toHost: peers.where((p) => p.id == to).firstOrNull?.host);

    messages.add(LanMessage2(
      mid: mid,
      from: id,
      fromName: name,
      to: to,
      toAll: false,
      kind: kind,
      text: file.uri.pathSegments.last,
      enc: ChatEnc.none,
      ts: ts,
      mine: true,
      delivered: true,
      file: {
        'name': file.uri.pathSegments.last,
        'size': size,
        'path': path,
      },
    ));
    await _saveMessages();
    tick.bump();
    return null;
  }

  /// 接收方下载完成后回执（协议 §5.3），让发送方知道"对方真的拿到了"。
  void fileAckOk(ChatFileOffer offer, String savedPath) {
    _sendRaw({
      't': ChatT.fileAck,
      'id': id,
      'to': offer.peerId,
      'mid': newMid(),
      'ok': true,
      'name': offer.fileName,
      'path': savedPath,
      'ts': DateTime.now().millisecondsSinceEpoch,
    }, toHost: offer.host.isEmpty ? null : offer.host);
  }

  /// 把某个文件消息绑上本机路径（下载完 / 自己发的）。
  ///
  /// `LanMessage2` 是不可变的，所以这里是**替换**而不是原地改。
  Future<void> attachLocalPath(String mid, String path) async {
    final i = messages.indexWhere((m) => m.mid == mid);
    if (i < 0) return;
    final m = messages[i];
    messages[i] = LanMessage2(
      mid: m.mid,
      from: m.from,
      fromName: m.fromName,
      to: m.to,
      toAll: m.toAll,
      kind: m.kind,
      text: m.text,
      enc: m.enc,
      ts: m.ts,
      mine: m.mine,
      delivered: m.delivered,
      pending: m.pending,
      file: {...?m.file, 'path': path},
    );
    await _saveMessages();
    tick.bump();
  }

  /// 下载并校验对端发来的文件，返回 (本地路径, 错误说明)。
  Future<(String?, String?)> fetchOffer(
      ChatFileOffer offer, String savePath) async {
    final host = offer.meta['host'] ?? offer.host;
    final port = offer.meta['port'];
    final token = offer.meta['token'];
    final expect = '${offer.meta['sha256'] ?? ''}';
    if (host == null || port == null || token == null) {
      return (null, '文件要约缺少下载地址，请让对方重发');
    }
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 20);
      final req = await client
          .getUrl(Uri.parse('http://$host:$port/dl/$token'));
      final res = await req.close();
      if (res.statusCode != 200) {
        return (null, '对方已停止分享该文件（HTTP ${res.statusCode}）');
      }
      final out = File(savePath);
      await out.parent.create(recursive: true);
      final sink = out.openWrite();
      await res.pipe(sink);

      final got = await _sha256Of(out);
      if (expect.isNotEmpty && got != expect) {
        await out.delete().catchError((_) => out);
        return (null, '文件校验失败（传输中可能损坏），请重新发送');
      }
      client.close();
      return (savePath, null);
    } catch (e) {
      return (null, '下载失败：$e；请确认两台设备仍在同一 WiFi 下');
    }
  }

  static String _randomToken() {
    final r = math.Random.secure();
    return List<int>.generate(32, (_) => r.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  static Future<String> _sha256Of(File f) async {
    // 用 chat_crypto 里的 SHA-256（cryptography 包），避免再引一个依赖
    final bytes = await f.readAsBytes();
    return ChatCrypto.sha256B64(bytes);
  }

  static String _mimeOf(String name) {
    final n = name.toLowerCase();
    if (n.endsWith('.png')) return 'image/png';
    if (n.endsWith('.jpg') || n.endsWith('.jpeg')) return 'image/jpeg';
    if (n.endsWith('.gif')) return 'image/gif';
    if (n.endsWith('.mp4')) return 'video/mp4';
    if (n.endsWith('.mp3')) return 'audio/mpeg';
    if (n.endsWith('.pdf')) return 'application/pdf';
    if (n.endsWith('.txt')) return 'text/plain';
    if (n.endsWith('.zip')) return 'application/zip';
    return 'application/octet-stream';
  }

  // ═════════════════════════════════════════════════════════════════
  // 好友
  // ═════════════════════════════════════════════════════════════════

  Future<void> addFriend(String peerId, String peerName, String host,
      {String fp = ''}) async {
    final i = friends.indexWhere((f) => f.id == peerId);
    if (i >= 0) {
      friends[i].name = peerName;
      friends[i].host = host;
      if (fp.isNotEmpty) friends[i].fp = fp;
      friends[i].lastSeen = DateTime.now().millisecondsSinceEpoch;
    } else {
      friends.add(ChatFriend(
          id: peerId, name: peerName, host: host, fp: fp));
    }
    await _saveFriends();
    tick.bump();
  }

  Future<void> removeFriend(String peerId) async {
    friends.removeWhere((f) => f.id == peerId);
    await _saveFriends();
    tick.bump();
  }

  Future<void> setBlocked(String peerId, bool v) async {
    final f = friends.where((x) => x.id == peerId).firstOrNull;
    if (f == null) return;
    f.blocked = v;
    await _saveFriends();
    tick.bump();
  }

  Future<void> clearMessages() async {
    messages.clear();
    _seen.clear();
    await _saveMessages();
    tick.bump();
  }

  /// 某会话的消息（已排序、已去重）。[peerId] 为 null = 区域频道。
  List<LanMessage2> messagesOf(String? peerId) {
    final sid = peerId == null ? '*' : peerId;
    return normalizeMessages(messages.where((m) {
      if (sid == '*') return m.isBroadcast;
      return !m.isBroadcast && (m.from == sid || m.to == sid);
    }));
  }
}

/// 一个待接收的文件要约。
class ChatFileOffer {
  final String peerId;
  final String peerName;
  final Map<String, dynamic> meta;
  final String host;
  ChatFileOffer({
    required this.peerId,
    required this.peerName,
    required this.meta,
    required this.host,
  });

  /// 原始文件名（拿不到时给个中性占位）。
  String get fileName => '${meta['name'] ?? '对方发来的文件'}';

  /// 字节数；拿不到时 -1。
  int get size => (meta['size'] as num?)?.toInt() ?? -1;

  /// 是否图片 / 视频（UI 决定用缩略还是通用图标）。
  bool get isImage => '${meta['mime'] ?? ''}'.startsWith('image/');
  bool get isVideo => '${meta['mime'] ?? ''}'.startsWith('video/');
}

/// 极小的 ValueNotifier 替身 —— 让本文件对 Flutter 零依赖（纯 Dart 可自检）。
///
/// 只实现 UI 真正需要的三件事：读值、加监听、去监听。刻意不做
/// `ValueListenable` 接口——那会引入 `package:flutter/foundation.dart`，
/// 而本文件要在纯 Dart 自检里直接跑（协议 §8）。
class ValueNotifierLike {
  int value = 0;
  final List<void Function()> _ls = [];

  void addListener(void Function() f) => _ls.add(f);
  void removeListener(void Function() f) => _ls.remove(f);

  void bump() {
    value++;
    // 复制一份再遍历：监听器在回调里退订是常见写法，直接遍历会并发修改
    for (final f in List<void Function()>.from(_ls)) {
      f();
    }
  }
}
