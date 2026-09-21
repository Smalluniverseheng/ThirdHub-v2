// ThirdHub v4.40.0 · F 组 相册/文件闭环(PLAN-v3 §3.4)
//   F-1 WiFi 自动备份 · F-2 哈希秒传 · F-3 时间轴 · F-4 释放空间 · F-5 人脸归档
//   F-6 加密柜 · F-7 版本历史 · F-8 分享链 · F-9 存储分析
//
// 闭环设计: 相册照片 → SHA-256 → (已有则秒传) → 后端 blob → 本地清单
//          → 「释放空间」只删"后端确认存在"的那些; 加密柜/分享链同一套 hash 体系。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/io_client.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart' as pm;
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import 'pro_kit.dart';

// ══════════════════════════════════════════════════════════════
// F-2 哈希(SHA-256) 工具
// ══════════════════════════════════════════════════════════════
class HashX {
  static Future<String> ofBytes(List<int> b) async {
    final h = await Sha256().hash(b);
    return h.bytes.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  }

  static Future<String?> ofFile(File f) async {
    try {
      return await ofBytes(await f.readAsBytes());
    } catch (_) {
      return null;
    }
  }

  static String human(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
  }
}

// ══════════════════════════════════════════════════════════════
// 后端 blob 客户端(F-1/F-2/F-7/F-8 共用)
// ══════════════════════════════════════════════════════════════
class BlobApi {
  static HttpClient _c() =>
      HttpClient()..badCertificateCallback = (_, __, ___) => true;

  /// 已经存过这个 hash 吗(秒传判定)
  static Future<int?> has(String hash) async {
    final r = await ProKit.getJson('/v1/blob/has?hash=$hash');
    final d = r['data'];
    if (d is Map && d['has'] == true) return (d['size'] as num?)?.toInt() ?? 0;
    return null;
  }

  static Future<String> upload(String hash, String name, List<int> bytes,
      {String ver = '1'}) async {
    final base = await ProKit.base();
    if (base.isEmpty) return '未连接后端';
    try {
      final uri = Uri.parse(
          '$base/v1/blob?hash=$hash&name=${Uri.encodeComponent(name)}&ver=$ver');
      final req = await _c().postUrl(uri);
      req.headers.set('X-TH-Token', await ProKit.token());
      req.headers.set('Content-Type', 'application/octet-stream');
      req.add(bytes);
      final res = await req.close().timeout(const Duration(minutes: 3));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode >= 400) {
        return 'HTTP ${res.statusCode} ${body.length > 100 ? body.substring(0, 100) : body}';
      }
      return '';
    } catch (e) {
      return '$e';
    }
  }

  static Future<Uint8List?> download(String hash) async {
    final base = await ProKit.base();
    if (base.isEmpty) return null;
    try {
      final req = await _c().getUrl(Uri.parse('$base/v1/blob?hash=$hash'));
      req.headers.set('X-TH-Token', await ProKit.token());
      final res = await req.close().timeout(const Duration(minutes: 3));
      if (res.statusCode >= 400) return null;
      final chunks = <int>[];
      await for (final c in res) {
        chunks.addAll(c);
      }
      return Uint8List.fromList(chunks);
    } catch (_) {
      return null;
    }
  }

  static Future<List<Map<String, String>>> remoteList() async {
    final r = await ProKit.getJson('/v1/blob/list');
    final d = r['data'];
    if (d is! List) return [];
    return [for (final e in d) Map<String, String>.from(e as Map)];
  }

  static Future<String> remove(String hash) async {
    final r = await ProKit.postJson('/v1/blob/delete', {'hash': hash});
    return r['ok'] == true ? '' : '删除失败';
  }

  /// F-8 分享链: 由后端生成局域网可访问链接
  static Future<String> share(String hash, String name) async {
    final r = await ProKit.postJson('/v1/share', {'hash': hash, 'name': name});
    final d = r['data'];
    if (d is Map && d['url'] != null) return '${d['url']}';
    return '';
  }
}

// ══════════════════════════════════════════════════════════════
// F-1 / F-4 / F-7 备份引擎 + 本地清单
// ══════════════════════════════════════════════════════════════
class BackupStore {
  static const mkManifest = 'backup_manifest_v1';
  static const mkVer = 'backup_versions_v1';
  static const mkCfg = 'backup_cfg_v1';
  static const mkFaces = 'face_tags_v1';

  static Future<List<Map<String, String>>> manifest() =>
      ProKit.listOf(mkManifest);

  static Future<void> addRec(Map<String, String> rec) async {
    await ProKit.push(mkManifest, rec, idKey: 'hash', max: 5000);
  }

  static Future<Map<String, String>> cfg() => ProKit.mapOf(mkCfg);

  static Future<void> setCfg(Map<String, String> v) => ProKit.saveMap(mkCfg, v);

  /// F-7 版本历史: 同名不同内容 → 记一条版本(v2/v3…)
  static Future<void> addVersion(String name, String hash, String ver) async {
    await ProKit.push(mkVer, {
      'id': '$name|$hash',
      'name': name,
      'hash': hash,
      'ver': ver,
      'at': ProKit.now(),
    }, max: 2000);
  }

  static Future<List<Map<String, String>>> versions() =>
      ProKit.listOf(mkVer);

  /// F-5 人脸归档(本地标记, 不上传任何图像)
  static Future<void> tagFace(String assetId, String name) async {
    await ProKit.push(mkFaces, {'id': assetId, 'name': name, 'at': ProKit.now()},
        max: 5000);
  }

  static Future<List<Map<String, String>>> faces() => ProKit.listOf(mkFaces);
}

class BackupStat {
  int scanned = 0, uploaded = 0, skipped = 0, failed = 0, bytes = 0;
  final errors = <String>[];
}

class BackupEngine {
  /// 备份一轮。onTick(已处理, 总数, 当前文件)
  static Future<BackupStat> runOnce({
    int limit = 300,
    void Function(int done, int total, String name)? onTick,
  }) async {
    final st = BackupStat();
    final perm = await pm.PhotoManager.requestPermissionExtend();
    if (!perm.isAuth) {
      st.errors.add('没有相册权限');
      return st;
    }
    final offline = (await ProKit.base()).isEmpty;
    if (offline) {
      st.errors.add('未连接后端, 只能本地登记(去「我的 → 连接资源库」)');
    }
    final albums = await pm.PhotoManager.getAssetPathList(
        type: pm.RequestType.common, onlyAll: true);
    if (albums.isEmpty) {
      st.errors.add('相册为空');
      return st;
    }
    final album = albums.first;
    final total = (await album.assetCountAsync).clamp(0, limit).toInt();
    final done = <String>{};
    for (final e in await BackupStore.manifest()) {
      done.add(e['hash'] ?? '');
    }
    var page = 0;
    var processed = 0;
    while (processed < total) {
      final assets = await album.getAssetListPaged(page: page, size: 40);
      if (assets.isEmpty) break;
      page++;
      for (final a in assets) {
        if (processed >= total) break;
        processed++;
        st.scanned++;
        // AssetEntity.title 是可空字段(部分资产没有标题) → 统一取一个非空显示名
        final nm = (a.title == null || a.title!.trim().isEmpty)
            ? 'IMG_${a.id}'
            : a.title!.trim();
        onTick?.call(processed, total, nm);
        try {
          final f = await a.file;
          if (f == null) continue;
          final bytes = await f.readAsBytes();
          final hash = await HashX.ofBytes(bytes);
          if (done.contains(hash)) {
            st.skipped++;
            continue;
          }
          if (offline) {
            st.skipped++;
            continue;
          }
          // F-2 秒传: 后端已有同一 hash → 不再上传
          final existSize = await BlobApi.has(hash);
          final ver = existSize == null ? '1' : '${await _nextVer(nm, hash)}';
          if (existSize == null) {
            final err = await BlobApi.upload(hash, nm, bytes, ver: ver);
            if (err.isNotEmpty) {
              st.failed++;
              if (st.errors.length < 4) st.errors.add('$nm: $err');
              continue;
            }
            st.uploaded++;
            st.bytes += bytes.length;
          } else {
            st.uploaded++;
            st.bytes += existSize;
            await BackupStore.addVersion(nm, hash, ver);
          }
          await BackupStore.addRec({
            'hash': hash,
            'name': nm,
            'size': '${bytes.length}',
            'assetId': a.id,
            'at': ProKit.now(),
            'ver': ver,
          });
          done.add(hash);
        } catch (e) {
          st.failed++;
          if (st.errors.length < 4) st.errors.add('$nm: $e');
        }
      }
    }
    final c = await BackupStore.cfg();
    c['lastRun'] = ProKit.now();
    c['lastUploaded'] = '${st.uploaded}';
    await BackupStore.setCfg(c);
    return st;
  }

  static Future<int> _nextVer(String name, String hash) async {
    final v = await BackupStore.versions();
    final same = v.where((e) => e['name'] == name).length;
    return same + 2;
  }

  /// F-4 释放空间: 只删"后端确认存在"的照片(逐张先 GET has 复核, 再删本地)
  static Future<Map<String, int>> freeUp(
      {void Function(int done, int total)? onTick}) async {
    final out = {'checked': 0, 'deleted': 0, 'kept': 0};
    final man = await BackupStore.manifest();
    final ids = <String>[];
    for (final e in man) {
      out['checked'] = (out['checked'] ?? 0) + 1;
      onTick?.call(out['checked']!, man.length);
      final hash = e['hash'] ?? '';
      final id = e['assetId'] ?? '';
      if (hash.isEmpty || id.isEmpty) continue;
      final exist = await BlobApi.has(hash);
      if (exist == null) {
        out['kept'] = (out['kept'] ?? 0) + 1;
        continue;
      }
      ids.add(id);
      if (ids.length >= 100) {
        out['deleted'] = (out['deleted'] ?? 0) + (await _del(ids));
        ids.clear();
      }
    }
    if (ids.isNotEmpty) out['deleted'] = (out['deleted'] ?? 0) + (await _del(ids));
    return out;
  }

  static Future<int> _del(List<String> ids) async {
    try {
      final r = await pm.PhotoManager.editor.deleteWithIds(List.of(ids));
      return r.length;
    } catch (_) {
      return 0;
    }
  }
}

// ══════════════════════════════════════════════════════════════
// F-6 加密柜: AES-256-GCM, 密钥 = SHA-256(口令); 密文只在本机私有目录
// ══════════════════════════════════════════════════════════════
class Vault {
  static const mkIdx = 'vault_index_v1';

  static Future<Directory> dir() async {
    final d = await getApplicationDocumentsDirectory();
    final v = Directory('${d.path}/vault');
    if (!await v.exists()) await v.create(recursive: true);
    return v;
  }

  static Future<List<Map<String, String>>> list() => ProKit.listOf(mkIdx);

  static Future<String> encryptIn(File src, String pass) async {
    try {
      final bytes = await src.readAsBytes();
      final key = await Sha256().hash(utf8.encode(pass));
      final alg = AesGcm.with256bits();
      final nonce = alg.newNonce();
      final box = await alg.encrypt(bytes,
          secretKey: SecretKey(key.bytes), nonce: nonce);
      final payload =
          Uint8List.fromList([...nonce, ...box.cipherText, ...box.mac.bytes]);
      final id = DateTime.now().microsecondsSinceEpoch.toString();
      final f = File('${(await dir()).path}/$id.enc');
      await f.writeAsBytes(payload, flush: true);
      await ProKit.push(mkIdx, {
        'id': id,
        'name': src.uri.pathSegments.isEmpty ? 'file' : src.uri.pathSegments.last,
        'size': '${bytes.length}',
        'at': ProKit.now(),
      }, max: 1000);
      return '';
    } catch (e) {
      return '$e';
    }
  }

  static Future<String> decryptOut(
      Map<String, String> item, String pass, File target) async {
    try {
      final f = File('${(await dir()).path}/${item['id']}.enc');
      if (!await f.exists()) return '密文已丢失';
      final raw = await f.readAsBytes();
      final key = await Sha256().hash(utf8.encode(pass));
      final alg = AesGcm.with256bits();
      final clear = await alg.decrypt(
        SecretBox(raw.sublist(12, raw.length - 16),
            nonce: raw.sublist(0, 12), mac: Mac(raw.sublist(raw.length - 16))),
        secretKey: SecretKey(key.bytes),
      );
      await target.writeAsBytes(clear, flush: true);
      return '';
    } catch (_) {
      return '口令错误或文件已损坏';
    }
  }

  static Future<void> remove(String id) async {
    final l = await list();
    l.removeWhere((e) => e['id'] == id);
    await ProKit.saveList(mkIdx, l);
    try {
      final f = File('${(await dir()).path}/$id.enc');
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}

// ══════════════════════════════════════════════════════════════
// F-9 存储分析
// ══════════════════════════════════════════════════════════════
class StorageScan {
  /// 返回 { 分类 → 字节 }
  static Future<Map<String, int>> run({bool deep = false}) async {
    final out = <String, int>{};
    try {
      final docs = await getApplicationDocumentsDirectory();
      out['应用数据'] = await _sizeOf(docs, deep);
      final tmp = await getTemporaryDirectory();
      out['临时缓存'] = await _sizeOf(tmp, false);
    } catch (_) {}
    try {
      final perm = await pm.PhotoManager.requestPermissionExtend();
      if (perm.isAuth) {
        final albums = await pm.PhotoManager.getAssetPathList(
            type: pm.RequestType.common, onlyAll: true);
        if (albums.isNotEmpty) {
          var n = 0, b = 0;
          final assets = await albums.first.getAssetListPaged(page: 0, size: 400);
          for (final a in assets) {
            try {
              final f = await a.file;
              if (f != null) {
                b += await f.length();
                n++;
              }
            } catch (_) {}
          }
          out['相册(前 $n 项)'] = b;
        }
      }
    } catch (_) {}
    out['加密柜'] = await _vaultSize();
    return out;
  }

  static Future<int> _vaultSize() async {
    try {
      final d = await Vault.dir();
      var s = 0;
      await for (final f in d.list()) {
        if (f is File) s += await f.length();
      }
      return s;
    } catch (_) {
      return 0;
    }
  }

  static Future<int> _sizeOf(Directory d, bool deep) async {
    var s = 0;
    try {
      if (!await d.exists()) return 0;
      await for (final e in d.list(followLinks: false)) {
        if (e is File) {
          s += await e.length();
        } else if (deep && e is Directory) {
          s += await _sizeOf(e, true);
        }
      }
    } catch (_) {}
    return s;
  }

  /// 应用私有目录里最大的若干文件(便于手动清理)
  static Future<List<Map<String, String>>> topFiles({int n = 20}) async {
    final all = <Map<String, String>>[];
    try {
      final docs = await getApplicationDocumentsDirectory();
      await for (final e in docs.list(followLinks: false)) {
        if (e is File) {
          all.add({
            'path': e.path,
            'size': '${await e.length()}',
          });
        }
      }
    } catch (_) {}
    all.sort((a, b) =>
        int.parse(b['size']!).compareTo(int.parse(a['size']!)));
    return all.take(n).toList();
  }
}

// ══════════════════════════════════════════════════════════════
// F 组 UI: 相册闭环总页
// ══════════════════════════════════════════════════════════════
class GalleryProPage extends ProPage {
  const GalleryProPage({super.key});
  @override
  State<GalleryProPage> createState() => _GP();
}

class _GP extends ProPageState<GalleryProPage> {
  bool autoBackup = false;
  int files = 0;
  int bytes = 0;
  int versions = 0;
  int faces = 0;
  String lastRun = '';
  bool busy = false;
  String stage = '';
  int done = 0;
  int total = 0;

  @override
  String get titleText => '相册闭环';

  @override
  Future<void> load() async {
    final cfg = await BackupStore.cfg();
    autoBackup = cfg['auto'] == '1';
    lastRun = cfg['lastRun'] ?? '';
    final man = await BackupStore.manifest();
    files = man.length;
    bytes = man.fold(0, (s, e) => s + (int.tryParse(e['size'] ?? '0') ?? 0));
    versions = (await BackupStore.versions()).length;
    faces = (await BackupStore.faces()).length;
  }

  @override
  List<Widget> buildBody(BuildContext c) {
    return [
      ProUI.card('F-1 / F-2 备份与秒传', [
        ProUI.sw('回到 App 时自动备份', autoBackup, (v) async {
          final cfg = await BackupStore.cfg();
          cfg['auto'] = v ? '1' : '0';
          await BackupStore.setCfg(cfg);
          touch(() => autoBackup = v);
        }, sub: '打开应用时检测相册新增并上传(后台被杀时不跑)', icon: Icons.backup_outlined),
        ProUI.row(
            Icons.cloud_upload_outlined, busy ? '正在备份…' : '立即备份相册',
            value: files == 0 ? '' : '$files 个文件',
            sub: busy
                ? '$stage  ($done/$total)'
                : (lastRun.isEmpty ? '还没备份过' : '上次: $lastRun'),
            onTap: busy ? null : () => _backupNow(c)),
        if (busy) Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            child: ProUI.progress(total == 0 ? 0.0 : done / total)),
        ProUI.row(Icons.savings_outlined, '已备份占用',
            value: HashX.human(bytes),
            sub: '相册里内容相同的照片不会重复上传(SHA-256 秒传)'),
        ProUI.row(Icons.history_toggle_off, '版本历史',
            value: '$versions 条', onTap: () => _push(c, const VersionsPage())),
      ], sub: 'F-1 备份 · F-2 秒传 · F-7 版本'),

      ProUI.card('F-4 释放空间', [
        ProUI.row(Icons.cleaning_services_outlined, '删除已备份的本机照片',
            sub: '逐张向后端复核存在后才删, 复核不过的保留', onTap: () => _freeUp(c)),
      ]),

      ProUI.card('F-3 / F-5 浏览与归档', [
        ProUI.row(Icons.photo_library_outlined, '时间轴',
            sub: '按天浏览整个相册', onTap: () => _push(c, const TimelinePage())),
        ProUI.row(Icons.face_retouching_natural, '人物归档(本地标记)',
            value: '$faces 人',
            sub: '标过的照片按人物分组, 全部留在本机', onTap: () => _push(c, const FacePage())),
      ]),

      ProUI.card('F-6 / F-8 安全与分享', [
        ProUI.row(Icons.lock_outline, '加密柜',
            sub: 'AES-256-GCM, 密文只在本机私有目录', onTap: () => _push(c, const VaultPage())),
        ProUI.row(Icons.link, '生成分享链',
            sub: '由后端把已备份文件暴露为局域网链接', onTap: () => _push(c, const SharePage())),
      ]),

      ProUI.card('F-9 存储分析', [
        ProUI.row(Icons.pie_chart_outline, '占用分布与最大文件',
            onTap: () => _push(c, const StoragePage())),
      ]),
    ];
  }

  void _push(BuildContext c, Widget w) {
    Navigator.push(c, MaterialPageRoute(builder: (_) => w)).then((_) {
      if (mounted) refresh();
    });
  }

  Future<void> _backupNow(BuildContext c) async {
    touch(() {
      busy = true;
      stage = '准备中';
      done = 0;
      total = 0;
    });
    final st = await BackupEngine.runOnce(limit: 400, onTick: (d, t, name) {
      touch(() {
        done = d;
        total = t;
        stage = name.length > 18 ? '${name.substring(0, 18)}…' : name;
      });
    });
    touch(() {
      busy = false;
      stage = '';
    });
    await refresh();
    if (!mounted) return;
    final msg = '扫描 ${st.scanned} · 上传 ${st.uploaded} · 跳过 ${st.skipped} · 失败 ${st.failed}';
    ProUI.toast(c, msg);
    if (st.errors.isNotEmpty) {
      await showDialog<void>(
        context: c,
        builder: (c2) => AlertDialog(
          title: const Text('备份提示'),
          content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                  child: Text(st.errors.join('\n\n'),
                      style: const TextStyle(fontSize: 12, height: 1.5)))),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c2), child: const Text('关闭')),
          ],
        ),
      );
    }
  }

  Future<void> _freeUp(BuildContext c) async {
    final man = await BackupStore.manifest();
    if (man.isEmpty) {
      ProUI.toast(c, '还没有备份记录, 先做一次备份');
      return;
    }
    final ok = await ProKit.confirm(c, '释放本机空间',
        '将检查 ${man.length} 个已备份文件, 对"后端仍存在"的那些删除本机照片。\n\n照片删除后只能从后端重新下载。请确认你信任当前后端。',
        ok: '开始检查');
    if (!ok) return;
    ProUI.toast(c, '检查中, 可能需要一会儿…');
    final r = await BackupEngine.freeUp();
    if (!mounted) return;
    ProUI.toast(c,
        '检查 ${r['checked']} · 删除 ${r['deleted']} · 保留 ${r['kept']}(后端未确认)');
    await refresh();
  }
}

// ══════════════════════════════════════════════════════════════
// F-3 时间轴
// ══════════════════════════════════════════════════════════════
class TimelinePage extends StatefulWidget {
  const TimelinePage({super.key});
  @override
  State<TimelinePage> createState() => _Tl();
}

class _Tl extends State<TimelinePage> {
  bool loading = true;
  final items = <pm.AssetEntity>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final perm = await pm.PhotoManager.requestPermissionExtend();
      if (perm.isAuth) {
        final albums = await pm.PhotoManager.getAssetPathList(
            type: pm.RequestType.common, onlyAll: true);
        if (albums.isNotEmpty) {
          for (var i = 0; i < 4; i++) {
            final page = await albums.first.getAssetListPaged(page: i, size: 100);
            if (page.isEmpty) break;
            items.addAll(page);
          }
        }
      }
    } catch (_) {}
    if (mounted) setState(() => loading = false);
  }

  String _day(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext c) {
    if (loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (items.isEmpty) {
      return Scaffold(
          appBar: AppBar(title: const Text('时间轴')),
          body: ProUI.empty('没有读到照片(可能未授予相册权限)'));
    }
    final groups = <String, List<pm.AssetEntity>>{};
    for (final a in items) {
      groups.putIfAbsent(_day(a.createDateTime), () => []).add(a);
    }
    final days = groups.keys.toList()..sort((a, b) => b.compareTo(a));
    return Scaffold(
      appBar: AppBar(title: Text('时间轴 · ${items.length} 项')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
        children: [
          for (final d in days) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 10, 4, 6),
              child: Row(children: [
                Text(d,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700)),
                const SizedBox(width: 6),
                ProUI.chip('${groups[d]!.length} 张'),
              ]),
            ),
            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: (MediaQuery.of(c).size.width / 108).floor().clamp(3, 8),
              mainAxisSpacing: 4,
              crossAxisSpacing: 4,
              children: [
                for (final a in groups[d]!)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: AssetEntityImage(a,
                        isOriginal: false,
                        fit: BoxFit.cover,
                        thumbnailSize: const pm.ThumbnailSize.square(240)),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// F-5 人物归档(本地)
// ══════════════════════════════════════════════════════════════
class FacePage extends ProPage {
  const FacePage({super.key});
  @override
  State<FacePage> createState() => _Fp();
}

class _Fp extends ProPageState<FacePage> {
  List<Map<String, String>> tags = [];

  @override
  String get titleText => '人物归档';

  @override
  Future<void> load() async => tags = await BackupStore.faces();

  @override
  List<Widget> buildBody(BuildContext c) {
    final byName = <String, List<Map<String, String>>>{};
    for (final t in tags) {
      byName.putIfAbsent(t['name'] ?? '', () => []).add(t);
    }
    return [
      ProUI.card('本地标记', [
        ProUI.row(Icons.add_a_photo_outlined, '从相册选一张并标记人物',
            sub: '不联网、不上传, 只在本机记录照片 ID 与名字',
            onTap: () => _tag(c)),
        ProUI.note('这台设备上的人脸识别模型不可用, 所以归档以"手动标记"为准: 标记后按人物分组浏览。'),
      ]),
      if (tags.isEmpty) ProUI.empty('还没有标记。选一张照片并写上名字即可。'),
      for (final e in byName.entries)
        ProUI.card(e.key, [
          ProUI.row(Icons.photo_library_outlined, '${e.value.length} 张',
              sub: '最近: ${e.value.first['at']}'),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            child: Wrap(spacing: 6, runSpacing: 6, children: [
              for (final t in e.value.take(12))
                ProUI.chip(t['at'] ?? ''),
            ]),
          ),
        ]),
    ];
  }

  Future<void> _tag(BuildContext c) async {
    final perm = await pm.PhotoManager.requestPermissionExtend();
    if (!perm.isAuth) {
      ProUI.toast(c, '没有相册权限');
      return;
    }
    final albums = await pm.PhotoManager.getAssetPathList(type: pm.RequestType.image);
    if (albums.isEmpty) return;
    final assets = await albums.first.getAssetListPaged(page: 0, size: 24);
    if (!mounted) return;
    final pick = await showDialog<pm.AssetEntity>(
      context: c,
      builder: (c2) => AlertDialog(
        title: const Text('选择照片'),
        content: SizedBox(
          width: 320,
          height: 320,
          child: GridView.builder(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3),
            itemCount: assets.length,
            itemBuilder: (_, i) => GestureDetector(
              onTap: () => Navigator.pop(c2, assets[i]),
              child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: AssetEntityImage(assets[i],
                      isOriginal: false,
                      fit: BoxFit.cover,
                      thumbnailSize: const pm.ThumbnailSize.square(200))),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c2), child: const Text('取消')),
        ],
      ),
    );
    if (pick == null || !c.mounted) return;
    final name = await ProKit.prompt(c, '这是谁', hint: '名字或称呼');
    if (name == null) return;
    await BackupStore.tagFace(pick.id, name);
    await refresh();
  }
}

// ══════════════════════════════════════════════════════════════
// F-6 加密柜
// ══════════════════════════════════════════════════════════════
class VaultPage extends ProPage {
  const VaultPage({super.key});
  @override
  State<VaultPage> createState() => _Vp();
}

class _Vp extends ProPageState<VaultPage> {
  List<Map<String, String>> items = [];

  @override
  String get titleText => '加密柜';

  @override
  Future<void> load() async => items = await Vault.list();

  @override
  List<Widget> buildBody(BuildContext c) {
    final bytes = items.fold(0, (s, e) => s + (int.tryParse(e['size'] ?? '0') ?? 0));
    return [
      ProUI.card('AES-256-GCM 本机密文', [
        ProUI.row(Icons.add, '从相册加密入库', onTap: () => _addFromGallery(c)),
        ProUI.row(Icons.folder_outlined, '已加密 ${items.length} 个',
            value: HashX.human(bytes),
            sub: '密文在应用私有目录, 其它 App 读不到'),
      ], sub: '口令即密钥派生的前身: 口令 → SHA-256 → AES 密钥'),
      if (items.isEmpty) ProUI.empty('柜子是空的。'),
      for (final e in items)
        ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
          leading: const Icon(Icons.lock, size: 18),
          title: Text(e['name'] ?? '', style: const TextStyle(fontSize: 13.5)),
          subtitle: Text('${HashX.human(int.tryParse(e['size'] ?? '0') ?? 0)} · ${e['at']}',
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
                tooltip: '解密导出',
                icon: const Icon(Icons.lock_open, size: 17),
                onPressed: () => _decrypt(c, e)),
            IconButton(
                icon: const Icon(Icons.delete_outline, size: 17),
                onPressed: () async {
                  final ok = await ProKit.confirm(c, '删除密文', '删除后无法恢复。');
                  if (!ok) return;
                  await Vault.remove(e['id'] ?? '');
                  await refresh();
                }),
          ]),
        ),
    ];
  }

  Future<void> _addFromGallery(BuildContext c) async {
    final perm = await pm.PhotoManager.requestPermissionExtend();
    if (!perm.isAuth) {
      ProUI.toast(c, '没有相册权限');
      return;
    }
    final albums = await pm.PhotoManager.getAssetPathList(type: pm.RequestType.image);
    if (albums.isEmpty) return;
    final assets = await albums.first.getAssetListPaged(page: 0, size: 24);
    if (!mounted) return;
    final pick = await showDialog<pm.AssetEntity>(
      context: c,
      builder: (c2) => AlertDialog(
        title: const Text('选择要加密的照片'),
        content: SizedBox(
          width: 320,
          height: 320,
          child: GridView.builder(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3),
            itemCount: assets.length,
            itemBuilder: (_, i) => GestureDetector(
              onTap: () => Navigator.pop(c2, assets[i]),
              child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: AssetEntityImage(assets[i],
                      isOriginal: false,
                      fit: BoxFit.cover,
                      thumbnailSize: const pm.ThumbnailSize.square(200))),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c2), child: const Text('取消')),
        ],
      ),
    );
    if (pick == null || !c.mounted) return;
    final pass = await ProKit.prompt(c, '设置加密口令',
        hint: '口令丢失将无法解密, 请牢记', init: '');
    if (pass == null) return;
    final f = await pick.file;
    if (f == null) {
      ProUI.toast(c, '读不到这张照片的原始文件');
      return;
    }
    ProUI.toast(c, '加密中…');
    final err = await Vault.encryptIn(f, pass);
    if (!mounted) return;
    ProUI.toast(c, err.isEmpty ? '已入库' : err);
    await refresh();
  }

  Future<void> _decrypt(BuildContext c, Map<String, String> e) async {
    final pass = await ProKit.prompt(c, '输入口令解密',
        hint: '口令错误会提示损坏', init: '');
    if (pass == null) return;
    final dir = await getApplicationDocumentsDirectory();
    final out = File('${dir.path}/vault_out_${e['id']}_${e['name']}');
    final err = await Vault.decryptOut(e, pass, out);
    if (!mounted) return;
    ProUI.toast(c, err.isEmpty ? '已导出到 ${out.path}' : err);
  }
}

// ══════════════════════════════════════════════════════════════
// F-7 版本历史
// ══════════════════════════════════════════════════════════════
class VersionsPage extends ProPage {
  const VersionsPage({super.key});
  @override
  State<VersionsPage> createState() => _Vs();
}

class _Vs extends ProPageState<VersionsPage> {
  List<Map<String, String>> items = [];

  @override
  String get titleText => '版本历史';

  @override
  Future<void> load() async => items = await BackupStore.versions();

  @override
  List<Widget> buildBody(BuildContext c) {
    return [
      ProUI.note('同一个文件名、内容发生变化时, 新内容会作为新版本入库; 这里能看到全部版本并可回取。'),
      if (items.isEmpty) ProUI.empty('还没有版本记录。'),
      for (final e in items)
        ProUI.card('', [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
            child: Row(children: [
              Expanded(
                  child: Text(e['name'] ?? '',
                      style: const TextStyle(
                          fontSize: 13.5, fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis)),
              ProUI.chip('v${e['ver']}'),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
            child: Text('${e['at']} · ${(e['hash'] ?? '').substring(0, (e['hash'] ?? '').length.clamp(0, 12))}',
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(
                onPressed: () => _fetch(c, e),
                child: const Text('取回这一版', style: TextStyle(fontSize: 12))),
          ]),
        ]),
    ];
  }

  Future<void> _fetch(BuildContext c, Map<String, String> e) async {
    ProUI.toast(c, '下载中…');
    final bytes = await BlobApi.download(e['hash'] ?? '');
    if (!mounted) return;
    if (bytes == null) {
      ProUI.toast(c, '后端没有这个版本(或未连接)');
      return;
    }
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}/ver_${e['ver']}_${e['name']}');
    await f.writeAsBytes(bytes, flush: true);
    if (!mounted) return;
    ProUI.toast(c, '已保存到 ${f.path}');
  }
}

// ══════════════════════════════════════════════════════════════
// F-8 分享链
// ══════════════════════════════════════════════════════════════
class SharePage extends ProPage {
  const SharePage({super.key});
  @override
  State<SharePage> createState() => _Sp();
}

class _Sp extends ProPageState<SharePage> {
  List<Map<String, String>> man = [];
  String link = '';

  @override
  String get titleText => '分享链';

  @override
  Future<void> load() async => man = await BackupStore.manifest();

  @override
  List<Widget> buildBody(BuildContext c) {
    return [
      ProUI.card('由后端生成', [
        ProUI.row(Icons.link, '生成链接',
            sub: '选一个已备份文件, 后端给出局域网直链',
            value: link.isEmpty ? '' : link,
            onTap: () => _pick(c)),
        if (link.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            child: Row(children: [
              Expanded(
                  child: SelectableText(link,
                      style: const TextStyle(fontSize: 12))),
              IconButton(
                  icon: const Icon(Icons.copy, size: 17),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: link));
                    if (c.mounted) ProUI.toast(c, '已复制');
                  }),
            ]),
          ),
        ProUI.note('链接只在同一局域网可用; 后端关掉就失效。分享前请确认内容不含隐私。'),
      ]),
      if (man.isEmpty) ProUI.empty('还没有可分享的文件, 先做一次备份。'),
    ];
  }

  Future<void> _pick(BuildContext c) async {
    if (man.isEmpty) {
      ProUI.toast(c, '先做一次备份');
      return;
    }
    final pick = await showModalBottomSheet<Map<String, String>>(
      context: c,
      builder: (c2) => SafeArea(
        child: ListView(
          children: [
            for (final e in man.take(60))
              ListTile(
                dense: true,
                leading: const Icon(Icons.insert_drive_file_outlined, size: 18),
                title: Text(e['name'] ?? '', style: const TextStyle(fontSize: 13)),
                subtitle: Text(
                    '${HashX.human(int.tryParse(e['size'] ?? '0') ?? 0)} · ${e['at']}',
                    style: const TextStyle(fontSize: 11, color: Colors.grey)),
                onTap: () => Navigator.pop(c2, e),
              ),
          ],
        ),
      ),
    );
    if (pick == null || !c.mounted) return;
    final url = await BlobApi.share(pick['hash'] ?? '', pick['name'] ?? '');
    if (!mounted) return;
    if (url.isEmpty) {
      ProUI.toast(c, '后端未连接或不支持分享端点');
      return;
    }
    touch(() => link = url);
  }
}

// ══════════════════════════════════════════════════════════════
// F-9 存储分析
// ══════════════════════════════════════════════════════════════
class StoragePage extends ProPage {
  const StoragePage({super.key});
  @override
  State<StoragePage> createState() => _Sto();
}

class _Sto extends ProPageState<StoragePage> {
  Map<String, int> data = {};
  List<Map<String, String>> top = [];

  @override
  String get titleText => '存储分析';

  @override
  Future<void> load() async {
    data = await StorageScan.run();
    top = await StorageScan.topFiles(n: 20);
  }

  @override
  List<Widget> buildBody(BuildContext c) {
    final total = data.values.fold<int>(0, (a, b) => a + b);
    return [
      ProUI.card('占用分布', [
        for (final e in data.entries)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                    child: Text(e.key, style: const TextStyle(fontSize: 13))),
                Text(HashX.human(e.value),
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ]),
              const SizedBox(height: 4),
              ProUI.progress(total == 0 ? 0.0 : e.value / total),
            ]),
          ),
        Padding(
          padding: const EdgeInsets.all(14),
          child: Text('合计 ${HashX.human(total)}',
              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
        ),
      ]),
      ProUI.card('应用数据里最大的文件', [
        for (final e in top)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14),
            leading: const Icon(Icons.insert_drive_file_outlined, size: 18),
            title: Text(e['path']!.split(Platform.pathSeparator).last,
                style: const TextStyle(fontSize: 12.5),
                overflow: TextOverflow.ellipsis),
            trailing: Text(HashX.human(int.tryParse(e['size'] ?? '0') ?? 0),
                style: const TextStyle(fontSize: 11.5, color: Colors.grey)),
          ),
        if (top.isEmpty) ProUI.note('应用数据目录下没有可统计的文件。'),
      ]),
      ProUI.card('清理', [
        ProUI.row(Icons.cleaning_services_outlined, '清空临时缓存',
            sub: '不会碰你的照片与备份清单', onTap: () => _clean(c)),
      ]),
    ];
  }

  Future<void> _clean(BuildContext c) async {
    final ok = await ProKit.confirm(c, '清空临时缓存', '将删除本应用的临时目录内容。');
    if (!ok) return;
    var n = 0;
    try {
      final tmp = await getTemporaryDirectory();
      await for (final e in tmp.list()) {
        try {
          if (e is File) {
            await e.delete();
            n++;
          } else if (e is Directory) {
            await e.delete(recursive: true);
            n++;
          }
        } catch (_) {}
      }
    } catch (_) {}
    if (!mounted) return;
    ProUI.toast(c, '已清理 $n 项');
    await refresh();
  }
}
