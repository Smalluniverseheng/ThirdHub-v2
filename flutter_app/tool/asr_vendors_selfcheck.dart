// 语音识别厂商规格自检（纯 Dart，不需要 Flutter）
//
// 为什么必须有一把这样的尺子：上一版的错**不是崩溃，是"静默不可用"** ——
// 小米/百炼被写成 `/v1/audio/transcriptions` multipart，代码看着没问题、
// analyze 全绿、设置页也能点，但一按就失败。这种错只有"逐字段对规范"能抓住。
//
// 跑法：
//   D:/ai/flutter-3.47.4/flutter/bin/cache/dart-sdk/bin/dart.exe \
//     --disable-dart-dev run tool/asr_vendors_selfcheck.dart
//
// ⚠️ 任何一条 FAIL 都要 exit(1)（CI 只看退出码）。

import 'dart:convert';
import 'dart:io';

import '../lib/core/asr_vendors.dart';

int _pass = 0;
int _fail = 0;

void ok(String what) {
  _pass++;
  print('  PASS  $what');
}

void bad(String what, [String detail = '']) {
  _fail++;
  print('  FAIL  $what${detail.isEmpty ? '' : '  →  $detail'}');
}

void check(bool cond, String what, [String detail = '']) {
  if (cond) {
    ok(what);
  } else {
    bad(what, detail);
  }
}

void main() {
  print('== 语音识别厂商规格自检 ==');

  print('\n[1] 表结构完整性');
  check(AsrVendors.all.length >= 8, '厂商数量 ≥ 8', '${AsrVendors.all.length}');
  for (final v in AsrVendors.all) {
    check(v.id.isNotEmpty && v.name.isNotEmpty && v.group.isNotEmpty,
        '${v.id} 基本字段非空');
    check(v.url.isNotEmpty, '${v.id} 有请求地址');
    check(v.textPath.isNotEmpty, '${v.id} 有文本路径');
    if (v.shape != AsrShape.openaiMultipart) {
      check(v.model.isNotEmpty, '${v.id} 非 multipart 形态必须有模型名');
    }
    check(AsrVendors.byId(v.id) != null, '${v.id} 可按 id 查回');
  }

  print('\n[2] ★回归：小米 / 百炼 必须走 chat/completions');
  // 这两家是上一版错得最狠的地方，单独钉死。
  final xiaomi = AsrVendors.byId('xiaomi')!;
  check(xiaomi.shape == AsrShape.chatAudio, '小米形态 = chatAudio',
      '${xiaomi.shape}');
  check(xiaomi.url.endsWith('/chat/completions'), '小米地址以 /chat/completions 结尾',
      xiaomi.url);
  check(!xiaomi.url.contains('/audio/transcriptions'),
      '小米地址不含 /audio/transcriptions');
  check(xiaomi.textPath == 'choices.0.message.content',
      '小米文本路径 = choices.0.message.content', xiaomi.textPath);
  check(xiaomi.asrOptions, '小米要带 asr_options');
  check(xiaomi.model == 'mimo-v2.5-asr', '小米模型 = mimo-v2.5-asr', xiaomi.model);
  // 官方：只收 wav / mp3
  final exts = AsrVendors.acceptedExts(xiaomi);
  check(exts.length == 2 && exts.contains('wav') && exts.contains('mp3'),
      '小米只接受 wav / mp3', exts.join(','));

  final ds = AsrVendors.byId('dashscope')!;
  check(ds.shape == AsrShape.chatAudio, '百炼形态 = chatAudio', '${ds.shape}');
  check(ds.url.contains('compatible-mode') && ds.url.endsWith('/chat/completions'),
      '百炼走 compatible-mode 的 chat/completions', ds.url);
  check(ds.model == 'qwen3-asr-flash', '百炼模型 = qwen3-asr-flash', ds.model);

  print('\n[3] chatAudio 形态的共性');
  for (final v in AsrVendors.all.where((e) => e.shape == AsrShape.chatAudio)) {
    check(v.textPath == 'choices.0.message.content',
        '${v.id} 文本路径正确', v.textPath);
    check(v.needsBase64, '${v.id} 需要 base64 音频');
    check(v.maxBytes == 10 * 1024 * 1024, '${v.id} 体积上限 10MB',
        '${v.maxBytes}');
  }

  print('\n[4] openaiMultipart 形态的共性');
  final mps = AsrVendors.all
      .where((e) => e.shape == AsrShape.openaiMultipart)
      .toList();
  check(mps.isNotEmpty, '至少一家走 multipart');
  for (final v in mps) {
    check(v.audioField == 'file', '${v.id} 音频字段名 = file', v.audioField);
    check(!v.needsBase64, '${v.id} 不需要 base64');
    check(v.url.contains('/audio/transcriptions'),
        '${v.id} 地址含 /audio/transcriptions', v.url);
  }

  print('\n[5] 私有 JSON 形态');
  final volc = AsrVendors.byId('volc')!;
  check(volc.shape == AsrShape.rawJson, '火山形态 = rawJson');
  check(volc.extraHeaders['X-Api-Resource-Id'] == 'volc.bigasr.auc_turbo',
      '火山带 X-Api-Resource-Id', '${volc.extraHeaders}');
  check(volc.extraHeaders.containsKey('X-Api-Request-Id'),
      '火山带 X-Api-Request-Id（每请求唯一）');
  check(volc.authHeader == 'X-Api-Key', '火山用 X-Api-Key 头', volc.authHeader);
  check(volc.textPath == 'body.result.text', '火山文本路径', volc.textPath);
  check(volc.bodyTpl.contains('{audio}'), '火山 body 含 {audio}');

  final baidu = AsrVendors.byId('baidu')!;
  check(baidu.shape == AsrShape.rawJson, '百度形态 = rawJson');
  // ★百度 len 必须是原始字节数，填 0 必失败 —— 上一版就是 0。
  check(baidu.bodyTpl.contains('"len":{len}'), '百度 body 的 len 用占位符',
      baidu.bodyTpl);
  check(!baidu.bodyTpl.contains('"len":0'), '百度 body 没有写死 len=0');
  check(baidu.bodyTpl.contains('{token}'), '百度 body 含 {token}');
  check(baidu.url.contains('{token}'), '百度 URL 含 {token}');
  check(baidu.tokenUrl.isNotEmpty, '百度有换 token 的地址', baidu.tokenUrl);
  check(baidu.textPath == 'result.0', '百度文本路径 = result.0', baidu.textPath);

  print('\n[6] 音频 MIME 映射');
  check(audioMime('wav') == 'audio/wav', 'wav → audio/wav', audioMime('wav'));
  check(audioMime('mp3') == 'audio/mpeg', 'mp3 → audio/mpeg', audioMime('mp3'));
  check(audioMime('m4a') == 'audio/mp4', 'm4a → audio/mp4', audioMime('m4a'));
  check(audioMime('ogg') == 'audio/ogg', 'ogg → audio/ogg', audioMime('ogg'));
  check(audioMime('flac') == 'audio/flac', 'flac → audio/flac', audioMime('flac'));
  // 未知扩展名要退回 wav，而不是空字符串（空 MIME 会被厂商直接拒）
  check(audioMime('xyz') == 'audio/wav', '未知扩展名退回 audio/wav',
      audioMime('xyz'));

  print('\n[7] 密钥归一化（AI 叫 aliyun → 这里 dashscope）');
  check(AsrVendors.byAnyName('aliyun')?.id == 'dashscope', 'aliyun → dashscope');
  check(AsrVendors.byAnyName('bytedance')?.id == 'volc', 'bytedance → volc');
  check(AsrVendors.byAnyName('xiaomi')?.id == 'xiaomi', 'xiaomi → xiaomi');

  print('\n[8] 响应解析');
  const body = '{"choices":[{"message":{"content":"你好世界"}}]}';
  check(pickJsonPath(_decode(body), 'choices.0.message.content') == '你好世界',
      '能按路径取到文本');
  check(pickJsonPath(_decode('{"result":["识别结果"]}'), 'result.0') == '识别结果',
      '能取数组第 0 项');
  check(pickJsonPath(_decode('{"a":1}'), 'x.y') == null, '路径不存在返回 null');

  print('\n──────────────────────────────');
  print('通过 $_pass 项，失败 $_fail 项');
  if (_fail > 0) {
    print('结果：FAIL（有 $_fail 条不符合厂商规范，必须修）');
    exit(1);
  }
  print('结果：PASS');
}

dynamic _decode(String s) {
  try {
    return jsonDecode(s);
  } catch (_) {
    return null;
  }
}
