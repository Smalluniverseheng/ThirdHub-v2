// ═══════════════════════════════════════════════════════════════════════════
// 局域网聊天 · 端到端加密（X25519 + AES-256-GCM）
//
// 对应 `docs/LANCHAT-PROTOCOL.md` §4。零 Flutter 依赖（cryptography 是纯 Dart），
// 所以可以直接跑 `dart run tool/chat_proto_selfcheck.dart` 验证。
//
// ★ 三条不可动摇的设计：
//  ① 长期身份密钥**不是每次广播现生成** —— 指纹必须稳定，否则用户每次核对
//    都对不上，核对这件事就失去意义。
//  ② `mid` 与 `ts` 进 AAD —— 篡改这两个字段必须导致解密失败，
//     否则攻击者可以把一条老消息的 id 换掉来伪造"撤回/重发"。
//  ③ 解密失败**返回 null**，由 UI 显示"无法解密"。绝不放行半截乱码。
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:convert';
import 'dart:math' as math;

import 'package:cryptography/cryptography.dart';

class ChatCrypto {
  ChatCrypto._();

  static final X25519 _x = X25519();
  static final AesGcm _aes = AesGcm.with256bits();
  static final Sha256 _sha = Sha256();
  static final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  /// HKDF 的 info 常量 —— 换它就等于换协议，必须有版本字样。
  static const String _kInfo = 'lanchat-msg-v1';

  /// salt 前缀：参与 HKDF，且排序后取用（双方算出同一个 salt）。
  static const String _kSaltPrefix = 'thirdhub-lanchat-v1';

  static final math.Random _rnd = math.Random.secure();

  /// 生成 32 字节随机 seed（用于身份密钥）。
  static List<int> newSeed() =>
      List<int>.generate(32, (_) => _rnd.nextInt(256));

  // ═══ 身份 ═══

  /// 由 seed 还原/新建身份密钥对，返回 `(公钥 bytes, 私钥 seed)`。
  ///
  /// seed 为 null 时新建。**调用方负责把 seed 持久化**（本文件不碰存储，
  /// 这样纯 Dart 自检不必装 shared_preferences）。
  static Future<(List<int> pub, List<int> seed)> identity(
      List<int>? seed) async {
    final s = (seed != null && seed.length == 32) ? seed : newSeed();
    final kp = await _x.newKeyPairFromSeed(s);
    final pub = await kp.extractPublicKey();
    return (pub.bytes, s);
  }

  /// 公钥指纹：SHA-256 前 8 字节的 hex（16 个字符），供用户肉眼核对。
  static Future<String> fingerprint(List<int> pub) async {
    final h = await _sha.hash(pub);
    return h.bytes
        .take(8)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  // ═══ 会话密钥 ═══

  /// 由「我方 seed + 我方公钥 + 对方公钥」派生会话密钥。
  ///
  /// salt 里把两个公钥**排序后拼接** —— 这样 A 端与 B 端算出的 salt 一致，
  /// 无需协商谁先谁后。
  static Future<SecretKey> sessionKey({
    required List<int> mySeed,
    required List<int> myPub,
    required List<int> peerPub,
  }) async {
    final mine = await _x.newKeyPairFromSeed(mySeed);
    final shared = await _x.sharedSecretKey(
      keyPair: mine,
      remotePublicKey: SimplePublicKey(peerPub, type: KeyPairType.x25519),
    );

    final pair = [base64Encode(myPub), base64Encode(peerPub)]..sort();
    final saltBytes = utf8.encode('$_kSaltPrefix|${pair[0]}|${pair[1]}');

    return _hkdf.deriveKey(
      secretKey: shared,
      nonce: saltBytes, // HKDF 的 salt
      info: utf8.encode(_kInfo),
    );
  }

  // ═══ 加解密 ═══

  /// 加密正文，返回 `{'ct': base64, 'iv': base64}`。
  ///
  /// `mid` 与 `ts` 进 AAD：改其中任何一个都会让解密失败。
  static Future<Map<String, String>> encryptText(
    String plain,
    SecretKey key, {
    required String mid,
    required int ts,
  }) async {
    final nonce = _aes.newNonce();
    final box = await _aes.encrypt(
      utf8.encode(plain),
      secretKey: key,
      nonce: nonce,
      aad: _aad(mid, ts),
    );
    return {
      'ct': base64Encode([...box.cipherText, ...box.mac.bytes]),
      'iv': base64Encode(box.nonce),
    };
  }

  /// 解密。**失败一律返回 null**（绝不放行乱码）。
  ///
  /// 密文格式：`ct || mac(16B)` 拼在一起再 base64。
  static Future<String?> decryptText(
    Map<String, dynamic> payload,
    SecretKey key, {
    required String mid,
    required int ts,
  }) async {
    try {
      final raw = base64Decode('${payload['ct'] ?? ''}');
      final iv = base64Decode('${payload['iv'] ?? ''}');
      if (raw.length < 16 || iv.isEmpty) return null;
      final ct = raw.sublist(0, raw.length - 16);
      final mac = raw.sublist(raw.length - 16);

      final clear = await _aes.decrypt(
        SecretBox(ct, nonce: iv, mac: Mac(mac)),
        secretKey: key,
        aad: _aad(mid, ts),
      );
      return utf8.decode(clear);
    } catch (_) {
      return null; // 密钥不匹配 / 被篡改 / 格式坏 —— 一律归为"无法解密"
    }
  }

  /// 把 mid+ts 编成 AAD 字节。用不可见分隔符，避免拼接歧义。
  static List<int> _aad(String mid, int ts) => utf8.encode('$mid\u0001$ts');

  /// 字节流的 SHA-256（base64），用于文件完整性校验。
  static Future<String> sha256B64(List<int> bytes) async {
    final h = await _sha.hash(bytes);
    return base64Encode(h.bytes);
  }

  // ═══ 工具 ═══

  /// bytes → base64（报文里公钥/密文都用它）。
  static String b64(List<int> b) => base64Encode(b);

  /// base64 → bytes；坏输入返回 null（公网来的数据不能崩）。
  static List<int>? unb64(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      return base64Decode(s);
    } catch (_) {
      return null;
    }
  }
}
