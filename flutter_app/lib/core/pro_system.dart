// ThirdHub v4.40.0 · S 组 系统 + E 组 商业生态(PLAN-v3 §3.5 / §6)
//   S-1 模块市场 · S-2 多后端/多节点 · S-3 数据迁移 · S-4 深色
//   S-5 长辈/儿童模式 · S-6 模块锁 · S-7 授权管理
//   E-1 verify 端点 · E-2 设备密钥出示身份 · E-3 授权管理 · E-4 远程引擎
//   E-5 PAYMENT_REQUIRED 交互 · E-6 开发者指南(Engine SDK / THP 契约)
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'pro_kit.dart';

/// main.dart 注册的桥: 系统页需要动"宿主"的东西(导航/主题/字体/打开模块)都走这里,
/// 这样 core 层不用直接依赖 main.dart 的实现细节。
class ProBridge {
  static List<String> Function()? moduleKeys;
  static List<String> Function()? navModules;
  static Future<void> Function(List<String>)? setNavModules;
  static String Function()? themeMode;
  static Future<void> Function(String)? setThemeMode;
  static double Function()? textScale;
  static Future<void> Function(double)? setTextScale;
  static void Function(String moduleKey)? openModule;
  static Future<void> Function(String title, String body)? openReader;
}

// ══════════════════════════════════════════════════════════════
// S-2 多后端 / 多节点
// ══════════════════════════════════════════════════════════════
class Backends {
  static const mk = 'backend_list_v1';

  static Future<List<Map<String, String>>> all() => ProKit.listOf(mk);

  static Future<void> add(String base, String token, String name) async {
    if (base.trim().isEmpty) return;
    await ProKit.push(mk, {
      'id': DateTime.now().microsecondsSinceEpoch.toString(),
      'base': base.trim().replaceAll(RegExp(r'/+$'), ''),
      'token': token.trim(),
      'name': name.trim().isEmpty ? base.trim() : name.trim(),
      'at': ProKit.now(),
    }, max: 30);
  }

  static Future<void> remove(String id) async {
    final l = await all();
    l.removeWhere((e) => e['id'] == id);
    await ProKit.saveList(mk, l);
  }

  /// 切换当前后端(写 main.dart 读的 'base'/'token' 两个键)
  static Future<void> switchTo(Map<String, String> e) async {
    final p = await ProKit.prefs();
    await p.setString('base', e['base'] ?? '');
    await p.setString('token', e['token'] ?? '');
  }

  static Future<Map<String, String>> current() async {
    final p = await ProKit.prefs();
    return {'base': p.getString('base') ?? '', 'token': p.getString('token') ?? ''};
  }

  /// 逐节点探活(取 /v1/ping 或 /health)
  static Future<String> probe(String base, String token) async {
    final p = await ProKit.prefs();
    final oldBase = p.getString('base'), oldTok = p.getString('token');
    await p.setString('base', base);
    await p.setString('token', token);
    var out = '不可达';
    for (final path in ['/v1/ping', '/health', '/v1/status']) {
      final r = await ProKit.getJson(path);
      if (r['ok'] == true) {
        out = '在线';
        break;
      }
    }
    if (oldBase != null) await p.setString('base', oldBase);
    if (oldTok != null) await p.setString('token', oldTok);
    return out;
  }
}

// ══════════════════════════════════════════════════════════════
// S-3 数据迁移: 全量设置导出/导入(默认不含凭据)
// ══════════════════════════════════════════════════════════════
class Migration {
  static const secretKeys = {'token', 'base'};

  static Future<String> export({bool withCred = false}) async {
    final p = await ProKit.prefs();
    final out = <String, dynamic>{};
    for (final k in p.getKeys()) {
      if (!withCred && secretKeys.contains(k)) continue;
      final v = p.get(k);
      if (v == null) continue;
      out[k] = v;
    }
    final payload = jsonEncode({
      'app': 'ThirdHub',
      'version': '4.41.0',
      'at': ProKit.now(),
      'withCred': withCred,
      'keys': out.length,
      'data': out,
    });
    final dir = await getApplicationDocumentsDirectory();
    final f = File(
        '${dir.path}/thirdhub_backup_${DateTime.now().millisecondsSinceEpoch}.json');
    await f.writeAsString(payload, flush: true);
    return f.path;
  }

  static Future<String> importFrom(File f, {bool overwrite = true}) async {
    try {
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final data = (j['data'] as Map?) ?? {};
      final p = await ProKit.prefs();
      var n = 0;
      for (final e in data.entries) {
        final v = e.value;
        if (!overwrite && p.containsKey(e.key)) continue;
        if (v is String) {
          await p.setString(e.key, v);
        } else if (v is int) {
          await p.setInt(e.key, v);
        } else if (v is double) {
          await p.setDouble(e.key, v);
        } else if (v is bool) {
          await p.setBool(e.key, v);
        } else if (v is List) {
          await p.setStringList(
              e.key, [for (final x in v) '$x']);
        }
        n++;
      }
      return '已恢复 $n 项设置';
    } catch (e) {
      return '导入失败: $e';
    }
  }

  static Future<List<File>> backups() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final l = <File>[];
      await for (final e in dir.list()) {
        if (e is File && e.path.contains('thirdhub_backup_')) l.add(e);
      }
      l.sort((a, b) => b.path.compareTo(a.path));
      return l;
    } catch (_) {
      return [];
    }
  }
}

// ══════════════════════════════════════════════════════════════
// S-5 长辈 / 儿童模式  +  S-6 模块锁
// ══════════════════════════════════════════════════════════════
class Modes {
  static const mkMode = 'ui_mode_v1'; // normal | elder | kid

  static Future<String> mode() async =>
      (await ProKit.prefs()).getString(mkMode) ?? 'normal';

  /// 三档模式的默认参数: 字体缩放 / 保留模块 / 是否强制内容过滤
  static const presets = {
    'normal': (1.0, <String>[], false),
    'elder': (1.28, <String>['搜索', '小说', '视频', 'AI', '相册', '我的'], true),
    'kid': (1.15, <String>['搜索', '学习中心', '记忆卡', '有声书', '壁纸', '我的'], true),
  };

  static Future<void> apply(String m) async {
    final p = await ProKit.prefs();
    await p.setString(mkMode, m);
    final (scale, keep, filter) = presets[m] ?? presets['normal']!;
    await p.setDouble('ui_text_scale', scale);
    await p.setBool('content_filter', filter);
    if (keep.isNotEmpty) {
      final cur = ProBridge.navModules?.call() ?? [];
      final merged = <String>[...keep];
      for (final k in cur) {
        if (merged.length >= 6) break;
        if (!merged.contains(k)) merged.add(k);
      }
      await ProBridge.setNavModules?.call(keep);
    } else {
      final all = ProBridge.moduleKeys?.call() ?? [];
      final core = all.where((k) =>
          ['搜索', '小说', '漫画', '视频', '音乐', 'AI', '浏览器', '文件', '相册', '我的'].contains(k));
      await ProBridge.setNavModules?.call(core.toList());
    }
    await ProBridge.setTextScale?.call(scale);
  }
}

class ModuleLocks {
  static const mk = 'module_pins_v1';

  static Future<Map<String, String>> all() => ProKit.mapOf(mk);

  static Future<void> set(String moduleKey, String pin) async {
    final m = await all();
    if (pin.isEmpty) {
      m.remove(moduleKey);
    } else {
      m[moduleKey] = pin;
    }
    await ProKit.saveMap(mk, m);
  }

  static Future<String> pinOf(String moduleKey) async =>
      (await all())[moduleKey] ?? '';

  /// 需要解锁吗(有 PIN 且本次会话没解过)
  static Future<bool> locked(String moduleKey) async {
    final pin = await pinOf(moduleKey);
    if (pin.isEmpty) return false;
    final p = await ProKit.prefs();
    return !(p.getBool('unlocked_$moduleKey') ?? false);
  }

  static Future<void> unlock(String moduleKey) async =>
      (await ProKit.prefs()).setBool('unlocked_$moduleKey', true);

  static Future<void> relockAll() async {
    final m = await all();
    final p = await ProKit.prefs();
    for (final k in m.keys) {
      await p.setBool('unlocked_$k', false);
    }
  }
}

// ══════════════════════════════════════════════════════════════
// E-2 设备密钥(Ed25519) + E-1 无状态验签
// ══════════════════════════════════════════════════════════════
class DeviceKey {
  static const mkSeed = 'device_priv_seed';
  static const mkPub = 'device_pub';
  static const mkId = 'device_id';

  // Ed25519 公钥的 SPKI DER 前缀(Node 侧直接 createPublicKey 验签用)
  static const spkiPrefix = <int>[
    0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00
  ];

  static Future<(String deviceId, String pubSpkiB64)> ensure() async {
    final p = await ProKit.prefs();
    var seedB64 = p.getString(mkSeed);
    var id = p.getString(mkId);
    final alg = Ed25519();
    SimpleKeyPair kp;
    if (seedB64 == null) {
      kp = await alg.newKeyPair();
      final seed = await kp.extractPrivateKeyBytes();
      seedB64 = base64Encode(seed);
      await p.setString(mkSeed, seedB64);
    } else {
      kp = await alg.newKeyPairFromSeed(base64Decode(seedB64));
    }
    final pub = await kp.extractPublicKey();
    final spki = [...spkiPrefix, ...pub.bytes];
    final pubB64 = base64Encode(spki);
    await p.setString(mkPub, pubB64);
    if (id == null) {
      id = 'TH-' +
          pub.bytes.take(6).map((x) => x.toRadixString(16).padLeft(2, '0')).join();
      await p.setString(mkId, id);
    }
    return (id, pubB64);
  }

  static Future<String> sign(String payload) async {
    final p = await ProKit.prefs();
    final seedB64 = p.getString(mkSeed);
    if (seedB64 == null) await ensure();
    final seed = base64Decode((await ProKit.prefs()).getString(mkSeed)!);
    final alg = Ed25519();
    final kp = await alg.newKeyPairFromSeed(seed);
    final sig = await alg.sign(utf8.encode(payload), keyPair: kp);
    return base64Encode(sig.bytes);
  }

  static Future<Map<String, String>> identity() async {
    final (id, pub) = await ensure();
    return {'deviceId': id, 'publicKey': pub};
  }

  /// E-1: 调云/后端的无状态验签端点
  static Future<Map<String, dynamic>> verify() async {
    final (id, pub) = await ensure();
    final nonce = DateTime.now().millisecondsSinceEpoch.toString();
    final sig = await sign('$id|$nonce');
    return ProKit.postJson('/v2/verify', {
      'deviceId': id,
      'publicKey': pub,
      'payload': '$id|$nonce',
      'signature': sig,
    });
  }
}

// ══════════════════════════════════════════════════════════════
// S-7 / E-3 授权管理(本机授权台账)
// ══════════════════════════════════════════════════════════════
class Grants {
  static const mk = 'grants_v1';

  static Future<List<Map<String, String>>> all() => ProKit.listOf(mk);

  static Future<void> add(String name, String type, {String note = ''}) async {
    await ProKit.push(mk, {
      'id': DateTime.now().microsecondsSinceEpoch.toString(),
      'name': name,
      'type': type,
      'note': note,
      'at': ProKit.now(),
    }, max: 200);
  }

  static Future<void> revoke(String id) async {
    final l = await all();
    l.removeWhere((e) => e['id'] == id);
    await ProKit.saveList(mk, l);
  }
}

// ══════════════════════════════════════════════════════════════
// E-4 远程引擎(官方零分发, 用户手动添加)
// ══════════════════════════════════════════════════════════════
class RemoteEngines {
  static const mk = 'remote_engines_v1';
  static Future<List<Map<String, String>>> all() => ProKit.listOf(mk);

  static Future<void> add(String base, String name, {String note = ''}) async {
    await ProKit.push(mk, {
      'id': DateTime.now().microsecondsSinceEpoch.toString(),
      'base': base.trim().replaceAll(RegExp(r'/+$'), ''),
      'name': name.trim().isEmpty ? base.trim() : name.trim(),
      'note': note,
      'at': ProKit.now(),
    }, max: 50);
  }

  static Future<void> remove(String id) async {
    final l = await all();
    l.removeWhere((e) => e['id'] == id);
    await ProKit.saveList(mk, l);
  }
}

// ══════════════════════════════════════════════════════════════
// E-5 PAYMENT_REQUIRED 交互
// ══════════════════════════════════════════════════════════════
class PaymentGate {
  /// 从任意信封里提取 402/PAYMENT_REQUIRED 信息
  static String? urlOf(Map<String, dynamic> env) {
    try {
      final err = env['error'] ?? env['data'];
      if (err is! Map) return null;
      if ('${err['code']}' != 'PAYMENT_REQUIRED') return null;
      final meta = err['meta'];
      if (meta is Map) {
        final ext = meta['ext'];
        if (ext is Map && ext['paymentUrl'] != null) return '${ext['paymentUrl']}';
        if (meta['paymentUrl'] != null) return '${meta['paymentUrl']}';
      }
      return '';
    } catch (_) {
      return null;
    }
  }

  static Future<void> show(BuildContext c, String url) async {
    await showDialog<void>(
      context: c,
      builder: (c2) => AlertDialog(
        title: const Text('该资源需要付费'),
        content: Text(
            url.isEmpty
                ? '服务方返回了 PAYMENT_REQUIRED, 但没有给出付款地址。请联系资源提供方。'
                : '服务方要求先完成付费。付款页面:\n\n$url',
            style: const TextStyle(fontSize: 13, height: 1.5)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c2), child: const Text('知道了')),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// 系统与生态中心页(4 个分区)
// ══════════════════════════════════════════════════════════════
class SystemCenterPage extends ProPage {
  const SystemCenterPage({super.key});
  @override
  State<SystemCenterPage> createState() => _Sys();
}

class _Sys extends ProPageState<SystemCenterPage> {
  List<String> modules = [];
  List<String> nav = [];
  List<Map<String, String>> backends = [];
  List<Map<String, String>> grants = [];
  List<Map<String, String>> engines = [];
  Map<String, String> locks = {};
  String mode = 'normal';
  String curBase = '';
  Map<String, String> dev = {};

  @override
  String get titleText => '系统与生态';

  @override
  Future<void> load() async {
    modules = ProBridge.moduleKeys?.call() ?? [];
    nav = ProBridge.navModules?.call() ?? [];
    backends = await Backends.all();
    grants = await Grants.all();
    engines = await RemoteEngines.all();
    locks = await ModuleLocks.all();
    mode = await Modes.mode();
    curBase = (await Backends.current())['base'] ?? '';
    dev = await DeviceKey.identity();
  }

  @override
  List<Widget> buildBody(BuildContext c) {
    return [
      // ── S-1 模块市场 ──
      ProUI.card('S-1 模块市场', [
        ProUI.row(Icons.apps, '选择底部导航模块',
            value: '已启用 ${nav.length} / ${modules.length}',
            sub: '勾选即出现在底部导航, 取消即隐藏(功能仍在)',
            onTap: () => _pickModules(c)),
        ProUI.row(Icons.swap_vert, '按分类一键恢复默认',
            sub: '核心 + 内容两类最常用',
            onTap: () async {
              final def = modules.where((k) =>
                  ['搜索', '小说', '漫画', '视频', '音乐', 'AI', '浏览器', '文件', '相册', '我的']
                      .contains(k));
              await ProBridge.setNavModules?.call(def.toList());
              await refresh();
            }),
      ], sub: 'S-1: 安装/隐藏/排序都在本机生效, 不需要下载'),

      // ── S-4 / S-5 外观与模式 ──
      ProUI.card('S-4 / S-5 深色与长辈儿童模式', [
        ProUI.row(Icons.contrast, '主题模式',
            value: _themeText(),
            sub: '深色 / 浅色 / 跟随系统',
            onTap: () => _themeSheet(c)),
        for (final m in ['normal', 'elder', 'kid'])
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14),
            leading: Icon(
                mode == m ? Icons.radio_button_checked : Icons.radio_button_off,
                size: 18,
                color: mode == m ? Theme.of(c).colorScheme.primary : Colors.grey),
            title: Text(_modeText(m), style: const TextStyle(fontSize: 13.5)),
            subtitle: Text(_modeDesc(m),
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
            onTap: () async {
              await Modes.apply(m);
              await refresh();
              ProUI.toast(c, '已切换到${_modeText(m)}');
            },
          ),
      ], sub: '长辈模式放大字体并精简导航; 儿童模式只留学习与音频'),

      // ── S-6 模块锁 ──
      ProUI.card('S-6 模块锁', [
        ProUI.row(Icons.lock_outline, '给模块加独立 PIN',
            value: '${locks.length} 个已锁',
            sub: '每次进入该模块都要输 PIN',
            onTap: () => _pickLock(c)),
        for (final e in locks.entries)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14),
            leading: const Icon(Icons.lock, size: 18),
            title: Text(e.key, style: const TextStyle(fontSize: 13.5)),
            trailing: IconButton(
                icon: const Icon(Icons.lock_open, size: 16),
                onPressed: () async {
                  await ModuleLocks.set(e.key, '');
                  await refresh();
                }),
          ),
      ]),

      // ── S-2 多后端 ──
      ProUI.card('S-2 多后端 / 多节点', [
        ProUI.row(Icons.dns_outlined, '添加后端节点',
            sub: '家里一台、办公室一台, 一键切换',
            onTap: () => _addBackend(c)),
        ProUI.row(Icons.wifi_tethering, '当前: ${curBase.isEmpty ? '未连接' : curBase}',
            sub: '切换后所有模块立即用新节点'),
        for (final e in backends)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14),
            leading: Icon(
                e['base'] == curBase ? Icons.check_circle : Icons.circle_outlined,
                size: 18,
                color: e['base'] == curBase
                    ? Theme.of(c).colorScheme.primary
                    : Colors.grey),
            title: Text(e['name'] ?? '', style: const TextStyle(fontSize: 13.5)),
            subtitle: Text(e['base'] ?? '',
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                  tooltip: '探活',
                  icon: const Icon(Icons.network_check, size: 17),
                  onPressed: () async {
                    ProUI.toast(c, '探测中…');
                    final s = await Backends.probe(e['base'] ?? '', e['token'] ?? '');
                    ProUI.toast(c, '${e['name']}: $s');
                  }),
              IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () async {
                    await Backends.remove(e['id'] ?? '');
                    await refresh();
                  }),
            ]),
            onTap: () async {
              await Backends.switchTo(e);
              await refresh();
              ProUI.toast(c, '已切到 ${e['name']}');
            },
          ),
      ], sub: '后端地址与令牌只存在本机'),

      // ── S-3 数据迁移 ──
      ProUI.card('S-3 数据迁移', [
        ProUI.row(Icons.upload_file, '导出全部设置与数据',
            sub: '含书架/书签/笔记/批注; 默认不含后端令牌',
            onTap: () async {
              final path = await Migration.export();
              ProUI.toast(c, '已导出到 $path');
              await refresh();
            }),
        ProUI.row(Icons.download_for_offline_outlined, '从备份恢复',
            sub: '从本机导出过的备份文件里恢复',
            onTap: () => _restore(c)),
      ], sub: '换机时导出这个文件即可'),

      // ── E 组 生态 ──
      ProUI.card('E-1 / E-2 设备身份', [
        ProUI.row(Icons.fingerprint, '设备身份码', value: dev['deviceId'] ?? ''),
        ProUI.row(Icons.verified_outlined, '向服务端出示身份',
            sub: '本地 Ed25519 私钥签名, 私钥不出设备',
            onTap: () => _verify(c)),
      ]),

      ProUI.card('E-3 授权管理', [
        for (final e in grants)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14),
            leading: const Icon(Icons.key_outlined, size: 18),
            title: Text(e['name'] ?? '', style: const TextStyle(fontSize: 13.5)),
            subtitle: Text('${e['type']} · ${e['at']}',
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
            trailing: TextButton(
                onPressed: () async {
                  await Grants.revoke(e['id'] ?? '');
                  await refresh();
                },
                child: const Text('撤销', style: TextStyle(fontSize: 11))),
          ),
        if (grants.isEmpty) ProUI.note('还没有授权记录。接入第三方引擎后其授权会登记在这里。'),
      ]),

      ProUI.card('E-4 远程引擎', [
        ProUI.row(Icons.hub_outlined, '手动添加远程引擎',
            sub: '官方零分发; 自行添加即自担风险',
            onTap: () => _addEngine(c)),
        for (final e in engines)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14),
            leading: const Icon(Icons.memory, size: 18),
            title: Text(e['name'] ?? '', style: const TextStyle(fontSize: 13.5)),
            subtitle: Text(e['base'] ?? '',
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
            trailing: IconButton(
                icon: const Icon(Icons.close, size: 16),
                onPressed: () async {
                  await RemoteEngines.remove(e['id'] ?? '');
                  await refresh();
                }),
          ),
      ], sub: '红线: 不分发引擎、不做推荐位、不审核内容'),

      ProUI.card('E-5 / E-6 付费与开发者', [
        ProUI.row(Icons.payments_outlined, 'PAYMENT_REQUIRED 处理演示',
            sub: '遇到付费墙时的统一交互', onTap: () => _payDemo(c)),
        ProUI.row(Icons.description_outlined, 'THP 契约与 Engine SDK 说明',
            onTap: () => Navigator.push(c,
                MaterialPageRoute(builder: (_) => const DevGuidePage()))),
      ]),
    ];
  }

  String _themeText() => switch (ProBridge.themeMode?.call() ?? 'system') {
        'dark' => '深色',
        'light' => '浅色',
        _ => '跟随系统',
      };

  String _modeText(String m) => switch (m) {
        'elder' => '长辈模式',
        'kid' => '儿童模式',
        _ => '常规模式',
      };

  String _modeDesc(String m) => switch (m) {
        'elder' => '字体放大 1.28 倍, 底部只留 6 个常用模块',
        'kid' => '只留学习/音频类, 强制内容过滤',
        _ => '全部模块, 标准字号',
      };

  Future<void> _themeSheet(BuildContext c) async {
    await showModalBottomSheet<void>(
      context: c,
      builder: (c2) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final e in [('system', '跟随系统'), ('dark', '深色'), ('light', '浅色')])
            ListTile(
              dense: true,
              title: Text(e.$2),
              trailing: (ProBridge.themeMode?.call() ?? 'system') == e.$1
                  ? const Icon(Icons.check, size: 18)
                  : null,
              onTap: () async {
                await ProBridge.setThemeMode?.call(e.$1);
                if (c2.mounted) Navigator.pop(c2);
                await refresh();
              },
            ),
        ]),
      ),
    );
  }

  Future<void> _pickModules(BuildContext c) async {
    final sel = <String>{...nav};
    await showModalBottomSheet<void>(
      context: c,
      isScrollControlled: true,
      builder: (c2) => StatefulBuilder(
        builder: (c2, setD) => SafeArea(
          child: SizedBox(
            height: MediaQuery.of(c2).size.height * 0.8,
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.all(10),
                child: Row(children: [
                  Text('底部导航模块 (${sel.length})',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  TextButton(
                      onPressed: () {
                        Navigator.pop(c2);
                        ProBridge.setNavModules?.call(sel.toList());
                      },
                      child: const Text('保存')),
                ]),
              ),
              Expanded(
                child: ListView(
                  children: [
                    for (final k in modules)
                      CheckboxListTile(
                        dense: true,
                        value: sel.contains(k),
                        title: Text(k, style: const TextStyle(fontSize: 13.5)),
                        onChanged: (v) => setD(() {
                          if (v == true) {
                            sel.add(k);
                          } else {
                            sel.remove(k);
                          }
                        }),
                      ),
                  ],
                ),
              ),
            ]),
          ),
        ),
      ),
    );
    await refresh();
  }

  Future<void> _pickLock(BuildContext c) async {
    final key = await showModalBottomSheet<String>(
      context: c,
      builder: (c2) => SafeArea(
        child: ListView(
          children: [
            for (final k in modules)
              ListTile(
                dense: true,
                title: Text(k),
                trailing: (locks[k] == null)
                    ? null
                    : const Icon(Icons.lock, size: 16),
                onTap: () => Navigator.pop(c2, k),
              ),
          ],
        ),
      ),
    );
    if (key == null || !c.mounted) return;
    final pin = await ProKit.prompt(c, '为「$key」设置 PIN', hint: '4-6 位数字, 留空表示取消锁定');
    await ModuleLocks.set(key, pin ?? '');
    await refresh();
  }

  Future<void> _addBackend(BuildContext c) async {
    final base = await ProKit.prompt(c, '后端地址', hint: 'https://192.168.1.10:9527');
    if (base == null) return;
    final token = await ProKit.prompt(c, '后端令牌', hint: '连接资源库时用的那串');
    final name = await ProKit.prompt(c, '备注名', hint: '家里 / 办公室');
    await Backends.add(base, token ?? '', name ?? '');
    await refresh();
  }

  Future<void> _restore(BuildContext c) async {
    final list = await Migration.backups();
    if (list.isEmpty) {
      ProUI.toast(c, '还没有备份文件');
      return;
    }
    final pick = await showModalBottomSheet<File>(
      context: c,
      builder: (c2) => SafeArea(
        child: ListView(
          children: [
            for (final f in list.take(20))
              ListTile(
                dense: true,
                title: Text(f.path.split(Platform.pathSeparator).last,
                    style: const TextStyle(fontSize: 12.5)),
                onTap: () => Navigator.pop(c2, f),
              ),
          ],
        ),
      ),
    );
    if (pick == null || !c.mounted) return;
    final ok = await ProKit.confirm(c, '恢复备份',
        '将用备份内容覆盖同名设置项。当前设置里没被覆盖的部分保持不变。');
    if (!ok) return;
    final msg = await Migration.importFrom(pick);
    ProUI.toast(c, msg);
    await refresh();
  }

  Future<void> _verify(BuildContext c) async {
    ProUI.toast(c, '正在本地签名并请求验签…');
    final r = await DeviceKey.verify();
    if (!c.mounted) return;
    final ok = r['ok'] == true;
    final url = PaymentGate.urlOf(r);
    if (url != null) {
      await PaymentGate.show(c, url);
      return;
    }
    await showDialog<void>(
      context: c,
      builder: (c2) => AlertDialog(
        title: Text(ok ? '验签结果' : '未能完成验签'),
        content: Text(
            ok
                ? '服务端已确认本机私钥签名有效。\n\n${jsonEncode(r['data'] ?? {})}'
                : '服务端未响应或未连接。验签需要云端点 /v2/verify 在线。\n\n本机公钥:\n${dev['publicKey']}',
            style: const TextStyle(fontSize: 12, height: 1.5)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c2), child: const Text('关闭')),
        ],
      ),
    );
  }

  Future<void> _addEngine(BuildContext c) async {
    final ok = await ProKit.confirm(c, '风险提示',
        '远程引擎由你自行添加。第三方引擎可能索取网络权限、记录你的访问行为, 也可能随时失效。\n\n本应用不提供、不推荐、不审核任何引擎, 使用后果自负。');
    if (!ok || !c.mounted) return;
    final base = await ProKit.prompt(c, '引擎地址', hint: 'https://host:port');
    if (base == null) return;
    final name = await ProKit.prompt(c, '名称', hint: '可选');
    await RemoteEngines.add(base, name ?? '');
    await Grants.add(name ?? base, '远程引擎', note: base);
    await refresh();
  }

  Future<void> _payDemo(BuildContext c) async {
    final env = <String, dynamic>{
      'ok': false,
      'error': {
        'code': 'PAYMENT_REQUIRED',
        'message': '需要先购买会员',
        'meta': {
          'ext': {'paymentUrl': 'https://example.com/pay?sku=demo'}
        }
      }
    };
    final url = PaymentGate.urlOf(env);
    if (url == null) {
      ProUI.toast(c, '这个信封不是 PAYMENT_REQUIRED');
      return;
    }
    await PaymentGate.show(c, url);
  }
}

// ══════════════════════════════════════════════════════════════
// E-6 开发者指南: THP 契约速查
// ══════════════════════════════════════════════════════════════
class DevGuidePage extends StatelessWidget {
  const DevGuidePage({super.key});

  static const _endpoints = [
    ('POST|GET', '/thp/m/{module}/{action}',
        'module ∈ novel|comic|music|video; action ∈ search|toc|content'),
    ('POST', '/thp/handshake', '零输入握手, 返回 iid/caps/name'),
    ('UDP 19527', 'THP/1 HELLO <port> <iid> engine <caps> <name>',
        '每 5 秒广播一次'),
  ];

  static const _envelope = '''{ "ok": true, "data": ... }
{ "ok": false, "error": { "code": "UNSUPPORTED", "message": "..." } }

降级铁律: 只有 code ∈ {UNSUPPORTED, NOT_FOUND} 才允许降级到别的线路。
content 形状:
  novel → { text }
  comic → { images: [] }
  music → { url, variants: [] }
  video → { url, header: {}, variants: [] }''';

  static const _capsNote = '''能力位标志(归一化时必须先判 video):
  text = 8 / audio = 32 / image = 64 / video = 4

调用方必须带 charset=utf-8:
  NanoHTTPD 2.3.1 在缺少 charset 时按 US-ASCII 读请求体,
  中文会变成不可逆的 U+FFFD(且仍返回 200)。

POST 源记法:
  searchUrl 可以是整串 "url,{json规则}";
  任何"按 id 形状过滤"的写法都会误杀整片 POST 源。''';

  @override
  Widget build(BuildContext c) {
    return Scaffold(
      appBar: AppBar(title: const Text('THP 契约 / Engine SDK')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          ProUI.card('E-6 端点', [
            for (final e in _endpoints)
              ListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                leading: ProUI.chip(e.$1),
                title: Text(e.$2, style: const TextStyle(fontSize: 12.5)),
                subtitle: Text(e.$3,
                    style: const TextStyle(fontSize: 11, color: Colors.grey)),
              ),
          ], sub: '协议只增不减'),
          ProUI.card('信封与内容形状', [
            Padding(
              padding: const EdgeInsets.all(12),
              child: SelectableText(_envelope,
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 11.5, height: 1.5)),
            ),
          ]),
          ProUI.card('踩坑备忘(引擎侧与调用侧)', [
            Padding(
              padding: const EdgeInsets.all(12),
              child: SelectableText(_capsNote,
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 11.5, height: 1.5)),
            ),
          ]),
          ProUI.note('开发者接入只需实现上面三个端点; 本应用不代管、不托管任何引擎。'),
        ],
      ),
    );
  }
}
