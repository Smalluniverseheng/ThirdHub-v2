// AI 控制总线 · 本地 HTTP 桥
//
// 为什么是本地 HTTP 而不是 ADB：
//   1) ADB 要求电脑、数据线、开启调试 —— 用户在手机上自测时根本没有；
//   2) 只有 App 自己知道「当前是第几个平台、播放器 buffered 到哪、这行字在哪个坐标」，
//      ADB 只能看像素，读不到语义；
//   3) 同一套协议手机、平板、桌面端都能用，不依赖平台工具链。
//
// 安全模型（别嫌啰嗦，这是对外开放端口）：
//   · 默认**关闭**，必须在设置里手动打开，且开关状态落 SharedPreferences；
//   · 每次请求校验 token（持久化生成一次的 16 字节随机串，显示在悬浮球面板里）；
//   · 只认白名单 op（见 agent_protocol.dart 的 agentOps），不做任意方法派发；
//   · 只提供「操作本 App 自己」的能力，不接受任意 URL / 任意文件路径参数。
//
// 协议：
//   GET  /agent/health           → {ok, proto, version, port, ops}
//   GET  /agent/state            → 应用状态快照
//   GET  /agent/tree             → 当前屏幕可寻址控件
//   GET  /agent/shot             → image/png 原始字节
//   POST /agent/exec   {op:...}  → {ok, data|error, ms}
//   POST /agent/script [{op},…]  → {ok, results:[…]}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_version.dart';
import 'agent_deeplink.dart';
import 'agent_map.dart';
import 'agent_protocol.dart';
import 'agent_targets.dart';

class AgentBridge {
  AgentBridge._();
  static final AgentBridge I = AgentBridge._();

  HttpServer? _srv;
  String token = '';
  int port = 9777;

  /// 是否在监听（悬浮球据此显示灯色）
  final ValueNotifier<bool> running = ValueNotifier(false);

  /// 每次有指令/日志变化 +1，供面板刷新（不用 StreamBuilder，简单）
  final ValueNotifier<int> tick = ValueNotifier(0);

  /// 最近 80 条日志，{t, line, ok}
  final List<Map<String, dynamic>> logs = [];

  int served = 0;
  String lastError = '';

  /// 指令串行队列：App 是单线程 UI，两条指令并发注入手势会互相打架
  /// （典型症状：tap 被后一条 swipe 的 down 抢走 → 表现为"点击没反应"）。
  Future<void> _chain = Future<void>.value();

  static const int defaultPort = 9777;

  // ── 生命周期 ──

  Future<bool> start({int? forcePort, bool? lan}) async {
    if (running.value) return true;
    try {
      final p = await SharedPreferences.getInstance();
      token = p.getString('agent_token') ?? '';
      if (token.isEmpty) {
        token = _randHex(16);
        await p.setString('agent_token', token);
      }
      port = forcePort ?? p.getInt('agent_port') ?? defaultPort;
      // ★4.81.83 权限模型（用户原话：「这个权限默认是开着的，
      //   只是要局域网连接的话才需要打开」）：
      //   · App 内 AI 操控（自驱动循环 / app_open）根本不经过这个 server，
      //     永远可用，不需要任何开关；
      //   · 这里只管"让别的设备连进来"，默认只绑 127.0.0.1，
      //     必须在设置里显式打开「局域网调试通道」才绑 0.0.0.0。
      //   兼容旧用户：以前开悬浮球就等于开桥，那时是 0.0.0.0 ——
      //   如果 agent_lan 从没写过而悬浮球是开的，视为已授权过局域网。
      final wantLan = lan ??
          p.getBool('agent_lan') ??
          (p.getBool('agent_orb') ?? false);
      _lan = wantLan;
      _srv = await HttpServer.bind(
        wantLan ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4,
        port,
        shared: false,
      );
      _srv!.autoCompress = true;
      running.value = true;
      lastError = '';
      _log('bridge start on ${wantLan ? '0.0.0.0' : '127.0.0.1'}:$port',
          ok: true);
      _srv!.listen(_guard, onError: (Object e) {
        lastError = '$e';
        _log('server error: $e', ok: false);
      });
      return true;
    } catch (e) {
      lastError = '$e';
      _log('bridge start failed: $e', ok: false);
      running.value = false;
      return false;
    }
  }

  /// 当前是否允许局域网连入（false = 只监听本机回环）
  bool _lan = false;
  bool get lan => _lan;

  /// 开/关局域网通道。落盘 + 运行中就重启一次绑定地址。
  Future<bool> setLan(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('agent_lan', v);
    _lan = v;
    if (running.value) {
      await stop();
      return start(lan: v);
    }
    return true;
  }

  Future<void> stop() async {
    try {
      await _srv?.close(force: true);
    } catch (_) {}
    _srv = null;
    running.value = false;
    _log('bridge stopped', ok: true);
  }

  /// 换端口（面板里可改）：先关再开，失败自动回滚到旧端口
  Future<bool> changePort(int np) async {
    if (np < 1024 || np > 65535) return false;
    final old = port;
    await stop();
    final ok = await start(forcePort: np);
    if (!ok) {
      await start(forcePort: old);
      return false;
    }
    final p = await SharedPreferences.getInstance();
    await p.setInt('agent_port', np);
    return true;
  }

  String _randHex(int bytes) {
    final r = Random.secure();
    return List.generate(bytes, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
  }

  // ── HTTP ──

  Future<void> _guard(HttpRequest req) async {
    try {
      await _route(req);
    } catch (e) {
      try {
        req.response.statusCode = 500;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'ok': false, 'error': '$e'}));
        await req.response.close();
      } catch (_) {}
    }
  }

  Future<void> _route(HttpRequest req) async {
    final res = req.response;
    res.headers.set('access-control-allow-origin', '*');
    res.headers.set('access-control-allow-headers', 'content-type,x-agent-token');
    res.headers.set('access-control-allow-methods', 'GET,POST,OPTIONS');
    if (req.method == 'OPTIONS') {
      res.statusCode = 204;
      await res.close();
      return;
    }

    final path = req.uri.path;
    if (path == '/agent/health') {
      // 探活**不校验 token**，但要暴露"是否需要 token"，方便客户端先探再带。
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode(agentEnvelope({
        'ready': true,
        'needToken': token.isNotEmpty,
        'port': port,
        'app': kAppVersion,
        'build': kAppCode,
        'ops': agentOps.toList()..sort(),
      })));
      await res.close();
      return;
    }

    if (!_authOk(req)) {
      res.statusCode = 401;
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode({'ok': false, 'error': 'bad token', 'hint': '带上 x-agent-token 头'}));
      await res.close();
      _log('401 $path', ok: false);
      return;
    }

    if (req.method == 'GET' && path == '/agent/state') {
      final r = await exec(const AgentCmd('state', {}));
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode(r.toJson()));
      await res.close();
      return;
    }

    if (req.method == 'GET' && path == '/agent/tree') {
      final r = await exec(const AgentCmd('tree', {}));
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode(r.toJson()));
      await res.close();
      return;
    }

    if (req.method == 'GET' && path == '/agent/shot') {
      final raw = await AgentTargets.shoot(
          pixelRatio: double.tryParse(req.uri.queryParameters['pr'] ?? '') ?? 1.0);
      if (raw == null) {
        res.statusCode = 503;
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({'ok': false, 'error': 'screenshot unavailable'}));
      } else {
        res.headers.contentType = ContentType('image', 'png');
        res.add(raw);
      }
      await res.close();
      return;
    }

    if (req.method == 'POST') {
      final body = await utf8.decoder.bind(req).join();
      Map<String, dynamic> j;
      try {
        final dec = jsonDecode(body);
        if (dec is List) {
          // 允许直接 POST 数组 → 等价于 script
          j = {'op': 'script', 'steps': dec};
        } else {
          j = Map<String, dynamic>.from(dec as Map);
        }
      } catch (e) {
        res.statusCode = 400;
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({'ok': false, 'error': 'bad json: $e'}));
        await res.close();
        return;
      }
      final r = await exec(AgentCmd.fromJson(j));
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode(r.toJson()));
      await res.close();
      return;
    }

    res.statusCode = 404;
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode({
      'ok': false,
      'error': 'no route $path',
      'hint': '可用：/agent/health /agent/state /agent/tree /agent/shot POST /agent/exec',
    }));
    await res.close();
  }

  bool _authOk(HttpRequest req) {
    if (token.isEmpty) return true;
    final h = req.headers.value('x-agent-token') ??
        req.uri.queryParameters['t'] ??
        req.uri.queryParameters['token'] ??
        '';
    if (h.length != token.length) return false;
    // 定长比较，避免按字节提前返回泄露 token 前缀
    var diff = 0;
    for (var i = 0; i < token.length; i++) {
      diff |= h.codeUnitAt(i) ^ token.codeUnitAt(i);
    }
    return diff == 0;
  }

  // ── 指令执行 ──

  Future<AgentResult> exec(AgentCmd cmd) {
    final c = Completer<AgentResult>();
    _chain = _chain.then((_) async {
      final sw = Stopwatch()..start();
      try {
        final r = await _run(cmd);
        sw.stop();
        final out = r.ok
            ? AgentResult.ok(r.data, ms: sw.elapsedMilliseconds)
            : AgentResult.err(r.error, hint: r.hint, ms: sw.elapsedMilliseconds);
        served++;
        _log('${cmd.op} ${cmd.args.isEmpty ? '' : _brief(cmd.args)} → ${out.ok ? 'ok' : 'ERR ${out.error}'} (${out.ms}ms)',
            ok: out.ok);
        c.complete(out);
      } catch (e) {
        sw.stop();
        lastError = '$e';
        _log('${cmd.op} threw: $e', ok: false);
        c.complete(AgentResult.err('$e', ms: sw.elapsedMilliseconds));
      }
    });
    return c.future;
  }

  String _brief(Map<String, dynamic> a) {
    final s = jsonEncode(a);
    return s.length > 120 ? '${s.substring(0, 117)}…' : s;
  }

  Future<AgentResult> _run(AgentCmd c) async {
    if (!agentOps.contains(c.op)) {
      return AgentResult.err('unknown op "${c.op}"',
          hint: '可用：${(agentOps.toList()..sort()).join(", ")}');
    }
    switch (c.op) {
      case 'ping':
        return AgentResult.ok({'pong': true, 'app': kAppVersion, 'port': port});

      case 'state':
        final s = AgentTargets.stateProvider?.call() ?? {};
        return AgentResult.ok({
          'app': kAppVersion,
          'build': kAppCode,
          'running': running.value,
          'served': served,
          ...s,
        });

      case 'tree':
        final nodes = AgentTargets.visibleTree(limit: c.integer('limit') ?? 220);
        return AgentResult.ok({
          'count': nodes.length,
          'nodes': nodes.map((e) => e.toJson()).toList(),
        });

      case 'nav':
        final m = c.str('module') ?? c.str('name') ?? c.str('target');
        if (m == null || m.isEmpty) {
          return AgentResult.err('nav needs module', hint: '{"op":"nav","module":"视频"}');
        }
        final f = AgentTargets.openModule;
        if (f == null) return AgentResult.err('openModule not wired');
        final ok = await f(m);
        await AgentTargets.settle(320);
        return ok
            ? AgentResult.ok({'module': m})
            : AgentResult.err('module "$m" not opened',
                hint: '模块名要与底部导航一致；也可能是当前平台门禁不允许该模块');

      case 'map':
        // 模块地图：给 AI / 宿主脚本一份"这个 App 有什么、能跳到哪"的确定答案。
        // 比让调用方截图猜快得多，也不会因为栏目顺序变了就跳空。
        final mq = (c.str('module') ?? '').trim();
        if (mq.isNotEmpty) {
          final mod = AgentMap.find(mq);
          if (mod == null) {
            return AgentResult.err('no module "$mq"',
                hint: '现有：${AgentMap.keys.join(" / ")}');
          }
          return AgentResult.ok({
            'module': mod.key,
            'what': mod.what,
            'deeplink': mod.deeplink,
            'searchable': mod.searchable,
            'pages': [
              for (final p in mod.pages)
                {'name': p.name, 'how': p.how, 'what': p.what}
            ],
          });
        }
        return AgentResult.ok({
          'text': AgentMap.prompt(),
          'modules': [
            for (final m in AgentMap.modules)
              {'module': m.key, 'what': m.what, 'deeplink': m.deeplink}
          ],
        });

      case 'deeplink':
        // 深链展开：thirdhub://video?platform=hongguo → [nav, platform]
        // 为什么走这里而不是让调用方自己拆：解析器只有一份（agent_deeplink.dart），
        // 外部意图、AI、宿主脚本三条路必须落到同一组动作上。
        final url = c.str('url') ?? c.str('uri');
        if (url == null || url.isEmpty) {
          return AgentResult.err('deeplink needs url',
              hint: '{"op":"deeplink","url":"thirdhub://video?platform=hongguo"}');
        }
        final steps = AgentDeeplink.parse(url);
        if (steps.isEmpty) {
          return AgentResult.err('unrecognized deeplink "$url"',
              hint: '支持：thirdhub://video?platform=… / novel?q=… / open?module=… / do?action=…');
        }
        final outs = <Map<String, dynamic>>[];
        for (final s in steps) {
          final r = await exec(AgentCmd.fromJson(s));
          outs.add({'op': s['op'], ...r.toJson()});
          if (!r.ok) {
            return AgentResult.err('deeplink step ${outs.length} failed: ${r.error}',
                hint: '${r.hint ?? ''} 已执行 ${outs.length}/${steps.length} 步');
          }
        }
        return AgentResult.ok({'url': url, 'steps': outs});

      case 'tab':

        final f = AgentTargets.switchModule;
        if (f == null) return AgentResult.err('switchModule not wired');
        final name = c.str('name') ?? c.str('module') ?? '${c.integer('index') ?? 0}';
        final ok = await f(name);
        await AgentTargets.settle(320);
        return ok
            ? AgentResult.ok({'tab': name})
            : AgentResult.err('tab "$name" not found');

      case 'platform':
        final f = AgentTargets.switchVideoPlatform;
        if (f == null) return AgentResult.err('switchVideoPlatform not wired');
        final name = c.str('name') ?? '${c.integer('index') ?? 0}';
        final ok = await f(name);
        await AgentTargets.settle(360);
        return ok
            ? AgentResult.ok({'platform': name})
            : AgentResult.err('platform "$name" not found',
                hint: '先 nav 到「视频」，平台列表随开关（第三方源）变化');

      case 'subtab':
        final f = AgentTargets.switchSubTab;
        if (f == null) return AgentResult.err('switchSubTab not wired');
        final page = c.str('page') ?? '';
        final tab = c.str('tab') ?? c.str('name') ?? '${c.integer('index') ?? 0}';
        final ok = await f(page, tab);
        await AgentTargets.settle(320);
        return ok
            ? AgentResult.ok({'page': page, 'tab': tab})
            : AgentResult.err('subtab "$tab" not found in "$page"');

      case 'tap':
        return _tap(c);

      case 'swipe':
        return _swipe(c);

      case 'input':
        return _input(c);

      case 'back':
        final nav = AgentTargets.navigatorKey?.currentState;
        if (nav == null) return AgentResult.err('navigator not ready');
        final popped = await nav.maybePop();
        await AgentTargets.settle(300);
        return AgentResult.ok({'popped': popped});

      case 'shot':
        final pr = c.num_('pr') ?? 1.0;
        final raw = await AgentTargets.shoot(pixelRatio: pr);
        if (raw == null) return AgentResult.err('screenshot failed');
        if (c.bool_('raw')) {
          return AgentResult.ok({'bytes': raw.length});
        }
        return AgentResult.ok({
          'bytes': raw.length,
          'png_b64': base64Encode(raw),
        });

      case 'wait':
        final ms = c.integer('ms') ?? 300;
        await Future<void>.delayed(Duration(milliseconds: ms.clamp(0, 30000)));
        return AgentResult.ok({'waited': ms});

      case 'assert':
        return _assert(c);

      case 'eval':
        final name = c.str('name');
        if (name == null) return AgentResult.err('eval needs name');
        final f = AgentTargets.actions[name];
        if (f == null) {
          return AgentResult.err('no action "$name"',
              hint: '已注册：${AgentTargets.actions.keys.join(", ")}');
        }
        final v = await f(c.args);
        await AgentTargets.settle(200);
        return AgentResult.ok(v);

      case 'script':
        final steps = c.args['steps'];
        if (steps is! List) {
          return AgentResult.err('script needs steps[]');
        }
        final outs = <Map<String, dynamic>>[];
        for (final s in steps) {
          if (s is! Map) continue;
          final r = await exec(AgentCmd.fromJson(Map<String, dynamic>.from(s)));
          outs.add({'op': (s['op'] ?? '?'), ...r.toJson()});
          if (!r.ok && !c.bool_('continueOnError')) {
            // 失败即停（默认），但把已跑的步骤一起带回去 ——
            // 「第 3 步挂了」比「脚本挂了」有用得多。
            return AgentResult.err('step ${outs.length} failed: ${r.error}',
                hint: '${r.hint ?? ''} 已执行 ${outs.length}/${steps.length} 步');
          }
        }
        return AgentResult.ok({'total': steps.length, 'steps': outs});
    }
    return AgentResult.err('unhandled op ${c.op}');
  }

  Future<AgentResult> _tap(AgentCmd c) async {
    Offset? target;
    String how;
    final key = c.str('key');
    final text = c.str('text') ?? c.str('label');
    final xy = c.xy;
    if (key != null && key.isNotEmpty) {
      final n = AgentTargets.findByKey(key);
      if (n == null) {
        return AgentResult.err('key "$key" not on screen',
            hint: 'GET /agent/tree 看当前有哪些 key；也可能是页面还没加载完，先 wait');
      }
      target = n.rect.center;
      how = 'key:$key';
    } else if (text != null && text.isNotEmpty) {
      final n = AgentTargets.findByText(text, exact: c.bool_('exact'));
      if (n == null) {
        return AgentResult.err('text "$text" not visible',
            hint: '文字必须与屏幕上完全可见的内容匹配；列表项可能需要先 swipe 出来');
      }
      target = n.rect.center;
      how = 'text:$text';
    } else if (xy != null) {
      target = AgentTargets.px(xy);
      how = 'xy:$xy';
    } else {
      return AgentResult.err('tap needs key / text / xy');
    }
    await AgentTargets.tap(target);
    await AgentTargets.settle(c.integer('settle') ?? 300);
    return AgentResult.ok({'at': [target.dx, target.dy], 'how': how});
  }

  Future<AgentResult> _swipe(AgentCmd c) async {
    final d = c.dir;
    if (d == null) {
      return AgentResult.err('swipe needs dir left|right|up|down');
    }
    final s = AgentTargets.screenSize;
    final w = s.width > 0 ? s.width : 1080.0;
    final h = s.height > 0 ? s.height : 1920.0;
    final frac = (c.num_('dist') ?? 0.55).clamp(0.05, 0.95);
    final center = c.xy != null
        ? AgentTargets.px(c.xy!)
        : Offset(w / 2, h * 0.5);
    Offset from, to;
    switch (d) {
      case 'left':
        from = Offset(center.dx + w * frac / 2, center.dy);
        to = Offset(center.dx - w * frac / 2, center.dy);
      case 'right':
        from = Offset(center.dx - w * frac / 2, center.dy);
        to = Offset(center.dx + w * frac / 2, center.dy);
      case 'up':
        from = Offset(center.dx, center.dy + h * frac / 2);
        to = Offset(center.dx, center.dy - h * frac / 2);
      default:
        from = Offset(center.dx, center.dy - h * frac / 2);
        to = Offset(center.dx, center.dy + h * frac / 2);
    }
    await AgentTargets.swipe(from, to,
        steps: c.integer('steps') ?? 10, ms: c.integer('ms') ?? 220);
    await AgentTargets.settle(c.integer('settle') ?? 420);
    return AgentResult.ok({'dir': d, 'from': [from.dx, from.dy], 'to': [to.dx, to.dy]});
  }

  Future<AgentResult> _input(AgentCmd c) async {
    final text = c.str('text') ?? '';
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return AgentResult.err('no element tree');
    // 找当前持有焦点的 EditableText（等价于"正在输入的那个框"）
    int count = 0;
    String? got;
    String? target;
    void visit(Element e) {
      if (got != null) return;
      final w = e.widget;
      if (w is EditableText) {
        count++;
        final focused = w.focusNode.hasFocus ||
            (c.bool_('first') && count == 1);
        if (focused) {
          got = text;
          target = w.controller.text.isEmpty ? '(empty)' : 'text field';
          w.controller.text = text;
          w.controller.selection =
              TextSelection.collapsed(offset: w.controller.text.length);
        }
      }
      e.visitChildren(visit);
    }

    visit(root);
    if (got == null) {
      return AgentResult.err('no focused text field',
          hint: '先用 tap 点一下输入框（{"op":"tap","text":"搜索"}），再 input');
    }
    await AgentTargets.settle(200);
    return AgentResult.ok({'filled': text.length, 'field': target});
  }

  Future<AgentResult> _assert(AgentCmd c) async {
    final text = c.str('text');
    final key = c.str('key');
    final waitMs = c.integer('timeout') ?? 0;
    final deadline = DateTime.now().add(Duration(milliseconds: waitMs));
    while (true) {
      if (text != null) {
        final n = AgentTargets.findByText(text, exact: c.bool_('exact'));
        if (n != null) {
          return AgentResult.ok({'found': 'text', 'rect': n.toJson()['rect']});
        }
      } else if (key != null) {
        final n = AgentTargets.findByKey(key);
        if (n != null) return AgentResult.ok({'found': 'key', 'label': key});
      } else {
        // 无参断言 → 断言 App 没崩（element tree 可遍历）+ 可选 check 表达式
        final st = AgentTargets.stateProvider?.call() ?? {};
        final want = c.str('module');
        if (want != null && (st['module'] != want)) {
          return AgentResult.err('current module ${st['module']} != $want');
        }
        return AgentResult.ok({'alive': true, 'state': st});
      }
      if (DateTime.now().isAfter(deadline)) {
        return AgentResult.err('assert failed: ${text != null ? "text" : "key"} "$text$key" not found',
            hint: 'App 可能还在加载；加大 timeout，或先 GET /agent/tree 看看当前屏幕');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  // ── 日志 ──

  void _log(String line, {required bool ok}) {
    logs.insert(0, {
      't': DateTime.now().toIso8601String().substring(11, 19),
      'line': line,
      'ok': ok,
    });
    if (logs.length > 80) logs.removeLast();
    tick.value++;
  }

  /// 给悬浮球用的连接信息
  String get connectHint => 'http://<手机IP>:$port  token=$token';
}
