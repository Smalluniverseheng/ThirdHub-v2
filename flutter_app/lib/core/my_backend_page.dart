// 我的后端 —— 会员把数据放在自己设备上的入口。
//
// 定位（2026-11-06 用户澄清）：
//   会员买的不是「官方云端更大空间」，而是**一套能装在自己设备上的后端**：
//   装完他的书架/进度/设置/收藏全存在自己的电脑或 NAS 上，走 IPv6 或局域网直连，
//   官方服务器完全不碰他的数据。他自己的网页端、他的 App 都连他自己那台机器。
//
// 这个页面把「怎么装、怎么连、怎么把已有数据搬过去」串成一条路。
// 安装包与镜像**已经在仓库里**（server/ThirdHubBackend.exe、server/Dockerfile、
// server/docker-compose.yml），所以这里只做分发与配对，不重复造后端。
//
// 为什么单独一页而不是塞进「后端管理」：
//   后者是「已经连上之后怎么管」（源、下载任务、存储），
//   这一页是「还没连上之前怎么装」—— 面向的人、要做的事完全不同。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'design_tokens.dart';
import 'i18n.dart';
import 'cloud.dart';
import 'discover.dart';
import 'dsh_hosts.dart';

/// 下载与文档地址。桶里的后端包由发版流程上传，版本号要跟着 server/package.json 走。
class SelfHostedLinks {
  static const String backendZip =
      'https://onhmosehcwyrqgxadjvb.supabase.co/storage/v1/object/public/downloads/'
      'thirdhub/thirdhub-backend-0.8.7-win-x64.zip';
  static const String repo = 'https://github.com/Smalluniverseheng/ThirdHub-v2';

  /// NAS 上的一条龙命令（假设已把 server/ 目录放进 /volume1/docker/thirdhub）
  static const String dockerCmd =
      'cd /volume1/docker/thirdhub/server && docker compose up -d';
}

class MyBackendPage extends StatefulWidget {
  const MyBackendPage({super.key});
  @override
  State<MyBackendPage> createState() => _MyBackendPageState();
}

class _MyBackendPageState extends State<MyBackendPage> {
  final _addr = TextEditingController();
  final _code = TextEditingController();
  bool _busy = false;
  String? _msg;
  bool _ok = false;

  /// 当前连的是不是自建（读 main.dart 启动时写的同一个判据）
  bool _selfHosted = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final base = p.getString('base') ?? '';
    final tok = p.getString('token') ?? '';
    if (!mounted) return;
    setState(() {
      _addr.text = base.contains('supabase.co') ? '' : base;
      _code.text = tok;
      _selfHosted = base.isNotEmpty && !base.contains('supabase.co');
    });
    // ★ 没配过后端就自动扫局域网，不让用户手填
    if (base.isEmpty || base.contains('supabase.co')) {
      await _autoDiscover();
    }
  }

  /// 自动找后端：先问云端绑定（账号里登记的内网 + IPv6），再扫局域网
  Future<void> _autoDiscover() async {
    if (!mounted) return;
    setState(() { _msg = tr('正在自动寻找局域网内的后端…'); });
    // 1) 云端绑定（登录状态下才有；会写 base/token）
    try {
      if (Cloud.loggedIn) {
        final ok = await Cloud.resolveBackend(force: true);
        if (ok && mounted) {
          final p = await SharedPreferences.getInstance();
          setState(() {
            _addr.text = p.getString('base') ?? '';
            _code.text = p.getString('token') ?? '';
            _selfHosted = true;
            _msg = tr('已找到后端：') + (p.getString('base') ?? '');
          });
          return;
        }
      }
    } catch (_) {}
    // 2) 局域网扫描兜底
    try {
      final devices = await ThpDiscovery.scan(timeoutMs: 400, concurrency: 32);
      if (!mounted) return;
      for (final d in devices) {
        if (d.port == 9527 || d.caps.contains('novel') || d.caps.contains('sources')) {
          final url = 'https://${d.host}:${d.port}';
          setState(() {
            _addr.text = url;
            _msg = tr('已找到后端：') + d.name + ' (' + d.host + ')';
          });
          return;
        }
      }
      setState(() { _msg = tr('没找到后端。可以手动填地址，或检查 NAS 是否开着。'); });
    } catch (e) {
      if (!mounted) return;
      setState(() { _msg = tr('自动搜索失败，可以手动填地址。'); });
    }
  }

  @override
  void dispose() {
    _addr.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _probe() async {
    final base = _addr.text.trim().replaceAll(RegExp(r'/+$'), '');
    if (base.isEmpty) {
      setState(() {
        _msg = '先填地址';
        _ok = false;
      });
      return;
    }
    setState(() {
      _busy = true;
      _msg = null;
    });
    // 后端是 HTTPS 自签证书 → 用 HttpClient 但忽略证书校验（内网自签是常态）
    var reachable = false;
    String detail = '';
    for (final path in ['/api/v1/health', '/v1/ping', '/health']) {
      try {
        final c = HttpClient()
          ..connectionTimeout = const Duration(seconds: 6)
          ..badCertificateCallback = (cert, host, port) => true;
        final req = await c.getUrl(Uri.parse('$base$path'));
        req.headers.set('Accept', 'application/json');
        final tok = _code.text.trim();
        if (tok.isNotEmpty) req.headers.set('X-TH-Token', tok);
        final resp = await req.close().timeout(const Duration(seconds: 8));
        final body = await resp.transform(utf8.decoder).join();
        c.close();
        if (resp.statusCode >= 200 && resp.statusCode < 300) {
          reachable = true;
          detail = body.length > 120 ? '${body.substring(0, 120)}…' : body;
          break;
        } else {
          detail = 'HTTP ${resp.statusCode}';
        }
      } catch (e) {
        detail = '$e';
      }
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _ok = reachable;
      _msg = reachable ? '连接成功' : '连不上：$detail';
    });
  }

  Future<void> _useThisBackend() async {
    final base = _addr.text.trim().replaceAll(RegExp(r'/+$'), '');
    if (base.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    await p.setString('base', base);
    await p.setString('token', _code.text.trim());
    // ★ 把后端地址存进账号 —— 其他设备登录后也能自动连上这个 NAS
    try { await Cloud.saveBackendUrl(base); } catch (_) {}
    if (!mounted) return;
    setState(() {
      _selfHosted = true;
      _msg = '已切换到这个后端。数据现在存在你那台设备上。';
      _ok = true;
    });
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('已切换。重启应用后生效。'))));
  }

  Future<void> _backToOfficial() async {
    final p = await SharedPreferences.getInstance();
    await p.remove('base');
    await p.remove('token');
    if (!mounted) return;
    setState(() {
      _selfHosted = false;
      _msg = tr('已切回官方云端');
    });
  }

  void _copy(String text, String what) {
    Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(trf('{what} 已复制', {'what': what}))));
    }
  }

  @override
  Widget build(BuildContext c) {
    final scheme = Theme.of(c).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr('我的后端'))),
      body: ListView(padding: const EdgeInsets.all(Gap.md), children: [
        // ── 说明 ──
        Container(
          padding: const EdgeInsets.all(Gap.md),
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.shield_outlined, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Text(tr('数据存在你自己的设备上'),
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: Gap.sm),
            const Text(
              '装一个后端到你自己的电脑或 NAS，书架、阅读进度、收藏、历史、设置'
              '就都存在那台机器上，官方服务器不碰你的数据。\n'
              '你的 App 和网页端都连它，也可以继续用官方云端 —— 随时能切。',
              style: TextStyle(fontSize: 12, height: 1.6, color: Colors.grey),
            ),
          ]),
        ),
        const SizedBox(height: Gap.md),

        // ── 第一步：装 ──
        _step('1', '装后端'),
        _card(c, [
          _row(
            Icons.desktop_windows_outlined,
            'Windows 电脑',
            '下载压缩包 → 解压 → 双击 ThirdHubBackend.exe',
            trailing: TextButton(
              onPressed: () => _copy(SelfHostedLinks.backendZip, '下载地址'),
              child: Text(tr('复制链接')),
            ),
          ),
          const Divider(height: 1, indent: 52),
          _row(
            Icons.dns_outlined,
            'NAS / 群晖 / 威联通',
            '把 server 目录放进去，跑一条命令',
            trailing: TextButton(
              onPressed: () =>
                  _copy(SelfHostedLinks.dockerCmd, '命令'),
              child: Text(tr('复制命令')),
            ),
          ),
          const Divider(height: 1, indent: 52),
          _row(
            Icons.memory,
            '要在 NAS 上看着跑',
            'docker compose up -d，访问 https://NAS地址:9527',
          ),
        ]),

        // ── 第二步：连 ──
        _step('2', '连上它'),
        _card(c, [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Column(children: [
              TextField(
                controller: _addr,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  labelText: tr('地址'),
                  hintText: tr('https://192.168.1.10:9527 或 http://[2408:...]:9527'),
                  hintStyle: TextStyle(fontSize: 11),
                ),
              ),
              const SizedBox(height: Gap.sm),
              TextField(
                controller: _code,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  labelText: tr('配对码'),
                  hintText: tr('后端首次启动时打印的密钥'),
                  hintStyle: TextStyle(fontSize: 11),
                ),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
            child: Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : _probe,
                  child: Text(_busy ? '检测中…' : '测试连接'),
                ),
              ),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: FilledButton(
                  onPressed: _busy ? null : _useThisBackend,
                  child: Text(tr('用它')),
                ),
              ),
            ]),
          ),
        ]),

        if (_msg != null)
          Padding(
            padding: const EdgeInsets.only(top: Gap.sm),
            child: Text(_msg!,
                style: TextStyle(
                    fontSize: 12,
                    color: _ok ? Colors.green : Colors.redAccent)),
          ),

        // ── 任务在哪跑（本机 / 远端）──
        //
        // 用户需求：产品要能本机跑，也要能在 NAS/电脑上跑；把后台删掉，
        // 任务在远端继续，再打开时结果同步回来；还可以选「优先本机 / 优先远端」。
        //
        // 这里只做「选谁」这一层 —— 会话续接本身靠 Host 侧的 session + events(since)，
        // 那个能力在 agent_dsh_client 里已经有了，不需要在这里重造。
        _step('3', tr('任务在哪跑')),
        _card(c, [
          ListTile(
            leading: const Icon(Icons.tune, size: 20),
            title: Text(tr('优先方式'), style: const TextStyle(fontSize: 14)),
            subtitle: Text(_preferText(), style: const TextStyle(fontSize: 11)),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: _pickPrefer,
          ),
          const Divider(height: 1, indent: 52),
          ListTile(
            leading: const Icon(Icons.hub_outlined, size: 20),
            title: Text(tr('已登记的资料库'), style: const TextStyle(fontSize: 14)),
            subtitle: Text(_hostText(), style: const TextStyle(fontSize: 11)),
            trailing: IconButton(
              tooltip: tr('逐个探活'),
              icon: const Icon(Icons.refresh, size: 18),
              onPressed: _refreshHosts,
            ),
          ),
        ]),

        // ── 第四步：状态 ──
        _step('4', '现在用哪个'),
        _card(c, [
          _row(
            _selfHosted ? Icons.check_circle : Icons.cloud_outlined,
            _selfHosted ? '正在用自己的后端' : '正在用官方云端',
            _selfHosted
                ? '数据存在你那台设备上，全部数据都会同步'
                : '数据存在官方云端；免费档只同步设置',
          ),
          if (_selfHosted) ...[
            const Divider(height: 1, indent: 52),
            ListTile(
              leading: const Icon(Icons.undo, size: 20),
              title: Text(tr('切回官方云端'), style: const TextStyle(fontSize: 14)),
              subtitle: Text(tr('你的数据不会丢，只是改从官方读取'),
                  style: TextStyle(fontSize: 11)),
              onTap: _backToOfficial,
            ),
          ],
        ]),

        const SizedBox(height: Gap.md),
        const Text(
          '说明：\n'
          '· 后端默认监听 9527，HTTPS 自签证书，浏览器首次访问要点「继续」\n'
          '· 电脑/NAS 在家时用局域网地址最快；在外面用 IPv6 地址或 P2P\n'
          '· 配对码在后端启动日志里，也可以用后端的 /api/v1/devices 重新生成',
          style: TextStyle(fontSize: 11, color: Colors.grey, height: 1.7),
        ),
      ]),
    );
  }

  String _preferText() => switch (DshHosts.prefer) {
        DshPrefer.localFirst => '优先本机，连不上再用远端',
        DshPrefer.remoteFirst => '优先远端（电脑/NAS），连不上再用本机',
        DshPrefer.localOnly => '只用本机',
        DshPrefer.remoteOnly => '只用远端，不在手机上跑',
      };

  String _hostText() {
    final hs = DshHosts.hosts;
    if (hs.isEmpty) return '还没登记。远端资料库可在「DSH 遥控」里配对，本机资料库待后续版本支持';
    final a = DshHosts.active;
    return '共 ${hs.length} 个 · 当前: ${a?.name ?? '都连不上'}';
  }

  Future<void> _pickPrefer() async {
    final v = await showModalBottomSheet<DshPrefer>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.all(16),
            // ★2026-11-07：这里此前写死中文，被 i18n_hardcoded 棘轮闸门记了一笔。
            //   实际只有 style 是 const、Text 本身不是，tr() 完全可用 ——
            //   4.81.41 那次 const 报错发生在别的常量上下文，不能靠"一律写死中文"躲。
            child: Text(tr('任务在哪跑'),
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600)),
          ),
          for (final e in DshPrefer.values)
            ListTile(
              leading: Icon(
                  e == DshHosts.prefer
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  size: 20),
              title: Text(
                  switch (e) {
                    DshPrefer.localFirst => '优先本机',
                    DshPrefer.remoteFirst => '优先远端（电脑/NAS）',
                    DshPrefer.localOnly => '只用本机',
                    DshPrefer.remoteOnly => '只用远端',
                  },
                  style: const TextStyle(fontSize: 14)),
              onTap: () => Navigator.pop(c, e),
            ),
        ]),
      ),
    );
    if (v == null) return;
    await DshHosts.setPrefer(v);
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _refreshHosts() async {
    setState(() => _busy = true);
    final hit = await DshHosts.pick();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _msg = hit == null ? '所有资料库都连不上' : '已连上: ${hit.name}';
      _ok = hit != null;
    });
  }

  Widget _step(String n, String title) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
        child: Row(children: [
          Container(
            width: 18,
            height: 18,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Text(n,
                style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 8),
          Text(title,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ]),
      );

  Widget _card(BuildContext c, List<Widget> children) => Card(
        margin: EdgeInsets.zero,
        child: Column(children: children),
      );

  Widget _row(IconData icon, String title, String sub, {Widget? trailing}) =>
      ListTile(
        leading: Icon(icon, size: 20),
        title: Text(title, style: const TextStyle(fontSize: 14)),
        subtitle: Text(sub, style: const TextStyle(fontSize: 11)),
        trailing: trailing,
      );
}
