// 短剧模块门控（4.81.94 建，4.81.111 测试阶段全开）。
//
// 4.81.111：用户明确「目前在测试，所有权限全部开放，让第一时间能体验」。
// 因此 unlocked 恒 true，去掉激活码/管理员门槛。门控代码保留但不再拦截，
// 后期要做「账号鉴权 → 云端下发模块解锁」时在这里恢复即可（见 README）。
// 注意：这**不是**安全边界，所有能力都在端上，门控只决定要不要拦普通用户。
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _kUnlocked = 'drama_unlocked';

/// 激活码 hash（SHA256）。明文由持有者保管，不写进包/日志/更新日志。
/// 默认值是占位符 hash；真实使用时用户可在「设置」里替换自己的码。
/// 这里放行逻辑：预置 owner 码的 hash，或管理员态。
const String kOwnerCodeHash =
    '8d969eef6ecad3c29a3a629280e686cf0c3f5d5a86aff3ca12020c923adc6c92'; // "123456" 示例

class DramaGate {
  DramaGate._();
  static final DramaGate I = DramaGate._();

  // 后期恢复门控时启用；测试阶段恒 true，字段仅保留状态供设置页读写。
  // ignore: unused_field
  bool _localUnlocked = false;

  /// 测试阶段（4.81.111）恒放行：所有用户直接可用，无需激活码 / 管理员账号。
  /// 后期要做账号鉴权时把这里改回 `_localUnlocked || ChangelogStore.isAdmin` 即可。
  bool get unlocked => true;

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    _localUnlocked = p.getBool(_kUnlocked) ?? false;
  }

  /// 校验激活码：匹配 owner hash 则解锁并存状态
  Future<bool> tryActivate(String code) async {
    final normalized = code.trim();
    if (normalized.isEmpty) return false;
    final h = sha256.convert(utf8.encode(normalized)).toString();
    if (h == kOwnerCodeHash) {
      _localUnlocked = true;
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kUnlocked, true);
      return true;
    }
    return false;
  }

  Future<void> deactivate() async {
    _localUnlocked = false;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kUnlocked, false);
  }
}
