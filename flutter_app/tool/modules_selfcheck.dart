// ═══════════════════════════════════════════════════════════════════════════
// 新模块「纯逻辑层」自检(纯 Dart, 不需要 flutter_tester)
//
// 用法: dart run tool/modules_selfcheck.dart
//
// 为什么需要它: 本机 flutter_tester 起不来(见 agent_selfcheck.dart 顶部注释),
// flutter test 全部无法运行。lab_logic.dart 已刻意不依赖 Flutter, 所以可以用
// 纯 Dart VM 直接验证:
//   · 2048 的压紧/合并/得分/终局判定
//   · 贪吃蛇的转向合法性 / 撞墙 / 撞自己 / 尾随 / 提速
//   · 五子棋的落子 / 五连判定(四方向) / 和棋 / 极简 AI 落点
//   · 局域网报文的编解码与容错(公网上什么包都有) / 设备超时剔除
//   · 社区与论坛导入时的去重合并
//   · 智能家居 Home Assistant 的域映射(开/关/触发/状态/中文名)
//   · 远程打印任务的序列化与"中断恢复"
// ═══════════════════════════════════════════════════════════════════════════
import 'dart:convert';
import 'dart:math' as math;

import 'package:thirdhub_app/core/lab_logic.dart';

int _pass = 0;
int _fail = 0;
final List<String> _fails = [];

void _ok(bool cond, String name, [String extra = '']) {
  if (cond) {
    _pass++;
    print('  \u2713 $name');
  } else {
    _fail++;
    _fails.add(name);
    print('  \u2717 $name${extra.isEmpty ? '' : '  -> $extra'}');
  }
}

void _eq(Object? a, Object? b, String name) =>
    _ok(a == b, name, 'expected=${_s(b)} actual=${_s(a)}');

String _s(Object? v) => v is String
    ? '"${v.length > 120 ? '${v.substring(0, 120)}…' : v}"'
    : '$v';

void main() {
  print('══ 新模块纯逻辑自检 ══\n');

  _g2048();
  _snake();
  _gomoku();
  _lan();
  _community();
  _homeAssistant();
  _print();

  print('\n════════════════════════════════════════');
  print('PASS $_pass   FAIL $_fail');
  if (_fail > 0) {
    print('\n失败项:');
    for (final f in _fails) {
      print('  - $f');
    }
  }
  print(_fail == 0 ? '\n\u2705 全部通过' : '\n\u274c 有失败');
}

// ───────────────────────────────────────────────────────────────────────────
// 1. 2048
// ───────────────────────────────────────────────────────────────────────────
void _g2048() {
  print('1) 2048 压紧 / 合并 / 得分');
  String row(List<int> r) => r.join(',');

  var (r, g) = G2048.collapse([2, 2, 4, 0]);
  _eq(row(r), '4,4,0,0', 'collapse([2,2,4,0]) 压紧+合并');
  _eq(g, 4, 'collapse 本行得分 = 4');

  (r, g) = G2048.collapse([2, 2, 2, 2]);
  _eq(row(r), '4,4,0,0', 'collapse([2,2,2,2]) 同名只合并一次');
  _eq(g, 8, '同名四连得分 = 8(不是 8+8)');

  (r, g) = G2048.collapse([2, 2, 2, 0]);
  _eq(row(r), '4,2,0,0', 'collapse([2,2,2,0]) 三连只并前两个');

  (r, g) = G2048.collapse([4, 4, 8, 8]);
  _eq(row(r), '8,16,0,0', 'collapse([4,4,8,8]) 多种数值各自合并');
  _eq(g, 24, '多种数值合并得分 = 8+16');

  (r, g) = G2048.collapse([0, 0, 0, 2]);
  _eq(row(r), '2,0,0,0', 'collapse 单子靠边');

  (r, g) = G2048.collapse([2, 4, 2, 4]);
  _eq(row(r), '2,4,2,4', '异值不合并');
  _eq(g, 0, '异值合并得分为 0');

  final g1 = G2048(rnd: math.Random(7));
  g1.reset();
  _eq(g1.cells.where((v) => v != 0).length, 2, 'reset 后场上恰好 2 个数字');
  _ok(g1.cells.every((v) => v == 0 || v == 2 || v == 4), '开局数字只可能是 2 或 4');
  _eq(g1.score, 0, 'reset 后 score = 0');
  _eq(g1.over, false, 'reset 后 over = false');

  // 满盘同类 → 一次左移应合并 4 行各 8 分 = 32
  final g2 = G2048(rnd: math.Random(1));
  for (var i = 0; i < g2.cells.length; i++) {
    g2.cells[i] = 2;
  }
  final moved = g2.move(GDir.left);
  _eq(moved, true, '满盘同类向左可动');
  _eq(g2.score, 32, '满盘同类左移得分 = 8×4 = 32');
  _eq(g2.at(0, 0), 4, '左移后首格 = 4');
  _eq(g2.at(0, 1), 4, '左移后次格 = 4');
  _eq(g2.cells.where((v) => v == 0).length, 7, '左移后 4×2 个空格被补掉 1 个');

  // 无变化的方向不应加分
  final g3 = G2048(rnd: math.Random(2));
  for (var i = 0; i < g3.cells.length; i++) {
    g3.cells[i] = 0;
  }
  g3.cells[0] = 2;
  _eq(g3.move(GDir.left), false, '空盘上方已有子时向左无变化');
  _eq(g3.score, 0, '无变化方向不加分');
  _eq(g3.cells.where((v) => v != 0).length, 1, '无变化方向不会随机补子');

  // 达成 2048 → won
  final g4 = G2048(rnd: math.Random(3));
  for (var i = 0; i < g4.cells.length; i++) {
    g4.cells[i] = 0;
  }
  g4.cells[0] = 1024;
  g4.cells[1] = 1024;
  g4.move(GDir.left);
  _eq(g4.at(0, 0), 2048, '两个 1024 合并为 2048');
  _eq(g4.won, true, '出现 2048 → won = true');

  // 棋盘全满且无可合并 → 走不动
  final g5 = G2048(rnd: math.Random(4));
  for (var rr = 0; rr < G2048.n; rr++) {
    for (var cc = 0; cc < G2048.n; cc++) {
      g5.cells[rr * G2048.n + cc] = ((rr + cc) % 2 == 0) ? 2 : 4;
    }
  }
  _eq(g5.canMove(), false, '棋盘交替格 → canMove = false');
  _eq(g5.moves.isEmpty, true, '棋盘交替格 → 四个方向都走不动');
  _eq(g5.move(GDir.left), false, '走不动时 move 返回 false');

  final g6 = G2048(rnd: math.Random(5));
  for (var i = 0; i < g6.cells.length; i++) {
    g6.cells[i] = 8;
  }
  _ok(g6.canMove(), '满盘同类 → canMove = true');
  _ok(g6.moves.isNotEmpty, '满盘同类 → 至少一个方向可动');

  final g7 = G2048(rnd: math.Random(6));
  for (var i = 0; i < g7.cells.length; i++) {
    g7.cells[i] = 2;
  }
  g7.cells[15] = 0;
  _ok(g7.canMove(), '有空格 → canMove = true');
}

// ───────────────────────────────────────────────────────────────────────────
// 2. 贪吃蛇
// ───────────────────────────────────────────────────────────────────────────
void _snake() {
  print('\n2) 贪吃蛇 转向 / 碰撞 / 提速');

  final s = SnakeGame(w: 15, h: 20, rnd: math.Random(11));
  _eq(s.body.length, 3, '开局长度 3');
  _eq(s.eaten, 0, '开局 eaten = 0');
  _eq(s.over, false, '开局 over = false');
  _eq(s.dirX, 1, '开局朝右(dirX=1)');
  _eq(s.dirY, 0, '开局 dirY=0');

  _eq(s.turn(0, 0), false, 'turn(0,0) 原地不动 → 拒绝');
  _eq(s.turn(1, 1), false, 'turn(1,1) 斜向 → 拒绝');
  _eq(s.turn(-1, 0), false, 'turn(-1,0) 掉头 → 拒绝');
  _eq(s.turn(1, 0), false, 'turn(1,0) 与当前同向 → 拒绝');
  _eq(s.turn(0, -1), true, 'turn(0,-1) 向上 → 接受');
  _eq(s.dirX, 0, '向上后 dirX = 0');
  _eq(s.dirY, -1, '向上后 dirY = -1');
  _eq(s.turn(0, 1), false, '此时向下是掉头 → 拒绝');

  // 普通前进: 长度不变, 头前进一格, 尾让位
  final s2 = SnakeGame(w: 15, h: 20, rnd: math.Random(12));
  s2.food = const math.Point(100, -100); // 挪到不可能的位置
  final head0 = s2.body.first;
  final tail0 = s2.body.last;
  s2.step();
  _eq(s2.body.length, 3, '前进后长度不变');
  _eq(s2.body.first.x, head0.x + 1, '前进后头 x +1');
  _eq(s2.body.first.y, head0.y, '前进后头 y 不变');
  _ok(!s2.body.contains(tail0) || tail0 == s2.body.first,
      '前进后原来的尾巴被移除');
  _eq(s2.over, false, '正常前进不会死');

  // 吃到食物 → 长度 +1, eaten +1
  final s3 = SnakeGame(w: 15, h: 20, rnd: math.Random(13));
  s3.food = math.Point(s3.body.first.x + 1, s3.body.first.y);
  s3.step();
  _eq(s3.body.length, 4, '吃到食物 → 长度 +1');
  _eq(s3.eaten, 1, '吃到食物 → eaten = 1');
  _ok(s3.food != s3.body.first, '吃到食物后会重新放置食物');

  // 撞墙
  final s4 = SnakeGame(w: 15, h: 20, rnd: math.Random(14));
  s4.food = const math.Point(100, -100);
  for (var i = 0; i < 20 && !s4.over; i++) {
    s4.step();
  }
  _eq(s4.over, true, '一路向右最终撞墙 → over = true');
  _eq(s4.turn(0, -1), false, '死亡后 turn 被拒绝');
  final lenBefore = s4.body.length;
  s4.step();
  _eq(s4.body.length, lenBefore, '死亡后 step 不再改变状态');

  // 撞自己(非尾巴)
  final s5 = SnakeGame(w: 15, h: 20, rnd: math.Random(15));
  s5.food = const math.Point(100, -100);
  s5.body = [
    const math.Point(5, 5),
    const math.Point(5, 4),
    const math.Point(4, 4),
    const math.Point(4, 5),
    const math.Point(4, 6),
  ];
  s5.dirX = 0;
  s5.dirY = -1; // 头(5,5) 向上会撞到 (5,4)
  s5.step();
  _eq(s5.over, true, '撞到自己身体 → over = true');

  // 尾随: 头进入"尾巴上一格"(尾巴会让位)→ 不该死
  final s6 = SnakeGame(w: 15, h: 20, rnd: math.Random(16));
  s6.food = math.Point(20, 20); // 不进身体
  s6.body = [
    const math.Point(1, 1),
    const math.Point(0, 1),
    const math.Point(0, 0),
    const math.Point(1, 0),
  ];
  s6.dirX = 0;
  s6.dirY = -1; // 头(1,1) 向下会走到尾(1,0)
  s6.step();
  _eq(s6.over, false, '头进入尾巴位置(尾让位)→ 不死');
  _eq(s6.body.first.x, 1, '尾随步进后头 x = 1');
  _eq(s6.body.first.y, 0, '尾随步进后头 y = 0');
  _eq(s6.body.length, 4, '尾随步进长度不变');

  _eq(s.speed, 220.0, '未吃时速度 = 220ms');
  final s7 = SnakeGame(w: 15, h: 20, rnd: math.Random(17));
  s7.eaten = 5;
  _eq(s7.speed, 180.0, 'eaten=5 → 220-40 = 180ms');
  s7.eaten = 100;
  _eq(s7.speed, 90.0, '速度下限锁定 90ms');
}

// ───────────────────────────────────────────────────────────────────────────
// 3. 五子棋
// ───────────────────────────────────────────────────────────────────────────
void _gomoku() {
  print('\n3) 五子棋 落子 / 五连 / 和棋 / AI');

  final g = Gomoku();
  _eq(g.at(7, 7), Gomoku.empty, '开局中心为空');
  _eq(g.at(-1, 0), -1, '越界 at() 返回 -1');
  _eq(g.at(0, 99), -1, '越界 at() 返回 -1');

  _eq(g.place(7, 7, Gomoku.black), true, '空点可落子');
  _eq(g.place(7, 7, Gomoku.white), false, '已占点不能落子');
  _eq(g.at(7, 7), Gomoku.black, '落子后读回正确');

  // 横向五连
  final gh = Gomoku();
  for (var c = 3; c <= 7; c++) {
    gh.place(7, c, Gomoku.black);
  }
  _eq(gh.judge(7, 7), Gomoku.black, '横向五连判黑胜');
  _eq(gh.judge(7, 6), Gomoku.black, '五连中任意点都判胜');
  _eq(gh.judge(7, 3), Gomoku.black, '五连起点也判胜');

  // 仅四连不算赢
  final g4 = Gomoku();
  for (var c = 3; c <= 6; c++) {
    g4.place(7, c, Gomoku.black);
  }
  _eq(g4.judge(7, 6), 0, '四连未结束');

  // 竖向
  final gv = Gomoku();
  for (var r = 2; r <= 6; r++) {
    gv.place(r, 9, Gomoku.white);
  }
  _eq(gv.judge(4, 9), Gomoku.white, '竖向五连判白胜');

  // 主对角
  final gd = Gomoku();
  for (var k = 0; k < 5; k++) {
    gd.place(3 + k, 4 + k, Gomoku.black);
  }
  _eq(gd.judge(5, 6), Gomoku.black, '主对角五连判胜');

  // 副对角
  final ga = Gomoku();
  for (var k = 0; k < 5; k++) {
    ga.place(3 + k, 10 - k, Gomoku.white);
  }
  _eq(ga.judge(5, 8), Gomoku.white, '副对角五连判胜');

  // 六连也算胜(>=5)
  final g6 = Gomoku();
  for (var c = 2; c <= 7; c++) {
    g6.place(9, c, Gomoku.black);
  }
  _eq(g6.judge(9, 4), Gomoku.black, '六连同样判胜');

  // 和棋: 填满棋盘且无五连
  final gd2 = Gomoku();
  for (var r = 0; r < Gomoku.n; r++) {
    for (var c = 0; c < Gomoku.n; c++) {
      gd2.place(r, c, ((r + 2 * c) % 4 < 2) ? Gomoku.black : Gomoku.white);
    }
  }
  _eq(gd2.judge(7, 7), 3, '满盘无五连 → 和棋(3)');

  // AI: 空盘兜底回中心
  final ge = Gomoku();
  _eq(ge.bestMove(Gomoku.white), (7, 7), '空盘 bestMove 回中心');

  // AI: 有子时在附近落点
  final gb = Gomoku();
  gb.place(7, 7, Gomoku.black);
  final (br, bc) = gb.bestMove(Gomoku.white);
  _ok(gb.at(br, bc) == Gomoku.empty, 'AI 落点必须是空点');
  _ok((br - 7).abs() <= 2 && (bc - 7).abs() <= 2, 'AI 落点在已有棋子附近',
      '落点=($br,$bc)');

  // AI: 对手四连时必须去堵
  final gc = Gomoku();
  for (var c = 3; c <= 6; c++) {
    gc.place(7, c, Gomoku.black); // 黑四连, 两端 (7,2) / (7,7) 是活口
  }
  final (cr, cc) = gc.bestMove(Gomoku.white);
  _ok((cr == 7 && (cc == 2 || cc == 7)), '对手四连 → AI 去堵两端', '落点=($cr,$cc)');

  _ok(gc.scoreAt(7, 2, Gomoku.black) > 10000, 'scoreAt 对成五点给高分',
      '${gc.scoreAt(7, 2, Gomoku.black)}');
}

// ───────────────────────────────────────────────────────────────────────────
// 4. 局域网聊天协议
// ───────────────────────────────────────────────────────────────────────────
void _lan() {
  print('\n4) 局域网聊天 报文编解码 / 设备超时');

  final enc = lanEncode({'t': 'msg', 'text': '你好'});
  _ok(enc.contains('thirdhub'), '编码结果带 app 标识');
  final dec = lanDecode(enc);
  _ok(dec != null, '本应用报文可解码');
  _eq(dec!['t'], 'msg', '解码后 t 保留');
  _eq(dec['text'], '你好', '解码后中文内容完整');
  _eq(dec['app'], 'thirdhub', '解码后 app 标识存在');
  _eq(dec['v'], 1, '解码后协议版本 = 1');

  _eq(lanDecode('这不是 JSON'), null, '坏 JSON → null(不崩)');
  _eq(lanDecode(''), null, '空串 → null');
  _eq(lanDecode('[1,2,3]'), null, 'JSON 数组(非对象)→ null');
  _eq(lanDecode('{"a":1}'), null, '缺 app → null');
  _eq(lanDecode('{"app":"other","t":"x"}'), null, '别的应用 → null');
  _eq(lanDecode('{"app":"thirdhub"}'), null, '缺 t → null');
  _ok(lanDecode(lanEncode({'t': 'beat'})) != null, '心跳报文可解码');

  final now = DateTime(2026, 9, 19, 15, 0, 0);
  final fresh = LanPeer(id: 'a', name: '新设备', host: '192.168.1.2',
      seen: now.subtract(const Duration(seconds: 5)));
  final old = LanPeer(id: 'b', name: '旧设备', host: '192.168.1.3',
      seen: now.subtract(const Duration(seconds: 90)));
  final edge = LanPeer(id: 'c', name: '边界', host: '192.168.1.4',
      seen: now.subtract(const Duration(seconds: 45)));
  final kept = prunePeers([fresh, old, edge], now: now);
  _eq(kept.length, 2, '剔除超时设备后剩 2 台');
  _ok(kept.any((p) => p.id == 'a'), '5 秒内的设备保留');
  _ok(kept.any((p) => p.id == 'c'), '恰好 45 秒的设备保留(含边界)');
  _ok(!kept.any((p) => p.id == 'b'), '90 秒未见的设备被剔除');

  final m = LanMessage(from: 'aa', name: '阿丽', text: '在吗', mine: true, toAll: false);
  final m2 = LanMessage.from(jsonDecode(jsonEncode(m.toJson())) as Map<String, dynamic>);
  _eq(m2.from, 'aa', 'LanMessage 往返 from');
  _eq(m2.name, '阿丽', 'LanMessage 往返 name');
  _eq(m2.text, '在吗', 'LanMessage 往返 text');
  _eq(m2.mine, true, 'LanMessage 往返 mine');
  _eq(m2.toAll, false, 'LanMessage 往返 toAll');

  final m3 = LanMessage.from(<String, dynamic>{});
  _eq(m3.text, '', '字段缺失不崩(text = "")');
  _eq(m3.toAll, true, '字段缺失时 toAll 默认 true(群发)');
  _eq(m3.mine, false, '字段缺失时 mine 默认 false');
}

// ───────────────────────────────────────────────────────────────────────────
// 5. 社区 / 论坛
// ───────────────────────────────────────────────────────────────────────────
void _community() {
  print('\n5) 社区 / 论坛 导入去重合并');

  _eq(kPostKinds.first, '全部', '社区分类首项是"全部"');
  _ok(kPostKinds.contains('规则'), '社区分类含"规则"');
  _ok(kForumBoards.contains('公告'), '论坛板块含"公告"');

  CommunityPost post(String id, String title) =>
      CommunityPost(id: id, title: title, body: 'b', kind: '心得', tags: const ['t'], ts: 1);

  // 同 id 去重
  var add = mergePosts([post('1', 'A')], [post('1', 'A改'), post('2', 'B')]);
  _eq(add.length, 1, '同 id 的导入被跳过');
  _eq(add.first.id, '2', '只留下真正新增的那条');

  // 同标题去重(id 不同)
  add = mergePosts([post('1', '标题X')], [post('9', '标题X')]);
  _eq(add.length, 0, '同标题不同 id 也被跳过');

  // 全新条目全部收下
  add = mergePosts([post('1', 'A')], [post('2', 'B'), post('3', 'C')]);
  _eq(add.length, 2, '全新条目全部导入');

  // 批内自重复也要去重
  add = mergePosts(const [], [post('1', 'A'), post('1', 'A'), post('2', 'B')]);
  _eq(add.length, 2, '同一批里的重复条目也只收一条');

  add = mergePosts(const [], const []);
  _eq(add.length, 0, '空导入 → 空结果');

  // 反序列化默认值
  final p = CommunityPost.from(<String, dynamic>{'id': 'x', 'title': 'T'});
  _eq(p.kind, '心得', 'kind 缺省为"心得"');
  _eq(p.likes, 0, 'likes 缺省为 0');
  _eq(p.tags.length, 0, 'tags 缺省为空');
  _eq(p.body, '', 'body 缺省为空');
  final p2 = CommunityPost.from(<String, dynamic>{
    'id': 'y', 'title': 'T2', 'kind': '求助', 'tags': ['a', 7], 'likes': 3,
  });
  _eq(p2.tags.join(','), 'a,7', 'tags 内非字符串元素被转成字符串');
  _eq(p2.likes, 3, 'likes 正确读入');

  // 序列化往返
  final p3 = CommunityPost.from(
      jsonDecode(jsonEncode(post('1', 'A').toJson())) as Map<String, dynamic>);
  _eq(p3.id, '1', '社区帖子往返 id');
  _eq(p3.title, 'A', '社区帖子往返 title');
  _eq(p3.tags.join(','), 't', '社区帖子往返 tags');

  ForumTopic topic(String id, String title, {List<ForumReply>? reps}) =>
      ForumTopic(id: id, board: '综合', title: title, body: 'b', ts: 1, replies: reps);

  var tadd = mergeTopics([topic('1', 'T1')], [topic('1', 'T1改'), topic('2', 'T2')]);
  _eq(tadd.length, 1, '论坛同 id 去重');
  tadd = mergeTopics([topic('1', '同名')], [topic('2', '同名')]);
  _eq(tadd.length, 0, '论坛同标题去重');
  tadd = mergeTopics([topic('1', 'A')], [topic('2', 'B'), topic('3', 'C')]);
  _eq(tadd.length, 2, '论坛全新主题全部导入');

  final t = ForumTopic.from(<String, dynamic>{'id': 'z', 'title': '只有ID和标题'});
  _eq(t.board, '综合', '主题缺省板块为"综合"');
  _eq(t.replies.length, 0, '主题缺省无回复');

  final withReplies = ForumTopic.from(<String, dynamic>{
    'id': 'z2', 'board': '求助', 'title': 'T', 'body': 'B', 'ts': 5,
    'replies': [
      {'by': '甲', 'text': '我也遇到', 'ts': 6},
      {'by': '乙', 'text': '已解决', 'ts': 7},
    ],
  });
  _eq(withReplies.board, '求助', '主题板块读入');
  _eq(withReplies.replies.length, 2, '主题回复数读入');
  _eq(withReplies.replies.first.by, '甲', '首条回复作者');
  _eq(withReplies.replies.last.text, '已解决', '末条回复内容');
  _eq(withReplies.ts, 5, '主题时间读入');

  final rt = ForumTopic.from(
      jsonDecode(jsonEncode(withReplies.toJson())) as Map<String, dynamic>);
  _eq(rt.replies.length, 2, '主题 + 回复序列化往返');
  _eq(rt.replies.first.ts, 6, '回复时间往返');
}

// ───────────────────────────────────────────────────────────────────────────
// 6. 智能家居 Home Assistant
// ───────────────────────────────────────────────────────────────────────────
void _homeAssistant() {
  print('\n6) 智能家居 Home Assistant 域映射');

  _eq(haDomain('light.kitchen'), 'light', 'haDomain 取点号前段');
  _eq(haDomain('switch.plug_1'), 'switch', 'haDomain 下划线不干扰');
  _eq(haDomain('nodot'), 'nodot', '无点号时原样返回');
  _eq(haDomain('.leading'), '.leading', '点号开头视为无域');
  _eq(haDomain(''), '', '空串安全');

  _eq(haToggleable('light.x'), true, 'light 可开关');
  _eq(haToggleable('lock.front'), true, 'lock 可开关');
  _eq(haToggleable('cover.curtain'), true, 'cover 可开关');
  _eq(haToggleable('sensor.temp'), false, 'sensor 不可开关(只读)');
  _eq(haToggleable('camera.door'), false, 'camera 不可开关(只读)');
  _eq(haToggleable('scene.movie'), false, 'scene 用触发不用开关');

  _eq(haTriggerable('scene.movie'), true, 'scene 可触发');
  _eq(haTriggerable('script.x'), true, 'script 可触发');
  _eq(haTriggerable('automation.y'), true, 'automation 可触发');
  _eq(haTriggerable('light.x'), false, 'light 不用触发');

  _eq(haTurnOnService('light'), 'turn_on', '普通域开 = turn_on');
  _eq(haTurnOnService('cover'), 'open_cover', '窗帘开 = open_cover');
  _eq(haTurnOnService('lock'), 'unlock', '门锁开 = unlock');
  _eq(haTurnOffService('light'), 'turn_off', '普通域关 = turn_off');
  _eq(haTurnOffService('cover'), 'close_cover', '窗帘关 = close_cover');
  _eq(haTurnOffService('lock'), 'lock', '门锁关 = lock');

  _eq(haIsOn('on'), true, 'state "on" → 开');
  _eq(haIsOn('ON'), true, 'state 大写也认');
  _eq(haIsOn('open'), true, '"open"(窗帘)→ 开');
  _eq(haIsOn('unlocked'), true, '"unlocked"(门锁)→ 开');
  _eq(haIsOn('playing'), true, '"playing"(播放器)→ 开');
  _eq(haIsOn('off'), false, '"off" → 关');
  _eq(haIsOn('closed'), false, '"closed" → 关');
  _eq(haIsOn('unavailable'), false, '不可用 → 关');

  _eq(haDomainLabel('light'), '灯', 'light 中文名');
  _eq(haDomainLabel('switch'), '开关/插座', 'switch 中文名');
  _eq(haDomainLabel('vacuum'), '扫地机', 'vacuum 中文名');
  _eq(haDomainLabel('unknown_thing'), 'unknown_thing', '未知域原样回显');

  final e = HaEntity.from(<String, dynamic>{
    'entity_id': 'light.living',
    'state': 'on',
    'attributes': {'friendly_name': '客厅灯', 'unit_of_measurement': '', 'brightness': 120},
  });
  _eq(e.entityId, 'light.living', 'HaEntity entityId');
  _eq(e.name, '客厅灯', 'HaEntity 取 friendly_name 做显示名');
  _eq(e.state, 'on', 'HaEntity state');
  _eq(e.attrs['brightness'], 120, 'HaEntity 保留其余属性');

  final e2 = HaEntity.from(<String, dynamic>{'entity_id': 'sensor.x', 'state': '5'});
  _eq(e2.name, 'sensor.x', '无 friendly_name 时回退用 entity_id');
  _eq(e2.unit, '', '无单位时为空串');
  _eq(e2.attrs.length, 0, '无 attributes 时为空 Map');

  final e3 = HaEntity.from(<String, dynamic>{'entity_id': 'sensor.y', 'state': '9',
    'attributes': {'unit_of_measurement': '°C'}});
  _eq(e3.unit, '°C', '单位读入');
  _eq(e3.name, 'sensor.y', '有 attributes 但无 friendly_name 仍回退 entity_id');

  final e4 = HaEntity.from(<String, dynamic>{});
  _eq(e4.entityId, '', '空 Map 不崩');
}

// ───────────────────────────────────────────────────────────────────────────
// 7. 远程打印
// ───────────────────────────────────────────────────────────────────────────
void _print() {
  print('\n7) 远程打印 任务状态 / 中断恢复');

  _eq(PrintState.waiting.zh, '待提交', 'waiting 中文名');
  _eq(PrintState.sending.zh, '提交中', 'sending 中文名');
  _eq(PrintState.sent.zh, '已提交', 'sent 中文名');
  _eq(PrintState.failed.zh, '失败', 'failed 中文名');

  final j = PrintJob(id: 'a', title: '文档', content: 'hello', ts: 100);
  _eq(j.state, PrintState.waiting, '新建任务默认"待提交"');
  _eq(j.message, '', '新建任务 message 默认空');
  _eq(j.filePath, '', '新建任务默认非文件提交');

  j.state = PrintState.sent;
  j.message = '已送达 192.168.1.9';
  final j2 = PrintJob.from(jsonDecode(jsonEncode(j.toJson())) as Map<String, dynamic>);
  _eq(j2.id, 'a', '打印任务往返 id');
  _eq(j2.title, '文档', '打印任务往返 title');
  _eq(j2.content, 'hello', '打印任务往返 content');
  _eq(j2.state, PrintState.sent, '打印任务往返 state');
  _eq(j2.message, '已送达 192.168.1.9', '打印任务往返 message');
  _eq(j2.ts, 100, '打印任务往返时间戳');

  // 中断恢复: sending 退回 waiting
  final a = PrintJob(id: '1', title: 'A', content: '', ts: 1)..state = PrintState.sending;
  final b = PrintJob(id: '2', title: 'B', content: '', ts: 2)..state = PrintState.sent;
  final c = PrintJob(id: '3', title: 'C', content: '', ts: 3)..state = PrintState.failed;
  final recovered = recoverPrintJobs([a, b, c]);
  _eq(recovered[0].state, PrintState.waiting, '卡在"提交中"的任务退回"待提交"');
  _eq(recovered[0].message, '上次提交被中断', '退回时打上中断提示');
  _eq(recovered[1].state, PrintState.sent, '已提交的任务不受影响');
  _eq(recovered[2].state, PrintState.failed, '失败的任务不受影响(留证据给用户)');

  final empty = recoverPrintJobs(<PrintJob>[]);
  _eq(empty.length, 0, '空队列恢复安全');

  final f = PrintJob.from(<String, dynamic>{'id': 'x', 'state': '不存在的状态'});
  _eq(f.state, PrintState.waiting, '未知状态回退"待提交"(不崩)');
  _eq(f.ts, 0, '缺时间戳回退 0');
  _eq(f.message, '', '缺 message 回退空串');

  final fj = PrintJob(id: 'k', title: 'T', content: 'C', filePath: 'D:/a.pdf', ts: 9);
  final fj2 = PrintJob.from(jsonDecode(jsonEncode(fj.toJson())) as Map<String, dynamic>);
  _eq(fj2.filePath, 'D:/a.pdf', '本机文件路径往返');
}
