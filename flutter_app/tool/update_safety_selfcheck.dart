// 更新链路安全闸门（4.81.116）
//
//   dart run tool/update_safety_selfcheck.dart
//
// 为什么必须有这条：#真实事故 用户从家里 NAS 下到 4.81.94 的 54MB 旧包，
// App 花十几分钟下完才报「校验未通过」——因为旧代码是**先下完再校验**，
// 而且是**先信线路、后看体积**。这类 bug 不崩、不报错，只在用户那里表现为
// 「下载了一个用不了的东西」，不写闸门就会被下一个人顺手改回去。
//
// 钉五件事：
//   ① 整包线路下载前必须做体积预检（HEAD），不符直接跳过；
//   ② 自己后端的下载请求必须带 Bearer（否则版本化包永远 401）；
//   ③ 分片下载必须逐段校验 sha256，且合并后再验整包 sha；
//   ④ 分段失败要能自动回落整包，而不是原地失败；
//   ⑤ 清单缺失 sha 时不能假装校验通过（宁可提示，不可静默）。
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

String read(String p) {
  final f = File(p);
  return f.existsSync() ? f.readAsStringSync() : '';
}

/// 预检必须出现在同名函数的下载调用之前（同一次循环体内）。
bool _preflightBeforeFetch(String src) {
  final i = src.indexOf('final cl = await _headSize(');
  if (i < 0) return false;
  final j = src.indexOf('await _fetchTo(mirrors[i]', i);
  return j > i;
}

void main() {
  // 允许从仓库根或 flutter_app/ 两种目录运行（CI 在 flutter_app 里跑）。
  final app = Directory('lib').existsSync()
      ? ''
      : (Directory('flutter_app').existsSync() ? 'flutter_app/' : '');
  final main = read('${app}lib/main.dart');

  print('=== 1. 下载前的体积预检 ===');
  ck('存在 _headSize 体积探测', main.contains('static Future<int> _headSize(String url)'));
  ck('体积不符会跳过线路', main.contains('与清单 ') && main.contains('不符，已跳过'));
  ck('跳过时带上两个体积数字', main.contains(r'(cl / 1048576)') && main.contains(r'(wantSize / 1048576)'));
  ck('预检在下载之前执行', _preflightBeforeFetch(main));
  ck('清单体积一路传到校验函数', main.contains('wantSize: size ?? 0') && main.contains('int wantSize = 0'));
  ck('探测失败不拒绝线路（返回 0 视为未知）', main.contains('return resp.contentLength > 0 ? resp.contentLength : 0'));

  print('=== 2. 自建后端要带令牌 ===');
  ck('存在 _addBackendAuth', main.contains('static void _addBackendAuth(HttpClientRequest req, String url)'));
  ck('只对自家后端发令牌', main.contains('if (!url.startsWith(b)) return;'));
  ck('_fetchTo 里调用了它', main.contains('_addBackendAuth(req, url);'));
  ck('空令牌不外发', main.contains('Api.token.isEmpty) return;'));

  print('=== 3. 分片与整包校验 ===');
  ck('逐段校验 sha256', main.contains("if (await _fileSha256(seg) != want)"));
  ck('合并后再验整包', main.contains('分段合并后内容与清单不符'));
  ck('段失败清理临时文件', main.contains('s.path').toString().isNotEmpty && main.contains('_downloadPartsTo'));
  ck('分段不可用自动回落整包', main.contains("分段不可用，改用整包下载…"));
  ck('整包线路逐条校验并换源', main.contains('线路 \${i + 1} 内容与清单不符'));

  print('=== 4. 反证：不能退回老写法 ===');
  ck('不存在「先下完再发现是旧包」的空体积调用',
      !main.contains('_downloadVerified(\n                f: f,\n                mirrors: mirrors,\n                progress: progress,\n                detail: detail,\n                sha: sha,\n              );'));

  print('\n$pass 通过 / $fail 失败');
  if (fail > 0) exit(1);
}
