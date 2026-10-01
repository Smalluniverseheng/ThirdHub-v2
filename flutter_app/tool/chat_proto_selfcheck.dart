// 局域网聊天协议 LANCHAT/1 自检（纯 Dart VM 可跑，零 Flutter 依赖）
//
//   cd flutter_app
//   dart.exe --disable-dart-dev --packages=.dart_tool/package_config.json \
//     tool/chat_proto_selfcheck.dart
//
// 对应 `docs/LANCHAT-PROTOCOL.md`。与 `server/test_agent_proto.cjs` 同一路数：
// **只断言行为，不断言数据结构长什么样**——结构改了但行为对，不该红；
// 行为错了但结构没变，必须红。
//
// ★ 失败必须非零退出。CI 的 dart-selfcheck 只看退出码，
//   只打印 FAIL 而 return 0 的话闸门形同虚设（2026-09-28 的教训）。
import 'dart:io';

import '../lib/core/chat_crypto.dart';
import '../lib/core/chat_logic.dart';

int pass = 0, fail = 0;
void ck(String name, bool ok) {
  if (ok) {
    pass++;
  } else {
    fail++;
    print('  FAIL  $name');
  }
}

Future<void> main() async {
  await envelope();
  await legacy();
  await dedupeAndOrder();
  await capAndPlan();
  await texts();
  await friends();
  await cryptoIdentity();
  await cryptoSession();
  await cryptoIntegrity();
  await hashing();

  print('');
  print('PASS $pass   FAIL $fail');
  if (fail == 0) print('\n✅ 全部通过');
  if (fail > 0) exit(1);
}

// ═══════════════════════════════════════════════════════════════════
// 1. 信封
// ═══════════════════════════════════════════════════════════════════
Future<void> envelope() async {
  print('== 1. 信封编解码 ==');
  final raw = encodeV2({'t': ChatT.hi, 'id': 'a1', 'name': '手机'});
  final m = decodeV2(raw);
  ck('自家报文能解出', m != null);
  ck('解出的 t 正确', m?['t'] == 'hi');
  ck('解出的 id 正确', m?['id'] == 'a1');
  ck('信封带 app 标记', m?['app'] == 'thirdhub');
  ck('信封带当前协议版本', m?['v'] == kLanChatVersion);

  // 各种坏输入：解析层绝不允许抛异常穿透到 socket 回调
  ck('坏 JSON → null', decodeV2('{不是 json') == null);
  ck('纯文本 → null', decodeV2('hello world') == null);
  ck('JSON 数组 → null', decodeV2('[1,2,3]') == null);
  ck('别的 app → null', decodeV2('{"app":"other","t":"hi"}') == null);
  ck('缺 t → null', decodeV2('{"app":"thirdhub"}') == null);
  ck('空串 → null', decodeV2('') == null);

  // 未来版本：不猜格式，直接丢
  ck('未来版本 v=99 → null', decodeV2('{"app":"thirdhub","t":"hi","v":99}') == null);
  ck('同版本 v=2 → 能解', decodeV2('{"app":"thirdhub","t":"hi","v":2}') != null);
}

// ═══════════════════════════════════════════════════════════════════
// 2. 旧版兼容
// ═══════════════════════════════════════════════════════════════════
Future<void> legacy() async {
  print('== 2. 旧版设备兼容 ==');
  // v1 报文没有 v 字段 —— 必须仍被认出来（否则老设备在新版眼里"消失"）
  final v1 = decodeV2('{"app":"thirdhub","t":"msg","id":"old","text":"你好"}');
  ck('无 v 字段的报文仍可解', v1 != null);
  ck('无 v → 判为 legacy', isLegacyEnvelope(v1!));
  ck('v=1 → 判为 legacy', isLegacyEnvelope({'v': 1, 't': 'msg'}));
  ck('v=2 → 不是 legacy', !isLegacyEnvelope({'v': 2, 't': 'msg'}));
  ck('v 缺失 → legacy', isLegacyEnvelope({'t': 'msg'}));
}

// ═══════════════════════════════════════════════════════════════════
// 3. 去重 + 排序（协议 §3）
// ═══════════════════════════════════════════════════════════════════
LanMessage2 mk(String from, String mid, int ts, {String text = 'x'}) =>
    LanMessage2(
      mid: mid,
      from: from,
      fromName: from,
      to: '*',
      toAll: true,
      kind: ChatKind.text,
      text: text,
      enc: ChatEnc.none,
      ts: ts,
    );

Future<void> dedupeAndOrder() async {
  print('== 3. 去重与排序 ==');

  // ★核心：同一条消息经广播 + 单播双到达，必须只显示一条
  final doubled = [mk('A', 'm1', 100), mk('A', 'm1', 100)];
  ck('广播+单播双到达 → 只剩 1 条', dedupeMessages(doubled).length == 1);

  // 不同发送方的相同 mid 不能互相吃掉
  final sameMid = [mk('A', 'm1', 100), mk('B', 'm1', 100)];
  ck('不同 from 的同 mid → 保留 2 条', dedupeMessages(sameMid).length == 2);

  // 同发送方不同 mid 全保留
  ck('同 from 不同 mid → 2 条',
      dedupeMessages([mk('A', 'm1', 100), mk('A', 'm2', 200)]).length == 2);

  // 去重必须保序，否则 render 会跳
  final order = dedupeMessages([mk('A', 'm1', 100), mk('B', 'm2', 200)]);
  ck('去重保持输入顺序', order.first.mid == 'm1' && order.last.mid == 'm2');

  // 排序：ts 递增
  final sorted = normalizeMessages([mk('A', 'c', 300), mk('A', 'a', 100), mk('A', 'b', 200)]);
  ck('按 ts 升序', sorted.map((e) => e.mid).join(',') == 'a,b,c');

  // ★兜底：ts 相同时靠 mid 字典序，保证每次渲染顺序一致
  final tie1 = normalizeMessages([mk('A', 'bb', 500), mk('A', 'aa', 500)]);
  final tie2 = normalizeMessages([mk('A', 'aa', 500), mk('A', 'bb', 500)]);
  ck('ts 相同 → mid 字典序兜底', tie1.map((e) => e.mid).join(',') == 'aa,bb');
  ck('兜底结果与输入顺序无关', tie2.map((e) => e.mid).join(',') == 'aa,bb');

  // 截断：超上限时丢最旧、留最新
  final many = [for (var i = 0; i < kLanMsgKeep + 7; i++) mk('A', 'm$i', i)];
  final trimmed = trimMessages(normalizeMessages(many));
  ck('截断到上限条数', trimmed.length == kLanMsgKeep);
  ck('截断丢的是最旧的', trimmed.first.ts == 7);
  ck('截断留的是最新的', trimmed.last.ts == kLanMsgKeep + 6);
  ck('未超上限则原样返回', trimMessages([mk('A', 'z', 1)]).length == 1);
}

// ═══════════════════════════════════════════════════════════════════
// 4. 能力声明与加密降级（协议 §4.3）—— 本协议最容易出错的地方
// ═══════════════════════════════════════════════════════════════════
Future<void> capAndPlan() async {
  print('== 4. 能力与降级 ==');

  final full = ChatCaps.parse(['text', 'file', 'enc']);
  ck('完整能力 → text/file/enc 全真', full.text && full.file && full.enc);

  // 老设备没 cap 字段 → 只当纯文本，宁可少给能力也不误判
  final none = ChatCaps.parse(null);
  ck('缺 cap → 只认 text', none.text && !none.file && !none.enc);
  ck('空列表 → 只认 text', !ChatCaps.parse([]).file);
  ck('未知能力串 → 三项皆假',
      !ChatCaps.parse(['wat']).text && !ChatCaps.parse(['wat']).enc);
  ck('toList 可往返', ChatCaps.parse(full.toList()).enc);

  // 三条传播序
  final b = planSend(broadcast: true, peerSupportsEnc: true, havePeerKey: true);
  ck('★广播 → 明文', !b.encrypted);
  ck('★广播 → 必须给原因', b.reason != null && b.reason!.isNotEmpty);

  final old = planSend(broadcast: false, peerSupportsEnc: false, havePeerKey: true);
  ck('对端不支持加密 → 明文', !old.encrypted);
  ck('对端不支持加密 → 必须给原因', old.reason != null);

  final noKey = planSend(broadcast: false, peerSupportsEnc: true, havePeerKey: false);
  ck('没有对方公钥 → 明文', !noKey.encrypted);
  ck('没有对方公钥 → 必须给原因', noKey.reason != null);

  final ok = planSend(broadcast: false, peerSupportsEnc: true, havePeerKey: true);
  ck('★私聊且条件齐 → 加密', ok.encrypted);
  ck('加密路径不降级 → reason 为 null', ok.reason == null);

  // 反向：广播即使万事俱备也不能加密（否则对端解不开）
  ck('广播永不加密（反证）',
      !planSend(broadcast: true, peerSupportsEnc: true, havePeerKey: true).encrypted);
}

// ═══════════════════════════════════════════════════════════════════
// 5. 文本与文件大小
// ═══════════════════════════════════════════════════════════════════
Future<void> texts() async {
  print('== 5. 文本/大小 ==');
  final (t1, cut1) = clampText('短');
  ck('未超长不截断', !cut1 && t1 == '短');

  final long = 'a' * (kChatTextMaxChars + 50);
  final (t2, cut2) = clampText(long);
  ck('超长被截断', cut2);
  ck('截断到上限长度', t2.length == kChatTextMaxChars);
  final (t3, cut3) = clampText('a' * kChatTextMaxChars);
  ck('恰好等于上限不截断', !cut3 && t3.length == kChatTextMaxChars);

  ck('B 级', fmtBytes(512) == '512 B');
  ck('KB 级', fmtBytes(2048) == '2.0 KB');
  ck('MB 级', fmtBytes(3 * 1024 * 1024) == '3.0 MB');
  ck('GB 级', fmtBytes(2 * 1024 * 1024 * 1024) == '2.00 GB');
  ck('0 字节不崩', fmtBytes(0) == '0 B');

  ck('文件上限正是 2GB', kChatFileMaxBytes == 2147483648);
  ck('2GB 恰好不超限', !(kChatFileMaxBytes > kChatFileMaxBytes));
}

// ═══════════════════════════════════════════════════════════════════
// 6. 好友持久化
// ═══════════════════════════════════════════════════════════════════
Future<void> friends() async {
  print('== 6. 好友 ==');
  final f = ChatFriend(id: 'p1', name: '客厅平板', host: '192.168.1.7', fp: 'ab12cd34');
  final back = ChatFriend.from(f.toJson());
  ck('id 往返', back.id == 'p1');
  ck('name 往返', back.name == '客厅平板');
  ck('host 往返', back.host == '192.168.1.7');
  ck('★指纹往返（身份锚点不能丢）', back.fp == 'ab12cd34');
  ck('blocked 默认假', !back.blocked);

  final b = ChatFriend.from(f.toJson())..blocked = true;
  ck('blocked 往返', ChatFriend.from(b.toJson()).blocked);

  ck('在线好友可见', isFriendVisible(f, online: true));
  ck('见过面的离线好友仍可见', isFriendVisible(f, online: false));
  ck('拉黑后不可见（在线也不可见）',
      !isFriendVisible(f..blocked = true, online: true));

  // 缺字段不该崩
  final bare = ChatFriend.from(<String, dynamic>{});
  ck('空 JSON 不崩且有名字兜底', bare.name.isNotEmpty);

  ck('区域频道 sid 与好友 sid 不撞',
      kBroadcastSid != friendSid('x'));
  ck('好友 sid 由 id 决定', friendSid('p1') == 'lan:p1');
}

// ═══════════════════════════════════════════════════════════════════
// 7. 身份密钥与指纹（协议 §4.1）
// ═══════════════════════════════════════════════════════════════════
Future<void> cryptoIdentity() async {
  print('== 7. 身份与指纹 ==');
  final seed = ChatCrypto.newSeed();
  ck('seed 是 32 字节', seed.length == 32);

  final (pubA, seedA) = await ChatCrypto.identity(seed);
  final (pubB, seedB) = await ChatCrypto.identity(seed);
  ck('公钥 32 字节', pubA.length == 32);
  ck('同 seed → 同公钥（确定性的）', pubA.join(',') == pubB.join(','));
  ck('同 seed → 同 seed 回显', seedA.join(',') == seedB.join(','));

  // ★ 指纹稳定：同一 seed 重建身份设备，指纹必须不变，否则"核对指纹"没有意义
  final fp1 = await ChatCrypto.fingerprint(pubA);
  final fp2 = await ChatCrypto.fingerprint(pubB);
  ck('指纹 16 位 hex', fp1.length == 16);
  ck('指纹是纯 hex', RegExp(r'^[0-9a-f]{16}$').hasMatch(fp1));
  ck('★同 seed 重建设备 → 指纹不变', fp1 == fp2);

  final (pubC, _) = await ChatCrypto.identity(ChatCrypto.newSeed());
  final fp3 = await ChatCrypto.fingerprint(pubC);
  ck('不同 seed → 指纹不同', fp1 != fp3);

  // 坏 seed 不能当身份用（长度不对要重新生成，而不是硬塞）
  final (pubD, seedD) = await ChatCrypto.identity([1, 2, 3]);
  ck('坏长度 seed → 重新生成 32 字节', seedD.length == 32);
  ck('坏长度 seed → 公钥仍合法', pubD.length == 32);
}

// ═══════════════════════════════════════════════════════════════════
// 8. 会话密钥协商（协议 §4.2）—— 端到端加密能否成立的根
// ═══════════════════════════════════════════════════════════════════
Future<void> cryptoSession() async {
  print('== 8. 会话密钥协商 ==');
  final (pubA, seedA) = await ChatCrypto.identity(ChatCrypto.newSeed());
  final (pubB, seedB) = await ChatCrypto.identity(ChatCrypto.newSeed());

  final kAB = await ChatCrypto.sessionKey(mySeed: seedA, myPub: pubA, peerPub: pubB);
  final kBA = await ChatCrypto.sessionKey(mySeed: seedB, myPub: pubB, peerPub: pubA);

  // ★ 这是整个端到端加密的地基：两端各自算出的密钥必须一样。
  //   用真实数据反证一次——拿 A 端密钥加密，B 端密钥必须解得开。
  final box = await ChatCrypto.encryptText('密钥一致验证', kAB, mid: 'm1', ts: 1000);
  final opened = await ChatCrypto.decryptText(
      {'ct': box['ct'], 'iv': box['iv']}, kBA, mid: 'm1', ts: 1000);
  ck('★A 加密 → B 解密（密钥协商成立）', opened == '密钥一致验证');

  // 反向再来一遍，排除"恰好单向成立"
  final box2 = await ChatCrypto.encryptText('反向', kBA, mid: 'm2', ts: 2000);
  final opened2 = await ChatCrypto.decryptText(
      {'ct': box2['ct'], 'iv': box2['iv']}, kAB, mid: 'm2', ts: 2000);
  ck('★B 加密 → A 解密（反向也成立）', opened2 == '反向');

  // 第三者 C 的密钥解不开
  final (pubC, seedC) = await ChatCrypto.identity(ChatCrypto.newSeed());
  final kCA = await ChatCrypto.sessionKey(mySeed: seedC, myPub: pubC, peerPub: pubA);
  final box3 = await ChatCrypto.encryptText('机密', kAB, mid: 'm3', ts: 3000);
  final spy = await ChatCrypto.decryptText(
      {'ct': box3['ct'], 'iv': box3['iv']}, kCA, mid: 'm3', ts: 3000);
  ck('★第三方密钥解不开（不是摆设）', spy == null);

  // 中文 / emoji / 超长 都要能原样往返
  for (final s in ['你好，世界', 'a\nb\tc', '中英混 mix 123', '。' * 500]) {
    final e = await ChatCrypto.encryptText(s, kAB, mid: 'x', ts: 1);
    final d = await ChatCrypto.decryptText(
        {'ct': e['ct'], 'iv': e['iv']}, kBA, mid: 'x', ts: 1);
    ck('往返一致: ${s.length > 8 ? '${s.substring(0, 8)}…' : s}', d == s);
  }
}

// ═══════════════════════════════════════════════════════════════════
// 9. 完整性：AAD 防篡改（协议 §4.2 铁律 ②）
// ═══════════════════════════════════════════════════════════════════
Future<void> cryptoIntegrity() async {
  print('== 9. 防篡改 ==');
  final (pubA, seedA) = await ChatCrypto.identity(ChatCrypto.newSeed());
  final (pubB, seedB) = await ChatCrypto.identity(ChatCrypto.newSeed());
  final k = await ChatCrypto.sessionKey(mySeed: seedA, myPub: pubA, peerPub: pubB);

  final e = await ChatCrypto.encryptText('原文', k, mid: 'mid-1', ts: 1000);
  final payload = {'ct': e['ct'], 'iv': e['iv']};

  ck('参数一致 → 解得开', (await ChatCrypto.decryptText(payload, k, mid: 'mid-1', ts: 1000)) == '原文');
  // ★ 改 mid 必须失败 —— 否则可以把老消息的 id 换掉伪造"再发一次"
  ck('★改 mid → 解密失败', (await ChatCrypto.decryptText(payload, k, mid: 'mid-2', ts: 1000)) == null);
  // ★ 改 ts 同理
  ck('★改 ts → 解密失败', (await ChatCrypto.decryptText(payload, k, mid: 'mid-1', ts: 1001)) == null);

  // 篡改密文本体 → MAC 校验失败
  final raw = payload['ct']!;
  final tampered = raw.substring(0, raw.length - 2) + (raw.endsWith('A') ? 'B' : 'A');
  ck('★篡改密文 → 解密失败',
      (await ChatCrypto.decryptText({'ct': tampered, 'iv': e['iv']}, k, mid: 'mid-1', ts: 1000)) == null);

  // 篡改 IV
  final iv = payload['iv']!;
  final ivBad = iv.substring(0, iv.length - 2) + (iv.endsWith('A') ? 'B' : 'A');
  ck('★篡改 IV → 解密失败',
      (await ChatCrypto.decryptText({'ct': e['ct'], 'iv': ivBad}, k, mid: 'mid-1', ts: 1000)) == null);

  // 垃圾输入绝不能抛异常穿透（解析层红线：公网上什么包都有）
  for (final bad in [
    <String, dynamic>{},
    <String, dynamic>{'ct': '', 'iv': ''},
    <String, dynamic>{'ct': '!!!!', 'iv': 'AAAA'},
    <String, dynamic>{'ct': 'AAAA', 'iv': '!!!!'},
    <String, dynamic>{'ct': 'AA', 'iv': 'AA'}, // 短于一个 MAC
  ]) {
    var threw = false;
    String? r;
    try {
      r = await ChatCrypto.decryptText(bad, k, mid: 'm', ts: 1);
    } catch (_) {
      threw = true;
    }
    ck('坏密文不抛异常且返回 null: ${bad['ct'] ?? '(空)'}', !threw && r == null);
  }

  // base64 往返
  ck('b64 → unb64 往返', ChatCrypto.unb64(ChatCrypto.b64([1, 2, 255]))!.join(',') == '1,2,255');
  ck('坏 base64 → null', ChatCrypto.unb64('!!!!') == null);
  ck('null → null', ChatCrypto.unb64(null) == null);
  ck('空串 → null', ChatCrypto.unb64('') == null);
}

// ═══════════════════════════════════════════════════════════════════
// 10. 摘要（文件传输校验用）
// ═══════════════════════════════════════════════════════════════════
Future<void> hashing() async {
  print('== 10. 摘要 ==');
  // 已知向量：SHA-256("") 与 SHA-256("abc") 的 base64
  final empty = await ChatCrypto.sha256B64(const []);
  ck('★空串摘要符合公开向量', empty == '47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=');

  final abc = await ChatCrypto.sha256B64(const [0x61, 0x62, 0x63]);
  ck('★"abc" 摘要符合公开向量', abc == 'ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=');

  // 内容变了摘要必须变（否则文件校验形同虚设）
  final a = await ChatCrypto.sha256B64([1, 2, 3]);
  final b = await ChatCrypto.sha256B64([1, 2, 4]);
  ck('★改 1 字节 → 摘要不同', a != b);
  ck('同内容 → 摘要相同', a == await ChatCrypto.sha256B64([1, 2, 3]));
}
