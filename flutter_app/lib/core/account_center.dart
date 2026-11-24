// 账号与在线状态中心（4.81.96）
//
// 用户原话：「各种账号在线都要能够自动识别」——所以这一页的定位不是「设置入口列表」，
// 而是**一张体检表**：进来就并行探活，每个账号自己报告 在线 / 离线 / 未登录 / 已过期。
//
// 覆盖：
//   q 云端账号（ThirdHub 账号，Supabase Auth）
//   q 家庭后端（NAS，局域网/IPv6 直连）
//   ×B站（端上扫码登录，决定能不能 1080P）
//   ×短剧解锁（管理员或激活码）
//   ×完全体助手（DSH，NAS 上的 dsh-remote）
//   ×AI 供应商（各厂商 API Key）
//
// 设计取舍：
//   · 探活全部**带超时**（各自 4–8 秒），任一挂住不拖累其它行 —— 用 Future 并行 + 各自 try；
//   · 状态与操作在一行里说清（右上一个状态胶囊，点这一行就是它该做的事）；
//   · 不做「全部重连」这种大按钮，避免用户不知道点了会发生什么。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_keys_page.dart';
import 'api_keys_store.dart';
import 'bili_auth.dart';
import 'bili_auth_page.dart';
import 'cloud.dart';
import 'cloud_auth_dialog.dart';
import 'drama_gate.dart';
import 'dsh_remote.dart';
import 'dsh_remote_page.dart';
import 'i18n.dart';
import 'th_http.dart';

/// 单个账号条目的状态
enum AccState { checking, online, offline, signedOut, expired, locked }

extension AccStateX on AccState {
  String get label => switch (this) {
        AccState.checking => tr('检测中…'),
        AccState.online => tr('在线'),
        AccState.offline => tr('离线'),
        AccState.signedOut => tr('未登录'),
        AccState.expired => tr('已过期'),
        AccState.locked => tr('未解锁'),
      };

  Color get color => switch (this) {
        AccState.checking => Colors.grey,
        AccState.online => const Color(0xFF2E9E5B),
        AccState.offline => Colors.orange,
        AccState.signedOut => Colors.grey,
        AccState.expired => Colors.orange,
        AccState.locked => Colors.grey,
      };
}

class AccountCenterPage extends StatefulWidget {
  const AccountCenterPage({super.key});
  @override
  State<AccountCenterPage> createState() => _AccountCenterPageState();
}

class _AccountCenterPageState extends State<AccountCenterPage> {
  AccState _cloud = AccState.checking;
  String _cloudWho = '';
  AccState _backend = AccState.checking;
  String _backendWho = '';
  AccState _bili = AccState.checking;
  String _biliWho = '';
  AccState _drama = AccState.checking;
  AccState _dsh = AccState.checking;
  String _dshWho = '';
  AccState _ai = AccState.checking;
  String _aiWho = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _cloud = _backend = _bili = _drama = _dsh = _ai = AccState.checking;
    });
    // 六条并行探活，各自兜底 —— 不并行的话弱网下这一页要转十几秒。
    await Future.wait([
      _probeCloud(),
      _probeBackend(),
      _probeBili(),
      _probeDrama(),
      _probeDsh(),
      _probeAi(),
    ]);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _probeCloud() async {
    var st = AccState.signedOut;
    var who = '';
    try {
      final s = await Cloud.sessionState();
      st = switch (s) {
        'ok' => AccState.online,
        'expired' => AccState.expired,
        'offline' => AccState.offline,
        _ => AccState.signedOut,
      };
      // 令牌被服务端判死：顺手清掉僵尸态，否则整页都是「登录了但同步不了」
      if (s == 'expired') await Cloud.clearStale();
      who = Cloud.email;
    } catch (_) {
      st = AccState.offline;
    }
    if (!mounted) return;
    setState(() {
      _cloud = st;
      _cloudWho = who;
    });
  }

  Future<void> _probeBackend() async {
    var st = AccState.signedOut;
    var who = '';
    try {
      final p = await SharedPreferences.getInstance();
      final base = (p.getString('base') ?? '').trim();
      final tok = (p.getString('token') ?? '').trim();
      if (base.isEmpty) {
        st = AccState.signedOut;
      } else {
        who = base;
        final c = HttpClient()..connectionTimeout = const Duration(seconds: 4);
        c.badCertificateCallback = ThirdHubHttpOverrides.trustCert;
        final cli = IOClient(c);
        try {
          final r = await cli.get(Uri.parse('$base/v1/meta'), headers: {
            if (tok.isNotEmpty) 'X-TH-Token': tok,
          }).timeout(const Duration(seconds: 5));
          st = r.statusCode == 200 ? AccState.online : AccState.offline;
        } finally {
          cli.close();
        }
      }
    } catch (_) {
      st = AccState.offline;
    }
    if (!mounted) return;
    setState(() {
      _backend = st;
      _backendWho = who;
    });
  }

  Future<void> _probeBili() async {
    var st = AccState.signedOut;
    var who = '';
    try {
      await BiliAuth.I.load();
      if (BiliAuth.I.loggedIn) {
        st = AccState.online;
        who = BiliAuth.I.name;
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _bili = st;
      _biliWho = who;
    });
  }

  Future<void> _probeDrama() async {
    var st = AccState.locked;
    try {
      await DramaGate.I.load();
      if (DramaGate.I.unlocked) st = AccState.online;
    } catch (_) {}
    if (!mounted) return;
    setState(() => _drama = st);
  }

  Future<void> _probeDsh() async {
    var st = AccState.signedOut;
    var who = '';
    try {
      await DshRemote.load();
      if (DshRemote.base.trim().isNotEmpty) {
        who = DshRemote.base;
        final p = await DshRemote.probe(timeoutMs: 5000);
        st = p.tokenOk ? AccState.online : AccState.offline;
        if (p.tokenOk && p.version.isNotEmpty) who = '${DshRemote.base} · ${p.version}';
      }
    } catch (_) {
      st = AccState.offline;
    }
    if (!mounted) return;
    setState(() {
      _dsh = st;
      _dshWho = who;
    });
  }

  Future<void> _probeAi() async {
    var st = AccState.signedOut;
    var who = '';
    try {
      final d = await ApiKeys.dump();
      if (d.isNotEmpty) {
        st = AccState.online;
        who = trf('已配置 {n} 个', {'n': d.length});
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _ai = st;
      _aiWho = who;
    });
  }

  // ── 行操作 ──────────────────────────────────────────────

  Future<void> _tapCloud() async {
    if (!Cloud.loggedIn) {
      final ok = await showCloudAuthDialog(context, isLogin: true);
      if (ok && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(tr('已登录'))));
      }
      await _refresh();
      return;
    }
    await _sheet('云端账号', [
      _Act(Icons.swap_horiz, '切换账号', () async {
        final ok = await showCloudAuthDialog(context, isLogin: true);
        if (ok) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(tr('已登录'))));
        }
      }),
      _Act(Icons.logout, '退出登录', () async {
        await Cloud.signOut();
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(tr('已退出登录'))));
        }
      }),
    ]);
    await _refresh();
  }

  Future<void> _tapBackend() async {
    await _sheet('家庭后端', [
      _Act(Icons.sync, '重新连接', () async {
        try {
          final ok = await Cloud.resolveBackend();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(ok ? tr('连接正常') : tr('连接失败'))));
          }
        } catch (_) {}
      }),
      _Act(Icons.link_off, '断开', () async {
        final p = await SharedPreferences.getInstance();
        await p.remove('base');
        await p.remove('token');
      }),
    ]);
    await _refresh();
  }

  Future<void> _tapBili() async {
    if (!BiliAuth.I.loggedIn) {
      await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const BiliAuthPage()));
    } else {
      await _sheet('B站账号', [
        _Act(Icons.logout, '退出登录', () async {
          await BiliAuth.I.logout();
        }),
      ]);
    }
    await _refresh();
  }

  Future<void> _tapDrama() async {
    if (DramaGate.I.unlocked) {
      await _sheet('短剧解锁', [
        _Act(Icons.lock_outline, '取消解锁', () async {
          await DramaGate.I.deactivate();
        }),
      ]);
    } else {
      final ctl = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(tr('输入激活码'),
              style: const TextStyle(fontSize: 16)),
          content: TextField(
            controller: ctl,
            autofocus: true,
            decoration: InputDecoration(
                labelText: tr('激活码'), isDense: true),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(d, false),
                child: Text(tr('取消'))),
            FilledButton(
                onPressed: () => Navigator.pop(d, true),
                child: Text(tr('解锁'))),
          ],
        ),
      );
      if (ok == true) {
        final good = await DramaGate.I.tryActivate(ctl.text);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(good ? tr('已解锁') : tr('激活码不对'))));
        }
      }
      ctl.dispose();
    }
    await _refresh();
  }

  Future<void> _tapDsh() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const DshRemotePage()));
    await _refresh();
  }

  Future<void> _tapAi() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const ApiKeysPage()));
    await _refresh();
  }

  Future<void> _sheet(String title, List<_Act> acts) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(title,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)))),
          for (final a in acts)
            ListTile(
              dense: true,
              leading: Icon(a.icon, size: 20),
              title: Text(tr(a.label), style: const TextStyle(fontSize: 14)),
              onTap: () async {
                Navigator.pop(c);
                await a.run();
              },
            ),
          const SizedBox(height: 6),
        ]),
      ),
    );
  }

  Widget _row({
    required IconData icon,
    required String title,
    required String sub,
    required AccState state,
    required VoidCallback onTap,
  }) {
    return ListTile(
      onTap: onTap,
      leading: Icon(icon, size: 20),
      title: Text(title, style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        sub.isEmpty ? state.label : '$sub · ${state.label}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: state.color),
      ),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: state.color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(state.label,
            style: TextStyle(fontSize: 10.5, color: state.color)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('账号与在线状态')),
        actions: [
          IconButton(
            tooltip: tr('全部检测'),
            icon: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
            onPressed: _busy ? null : _refresh,
          )
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(tr('自动识别各账号登录态与连通性'),
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ),
            _row(
              icon: Icons.cloud_outlined,
              title: tr('云端账号'),
              sub: _cloudWho,
              state: _cloud,
              onTap: _tapCloud,
            ),
            _row(
              icon: Icons.dns_outlined,
              title: tr('家庭后端'),
              sub: _backendWho,
              state: _backend,
              onTap: _tapBackend,
            ),
            const Divider(height: 18),
            _row(
              icon: Icons.play_circle_outline,
              title: tr('B站账号'),
              sub: _biliWho,
              state: _bili,
              onTap: _tapBili,
            ),
            _row(
              icon: Icons.movie_filter_outlined,
              title: tr('短剧解锁'),
              sub: '',
              state: _drama,
              onTap: _tapDrama,
            ),
            _row(
              icon: Icons.smart_toy_outlined,
              title: tr('完全体助手'),
              sub: _dshWho,
              state: _dsh,
              onTap: _tapDsh,
            ),
            const Divider(height: 18),
            _row(
              icon: Icons.key_outlined,
              title: tr('AI 供应商'),
              sub: _aiWho,
              state: _ai,
              onTap: _tapAi,
            ),
          ],
        ),
      ),
    );
  }
}

class _Act {
  const _Act(this.icon, this.label, this.run);
  final IconData icon;
  final String label;
  final Future<void> Function() run;
}
