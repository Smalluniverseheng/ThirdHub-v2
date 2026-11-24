// 短剧模块解锁门控（4.81.94）——管理员账号或激活码二选一放行。
//
// 用户诉求："软件本身要有这个功能，当我输入激活码或者检测到是我这个管理员账号
// 的时候，就能够正常使用。" 本模块实现这个门控：
//   · 管理员：复用 ChangelogStore.isAdmin（登录态里 role=admin / is_admin=true）
//   · 激活码：本地 SHA256 比对，成功状态存 prefs；激活码常量只存 hash 不存明文
//
// 注意：这是**功能开关**不是安全边界——所有内容都在端上，破解者绕过开关没有
// 意义（他们直接改包即可）。它只是让普通用户不会误入、授权用户能正常用。
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'changelog.dart' show ChangelogStore;

const String _kUnlocked = 'drama_unlocked';

/// 激活码 hash（SHA256）。明文由持有者保管，不写进包/日志/更新日志。
/// 默认值是占位符 hash；真实使用时用户可在「设置」里替换自己的码。
/// 这里放行逻辑：预置 owner 码的 hash，或管理员态。
const String kOwnerCodeHash =
    '8d969eef6ecad3c29a3a629280e686cf0c3f5d5a86aff3ca12020c923adc6c92'; // "123456" 示例

class DramaGate {
  DramaGate._();
  static final DramaGate I = DramaGate._();

  bool _localUnlocked = false;

  bool get unlocked => _localUnlocked || ChangelogStore.isAdmin;

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
