// 口径与契约自检（纯 Dart VM 可跑）
//   dart run tool/branding_selfcheck.dart
//
// ─────────────────────────────────────────────────────────────────────────────
// 盯两件用户明确提过、且**静默**的事：
//
// ① 口径：「前后端都不许出现『引擎』这种字样，也不要『换源』这种容易触发版权纠纷的词。
//    引擎是**隐藏层**，对用户就当它是个本地资料库 —— 客户端自己调自己的数据源检索。
//    这类改动的危险在于**它不会报错**：改漏一处，界面照样跑，只是又露出"引擎"两个字。
//    所以必须有能扫全树的闸门，而不是靠人翻。
//
// ② 头像契约：用户报「App 头像和网页端同步不了」。真因不是字段名不一致，而是
//    **线上 `th_profiles` 表里根本没有 `avatar_b64` / `avatar_url` 这两列**
//    （PostgREST 报 column does not exist）→ App 写必 400、读必为空，云端同步从未工作过。
//    修法是两端统一只用**已存在的 `avatar` 列**。
//    ★这个坑会复发：谁再加一次"顺手把 avatar_b64 也写上"就又炸了。
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:io';

int pass = 0, fail = 0;
void ck(String name, bool ok, [String extra = '']) {
  if (ok) {
    pass++;
  } else {
    fail++;
    print('  FAIL  $name${extra.isEmpty ? '' : '  → $extra'}');
  }
}

/// 剥掉注释，避免"注释里提到旧写法"被误判成"旧写法还在"。
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  while (i < src.length) {
    if (src.startsWith('//', i)) {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
    } else if (src.startsWith('/*', i)) {
      i += 2;
      while (i < src.length && !src.startsWith('*/', i)) {
        i++;
      }
      i += 2;
    } else {
      out.write(src[i]);
      i++;
    }
  }
  return out.toString();
}

/// 源码里所有 `tr('…')` 的参数（用户可见文案的权威集合）
Set<String> trLiterals(String src) {
  final out = <String>{};
  final re = RegExp(r"tr\(\s*'((?:[^'\\]|\\.)*)'");
  for (final m in re.allMatches(src)) {
    out.add(m.group(1)!);
  }
  return out;
}

void main() {
  // ── §1 App：用户可见文案不得出现「引擎 / 换源」──
  print('== 1. App 用户可见文案：不得出现「引擎」「换源」==');
  final appFiles = [
    'lib/main.dart',
    'lib/core/novel_reader.dart',
    'lib/core/engine_direct.dart',
    'lib/core/engine_direct_page.dart',
    'lib/core/manual_book.dart',
    'lib/core/pro_reading.dart',
    'lib/core/mini_modules.dart',
    'lib/core/mini_modules4.dart',
    'lib/core/mini_modules5.dart',
    'lib/core/mini_modules6.dart',
  ];
  final banned = ['引擎', '换源', '书源'];
  var hitEngine = 0, hitSwap = 0, hitBookSrc = 0;
  for (final f in appFiles) {
    if (!File(f).existsSync()) continue;
    for (final k in trLiterals(File(f).readAsStringSync())) {
      if (banned.contains('引擎') && k.contains('引擎')) {
        hitEngine++;
        print('     引擎 @ $f  「$k」');
      }
      if (k.contains('换源')) {
        hitSwap++;
        print('     换源 @ $f  「$k」');
      }
      if (k.contains('书源')) {
        hitBookSrc++;
        print('     书源 @ $f  「$k」');
      }
    }
  }
  ck('tr() 文案里没有「引擎」', hitEngine == 0, '发现 $hitEngine 处');
  ck('tr() 文案里没有「换源」', hitSwap == 0, '发现 $hitSwap 处');
  ck('tr() 文案里没有「书源」', hitBookSrc == 0, '发现 $hitBookSrc 处');

  // 说明书（用户会逐字读，比普通文案更敏感）
  final manual = File('lib/core/manual_book.dart').readAsStringSync();
  ck('说明书正文没有「引擎」', !manual.contains('引擎'),
      manual.contains('引擎') ? '说明书里还有"引擎"' : '');
  ck('说明书正文没有「换源」', !manual.contains('换源'));
  ck('说明书正文没有「书源」', !manual.contains('书源'));
  // 反向：确认新口径真的出现了（否则上面几条可能因为"文案被清空"而假绿）
  ck('说明书用了新口径「资料库」', manual.contains('资料库'));
  ck('说明书用了新口径「换一批结果」', manual.contains('换一批结果'));

  // ── §2 头像契约：两端只用线上真实存在的 avatar 列 ──
  print('== 2. 头像跨端契约（线上 th_profiles 只有 avatar 一列）==');
  final main2 = File('lib/main.dart').readAsStringSync();
  final noComment = stripComments(main2);
  // 上传：只写 avatar
  ck('云端上传走 pushAvatarCloud', main2.contains('pushAvatarCloud'));
  final pushBody = RegExp(r'Future<void> pushAvatarCloud[\s\S]*?\n  }').firstMatch(main2)?.group(0) ?? '';
  ck('pushAvatarCloud 只写 avatar 列（不写不存在的 avatar_b64）',
      pushBody.contains("'avatar'") && !pushBody.contains("'avatar_b64'"),
      'pushAvatarCloud 里出现了 avatar_b64');
  // 下行：只读 avatar
  final downBody = RegExp(r'头像下行[\s\S]*?await AppSettings\.sync\(\);').firstMatch(main2)?.group(0) ?? '';
  ck('云端下行只读 avatar 列',
      downBody.contains("prof['avatar']") && !downBody.contains("prof['avatar_b64']"),
      '下行还在读 avatar_b64');
  ck('有 dataURI → 裸 base64 的归一', main2.contains('normAvatarB64'));
  ck('有裸 base64 → dataURI 的补齐', main2.contains('b64ToAvatarDataUri'));

  // 网页端同一套口径
  final webAuth = File('D:/ai/deep seek/js/auth.js').existsSync()
      ? File('D:/ai/deep seek/js/auth.js').readAsStringSync()
      : '';
  if (webAuth.isEmpty) {
    print('  SKIP  未找到网页端 js/auth.js');
  } else {
    final webNc = stripComments(webAuth);
    ck('网页端 updateProfile 往 row 里只写 avatar（不写 avatar_b64）',
        !RegExp(r"row\.avatar_b64\s*=").hasMatch(webNc));
    ck('网页端有 avatarToDataUri 归一', webAuth.contains('avatarToDataUri'));
    ck('网页端 currentUser 读 avatar', webAuth.contains('profile.avatar'));
  }
  final webManual = File('D:/ai/deep seek/js/engine/manual-source.js').existsSync()
      ? File('D:/ai/deep seek/js/engine/manual-source.js').readAsStringSync()
      : '';
  if (webManual.isNotEmpty) {
    ck('网页端说明书没有「引擎」', !webManual.contains('引擎'));
    ck('网页端说明书没有「换源」', !webManual.contains('换源'));
  }

  print('');
  print('PASS $pass   FAIL $fail');
  if (fail == 0) {
    print('\n✅ 口径与契约完好：用户可见处只见「资料库 / 换一批结果」；头像两端统一走 avatar 列');
  }
  if (fail > 0) exit(1);
}
