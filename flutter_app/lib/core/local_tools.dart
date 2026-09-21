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
import 'tts_presets.dart';
import 'ai.dart';
import 'local_tools_logic.dart';
import 'peer_hub.dart';

// 让调用方（main.dart / prompt 构建）只 import 本文件就能用上零依赖能力层
export 'local_tools_logic.dart';

/// 前端向「本地工具」暴露的 App 能力钩子。
///
/// 为什么用钩子而不是直接 import：local_tools 是底层工具表，
/// 直接依赖 main.dart / 导航层会造成循环 import。由 App 启动时注入实现。
class LocalHooks {
  /// 当前上下文摘要（在哪个模块、版本、在线状态…）—— 上下文注入用
  static Future<String> Function()? contextOf;

  /// 切到某个模块（前端是控制层，理应能指挥自己）
  static Future<String> Function(String module)? gotoModule;

  /// 读一个设置项
  static Future<String> Function(String key)? getSetting;

  /// 写一个设置项
  static Future<String> Function(String key, String value)? setSetting;

  /// 列出所有可用模块名
  static Future<List<String>> Function()? listModules;
}

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
    LocalTool('file_share', '把 App 文档目录里已保存的文件调起系统分享(发给微信/存到网盘等)', _obj({'name': '文件名'}, ['name']), (a) async {
      final f = File('${(await _dir()).path}/${'${a['name'] ?? ''}'.replaceAll(RegExp(r'[/\\]'), '_')}');
      if (!await f.exists()) return '文件不存在';
      await Share.shareXFiles([XFile(f.path)]);
      return '已调起分享: ${f.path.split('/').last}';
    }),
    // Python 代码执行: 走家庭后端 /v1/py(后端本机 python 跑), 不在手机上跑
    LocalTool('run_python', '在家庭后端(电脑)上执行 Python 代码并返回输出(计算/数据处理/批量生成等)',
      _obj({'code': '要执行的 Python 代码'}, ['code']), (a) async {
      if (!TtsBackend.available) return '未连接家庭后端——Python 执行需要后端在线(在「设备互联」里配对/连接后端)';
      final code = '${a['code'] ?? ''}';
      if (code.trim().isEmpty) return 'code 不能为空';
      try {
        final c = HttpClient()..badCertificateCallback = (_, __, ___) => true;
        final req = await c.postUrl(Uri.parse('${TtsBackend.base}/v1/py')).timeout(const Duration(seconds: 10));
        req.headers.set('X-TH-Token', TtsBackend.token);
        req.headers.set('Content-Type', 'application/json; charset=utf-8');
        req.write(jsonEncode({'code': code}));
        final resp = await req.close().timeout(const Duration(seconds: 35));
        final bodyText = utf8.decode(await resp.expand((c2) => c2).toList());
        final j = jsonDecode(bodyText);
        if (resp.statusCode != 200) return '执行失败: ${j['data']?['message'] ?? 'HTTP ${resp.statusCode}'}';
        final d = j['data'] ?? {};
        final out = StringBuffer();
        if ('${d['stdout'] ?? ''}'.isNotEmpty) out.write('输出:\n${d['stdout']}');
        if ('${d['stderr'] ?? ''}'.isNotEmpty) out.write('${out.isEmpty ? '' : '\n'}错误输出:\n${d['stderr']}');
        if (out.isEmpty) out.write('(无输出, 退出码 ${d['code']})');
        return out.toString();
      } catch (e) { return 'Python 执行调用失败: $e'; }
    }),
    LocalTool('web_search', '联网搜索(需已配置搜索服务)', _obj({'query': '搜索关键词'}, ['query']), (a) async {
      final items = await WebSearch.search('${a['query'] ?? ''}');
      if (items.isEmpty) return '没有结果';
      return WebSearch.toContext('${a['query'] ?? ''}', items);
    }),

    // ══════════════════════════════════════════════════════════════════════
    // ★4.44.0 离线能力批：以下工具**完全不依赖后端与网络**。
    //   没连后端、DSH 不在、断网 —— 这一批照常可用。
    //   这正是"前端不该变成废物"的落地：日常问答所需的计算/文本/编码/时间
    //   /单位/正则/差异/笔记/上下文，全部在手机上直接完成。
    // ══════════════════════════════════════════════════════════════════════
    LocalTool('calc', '计算数学表达式(支持 + - * / ^ 括号 一元正负 百分比后缀, 如 350*20%)',
      _obj({'expr': '表达式, 如 (1+2)*3^2'}, ['expr']), (a) async {
      final e = '${a['expr'] ?? ''}';
      final v = LocalCalc.calc(e);
      return v == null ? '表达式无法解析(检查括号/运算符): $e' : '$e = $v';
    }),
    LocalTool('text_stats', '统计文本的字数/行数/中英文字符数/词数/句子数, 并给出高频词',
      _obj({'text': '要统计的文本', 'top': '高频词个数, 默认 8'}, ['text']), (a) async {
      final t = '${a['text'] ?? ''}';
      final s = TextStats.of(t);
      final n = int.tryParse('${a['top'] ?? ''}') ?? 8;
      final top = TextStats.topWords(t, n: n);
      final buf = StringBuffer()
        ..writeln('字符 ${s['chars']}（含空白）· ${s['charsNoSpace']}（不含空白）')
        ..writeln('中文 ${s['cjk']} · 英文 ${s['latin']} · 数字 ${s['digits']}')
        ..writeln('行 ${s['lines']}（非空 ${s['nonEmptyLines']}）· 词 ${s['words']} · 句 ${s['sentences']}');
      final ll = TextStats.longestLine(t);
      if (ll != null) buf.writeln('最长行: 第 ${ll.$1} 行（${ll.$2.length} 字）');
      if (top.isNotEmpty) buf.writeln('高频词: ${top.map((e) => '${e.key}(${e.value})').join(' ')}');
      return buf.toString().trim();
    }),
    LocalTool('text_diff', '对比两段文本的差异(行级), 返回增删统计与逐行标记',
      _obj({'old': '旧文本', 'new': '新文本', 'show': '最多展示多少行, 默认 60'}, ['old', 'new']), (a) async {
      final d = TextDiff.byLine('${a['old'] ?? ''}', '${a['new'] ?? ''}');
      final st = TextDiff.stat(d);
      final limit = int.tryParse('${a['show'] ?? ''}') ?? 60;
      final buf = StringBuffer('新增 ${st.$1} 行 · 删除 ${st.$2} 行 · 相似度 ${(TextDiff.similarity('${a['old'] ?? ''}', '${a['new'] ?? ''}') * 100).toStringAsFixed(1)}%\n');
      for (final l in d.take(limit)) {
        final mark = l.kind == 'add' ? '+' : (l.kind == 'del' ? '-' : ' ');
        buf.writeln('$mark ${l.text}');
      }
      if (d.length > limit) buf.writeln('…(共 ${d.length} 行, 已截断)');
      return buf.toString().trim();
    }),
    LocalTool('json_tool', '处理 JSON: 美化 / 压缩 / 校验 / 按路径取值 / 列出键路径',
      _obj({'action': 'pretty | minify | valid | at | keys', 'json': 'JSON 文本', 'path': 'at 时用的点号路径, 如 a.b.0'}, ['action', 'json']), (a) async {
      final act = '${a['action'] ?? ''}'.trim().toLowerCase();
      final src = '${a['json'] ?? ''}';
      switch (act) {
        case 'pretty':
        case 'format':
          return JsonTool.pretty(src) ?? '不是合法 JSON';
        case 'minify':
          return JsonTool.minify(src) ?? '不是合法 JSON';
        case 'valid':
        case 'check':
          return JsonTool.valid(src) ? '合法 JSON' : '不是合法 JSON';
        case 'at':
        case 'get': {
          final v = JsonTool.at(src, '${a['path'] ?? ''}');
          return v == null ? '取不到该路径: ${a['path']}' : jsonEncode(v);
        }
        case 'keys':
        case 'paths': {
          final k = JsonTool.keys(src);
          return k.isEmpty ? '(没有键, 或不是合法 JSON)' : k.join('\n');
        }
        default:
          return 'action 只支持 pretty / minify / valid / at / keys';
      }
    }),
    LocalTool('codec', '编解码: base64 / url / hex 的正向与反向',
      _obj({'action': 'b64e|b64d|urle|urld|hexe|hexd', 'text': '要处理的文本'}, ['action', 'text']), (a) async {
      final act = '${a['action'] ?? ''}'.trim().toLowerCase();
      final t = '${a['text'] ?? ''}';
      switch (act) {
        case 'b64e': case 'base64encode': return Codec.b64e(t);
        case 'b64d': case 'base64decode': return Codec.b64d(t) ?? '不是合法的 Base64';
        case 'urle': case 'urlencode': return Codec.urlE(t);
        case 'urld': case 'urldecode': return Codec.urlD(t) ?? '不是合法的 URL 编码';
        case 'hexe': case 'hexencode': return Codec.hexE(t);
        case 'hexd': case 'hexdecode': return Codec.hexD(t) ?? '不是合法的十六进制';
        default: return 'action 只支持 b64e/b64d/urle/urld/hexe/hexd';
      }
    }),
    LocalTool('unit_convert', '单位换算: 长度(length) / 重量(mass) / 数据(data) / 面积(area) / 温度(temperature)',
      _obj({'category': 'length|mass|data|area|temperature', 'from': '源单位, 如 km', 'to': '目标单位, 如 m', 'value': '数值'}, ['category', 'from', 'to', 'value']), (a) async {
      final v = double.tryParse('${a['value'] ?? ''}');
      if (v == null) return 'value 不是数字';
      final r = UnitConv.convert('${a['category'] ?? ''}'.trim(), '${a['from'] ?? ''}'.trim(), '${a['to'] ?? ''}'.trim(), v);
      if (r == null) return '不认识的类别或单位（长度 mm cm m km inch ft mile 里 尺；重量 mg g kg t lb oz 斤 两；数据 B KB MB GB TB PB；温度 C F K）';
      return '$v ${a['from']} = ${LocalCalc.fmt(r)} ${a['to']}';
    }),
    LocalTool('regex_tool', '正则: 提取全部匹配 / 取首个 / 测试是否命中 / 替换 / 校验正则合法性',
      _obj({'action': 'all|first|test|replace|check', 'pattern': '正则', 'text': '目标文本', 'group': '分组号, 默认 0', 'with': 'replace 时的替换串'}, ['action', 'pattern']), (a) async {
      final act = '${a['action'] ?? ''}'.trim().toLowerCase();
      final p = '${a['pattern'] ?? ''}';
      final t = '${a['text'] ?? ''}';
      final g = int.tryParse('${a['group'] ?? ''}') ?? 0;
      if (act == 'check') {
        final r = RegexTool.check(p);
        return r.$1 ? '正则可用的' : '正则非法: ${r.$2}';
      }
      switch (act) {
        case 'all': {
          final l = RegexTool.all(p, t, group: g);
          return l.isEmpty ? '(无匹配)' : l.join('\n');
        }
        case 'first': return RegexTool.first(p, t, group: g) ?? '(无匹配)';
        case 'test': return RegexTool.test(p, t) ? '命中' : '未命中';
        case 'replace': return RegexTool.replace(p, t, '${a['with'] ?? ''}') ?? '正则非法';
        default: return 'action 只支持 all/first/test/replace/check';
      }
    }),
    LocalTool('time_tool', '时间: 取当前时间 / 时间戳与日期互转 / 时长格式化',
      _obj({'action': 'now|from_epoch|dur', 'value': 'from_epoch 的秒或毫秒; dur 的毫秒数'}, ['action']), (a) async {
      final act = '${a['action'] ?? ''}'.trim().toLowerCase();
      switch (act) {
        case 'now': case '': {
          final n = DateTime.now();
          return '本地时间 ${TimeTool.full(n)}\n'
              'UTC ${TimeTool.full(n.toUtc())}\n'
              '时间戳 ${n.millisecondsSinceEpoch} ms / ${n.millisecondsSinceEpoch ~/ 1000} s\n'
              '星期${['一', '二', '三', '四', '五', '六', '日'][n.weekday - 1]}';
        }
        case 'from_epoch': {
          final v = num.tryParse('${a['value'] ?? ''}');
          if (v == null) return 'value 不是数字';
          final t = TimeTool.fromEpoch(v);
          return t == null ? '无法识别的时间戳' : TimeTool.full(t);
        }
        case 'dur': {
          final v = int.tryParse('${a['value'] ?? ''}');
          return v == null ? 'value 不是整数毫秒' : TimeTool.dur(v);
        }
        default: return 'action 只支持 now / from_epoch / dur';
      }
    }),
    LocalTool('hash_text', '计算文本指纹(FNV-1a 32/64 位), 用于去重与快速比对(非密码学安全)',
      _obj({'text': '要计算的文本'}, ['text']), (a) async {
      final t = '${a['text'] ?? ''}';
      return 'fnv1a32 = ${Hashing.fnv1a32(t)}\nfnv1a64 = ${Hashing.fnv1a64(t)}\n长度 ${t.length}';
    }),
    LocalTool('id_gen', '生成不重复的短 id(可用于命名文件/笔记/任务)',
      _obj({'prefix': '前缀, 默认 id', 'count': '生成几个, 默认 1(最多 20)'}, []), (a) async {
      final p = '${a['prefix'] ?? 'id'}'.trim();
      final n = (int.tryParse('${a['count'] ?? ''}') ?? 1).clamp(1, 20);
      return List.generate(n, (_) => IdGen.next(p.isEmpty ? 'id' : p)).join('\n');
    }),
    LocalTool('context_now', '获取当前上下文(用户正处在哪个模块/App 版本/在线状态/可用模块), 用于回答"我现在在哪""能做什么"',
      _obj({}), (_) async {
      final hook = LocalHooks.contextOf;
      if (hook == null) return '上下文钩子未注入';
      try { return await hook(); } catch (e) { return '取上下文失败: $e'; }
    }),
    LocalTool('goto_module', '切换到某个模块(前端是控制层, 可直接指挥自己)',
      _obj({'module': '模块名, 如 "浏览器"/"相册"'}, ['module']), (a) async {
      final hook = LocalHooks.gotoModule;
      if (hook == null) return '模块切换钩子未注入';
      final m = '${a['module'] ?? ''}'.trim();
      if (m.isEmpty) return 'module 不能为空';
      try { return await hook(m); } catch (e) { return '切换失败: $e'; }
    }),
    LocalTool('list_modules', '列出当前导航栏里的全部模块名', _obj({}), (_) async {
      final hook = LocalHooks.listModules;
      if (hook == null) return '模块列表钩子未注入';
      try {
        final l = await hook();
        return l.isEmpty ? '(导航栏为空)' : l.join(' · ');
      } catch (e) { return '取模块列表失败: $e'; }
    }),
    LocalTool('setting', '读取或修改 App 设置项(如 nav_swipe 左右滑动/auto_fs_sec 自动全屏秒数/nav_style 导航形态)',
      _obj({'action': 'get|set', 'key': '设置键', 'value': 'set 时的值'}, ['action', 'key']), (a) async {
      final act = '${a['action'] ?? ''}'.trim().toLowerCase();
      final k = '${a['key'] ?? ''}'.trim();
      if (k.isEmpty) return 'key 不能为空';
      if (act == 'get') {
        final h = LocalHooks.getSetting;
        return h == null ? '设置钩子未注入' : await h(k);
      }
      if (act == 'set') {
        final h = LocalHooks.setSetting;
        return h == null ? '设置钩子未注入' : await h(k, '${a['value'] ?? ''}');
      }
      return 'action 只支持 get / set';
    }),
    // ── 本地笔记：纯文件存储, 离线可用(不依赖后端/账号/网络) ──
    LocalTool('note', '本地笔记: 新增(add) / 列出(list) / 搜索(search) / 删除(del)',
      _obj({'action': 'add|list|search|del', 'text': 'add 时的内容', 'id': 'del 时的笔记 id', 'query': 'search 时的关键词'}, ['action']), (a) async {
      final act = '${a['action'] ?? ''}'.trim().toLowerCase();
      final list = await LocalNotes.load();
      switch (act) {
        case 'add': {
          final t = '${a['text'] ?? ''}'.trim();
          if (t.isEmpty) return 'text 不能为空';
          final id = IdGen.next('note');
          list.insert(0, {'id': id, 'text': t, 'ts': DateTime.now().millisecondsSinceEpoch});
          await LocalNotes.save(list);
          return '已新增笔记 $id（共 ${list.length} 条）';
        }
        case 'list': {
          if (list.isEmpty) return '(还没有笔记)';
          return list.take(50).map((e) =>
            '[${e['id']}] ${TimeTool.rel(DateTime.now(), TimeTool.fromEpoch(e['ts'] as int)!)}  ${e['text']}').join('\n');
        }
        case 'search': {
          final q = '${a['query'] ?? ''}'.toLowerCase();
          final hit = list.where((e) => '${e['text']}'.toLowerCase().contains(q)).toList();
          if (hit.isEmpty) return '(没有匹配的笔记)';
          return hit.take(30).map((e) => '[${e['id']}] ${e['text']}').join('\n');
        }
        case 'del': {
          final id = '${a['id'] ?? ''}'.trim();
          final before = list.length;
          list.removeWhere((e) => '${e['id']}' == id);
          if (list.length == before) return '没找到该 id 的笔记';
          await LocalNotes.save(list);
          return '已删除 $id（剩 ${list.length} 条）';
        }
        default: return 'action 只支持 add / list / search / del';
      }
    }),

    // ── 端网（PH/1）：让 AI 也能指挥局域网里的插件 / 其他端 ──
    //  这两个工具是"一方输入，其他方都能用"在 AI 侧的落点：
    //  用户在 App 里让 AI「用下载插件把这个磁力加上」，AI 就能自己找到插件并派活。
    LocalTool('peer_list', '查看端网里有哪些端（局域网插件/其他设备/后端），各自能干什么、是否在线', _obj({}), (_) async {
      final reg = (await PeerHubClient.list()).stamped(DateTime.now().millisecondsSinceEpoch);
      if (reg.peers.isEmpty) {
        return '端网里还没有任何端。';
      }
      final b = StringBuffer();
      for (final p in reg.online) {
        b.writeln('[在线] ${p.name.isEmpty ? p.iid : p.name} (${p.iid}) · ${peerKindName(p.kind)}'
            '${p.caps.isEmpty ? "" : " · 能力:${p.caps.join("/")}"}'
            '${p.tools.isEmpty ? "" : " · 工具:${p.tools.join("/")}"}');
      }
      for (final p in reg.pendingLogins) {
        b.writeln('[待登录] ${p.name.isEmpty ? p.iid : p.name} (${p.iid})'
            '${p.caps.isEmpty ? "" : " · 能力:${p.caps.join("/")}"}'
            ' —— 还没登录账号，不能用；需要在插件那边填账号口令');
      }
      for (final p in reg.offline.where((e) => !e.pendingLogin)) {
        b.writeln('[离线] ${p.name.isEmpty ? p.iid : p.name} (${p.iid})');
      }
      b.writeln(reg.hub == null ? '后端：不在线（只能直连插件）' : '后端：在线');
      return b.toString().trim();
    }),

    LocalTool('peer_invoke', '调用端网里某个端提供的工具（比如插件的 dl.add 加下载任务）。'
        '不填 peer 时按 tool 自动挑选能干的端；不填 tool 时先看看这个端会什么',
        _obj({'peer': '目标端的 iid 或名字，不填则自动选', 'tool': '要调用的工具名，如 dl.add',
              'args': '参数的 JSON 字符串，如 {"link":"magnet:?xt=..."}'}), (_a) async {
      final args = _a as Map<String, dynamic>;
      final reg = (await PeerHubClient.list()).stamped(DateTime.now().millisecondsSinceEpoch);
      final wantPeer = '${args['peer'] ?? ''}'.trim();
      final tool = '${args['tool'] ?? ''}'.trim();
      Map<String, dynamic> callArgs = const {};
      final raw = '${args['args'] ?? ''}'.trim();
      if (raw.isNotEmpty) {
        try {
          final o = jsonDecode(raw);
          if (o is Map) callArgs = Map<String, dynamic>.from(o);
        } catch (_) {
          return 'args 不是合法 JSON：$raw';
        }
      }
      // 定位目标端：iid 或名字（判定在内核里，有自检守着"重名不猜"）
      PeerInfo? target;
      if (wantPeer.isNotEmpty) {
        target = reg.resolve(wantPeer);
        if (target == null) {
          final dup = reg.peers.where((p) => p.name == wantPeer).length > 1;
          return dup
              ? '端网里有多个端都叫「$wantPeer」，请改用 iid 指定。'
              : '端网里没有「$wantPeer」。先调 peer_list 看看有哪些端。';
        }
        if (target.pendingLogin) {
          return '「${target.name}」只是被局域网发现，还没登录账号接入，不能用。'
              '需要先在插件那边填账号口令。';
        }
        if (!target.online) return '「${target.name}」当前不在线。';
      } else {
        if (tool.isEmpty) return '请至少给 tool（或给 peer 让我看看它会什么）。';
        // 不指定目标：按工具名自动挑一个能接的端
        final route = PeerRouter.route(reg, cap: tool, allowLocal: false);
        if (route == null || route.peer == null) {
          return '端网里没有端能提供「$tool」。先调 peer_list 看看都有什么。';
        }
        target = route.peer;
      }
      // 到这里 target 一定非空（两条分支要么 return，要么赋了值），但 Dart 的
      // 流分析看不穿「某个分支里 route.peer 已判非空」，所以显式收成一个非空局部量。
      final PeerInfo t = target!;
      if (tool.isEmpty) {
        return '「${t.name}」提供的工具：'
            '${t.tools.isEmpty ? "(它没上报工具名，只有能力 ${t.caps.join("/")})" : t.tools.join(", ")}';
      }
      // ★ invoke 的第一个位置参数是 **cap**（能力），不是工具名 —— 这里是
      //   `invoke(String cap, {String? tool, ...})`。传 tool 当 cap 是有意的：
      //   内核的 canTake/route 对 cap 与 tool 是**两套标识都查**的
      //   （caps 粗粒度如 download，tools 具体如 dl.add），所以 tool 名同样能匹配到端。
      final r = await PeerHubClient.invoke(tool, tool: tool, args: callArgs, preferIid: t.iid);
      if (!r.ok) return '调用失败：${r.error}';
      final s = r.result is String ? r.result : jsonEncode(r.result);
      return '已通过${r.via == PeerVia.hub ? "后端转发" : "直连"}调用「${t.name}」的 $tool，结果：$s';
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

/// 本地笔记：纯文件存储（App 文档目录 `th_notes.json`），离线可用。
/// 不依赖后端、不依赖账号 —— 没网也记得住事。最多保留 [max] 条。
class LocalNotes {
  static const int max = 200;

  static Future<File> _file() async {
    final d = await getApplicationDocumentsDirectory();
    return File('${d.path}/th_notes.json');
  }

  static Future<List<Map<String, dynamic>>> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return [];
      final o = jsonDecode(await f.readAsString());
      if (o is! List) return [];
      return [for (final e in o) if (e is Map) Map<String, dynamic>.from(e)];
    } catch (_) {
      return []; // 文件损坏/权限问题一律当空，不把异常甩给模型
    }
  }

  static Future<void> save(List<Map<String, dynamic>> list) async {
    try {
      final trimmed = list.length > max ? list.sublist(0, max) : list;
      await (await _file()).writeAsString(jsonEncode(trimmed));
    } catch (_) {}
  }

  static Future<int> count() async => (await load()).length;
}
