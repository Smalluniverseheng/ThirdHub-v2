// 本地工具调用(TH-LocalTools v1): 设备能力暴露给 AI, 与 MCP 工具统一进 function-calling 循环
// Harness 设计参考开源 smolagents/llama-index 的 ReAct 工具循环(自研实现, 无代码拷贝)
import 'dart:convert';
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'tts.dart';
import 'ai.dart';

class LocalTool {
  final String name, description;
  final Map<String, dynamic> schema;
  final Future<String> Function(Map<String, dynamic> args) run;
  const LocalTool(this.name, this.description, this.schema, this.run);
}

class LocalTools {
  static Map<String, dynamic> _obj(Map<String, String> props, [List<String> required = const []]) => {
    'type': 'object',
    'properties': { for (final e in props.entries) e.key: {'type': 'string', 'description': e.value} },
    if (required.isNotEmpty) 'required': required,
  };

  static Future<Directory> _dir() async => await getApplicationDocumentsDirectory();

  static List<LocalTool> all = [
    LocalTool('get_device_info', '获取手机设备信息(品牌/型号/系统版本)', _obj({}), (_) async {
      final d = DeviceInfoPlugin();
      if (Platform.isAndroid) { final a = await d.androidInfo;
        return '品牌:${a.brand} 型号:${a.model} Android:${a.version.release} SDK:${a.version.sdkInt}'; }
      final b = await d.deviceInfo; return b.data.toString();
    }),
    LocalTool('clipboard_read', '读取剪贴板内容', _obj({}), (_) async {
      final d = await Clipboard.getData('text/plain'); return d?.text ?? '(剪贴板为空)';
    }),
    LocalTool('clipboard_write', '把文本写入剪贴板', _obj({'text': '要复制的文本'}, ['text']), (a) async {
      await Clipboard.setData(ClipboardData(text: '${a['text'] ?? ''}')); return '已复制到剪贴板';
    }),
    LocalTool('tts_speak', '用系统语音朗读一段文本', _obj({'text': '要朗读的文本'}, ['text']), (a) async {
      await TtsManager.speak('${a['text'] ?? ''}'); return '已开始朗读';
    }),
    LocalTool('open_url', '在浏览器中打开链接', _obj({'url': '完整网址(https://...)'}, ['url']), (a) async {
      final u = Uri.tryParse('${a['url'] ?? ''}');
      if (u == null) return '无效网址';
      final ok = await launchUrl(u, mode: LaunchMode.externalApplication);
      return ok ? '已打开' : '打开失败';
    }),
    LocalTool('share_text', '调起系统分享, 把文本分享给其他 App', _obj({'text': '要分享的内容'}, ['text']), (a) async {
      await Share.share('${a['text'] ?? ''}'); return '已调起分享';
    }),
    LocalTool('file_write', '把文本保存为本机文件(App文档目录)', _obj({'name': '文件名, 如 note.txt', 'content': '文件内容'}, ['name', 'content']), (a) async {
      final name = '${a['name'] ?? ''}'.replaceAll(RegExp(r'[/\\]'), '_');
      if (name.isEmpty) return '文件名不能为空';
      final f = File('${(await _dir()).path}/$name');
      await f.writeAsString('${a['content'] ?? ''}');
      return '已保存: ${f.path} (${await f.length()} 字节)';
    }),
    LocalTool('file_read', '读取 App 文档目录里的文本文件', _obj({'name': '文件名'}, ['name']), (a) async {
      final f = File('${(await _dir()).path}/${'${a['name'] ?? ''}'.replaceAll(RegExp(r'[/\\]'), '_')}');
      if (!await f.exists()) return '文件不存在';
      final t = await f.readAsString();
      return t.length > 8000 ? '${t.substring(0, 8000)}\n…(截断, 共${t.length}字符)' : t;
    }),
    LocalTool('file_list', '列出 App 文档目录的文件', _obj({}), (_) async {
      final d = await _dir();
      final list = await d.list().where((e) => e is File).toList();
      if (list.isEmpty) return '(目录为空)';
      return list.map((e) => e.path.split('/').last).join('\n');
    }),
    LocalTool('file_delete', '删除 App 文档目录里的文件', _obj({'name': '文件名'}, ['name']), (a) async {
      final f = File('${(await _dir()).path}/${'${a['name'] ?? ''}'.replaceAll(RegExp(r'[/\\]'), '_')}');
      if (!await f.exists()) return '文件不存在';
      await f.delete(); return '已删除';
    }),
    LocalTool('web_search', '联网搜索(需已配置搜索服务)', _obj({'query': '搜索关键词'}, ['query']), (a) async {
      final items = await WebSearch.search('${a['query'] ?? ''}');
      if (items.isEmpty) return '没有结果';
      return WebSearch.toContext('${a['query'] ?? ''}', items);
    }),
  ];

  // 转成 AiChat.chat 需要的统一工具格式(带 serverId=local 标记)
  static List<Map<String, dynamic>> schemas() => [
    for (final t in all) {'serverId': 'local', 'serverName': '本机工具', 'name': 'local_${t.name}',
      'description': t.description, 'inputSchema': t.schema} ];

  static Future<String> call(String name, Map<String, dynamic> args) async {
    final n = name.startsWith('local_') ? name.substring(6) : name;
    for (final t in all) { if (t.name == n) return t.run(args); }
    throw Exception('未知本地工具: $name');
  }
}
