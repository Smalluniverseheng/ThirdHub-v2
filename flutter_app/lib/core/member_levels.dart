// ─────────────────────────────────────────────────────────────────────────────
// 会员等级（单一来源）—— 与网页端 `js/auth.js` 的 `LEVELS` **逐字对齐**
//
// 为什么要单独一个文件：
//   此前 App 端**根本没有读等级** —— 界面上只有两处写死的文案：
//     · `main.dart:3074`  `Text(logged ? '会员' : '游客')`
//     · `main.dart:13149` `Text('免费 · 会员体系冻结期')`
//   而 `th_profiles` 里的 `level` 字段其实**早就拉下来了**（`Cloud.profile()`），
//   只是没有任何界面用它 → 用户看到的永远是"会员"两个字，看不到自己到底是什么档。
//
// 分工（用户已拍板）：
//   · **购买只在网页端**（`js/modules/vip.js` 的会员中心）。
//   · App 端**只显示等级**，不做任何购买入口 —— 本文件里也刻意不含价格/下单逻辑，
//     `priceCny` 仅用于"这一档是付费档还是免费档"的判断与展示，不构成收银台。
//
// ★ 本文件刻意**不 import flutter**（颜色存 ARGB int）：
//   这样它可以用 `dart run` 直接跑自检（`tool/member_levels_selfcheck.dart`），
//   而不需要 flutter 环境。UI 侧再 `Color(level.colorValue)` 转。
// ─────────────────────────────────────────────────────────────────────────────

/// 一档会员等级。
class MemberLevel {
  /// 等级 id —— 与网页端 `LEVELS[].id` 逐字一致，也是云端 `th_profiles.level` 的取值。
  final String id;

  /// 显示名（中文）—— 与网页端 `LEVELS[].name` 逐字一致。
  final String name;

  /// 英文名 —— 与网页端 `vip.js` 套餐名里的英文一致（卫星版 Satellite 等）。
  final String nameEn;

  /// 徽章底色（ARGB）。与网页端 CSS 的 `lv-*` 配色同色系。
  final int colorValue;

  /// 云存储额度（字节）。`-1` 表示不限。
  final int storageBytes;

  /// 是否付费档。**仅用于展示判断**，App 端不提供购买。
  final bool paid;

  const MemberLevel({
    required this.id,
    required this.name,
    required this.nameEn,
    required this.colorValue,
    required this.storageBytes,
    required this.paid,
  });

  /// 是否不限量存储。
  bool get unlimitedStorage => storageBytes < 0;
}

/// 六档等级 —— 顺序即"由低到高"，充值/升级判断依赖这个顺序。
///
/// ★ 改动这里必须同步改网页端 `js/auth.js` 的 `LEVELS`；
///   `tool/member_levels_selfcheck.dart` 会拿网页端文件逐字比对。
const List<MemberLevel> kMemberLevels = <MemberLevel>[
  MemberLevel(
    id: 'guest',
    name: '游客',
    nameEn: 'Guest',
    colorValue: 0xFF9E9E9E, // 灰
    storageBytes: 0,
    paid: false,
  ),
  MemberLevel(
    id: 'satellite',
    name: '卫星',
    nameEn: 'Satellite',
    colorValue: 0xFF3B82F6, // 蓝
    storageBytes: 10 * 1024 * 1024, // 10MB
    paid: false,
  ),
  MemberLevel(
    id: 'planet',
    name: '行星',
    nameEn: 'Planet',
    colorValue: 0xFF10B981, // 绿
    storageBytes: 1024 * 1024 * 1024, // 1GB
    paid: true,
  ),
  MemberLevel(
    id: 'star',
    name: '恒星',
    nameEn: 'Star',
    colorValue: 0xFFF59E0B, // 橙
    storageBytes: 5 * 1024 * 1024 * 1024, // 5GB
    paid: true,
  ),
  MemberLevel(
    id: 'galaxy',
    name: '星系',
    nameEn: 'Galaxy',
    colorValue: 0xFF8B5CF6, // 紫
    storageBytes: 20 * 1024 * 1024 * 1024, // 20GB
    paid: true,
  ),
  MemberLevel(
    id: 'universe',
    name: '宇宙',
    nameEn: 'Universe',
    colorValue: 0xFFFACC15, // 金
    storageBytes: -1, // 不限
    paid: true,
  ),
];

/// 兜底档位：拿不到等级、或等级 id 不认识时用「游客」。
/// ★ 与网页端 `levelById()` 的兜底一致（`|| LEVELS[0]`）——**不要**兜底成"卫星"，
///   那会让未登录用户白看到 10MB 额度。
///
/// 注：这里只能是 `final` 而不是 `const` —— Dart 不允许在常量表达式里对
/// 常量列表取下标（`kMemberLevels[0]` 会报 "method '[]' can't be invoked"）。
final MemberLevel kGuestLevel = kMemberLevels[0];

/// 按 id 取等级。认不出就返回游客档（不抛异常 —— 云端加了新档时旧客户端不能崩）。
MemberLevel memberLevelById(String? id) {
  if (id == null || id.isEmpty) return kGuestLevel;
  for (final MemberLevel l in kMemberLevels) {
    if (l.id == id) return l;
  }
  return kGuestLevel;
}

/// 档次高低（0 起）。用于比较"是不是更高档"。
int memberLevelRank(String? id) {
  for (int i = 0; i < kMemberLevels.length; i++) {
    if (kMemberLevels[i].id == id) return i;
  }
  return 0;
}

/// 额度文案：不限 / 10MB / 1GB …
String memberStorageText(MemberLevel l) {
  if (l.unlimitedStorage) return '不限';
  final int b = l.storageBytes;
  if (b >= 1024 * 1024 * 1024) {
    final double g = b / (1024 * 1024 * 1024);
    return '${g == g.roundToDouble() ? g.round() : g}GB';
  }
  if (b >= 1024 * 1024) {
    final double m = b / (1024 * 1024);
    return '${m == m.roundToDouble() ? m.round() : m}MB';
  }
  if (b <= 0) return '无';
  return '${b}B';
}

/// 把「会员等级」这一行的说明文案统一在这里生成 ——
/// 避免再次出现"页面上写死一句话、跟真实等级对不上"的老问题。
///
/// · 未登录 → 引导登录
/// · 已登录 → `卫星 · 云存储 10MB`
String memberSubtitle({
  required bool loggedIn,
  required String? levelId,
  String? expireAt,
}) {
  if (!loggedIn) return '未登录 · 登录后同步网页端等级';
  final MemberLevel l = memberLevelById(levelId);
  final String base = '${l.name} · 云存储 ${memberStorageText(l)}';
  final String exp = _expireText(expireAt);
  return exp.isEmpty ? base : '$base · $exp';
}

/// 到期文案。给不出日期就返回空串（不显示，比显示"已过期"更安全）。
String _expireText(String? expireAt) {
  if (expireAt == null || expireAt.isEmpty) return '';
  final DateTime? d = DateTime.tryParse(expireAt);
  if (d == null) return '';
  final DateTime now = DateTime.now();
  if (!d.isAfter(now)) return '已过期';
  final int days = d.difference(now).inDays;
  if (days <= 0) return '今日到期';
  return '$days 天后到期';
}
