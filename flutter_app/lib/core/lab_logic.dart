// ═══════════════════════════════════════════════════════════════════════════
// 新模块的"纯逻辑层" —— 刻意不依赖 Flutter
//
// 游戏规则 / 局域网报文 / 分享板合并 / HA 域映射 / 打印状态 这些东西
// **不需要 UI 也能验证**, 抽到这里之后就能用纯 Dart 直接跑自检:
//     dart run tool/modules_selfcheck.dart
// UI 与存储分别留在 lab_games.dart / lab_social.dart / home_io.dart。
// ═══════════════════════════════════════════════════════════════════════════
import 'dart:convert';
import 'dart:math' as math;

// ═══════════════════════════════════════════════════════════════════════════
// 1. 2048
// ═══════════════════════════════════════════════════════════════════════════
enum GDir { up, down, left, right }

class G2048 {
  static const int n = 4;
  final List<int> cells = List.filled(n * n, 0);
  int score = 0;
  int best = 0;
  bool won = false;
  bool over = false;
  final math.Random _rnd;

  G2048({math.Random? rnd}) : _rnd = rnd ?? math.Random();

  int at(int r, int c) => cells[r * n + c];

  void reset() {
    for (var i = 0; i < cells.length; i++) { cells[i] = 0; }
    score = 0; won = false; over = false;
    spawn(); spawn();
  }

  bool spawn() {
    final empty = [for (var i = 0; i < cells.length; i++) if (cells[i] == 0) i];
    if (empty.isEmpty) return false;
    final i = empty[_rnd.nextInt(empty.length)];
    cells[i] = _rnd.nextDouble() < 0.9 ? 2 : 4;
    return true;
  }

  /// 把一行向左压紧并合并同类 —— 返回 (新行, 本行得分)
  static (List<int>, int) collapse(List<int> row) {
    final v = [for (final x in row) if (x != 0) x];
    final out = <int>[];
    var gained = 0;
    for (var i = 0; i < v.length; i++) {
      if (i + 1 < v.length && v[i] == v[i + 1]) {
        out.add(v[i] * 2); gained += v[i] * 2; i++; // 同名合并只发生一次
      } else {
        out.add(v[i]);
      }
    }
    while (out.length < n) { out.add(0); }
    return (out, gained);
  }

  List<int> _row(int r, GDir d) {
    switch (d) {
      case GDir.left: return [for (var c = 0; c < n; c++) at(r, c)];
      case GDir.right: return [for (var c = n - 1; c >= 0; c--) at(r, c)];
      case GDir.up: return [for (var c = 0; c < n; c++) at(c, r)];
      case GDir.down: return [for (var c = n - 1; c >= 0; c--) at(c, r)];
    }
  }

  void _putRow(int r, GDir d, List<int> v) {
    for (var k = 0; k < n; k++) {
      switch (d) {
        case GDir.left: cells[r * n + k] = v[k];
        case GDir.right: cells[r * n + (n - 1 - k)] = v[k];
        case GDir.up: cells[k * n + r] = v[k];
        case GDir.down: cells[(n - 1 - k) * n + r] = v[k];
      }
    }
  }

  bool move(GDir d) {
    if (over) return false;
    var changed = false;
    for (var r = 0; r < n; r++) {
      final before = _row(r, d);
      final (after, gained) = collapse(before);
      if (!_same(before, after)) { _putRow(r, d, after); changed = true; }
      score += gained;
      if (score > best) best = score;
    }
    if (changed) {
      if (cells.any((v) => v >= 2048)) won = true;
      spawn();
      over = !canMove();
    }
    return changed;
  }

  static bool _same(List<int> a, List<int> b) {
    for (var i = 0; i < a.length; i++) { if (a[i] != b[i]) return false; }
    return true;
  }

  bool canMove() {
    if (cells.any((v) => v == 0)) return true;
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        final v = at(r, c);
        if (c + 1 < n && at(r, c + 1) == v) return true;
        if (r + 1 < n && at(r + 1, c) == v) return true;
      }
    }
    return false;
  }

  /// 还有哪些方向会发生变化(用来判断"彻底走不动了")
  List<GDir> get moves => [for (final d in GDir.values) if (_wouldChange(d)) d];
  bool _wouldChange(GDir d) {
    for (var r = 0; r < n; r++) {
      final (after, _) = collapse(_row(r, d));
      if (!_same(_row(r, d), after)) return true;
    }
    return false;
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 2. 贪吃蛇
// ═══════════════════════════════════════════════════════════════════════════
class SnakeGame {
  final int w, h;
  late List<math.Point<int>> body;
  late math.Point<int> food;
  int dirX = 1, dirY = 0;
  bool over = false;
  int eaten = 0;
  final math.Random _rnd;

  SnakeGame({this.w = 15, this.h = 20, math.Random? rnd}) : _rnd = rnd ?? math.Random() {
    reset();
  }

  void reset() {
    body = [math.Point(w ~/ 2, h ~/ 2), math.Point(w ~/ 2 - 1, h ~/ 2), math.Point(w ~/ 2 - 2, h ~/ 2)];
    dirX = 1; dirY = 0; over = false; eaten = 0;
    _placeFood();
  }

  void _placeFood() {
    final free = <math.Point<int>>[];
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final p = math.Point(x, y);
        if (!body.contains(p)) free.add(p);
      }
    }
    if (free.isEmpty) { over = true; return; }
    food = free[_rnd.nextInt(free.length)];
  }

  /// 转向: 不接受掉头, 也不接受原地同向重复设置
  bool turn(int dx, int dy) {
    if (over) return false;
    if ((dx == 0 && dy == 0) || (dx != 0 && dy != 0)) return false;
    if (dx == -dirX && dy == -dirY) return false;
    if (dx == dirX && dy == dirY) return false;
    dirX = dx; dirY = dy;
    return true;
  }

  void step() {
    if (over) return;
    final head = body.first;
    final next = math.Point(head.x + dirX, head.y + dirY);
    if (next.x < 0 || next.y < 0 || next.x >= w || next.y >= h) { over = true; return; }
    final willGrow = next == food;
    // 尾巴会让位, 所以撞到"最后一节"不算死
    final hits = willGrow ? body : body.sublist(0, body.length - 1);
    if (hits.contains(next)) { over = true; return; }
    body.insert(0, next);
    if (willGrow) { eaten++; _placeFood(); } else { body.removeLast(); }
  }

  /// 越长越快: 220ms → 90ms
  double get speed {
    final ms = 220 - eaten * 8;
    return ms < 90 ? 90 : ms.toDouble();
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 3. 五子棋
// ═══════════════════════════════════════════════════════════════════════════
class Gomoku {
  static const int n = 15;
  static const int empty = 0, black = 1, white = 2;
  final List<int> board = List.filled(n * n, empty);

  int at(int r, int c) => (r < 0 || c < 0 || r >= n || c >= n) ? -1 : board[r * n + c];

  void reset() { for (var i = 0; i < board.length; i++) { board[i] = empty; } }

  bool place(int r, int c, int who) {
    if (at(r, c) != empty) return false;
    board[r * n + c] = who;
    return true;
  }

  /// 落子后判定: 0 = 未结束, 1/2 = 胜方, 3 = 和棋
  int judge(int r, int c) {
    final who = at(r, c);
    if (who <= 0) return 0;
    const dirs = [(0, 1), (1, 0), (1, 1), (1, -1)];
    for (final (dr, dc) in dirs) {
      var count = 1;
      for (final sign in [1, -1]) {
        var rr = r + dr * sign, cc = c + dc * sign;
        while (at(rr, cc) == who) { count++; rr += dr * sign; cc += dc * sign; }
      }
      if (count >= 5) return who;
    }
    return board.any((v) => v == empty) ? 0 : 3;
  }

  int _lineScore(int r, int c, int dr, int dc, int who) {
    var count = 1, open = 0;
    for (final sign in [1, -1]) {
      var rr = r + dr * sign, cc = c + dc * sign;
      while (at(rr, cc) == who) { count++; rr += dr * sign; cc += dc * sign; }
      if (at(rr, cc) == empty) open++;
    }
    if (count >= 5) return 1000000;
    if (count == 4) return open >= 1 ? 30000 : 800;
    if (count == 3) return open == 2 ? 2500 : (open == 1 ? 250 : 0);
    if (count == 2) return open == 2 ? 180 : (open == 1 ? 18 : 0);
    return open == 2 ? 6 : 1;
  }

  int scoreAt(int r, int c, int who) {
    const dirs = [(0, 1), (1, 0), (1, 1), (1, -1)];
    var s = 0;
    for (final (dr, dc) in dirs) { s += _lineScore(r, c, dr, dc, who); }
    return s;
  }

  /// 极简 AI: 只考虑已有棋子附近的空点, 攻守加权取最大
  (int, int) bestMove(int me) {
    final foe = me == black ? white : black;
    var bestR = -1, bestC = -1;
    var bestScore = -1.0;
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        if (at(r, c) != empty) continue;
        if (!_nearStone(r, c)) continue;
        final s = scoreAt(r, c, me) * 1.1 + scoreAt(r, c, foe);
        if (s > bestScore) { bestScore = s; bestR = r; bestC = c; }
      }
    }
    if (bestR < 0) return (n ~/ 2, n ~/ 2);
    return (bestR, bestC);
  }

  bool _nearStone(int r, int c) {
    for (var dr = -2; dr <= 2; dr++) {
      for (var dc = -2; dc <= 2; dc++) {
        if (at(r + dr, c + dc) > 0) return true;
      }
    }
    return false;
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 4. 局域网聊天协议
// ═══════════════════════════════════════════════════════════════════════════
const int kLanPort = 45871;

String lanEncode(Map<String, dynamic> m) => jsonEncode({...m, 'app': 'thirdhub', 'v': 1});

/// 解出报文; 非本应用 / 坏 JSON 一律 null(公网上什么包都有, 不能崩)
Map<String, dynamic>? lanDecode(String raw) {
  try {
    final j = jsonDecode(raw);
    if (j is! Map) return null;
    final m = Map<String, dynamic>.from(j);
    if (m['app'] != 'thirdhub') return null;
    if (m['t'] == null) return null;
    return m;
  } catch (_) { return null; }
}

class LanPeer {
  final String id;
  String name;
  final String host;
  DateTime seen;
  LanPeer({required this.id, required this.name, required this.host, DateTime? seen})
    : seen = seen ?? DateTime.now();
  bool get stale => DateTime.now().difference(seen).inSeconds > 45;
}

/// 清掉超时未见的设备
List<LanPeer> prunePeers(List<LanPeer> peers, {int staleSeconds = 45, DateTime? now}) {
  final t = now ?? DateTime.now();
  return [for (final p in peers) if (t.difference(p.seen).inSeconds <= staleSeconds) p];
}

class LanMessage {
  final String from, name, text;
  final bool mine, toAll;
  final DateTime ts;
  LanMessage({required this.from, required this.name, required this.text,
    required this.mine, required this.toAll, DateTime? ts}) : ts = ts ?? DateTime.now();
  Map<String, dynamic> toJson() => {
    'from': from, 'name': name, 'text': text, 'mine': mine, 'toAll': toAll,
    'ts': ts.millisecondsSinceEpoch,
  };
  factory LanMessage.from(Map<String, dynamic> j) => LanMessage(
    from: '${j['from'] ?? ''}', name: '${j['name'] ?? ''}', text: '${j['text'] ?? ''}',
    mine: j['mine'] == true, toAll: j['toAll'] != false,
    ts: DateTime.fromMillisecondsSinceEpoch((j['ts'] as num?)?.toInt() ?? 0));
}

// ═══════════════════════════════════════════════════════════════════════════
// 5. 社区 / 论坛 的数据模型
// ═══════════════════════════════════════════════════════════════════════════
const List<String> kPostKinds = ['全部', '规则', '源', '心得', '求助', '链接'];
const List<String> kForumBoards = ['综合', '经验', '求助', '收藏', '公告'];

class CommunityPost {
  final String id, title, body, kind;
  final List<String> tags;
  final int ts;
  int likes;
  CommunityPost({required this.id, required this.title, required this.body,
    required this.kind, required this.tags, required this.ts, this.likes = 0});
  Map<String, dynamic> toJson() => {
    'id': id, 'title': title, 'body': body, 'kind': kind, 'tags': tags, 'ts': ts, 'likes': likes,
  };
  factory CommunityPost.from(Map<String, dynamic> j) => CommunityPost(
    id: '${j['id'] ?? ''}', title: '${j['title'] ?? ''}', body: '${j['body'] ?? ''}',
    kind: '${j['kind'] ?? '心得'}',
    tags: [for (final e in (j['tags'] as List? ?? [])) '$e'],
    ts: (j['ts'] as num?)?.toInt() ?? 0, likes: (j['likes'] as num?)?.toInt() ?? 0);
}

/// 导入合并: 同 id 或同标题已有则跳过(避免重复导入刷屏)
List<CommunityPost> mergePosts(List<CommunityPost> existing, List<CommunityPost> incoming) {
  final ids = {for (final p in existing) p.id};
  final titles = {for (final p in existing) p.title};
  final add = <CommunityPost>[];
  for (final p in incoming) {
    if (ids.contains(p.id) || titles.contains(p.title)) continue;
    ids.add(p.id); titles.add(p.title);
    add.add(p);
  }
  return add;
}

class ForumReply {
  final String by, text;
  final int ts;
  ForumReply({required this.by, required this.text, required this.ts});
  Map<String, dynamic> toJson() => {'by': by, 'text': text, 'ts': ts};
  factory ForumReply.from(Map<String, dynamic> j) =>
    ForumReply(by: '${j['by'] ?? ''}', text: '${j['text'] ?? ''}', ts: (j['ts'] as num?)?.toInt() ?? 0);
}

class ForumTopic {
  final String id, board, title, body;
  final int ts;
  final List<ForumReply> replies;
  ForumTopic({required this.id, required this.board, required this.title, required this.body,
    required this.ts, List<ForumReply>? replies}) : replies = replies ?? [];
  Map<String, dynamic> toJson() => {
    'id': id, 'board': board, 'title': title, 'body': body, 'ts': ts,
    'replies': [for (final r in replies) r.toJson()],
  };
  factory ForumTopic.from(Map<String, dynamic> j) => ForumTopic(
    id: '${j['id'] ?? ''}', board: '${j['board'] ?? '综合'}', title: '${j['title'] ?? ''}',
    body: '${j['body'] ?? ''}', ts: (j['ts'] as num?)?.toInt() ?? 0,
    replies: [for (final e in (j['replies'] as List? ?? [])) ForumReply.from(Map<String, dynamic>.from(e))]);
}

/// 主题导入合并: 同 id 或同标题跳过
List<ForumTopic> mergeTopics(List<ForumTopic> existing, List<ForumTopic> incoming) {
  final ids = {for (final t in existing) t.id};
  final titles = {for (final t in existing) t.title};
  final add = <ForumTopic>[];
  for (final t in incoming) {
    if (ids.contains(t.id) || titles.contains(t.title)) continue;
    ids.add(t.id); titles.add(t.title); add.add(t);
  }
  return add;
}

// ═══════════════════════════════════════════════════════════════════════════
// 6. 智能家居 (Home Assistant) 域映射
// ═══════════════════════════════════════════════════════════════════════════
String haDomain(String entityId) {
  final i = entityId.indexOf('.');
  return i <= 0 ? entityId : entityId.substring(0, i);
}

bool haToggleable(String entityId) {
  const onOff = {'light', 'switch', 'fan', 'input_boolean', 'media_player',
    'automation', 'script', 'cover', 'lock', 'siren', 'humidifier'};
  return onOff.contains(haDomain(entityId));
}

bool haTriggerable(String entityId) =>
  {'scene', 'script', 'automation'}.contains(haDomain(entityId));

String haTurnOnService(String domain) => switch (domain) {
  'cover' => 'open_cover', 'lock' => 'unlock', _ => 'turn_on',
};

String haTurnOffService(String domain) => switch (domain) {
  'cover' => 'close_cover', 'lock' => 'lock', _ => 'turn_off',
};

bool haIsOn(String state) {
  const on = {'on', 'open', 'unlocked', 'playing', 'home', 'cleaning'};
  return on.contains(state.toLowerCase());
}

String haDomainLabel(String domain) => switch (domain) {
  'light' => '灯', 'switch' => '开关/插座', 'fan' => '风扇', 'cover' => '窗帘/门',
  'lock' => '门锁', 'climate' => '空调/温控', 'media_player' => '播放器',
  'sensor' => '传感器', 'binary_sensor' => '二元传感器', 'scene' => '情景',
  'script' => '脚本', 'automation' => '自动化', 'camera' => '摄像头',
  'vacuum' => '扫地机', 'humidifier' => '加湿器', 'input_boolean' => '虚拟开关',
  _ => domain,
};

class HaEntity {
  final String entityId, state, name, unit;
  final Map<String, dynamic> attrs;
  HaEntity({required this.entityId, required this.state, required this.name,
    required this.unit, required this.attrs});
  factory HaEntity.from(Map<String, dynamic> j) {
    final attrs = j['attributes'] is Map ? Map<String, dynamic>.from(j['attributes'] as Map) : <String, dynamic>{};
    return HaEntity(
      entityId: '${j['entity_id'] ?? ''}', state: '${j['state'] ?? ''}',
      name: '${attrs['friendly_name'] ?? j['entity_id'] ?? ''}',
      unit: '${attrs['unit_of_measurement'] ?? ''}', attrs: attrs);
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 7. 打印队列状态
// ═══════════════════════════════════════════════════════════════════════════
enum PrintState { waiting, sending, sent, failed }

extension PrintStateX on PrintState {
  String get zh => switch (this) {
    PrintState.waiting => '待提交', PrintState.sending => '提交中',
    PrintState.sent => '已提交', PrintState.failed => '失败',
  };
}

class PrintJob {
  final String id, title, content;
  final String filePath; // 非空 = 提交本机文件
  PrintState state;
  String message;
  final int ts;

  PrintJob({required this.id, required this.title, required this.content,
    this.filePath = '', this.state = PrintState.waiting, this.message = '',
    required this.ts});

  Map<String, dynamic> toJson() => {
    'id': id, 'title': title, 'content': content, 'filePath': filePath,
    'state': state.name, 'message': message, 'ts': ts,
  };
  factory PrintJob.from(Map<String, dynamic> j) => PrintJob(
    id: '${j['id'] ?? ''}', title: '${j['title'] ?? ''}', content: '${j['content'] ?? ''}',
    filePath: '${j['filePath'] ?? ''}', ts: (j['ts'] as num?)?.toInt() ?? 0)
    ..message = '${j['message'] ?? ''}'
    ..state = PrintState.values.firstWhere((e) => e.name == '${j['state']}', orElse: () => PrintState.waiting);
}

/// 进程被杀后重新装载: 把卡在"提交中"的退回"待提交"(否则会永远显示在发)
List<PrintJob> recoverPrintJobs(List<PrintJob> jobs) {
  for (final j in jobs) {
    if (j.state == PrintState.sending) { j.state = PrintState.waiting; j.message = '上次提交被中断'; }
  }
  return jobs;
}
