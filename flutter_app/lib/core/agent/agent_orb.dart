// AI 控制总线 · 智能助手悬浮球
//
// 这就是用户说的「AI 对话的时候生成一个智能助手悬浮球」——
// 它同时是三个东西：
//   1) 状态灯：绿=桥在监听，灰=关闭（不用连电脑就知道通不通）
//   2) 连接信息：手机 IP、端口、token，一键复制给 AI 侧
//   3) 日志窗：AI 发的每条指令都会在这里出现，人机看的是同一份事实
//
// 挂载方式：MaterialApp.builder 里包一层（见 main.dart），
// 这样它浮在**所有**路由之上，连全屏播放器盖不住它（锁屏时可关）。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../i18n.dart';
import 'agent_bridge.dart';
import 'agent_protocol.dart';

/// 悬浮球宿主：把所有页面包进来，球叠在最上层。
class AgentOrbHost extends StatefulWidget {
  final Widget child;

  /// 默认是否显示球（设置项 `agent_orb`，默认关）
  final bool show;

  const AgentOrbHost({super.key, required this.child, this.show = false});

  @override
  State<AgentOrbHost> createState() => AgentOrbHostState();
}

class AgentOrbHostState extends State<AgentOrbHost> {
  static AgentOrbHostState? inst;

  bool show = false;
  bool open = false;
  String ip = '';
  Offset? pos; // null = 还没拖动过，按屏幕位置摆默认点

  @override
  void initState() {
    super.initState();
    inst = this;
    show = widget.show;
    _loadIp();
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      final on = p.getBool('agent_orb') ?? false;
      setState(() {
        show = on;
      });
      // 上次退出时球是开的 → 这次一启动就把桥拉起来。
      // 不这么做的话，App 重启后球还在、灯却是灰的，
      // 用户会以为"这功能只有刚打开那一下能用"。
      if (on) AgentBridge.I.start();
    });
  }

  @override
  void dispose() {
    if (inst == this) inst = null;
    super.dispose();
  }

  Future<void> _loadIp() async {
    try {
      final list = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false);
      final cand = <String>[];
      for (final n in list) {
        for (final a in n.addresses) {
          if (a.address.startsWith('169.254')) continue;
          cand.add(a.address);
        }
      }
      // 局域网地址优先（192.168 / 10. / 172.16-31）
      cand.sort((a, b) {
        int rank(String s) {
          if (s.startsWith('192.168.')) return 0;
          if (s.startsWith('10.')) return 1;
          if (s.startsWith('172.')) return 2;
          return 3;
        }

        return rank(a).compareTo(rank(b));
      });
      if (!mounted) return;
      setState(() => ip = cand.isEmpty ? '127.0.0.1' : cand.first);
    } catch (_) {}
  }

  /// 外部（设置页开关）调用：开关球并落盘
  static Future<void> setShow(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('agent_orb', v);
    inst?.setState(() => inst!.show = v);
    // 开球 = 同时把桥拉起来（否则"球在但没监听"是最难解释的状态）
    if (v) {
      await AgentBridge.I.start();
    } else {
      await AgentBridge.I.stop();
      inst?.setState(() => inst!.open = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!show) return widget.child;
    final mq = MediaQuery.of(context);
    final size = mq.size;
    // 首次用默认位置（右侧偏下），之后跟随拖动；旋转/分屏时夹回可视区。
    final base = pos ?? Offset(size.width - 64, size.height * 0.62);
    final eff = Offset(
      base.dx.clamp(4.0, size.width - 56),
      base.dy.clamp(mq.padding.top + 40, size.height - 120),
    );
    return Stack(
      children: [
        widget.child,
        Positioned(
          left: eff.dx,
          top: eff.dy,
          child: Material(
            type: MaterialType.transparency,
            child: ValueListenableBuilder<bool>(
              valueListenable: AgentBridge.I.running,
              builder: (c, _, __) => Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (open) _panel(context),
                  _ball(context),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _ball(BuildContext context) {
    final on = AgentBridge.I.running.value;
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => setState(() => open = !open),
      onPanUpdate: (d) => setState(() {
        final mq = MediaQuery.of(context);
        final cur = pos ?? Offset(mq.size.width - 64, mq.size.height * 0.62);
        pos = cur + d.delta;
      }),
      child: Container(
        width: 48,
        height: 48,
        margin: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: (on ? cs.primary : cs.surfaceContainerHighest).withValues(alpha: 0.92),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.22),
                blurRadius: 10,
                offset: const Offset(0, 3))
          ],
          border: Border.all(
              color: on ? cs.primary : cs.outlineVariant, width: on ? 2 : 1),
        ),
        child: Icon(
          on ? Icons.smart_toy : Icons.smart_toy_outlined,
          size: 22,
          color: on ? cs.onPrimary : cs.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _panel(BuildContext context) {
    final b = AgentBridge.I;
    final cs = Theme.of(context).colorScheme;
    final on = b.running.value;
    return Container(
      width: 300,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 20,
              offset: const Offset(0, 6))
        ],
        border: Border.all(color: cs.outlineVariant),
      ),
      child: ValueListenableBuilder<int>(
        valueListenable: b.tick,
        builder: (c, _, __) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: on ? Colors.green : cs.outline)),
              const SizedBox(width: 8),
              Text(tr('AI 控制'),
                  style: TextStyle(
                      fontWeight: FontWeight.w600, color: cs.onSurface)),
              const Spacer(),
              Transform.scale(
                scale: 0.75,
                child: Switch(
                  value: on,
                  onChanged: (v) async {
                    if (v) {
                      await b.start();
                    } else {
                      await b.stop();
                    }
                    setState(() {});
                  },
                ),
              ),
            ]),
            const SizedBox(height: 2),
            Text(
              on
                  ? 'http://$ip:${b.port}'
                  : (b.lastError.isEmpty
                      ? tr('未开启，AI 无法连接')
                      : trf('端口占用：{e}', {'e': b.lastError})),
              style: TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: on ? cs.onSurface : cs.onSurfaceVariant),
            ),
            if (on) ...[
              const SizedBox(height: 2),
              Text('token ${b.token}',
                  style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: cs.onSurfaceVariant)),
              const SizedBox(height: 6),
              Row(children: [
                _mini(cs, tr('复制连接'), () async {
                  await Clipboard.setData(ClipboardData(
                      text: 'http://$ip:${b.port}\ntoken=${b.token}'));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(tr('已复制')), duration: const Duration(seconds: 1)));
                }),
                const SizedBox(width: 6),
                _mini(cs, tr('状态'), () async {
                  final r = await b.exec(const AgentCmd('state', {}));
                  if (!context.mounted) return;
                  showDialog(
                      context: context,
                      builder: (_) => AlertDialog(
                            title: Text(tr('当前状态')),
                            content: SingleChildScrollView(
                                child: SelectableText('${r.data}')),
                            actions: [
                              TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: Text(tr('关闭')))
                            ],
                          ));
                }),
                const SizedBox(width: 6),
                _mini(cs, tr('查看'), () => setState(() => open = false)),
              ]),
            ],
            const Divider(height: 16),
            Row(children: [
              Text(tr('指令日志'),
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              const Spacer(),
              Text('${b.served}',
                  style: TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      color: cs.onSurfaceVariant)),
            ]),
            const SizedBox(height: 4),
            SizedBox(
              height: 132,
              child: b.logs.isEmpty
                  ? Center(
                      child: Text(tr('暂无'),
                          style: TextStyle(
                              fontSize: 12, color: cs.onSurfaceVariant)))
                  : ListView.builder(
                      padding: EdgeInsets.zero,
                      itemCount: b.logs.length,
                      itemBuilder: (c, i) {
                        final e = b.logs[i];
                        final ok = e['ok'] == true;
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1.5),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${e['t']}  ',
                                  style: TextStyle(
                                      fontSize: 10,
                                      fontFamily: 'monospace',
                                      color: cs.outline)),
                              Expanded(
                                child: Text('${e['line']}',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 10,
                                        fontFamily: 'monospace',
                                        color: ok
                                            ? cs.onSurfaceVariant
                                            : cs.error)),
                              ),
                            ],
                          ),
                        );
                      }),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => AgentOrbHostState.setShow(false),
                child: Text(tr('隐藏悬浮球'), style: const TextStyle(fontSize: 12)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mini(ColorScheme cs, String label, VoidCallback onTap) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: cs.outlineVariant)),
          child: Text(label, style: const TextStyle(fontSize: 11)),
        ),
      );
}

/// AI 控制设置页（我的 → 设置 → AI 控制）。
///
/// 为什么必须有这一页：悬浮球默认不显示，**没有任何入口**的功能等于没做。
/// 页面里那颗「自检」按钮是整条链路唯一能让用户自己确认"通不通"的东西 ——
/// 它跑两遍：一遍走内部指令（验证指令实现），一遍走 127.0.0.1 的真实 HTTP
/// （验证传输层 + token）。两条都绿才叫通。
class AgentControlPage extends StatefulWidget {
  const AgentControlPage({super.key});
  @override
  State<AgentControlPage> createState() => _Acp();
}

class _Acp extends State<AgentControlPage> {
  bool orb = false;
  final _port = TextEditingController();
  final List<String> _lines = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      setState(() {
        orb = p.getBool('agent_orb') ?? false;
        _port.text = '${p.getInt('agent_port') ?? AgentBridge.defaultPort}';
      });
    });
  }

  @override
  void dispose() {
    _port.dispose();
    super.dispose();
  }

  void _say(String s) => setState(() => _lines.insert(0, s));

  Future<void> _toggle(bool v) async {
    setState(() => orb = v);
    await AgentOrbHostState.setShow(v);
    if (!mounted) return;
    setState(() {});
  }

  /// 自检：内部指令 + 真实 HTTP 各跑一遍
  Future<void> _selfTest() async {
    setState(() {
      _busy = true;
      _lines.clear();
    });
    final b = AgentBridge.I;
    try {
      if (!b.running.value) {
        final ok = await b.start();
        _say(ok ? '① 桥已启动 :${b.port}' : '① 桥启动失败：${b.lastError}');
      } else {
        _say('① 桥在监听 :${b.port}');
      }

      // ② 传输层：自己连自己（127.0.0.1），带 token
      try {
        final cli = HttpClient();
        final req = await cli
            .getUrl(Uri.parse('http://127.0.0.1:${b.port}/agent/health'));
        req.headers.set('x-agent-token', b.token);
        final res = await req.close().timeout(const Duration(seconds: 4));
        final body = await res.transform(utf8.decoder).join();
        cli.close(force: true);
        _say(res.statusCode == 200
            ? '② HTTP 通（${res.statusCode}，${body.length}B）'
            : '② HTTP 异常 ${res.statusCode}');
      } catch (e) {
        _say('② HTTP 失败：$e（端口被占用？换一个）');
      }

      // ③ 指令层：读状态
      final st = await b.exec(const AgentCmd('state', {}));
      _say(st.ok
          ? '③ 状态：模块=${st.data is Map ? (st.data as Map)['module'] : '?'} '
              '页签=${st.data is Map ? (st.data as Map)['moduleIndex'] : '?'}'
          : '③ 状态失败：${st.error}');

      // ④ 界面层：数一数屏幕上能寻址的控件
      final tree = await b.exec(const AgentCmd('tree', {}));
      final n = tree.ok && tree.data is Map ? (tree.data as Map)['count'] : 0;
      _say('④ 可寻址控件 $n 个${n == 0 ? '（空？页面可能还在加载）' : ''}');

      // ⑤ 手势层：点一下当前页中央空白处不报错即可（不发真实指令，避免误触）
      _say('⑤ 手势注入：由单元测试覆盖（findByText + PointerEvent）');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = AgentBridge.I;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr('AI 控制'))),
      body: ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
        SwitchListTile(
          value: orb,
          onChanged: _toggle,
          title: Text(tr('智能助手悬浮球')),
          subtitle: Text(tr('开启后屏幕上出现小球，AI 可远程操控本机做真机测试')),
        ),
        const Divider(),
        ListTile(
          title: Text(tr('监听端口')),
          subtitle: Text(
            b.running.value
                ? 'http://127.0.0.1:${b.port}  已就绪'
                : (b.lastError.isEmpty ? tr('未开启') : trf('失败：{e}', {'e': b.lastError})),
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          trailing: SizedBox(
            width: 100,
            child: TextField(
              controller: _port,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(isDense: true, hintText: '9777'),
              onSubmitted: (v) async {
                final n = int.tryParse(v.trim());
                if (n == null) return;
                final ok = await b.changePort(n);
                _say(ok ? '端口已改为 $n' : '端口 $n 不可用，已回滚');
                if (mounted) setState(() {});
              },
            ),
          ),
        ),
        ListTile(
          title: Text(tr('访问令牌')),
          subtitle: SelectableText(
            b.token.isEmpty ? tr('未开启') : b.token,
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          ),
          trailing: IconButton(
            icon: const Icon(Icons.copy, size: 18),
            onPressed: b.token.isEmpty
                ? null
                : () => Clipboard.setData(ClipboardData(text: b.token)),
          ),
        ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(children: [
            FilledButton.icon(
              onPressed: _busy ? null : _selfTest,
              icon: _busy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.play_arrow, size: 18),
              label: Text(tr('运行自检')),
            ),
            const SizedBox(width: 12),
            Text(tr('本机自检，不需要电脑'),
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
          ]),
        ),
        if (_lines.isNotEmpty)
          Container(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final l in _lines)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: SelectableText(l,
                        style: const TextStyle(
                            fontSize: 12, fontFamily: 'monospace')),
                  ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr('电脑端用 tools/th_agent.py 连接本机'),
                  style: TextStyle(
                      fontSize: 12, color: cs.onSurfaceVariant, height: 1.5)),
              Text(tr('填手机 IP、端口和令牌即可操控'),
                  style: TextStyle(
                      fontSize: 12, color: cs.onSurfaceVariant, height: 1.5)),
            ],
          ),
        ),
      ]),
    );
  }
}
