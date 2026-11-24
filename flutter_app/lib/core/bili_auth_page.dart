// B站端上登录页（4.81.94）——扫码登录拿 cookie，解锁 1080p。
//
// 纯端上：passport 扫码 → 轮询 → cookie 存本机。不依赖 NAS 后端。
// 已登录态显示账号与退出；未登录显示二维码 + 状态提示。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'bili_auth.dart';
import 'design_tokens.dart';
import 'i18n.dart';

class BiliAuthPage extends StatefulWidget {
  const BiliAuthPage({super.key});

  @override
  State<BiliAuthPage> createState() => _BiliAuthPageState();
}

class _BiliAuthPageState extends State<BiliAuthPage> {
  final BiliAuth _auth = BiliAuth.I;
  BiliQr? _qr;
  String _hint = '';
  bool _loading = true;
  bool _logged = false;
  Timer? _pollTimer;
  int _pollCount = 0;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    await _auth.load();
    if (!mounted) return;
    setState(() {
      _logged = _auth.loggedIn;
      _loading = false;
      _hint = _logged ? '' : tr('正在生成二维码…');
    });
    if (!_logged) _newQr();
  }

  Future<void> _newQr() async {
    _pollTimer?.cancel();
    setState(() {
      _loading = true;
      _qr = null;
      _pollCount = 0;
      _hint = tr('正在生成二维码…');
    });
    final qr = await _auth.generate();
    if (!mounted) return;
    if (qr == null) {
      setState(() {
        _loading = false;
        _hint = tr('二维码生成失败，点「换一张」重试');
      });
      return;
    }
    setState(() {
      _qr = qr;
      _loading = false;
      _hint = tr('请用 B站 App 扫码登录');
    });
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }

  Future<void> _poll() async {
    final qr = _qr;
    if (qr == null) return;
    _pollCount++;
    if (_pollCount > 90) {
      _pollTimer?.cancel();
      if (mounted) setState(() => _hint = tr('二维码已过期，点「换一张」'));
      return;
    }
    final r = await _auth.poll(qr.key);
    if (!mounted) return;
    switch (r.state) {
      case 'ok':
        _pollTimer?.cancel();
        setState(() {
          _logged = true;
          _hint = '';
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(tr('登录成功，现在可以看高清了'))),
          );
        }
        break;
      case 'expired':
        _pollTimer?.cancel();
        setState(() => _hint = tr('二维码已过期，点「换一张」'));
        break;
      case 'confirmed':
        setState(() => _hint = tr('已在手机上确认，请在 B站 App 里点「确认登录」'));
        break;
      case 'error':
        setState(() => _hint = tr('网络不稳，继续等待…'));
        break;
      default: // waiting
        setState(() => _hint = tr('等待扫码…'));
    }
  }

  Future<void> _logout() async {
    await _auth.logout();
    if (!mounted) return;
    setState(() => _logged = false);
    _newQr();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr('B站登录'))),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(Gap.lg),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: _logged ? _loggedCard(cs) : _qrCard(cs),
          ),
        ),
      ),
    );
  }

  Widget _loggedCard(ColorScheme cs) => Card(
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(children: [
            Icon(Icons.verified_user, size: 48, color: cs.primary),
            const SizedBox(height: 12),
            Text('${_auth.name.isEmpty ? tr('已登录 B站') : _auth.name}',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(tr('登录后可以看 1080P 高清视频'),
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
            const SizedBox(height: 20),
            FilledButton.tonal(
              onPressed: _logout,
              child: Text(tr('退出登录')),
            ),
          ]),
        ),
      );

  Widget _qrCard(ColorScheme cs) => Card(
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(children: [
            Icon(Icons.qr_code_2, size: 40, color: cs.primary),
            const SizedBox(height: 10),
            Text(tr('扫码登录 B站'),
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(tr('登录后可以在线看 1080P 高清，还能点赞收藏'),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            const SizedBox(height: 20),
            if (_loading)
              const SizedBox(
                height: 200,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_qr != null)
              Container(
                padding: const EdgeInsets.all(12),
                color: Colors.white,
                child: QrImageView(data: _qr!.url, size: 190),
              )
            else
              SizedBox(
                height: 200,
                child: Center(child: Text(_hint, textAlign: TextAlign.center)),
              ),
            const SizedBox(height: 14),
            Text(_hint,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: cs.primary)),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: _newQr,
              icon: const Icon(Icons.refresh, size: 16),
              label: Text(tr('换一张')),
            ),
          ]),
        ),
      );
}
