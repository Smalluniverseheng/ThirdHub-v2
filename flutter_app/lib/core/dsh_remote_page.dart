// ═══════════════════════════════════════════════════════════════════════════
// 「DSH 遥控」—— 手机操作电脑上 DSH 的入口（我的 → DSH 遥控）
//
// 这一页只做三件事，顺序就是用户手上的动作顺序：
//   ① 把「电脑地址 + 配对令牌」填进来（或一次粘贴整条连接串）；
//   ② 点「测试连接」，当场告出到底是地址错了还是令牌错了；
//   ③ 点「打开控制台」，用内嵌 WebView 打开电脑上的手机控制台。
//
// 规则全在 `dsh_remote.dart`（纯 Dart、可自检），本文件只负责显示与输入。
// ═══════════════════════════════════════════════════════════════════════════
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../main.dart' show Api;
import 'dsh_remote.dart';
import 'i18n.dart';

// ═══ 配置页（我的 → DSH 遥控） ═══
class DshRemotePage extends StatefulWidget {
  const DshRemotePage({super.key});
  @override
  State<DshRemotePage> createState() => _DshRemotePageState();
}

class _DshRemotePageState extends State<DshRemotePage> {
  final _addr = TextEditingController();
  final _tok = TextEditingController();
  bool _busy = false;
  bool _showTok = false;
  String _msg = '';
  bool _msgOk = false;
  String _detail = '';

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _addr.dispose();
    _tok.dispose();
    super.dispose();
  }

  /// 起步：先读本机存过的值；没存过就按「家庭后端」的地址猜一个 ——
  /// 后端就跑在那台电脑上（同一个 IP，只是端口换成网关的 8787），
  /// 这样多数人**连地址都不用填**，只剩令牌要抄。
  Future<void> _boot() async {
    await DshRemote.load();
    var a = DshRemote.base;
    if (a.isEmpty) {
      final b = Uri.tryParse(Api.base.trim());
      if (b != null && b.host.isNotEmpty) {
        a = DshRemote.normalizeBase('${b.scheme}://${b.host}');
      }
    }
    if (!mounted) return;
    setState(() {
      _addr.text = a;
      _tok.text = DshRemote.token;
    });
  }

  Future<void> _paste() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    final raw = (d?.text ?? '').trim();
    if (raw.isEmpty) {
      _show(tr('剪贴板里没有能用的地址'), false);
      return;
    }
    final p = DshRemote.parsePasted(raw);
    setState(() {
      if (p.base.isNotEmpty) _addr.text = p.base;
      if (p.token.isNotEmpty) _tok.text = p.token;
    });
    await DshRemote.save(at: _addr.text, tok: _tok.text);
    _show(tr('已填入'), true);
  }

  void _show(String m, bool ok, {String detail = ''}) {
    if (!mounted) return;
    setState(() {
      _msg = m;
      _msgOk = ok;
      _detail = detail;
    });
  }

  Future<void> _test() async {
    final a = DshRemote.normalizeBase(_addr.text);
    setState(() {
      _busy = true;
      _msg = '';
      _detail = '';
    });
    final r = await DshRemote.probe(at: a, tok: _tok.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _addr.text = a.isEmpty ? _addr.text : a;
    });
    if (r.ok) {
      await DshRemote.save(at: a, tok: _tok.text);
      final bits = <String>[];
      if (r.version.isNotEmpty) bits.add('v${r.version}');
      if (r.status.isNotEmpty) bits.add(r.status);
      _show(tr('已连接'), true, detail: bits.join(' · '));
    } else {
      _show(tr(DshErr.text(r.error)), false);
    }
  }

  Future<void> _open({required bool admin}) async {
    final a = DshRemote.normalizeBase(_addr.text);
    if (a.isEmpty) {
      _show(tr('请先填电脑地址'), false);
      return;
    }
    if (_tok.text.trim().isEmpty) {
      _show(tr('请填配对令牌'), false);
      return;
    }
    await DshRemote.save(at: a, tok: _tok.text);
    final url = admin
        ? DshRemote.adminUrl(at: a, tok: _tok.text)
        : DshRemote.consoleUrl(at: a, tok: _tok.text);
    if (!mounted) return;
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => DshConsolePage(
                url: url,
                title: admin ? tr('管理控制台') : tr('DSH 遥控'),
                admin: admin)));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr('DSH 遥控'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          _steps(cs),
          const SizedBox(height: 16),
          _fieldCard(cs),
          const SizedBox(height: 16),
          SizedBox(
            height: 44,
            child: FilledButton.icon(
              onPressed: _busy ? null : _test,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.wifi_tethering, size: 18),
              label: Text(tr('测试连接')),
            ),
          ),
          if (_msg.isNotEmpty) ...[
            const SizedBox(height: 8),
            _resultCard(cs),
          ],
          const SizedBox(height: 16),
          SizedBox(
            height: 48,
            child: FilledButton.icon(
              onPressed: () => _open(admin: false),
              icon: const Icon(Icons.open_in_new, size: 18),
              label: Text(tr('打开控制台')),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 44,
            child: OutlinedButton.icon(
              onPressed: () => _open(admin: true),
              icon: const Icon(Icons.tune, size: 18),
              label: Text(tr('管理控制台')),
            ),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Icon(Icons.lock_outline, size: 14, color: cs.outline),
            const SizedBox(width: 4),
            Expanded(
                child: Text(tr('令牌只存在这台手机，不上云'),
                    style: TextStyle(fontSize: 11, color: cs.outline))),
          ]),
        ],
      ),
    );
  }

  Widget _steps(ColorScheme cs) => Container(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('怎么用'),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          _step(1, tr('电脑上打开 DSH，进「更多 → 手机连接」')),
          _step(2, tr('把页面上那条连接串复制下来，点下面的「从剪贴板填入」')),
          _step(3, tr('点「测试连接」，显示已连接就成了')),
          _step(4, tr('点「打开控制台」，之后就能用手机操作电脑')),
        ]),
      );

  Widget _step(int n, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
              width: 18,
              child: Text('$n.',
                  style: const TextStyle(fontSize: 12, color: Colors.grey))),
          Expanded(
              child: Text(text,
                  style: const TextStyle(fontSize: 12, height: 1.5))),
        ]),
      );

  Widget _fieldCard(ColorScheme cs) => Container(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.6)),
        ),
        child: Column(children: [
          TextField(
            controller: _addr,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: tr('电脑地址'),
              hintText: 'http://192.168.1.5:8787',
              helperText: tr('例：192.168.1.5 或 http://192.168.1.5:8787'),
              helperStyle: const TextStyle(fontSize: 11),
            ),
          ),
          TextField(
            controller: _tok,
            obscureText: !_showTok,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: tr('配对令牌'),
              suffixIcon: IconButton(
                icon: Icon(
                    _showTok ? Icons.visibility_off : Icons.visibility_outlined,
                    size: 18),
                onPressed: () => setState(() => _showTok = !_showTok),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _paste,
              icon: const Icon(Icons.content_paste, size: 16),
              label: Text(tr('从剪贴板填入'),
                  style: const TextStyle(fontSize: 12)),
            ),
          ),
        ]),
      );

  Widget _resultCard(ColorScheme cs) {
    final c = _msgOk ? Colors.green : cs.error;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.withValues(alpha: 0.35)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(_msgOk ? Icons.check_circle_outline : Icons.error_outline,
            size: 16, color: c),
        const SizedBox(width: 6),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_msg, style: TextStyle(fontSize: 12.5, color: c)),
            if (_detail.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(_detail,
                    style: TextStyle(fontSize: 11, color: cs.outline)),
              ),
          ]),
        ),
      ]),
    );
  }
}

// ═══ 内嵌控制台 ═══
class DshConsolePage extends StatefulWidget {
  const DshConsolePage(
      {super.key, required this.url, required this.title, this.admin = false});

  final String url;
  final String title;
  final bool admin;

  @override
  State<DshConsolePage> createState() => _DshConsolePageState();
}

class _DshConsolePageState extends State<DshConsolePage> {
  WebViewController? _c;
  int _progress = 0;
  String _err = '';

  @override
  void initState() {
    super.initState();
    final c = WebViewController();
    c.setJavaScriptMode(JavaScriptMode.unrestricted);
    // 控制台要上传文件 / 下文件，DOM storage 必须开（登录态与设备记忆都存在里面）
    c.setBackgroundColor(const Color(0xFF0F1115));
    c.setNavigationDelegate(NavigationDelegate(
      onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      },
      onWebResourceError: (e) {
        // 只关心主文档的失败；子资源（图标 / 接口）404 不该盖住页面
        if (e.isForMainFrame == false) return;
        if (mounted) setState(() => _err = '${e.description}');
      },
      onPageFinished: (_) {
        if (mounted) setState(() => _err = '');
      },
    ));
    c.loadRequest(Uri.parse(widget.url));
    _c = c;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: tr('重新加载'),
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: () {
              setState(() => _err = '');
              _c?.reload();
            },
          ),
          IconButton(
            tooltip: tr('用浏览器打开'),
            icon: const Icon(Icons.public, size: 20),
            onPressed: () =>
                launchUrl(Uri.parse(widget.url), mode: LaunchMode.externalApplication),
          ),
        ],
        bottom: _progress > 0 && _progress < 100
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(
                    value: _progress / 100, minHeight: 2))
            : null,
      ),
      body: _err.isEmpty
          ? (_c == null
              ? Center(child: Text(tr('正在打开…')))
              : WebViewWidget(controller: _c!))
          : Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.cloud_off, size: 40, color: cs.outline),
                    const SizedBox(height: 12),
                    Text(tr('页面打不开'),
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    Text(_err,
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12, color: cs.outline)),
                    const SizedBox(height: 8),
                    Text(tr('确认手机和电脑在同一个 Wi-Fi，且电脑端 DSH 没关'),
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12, color: cs.outline)),
                    const SizedBox(height: 16),
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      OutlinedButton(
                          onPressed: () {
                            setState(() => _err = '');
                            _c?.reload();
                          },
                          child: Text(tr('重新加载'))),
                      const SizedBox(width: 8),
                      FilledButton(
                          onPressed: () => launchUrl(Uri.parse(widget.url),
                              mode: LaunchMode.externalApplication),
                          child: Text(tr('用浏览器打开'))),
                    ]),
                  ],
                ),
              ),
            ),
    );
  }
}
