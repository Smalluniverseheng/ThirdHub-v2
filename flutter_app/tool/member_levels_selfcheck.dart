// 会员等级自检（纯 Dart VM 可跑，零 Flutter 依赖）
//
//   dart.exe --disable-dart-dev --packages=.dart_tool/package_config.json \
//     tool/member_levels_selfcheck.dart
//
// 覆盖两件事：
//   一、**纯 Dart 断言**：六档完整性 / 顺序 / id 唯一 / 兜底行为 / 额度文案 /
//       副标题文案 —— 不依赖任何外部文件，任何环境都能跑。
//   二、**跨端一致性**：与网页端 `js/auth.js` 的 `LEVELS` **逐字对齐**
//       （id / 中文名 / 顺序 / 云存储额度）。这是"两端等级不会再漂"的机械保障。
//
// ★ 关于网页端文件找不到时怎么办（本项目铁律：传了就必须扫到，否则是假绿）：
//   这里采取**硬失败** —— 找不到就 exit 1 并打印找过的每个路径。
//   理由：这条闸门的存在意义**就是**跨端对齐；扫不到目标时"通过"是假的。
//   本地开发若只想跑纯 Dart 部分，传 `--no-web` 显式跳过（CI 绝不传）。
//
// ★ 断言一律用 join(',') 比较 —— Dart 的 List == 是引用比较，直接 == [...] 恒假。
import '../lib/core/member_levels.dart';
import 'dart:io';

int pass = 0, fail = 0;
void ck(String name, bool ok) {
  if (ok) {
    pass++;
  } else {
    fail++;
    print('  FAIL  $name');
  }
}

/// 网页端 js/auth.js 的候选位置（本地 → CI checkout 到 _web/ 的位置）
List<String> webAuthCandidates() {
  final List<String> out = <String>[];
  final String? env = Platform.environment['TH_WEB_ROOT'];
  if (env != null && env.trim().isNotEmpty) {
    out.add('${env.replaceAll(r'\', '/')}/js/auth.js');
  }
  out.add('D:/ai/deep seek/js/auth.js');
  // CI：网页端被 checkout 到 $GITHUB_WORKSPACE/_web
  final String? ws = Platform.environment['GITHUB_WORKSPACE'];
  if (ws != null && ws.trim().isNotEmpty) {
    out.add('${ws.replaceAll(r'\', '/')}/_web/js/auth.js');
  }
  // 相对当前工作目录（flutter_app/ 的上一层再进 web 名）
  out.add('../deep seek/js/auth.js');
  return out;
}

/// 从网页端 auth.js 里抠出 LEVELS 的字面量行
List<String> extractWebLevels(String src) {
  final List<String> out = <String>[];
  final RegExp re = RegExp(r"\{\s*id:\s*'([a-z]+)'[^\n]*");
  for (final String line in src.split(RegExp(r'\r?\n'))) {
    if (line.contains('export const LEVELS')) continue;
    final RegExpMatch? m = re.firstMatch(line.trim());
    if (m != null) out.add(line.trim());
  }
  return out;
}

void main(List<String> args) {
  final bool noWeb = args.contains('--no-web');

  // ══ 一、纯 Dart 断言 ══
  print('== 1. 表体完整性 ==');
  ck('六档', kMemberLevels.length == 6);

  final List<String> ids = <String>[for (final MemberLevel l in kMemberLevels) l.id];
  ck('id 顺序 = guest,satellite,planet,star,galaxy,universe',
      ids.join(',') == 'guest,satellite,planet,star,galaxy,universe');
  ck('id 无重复', ids.toSet().length == ids.length);

  final List<String> names = <String>[for (final MemberLevel l in kMemberLevels) l.name];
  ck('中文名 = 游客,卫星,行星,恒星,星系,宇宙',
      names.join(',') == '游客,卫星,行星,恒星,星系,宇宙');

  final List<String> ens = <String>[for (final MemberLevel l in kMemberLevels) l.nameEn];
  ck('英文名 = Guest,Satellite,Planet,Star,Galaxy,Universe',
      ens.join(',') == 'Guest,Satellite,Planet,Star,Galaxy,Universe');

  print('== 2. 付费档判定 ==');
  ck('guest 免费', kMemberLevels[0].paid == false);
  ck('satellite 免费', kMemberLevels[1].paid == false);
  ck('planet/star/galaxy/universe 付费',
      kMemberLevels[2].paid && kMemberLevels[3].paid && kMemberLevels[4].paid && kMemberLevels[5].paid);

  print('== 3. 兜底行为（认不出不能崩、也不能白送额度）==');
  ck('null → guest', memberLevelById(null).id == 'guest');
  ck('空串 → guest', memberLevelById('').id == 'guest');
  ck('未知 id → guest', memberLevelById('super_vip_2099').id == 'guest');
  ck('未知 id 不白送额度', memberLevelById('super_vip_2099').storageBytes == 0);
  ck('kGuestLevel 就是第一档', kGuestLevel.id == 'guest');

  print('== 4. 档次高低 ==');
  ck('guest 最低', memberLevelRank('guest') == 0);
  ck('universe 最高', memberLevelRank('universe') == 5);
  ck('star > planet', memberLevelRank('star') > memberLevelRank('planet'));
  ck('未知 id 等同最低', memberLevelRank('nope') == 0);

  print('== 5. 额度文案 ==');
  ck('guest = 无', memberStorageText(kMemberLevels[0]) == '无');
  ck('satellite = 10MB', memberStorageText(kMemberLevels[1]) == '10MB');
  ck('planet = 1GB', memberStorageText(kMemberLevels[2]) == '1GB');
  ck('star = 5GB', memberStorageText(kMemberLevels[3]) == '5GB');
  ck('galaxy = 20GB', memberStorageText(kMemberLevels[4]) == '20GB');
  ck('universe = 不限', memberStorageText(kMemberLevels[5]) == '不限');

  print('== 6. 副标题文案（★ 防"页面上写死一句话"重演）==');
  ck('未登录 → 引导登录',
      memberSubtitle(loggedIn: false, levelId: 'planet').contains('未登录'));
  ck('已登录显示真实等级名',
      memberSubtitle(loggedIn: true, levelId: 'planet').startsWith('行星'));
  ck('已登录显示额度',
      memberSubtitle(loggedIn: true, levelId: 'planet').contains('1GB'));
  ck('★ 不再出现"冻结期"',
      !memberSubtitle(loggedIn: true, levelId: 'planet').contains('冻结'));
  ck('无到期日 → 不显示到期段',
      memberSubtitle(loggedIn: true, levelId: 'star').split('·').length == 2);
  ck('过期日 → 显示已过期',
      memberSubtitle(loggedIn: true, levelId: 'star', expireAt: '2020-01-01T00:00:00Z')
          .contains('已过期'));
  ck('未来到期 → 显示天数',
      memberSubtitle(
              loggedIn: true,
              levelId: 'star',
              expireAt:
                  DateTime.now().add(const Duration(days: 30)).toUtc().toIso8601String())
          .contains('天后到期'));

  print('== 7. 颜色唯一（防两档同色认不出）==');
  final Set<int> colors = <int>{for (final MemberLevel l in kMemberLevels) l.colorValue};
  ck('六档六色', colors.length == 6);

  // ══ 二、跨端一致性 ══
  print('== 8. 跨端一致性（vs 网页端 js/auth.js）==');
  if (noWeb) {
    print('  SKIP  显式 --no-web，跳过跨端比对（CI 不得传此参数）');
  } else {
    String? found;
    for (final String p in webAuthCandidates()) {
      if (File(p).existsSync()) {
        found = p;
        break;
      }
    }
    if (found == null) {
      fail++;
      print('  FAIL  找不到网页端 js/auth.js —— 无法证明两端一致');
      print('        找过这些路径：');
      for (final String p in webAuthCandidates()) {
        print('          · $p');
      }
      print('        若只想跑纯 Dart 部分：加 --no-web（CI 绝不加）');
    } else {
      print('  使用网页端文件: $found');
      final String src = File(found).readAsStringSync();
      final List<String> web = extractWebLevels(src);
      ck('网页端解析到 6 档（不是 0 档 —— 防正则失效假绿）', web.length == 6);

      final List<String> webIds = <String>[];
      final List<String> webNames = <String>[];
      for (final String l in web) {
        final RegExpMatch? mi = RegExp(r"id:\s*'([a-z]+)'").firstMatch(l);
        final RegExpMatch? mn = RegExp(r"name:\s*'([^']+)'").firstMatch(l);
        if (mi != null) webIds.add(mi.group(1)!);
        if (mn != null) webNames.add(mn.group(1)!);
      }
      ck('等级 id 两端逐字一致: ${webIds.join(",")}', webIds.join(',') == ids.join(','));
      ck('中文名两端逐字一致: ${webNames.join(",")}', webNames.join(',') == names.join(','));

      // 云存储额度：网页端写的是 10 * 1024 ** 2 这类表达式，只校验数量级关键词
      ck('网页端含 satellite 的 10MB 定义', src.contains('10 * 1024 ** 2'));
      ck('网页端含 planet 的 1GB 定义', src.contains('1024 ** 3'));
      ck('网页端含 star 的 5GB 定义', src.contains('5 * 1024 ** 3'));
      ck('网页端含 galaxy 的 20GB 定义', src.contains('20 * 1024 ** 3'));
      ck('网页端含 universe 的 Infinity', src.contains('Infinity'));
    }
  }

  print('');
  print('PASS $pass / FAIL $fail');
  exit(fail == 0 ? 0 : 1);
}
