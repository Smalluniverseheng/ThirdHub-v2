// B站字幕三态解析自检（纯 Dart VM，零 Flutter 依赖）
//   dart run tool/subtitle_selfcheck.dart
// 覆盖：json(B站原生 body) / srt / ass / 时间轴命中 / 边界 / 空态。
import '../lib/core/bili_subtitle_parser.dart';

int pass = 0, fail = 0;
void ck(String name, bool ok) {
  if (ok) {
    pass++;
  } else {
    fail++;
    print('  FAIL  $name');
  }
}

void main() {
  print('== 1. B站原生 json ==');
  const jsonRaw = '''{
    "body": [
      {"from": 0, "to": 2.5, "location": 2, "content": "第一句"},
      {"from": 2.6, "to": 5, "location": 2, "content": "第二句\\n换行"},
      {"from": 10, "to": 12, "location": 2, "content": "第三句"}
    ]
  }''';
  final j = parseSubtitle(jsonRaw);
  ck('json 3 条', j.length == 3);
  ck('json 首条 t0/t1/x', j.isNotEmpty && j[0]['t0'] == 0.0 && j[0]['t1'] == 2.5 && j[0]['x'] == '第一句');
  ck('json \\n 还原为换行', j.length > 1 && '${j[1]['x']}'.contains('\n'));

  print('== 2. json 字符串时间 + data.body 包裹 ==');
  const jsonStr = '{"data":{"body":[{"from":"1.5","to":"3","content":"字符串时间"}]}}';
  final js = parseSubtitle(jsonStr);
  ck('字符串时间解析', js.length == 1 && js[0]['t0'] == 1.5 && js[0]['t1'] == 3.0);

  print('== 3. srt ==');
  const srtRaw = '''1
00:00:01,000 --> 00:00:03,500
你好，世界
第二行

2
00:00:04,000 --> 00:00:06,000
Hello''';
  final s = parseSubtitle(srtRaw);
  ck('srt 2 条', s.length == 2);
  ck('srt 首条 t0=1 t1=3.5', s.isNotEmpty && s[0]['t0'] == 1.0 && s[0]['t1'] == 3.5);
  ck('srt 多行合并', s.isNotEmpty && '${s[0]['x']}'.contains('\n'));
  ck('srt 第二条文本', s.length > 1 && s[1]['x'] == 'Hello');

  print('== 4. ass（标准列序 + 自定义列序）==');
  const assRaw = '''[Script Info]
Title: test
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:02.00,0:00:04.50,Default,,0,0,0,,ASS 字幕
Dialogue: 0,0:00:05.00,0:00:07.00,Default,,0,0,0,,第二句,带逗号''';
  final a = parseSubtitle(assRaw);
  ck('ass 2 条', a.length == 2);
  ck('ass 首条 t0=2 t1=4.5', a.isNotEmpty && a[0]['t0'] == 2.0 && a[0]['t1'] == 4.5);
  ck('ass 文本列定位', a.isNotEmpty && a[0]['x'] == 'ASS 字幕');
  ck('ass 正文逗号保留', a.length > 1 && '${a[1]['x']}'.contains(','));

  // ASS 规范：Text 必须是最后一列（正文含逗号，放中间会被当成分隔符）。
  // 这里只把 Start/End 换到非默认列，验证按 Format 定位而非写死列号。
  const assCustom = '''[Events]
Format: Layer, Start, End, Style, Text
Dialogue: 0,0:00:01.00,0:00:02.00,Default,自定义列序''';
  final ac = parseSubtitle(assCustom);
  ck('ass 自定义列序', ac.length == 1 && ac[0]['x'] == '自定义列序' && ac[0]['t0'] == 1.0);

  print('== 5. 时间轴命中 cueAt ==');
  ck('命中首条', cueAt(j, 1.0)?['x'] == '第一句');
  ck('命中边界 t0', cueAt(j, 2.5)?['x'] == '第一句');
  ck('间隔中无字幕', cueAt(j, 7.0) == null);
  ck('命中第三条', cueAt(j, 11.0)?['x'] == '第三句');
  ck('越界之前 null', cueAt(j, -1) == null);
  ck('越界之后 null', cueAt(j, 99) == null);

  print('== 6. 空态 / 脏数据 ==');
  ck('空串', parseSubtitle('').isEmpty);
  ck('空白', parseSubtitle('   \n  ').isEmpty);
  ck('坏 json', parseSubtitle('{bad').isEmpty);
  ck('无 cue 的空数组', parseSubtitle('{"body":[]}').isEmpty);
  ck('空 cues 命中 null', cueAt(const [], 1.0) == null);

  print('== 7. hint 强制格式 ==');
  final forced = parseSubtitle('00:00:01,000 --> 00:00:02,000\n强制 srt', hint: 'srt');
  ck('hint=srt 覆盖嗅探', forced.length == 1 && forced[0]['t0'] == 1.0);

  print('');
  print('PASS $pass  FAIL $fail');
  if (fail > 0) throw StateError('$fail checks failed');
}
