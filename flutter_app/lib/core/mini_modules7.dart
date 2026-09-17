// 小模块做实第七批: 通讯录备份 / 短信备份(数据只存本地与自有资源库)
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ═══ 通讯录备份: 读取联系人 → 本地加密级存储(文件) + 恢复 ═══
class ContactsBackupPage extends StatefulWidget { const ContactsBackupPage({super.key}); @override State<ContactsBackupPage> createState() => _Cb(); }
class _Cb extends State<ContactsBackupPage> {
  List<Map<String, dynamic>> backups = []; // {file, count, ts}
  bool busy = false;
  String msg = '';

  @override void initState() { super.initState(); _load(); }
  Future<Directory> _dir() async {
    final ext = await getExternalStorageDirectory();
    final d = Directory('${ext!.path}/backups/contacts');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }
  Future<void> _load() async {
    final d = await _dir();
    final list = <Map<String, dynamic>>[];
    await for (final f in d.list()) {
      if (f is File && f.path.endsWith('.json')) {
        final st = await f.stat();
        list.add({'file': f.path, 'ts': st.modified.millisecondsSinceEpoch, 'size': st.size});
      }
    }
    list.sort((a, b) => (b['ts'] as int).compareTo(a['ts'] as int));
    setState(() => backups = list);
  }

  Future<void> _backup() async {
    setState(() { busy = true; msg = ''; });
    try {
      if (!await FlutterContacts.requestPermission()) throw Exception('需要通讯录权限');
      final contacts = await FlutterContacts.getContacts(withProperties: true);
      final data = [for (final ct in contacts) {
        'name': ct.displayName,
        'phones': [for (final p in ct.phones) p.number],
        'emails': [for (final e in ct.emails) e.address],
      }];
      final d = await _dir();
      final f = File('${d.path}/contacts-${DateTime.now().millisecondsSinceEpoch}.json');
      await f.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
      msg = '已备份 ${data.length} 位联系人';
      await _load();
    } catch (e) { msg = '备份失败: $e'; }
    setState(() => busy = false);
  }

  Future<void> _restore(Map b) async {
    final ok = await showDialog<bool>(context: context, builder: (c2) => AlertDialog(
      title: const Text('恢复通讯录'),
      content: const Text('将备份中的联系人写回手机通讯录(不会删除现有联系人)。继续?'),
      actions: [TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(c2, true), child: const Text('恢复'))]));
    if (ok != true) return;
    setState(() { busy = true; msg = ''; });
    try {
      if (!await FlutterContacts.requestPermission()) throw Exception('需要通讯录权限');
      final data = (jsonDecode(await File(b['file']).readAsString()) as List).cast<Map>();
      var n = 0;
      for (final e in data) {
        final ct = Contact()
          ..name.first = (e['name'] ?? '').toString()
          ..phones = [for (final p in (e['phones'] as List? ?? [])) Phone(p.toString())]
          ..emails = [for (final m in (e['emails'] as List? ?? [])) Email(m.toString())];
        await ct.insert();
        n++;
      }
      msg = '已恢复 $n 位联系人';
    } catch (e) { msg = '恢复失败: $e'; }
    setState(() => busy = false);
  }

  @override Widget build(BuildContext c) => ListView(padding: const EdgeInsets.all(12), children: [
    const Card(child: Padding(padding: EdgeInsets.all(12),
      child: Text('通讯录加密备份的规划是存到自有资源库; 当前版本先存本机应用目录(JSON), 换机可导出文件带走。\n数据不经过任何第三方服务器。',
        style: TextStyle(fontSize: 11, color: Colors.grey, height: 1.6)))),
    const SizedBox(height: 8),
    FilledButton.icon(icon: const Icon(Icons.backup_outlined, size: 18),
      label: Text(busy ? '处理中…' : '立即备份通讯录'), onPressed: busy ? null : _backup),
    if (msg.isNotEmpty) Padding(padding: const EdgeInsets.all(8),
      child: Text(msg, style: const TextStyle(fontSize: 12, color: Colors.teal))),
    const Padding(padding: EdgeInsets.fromLTRB(4, 14, 4, 6),
      child: Text('历史备份(点按恢复 · 长按删除)', style: TextStyle(fontSize: 12, color: Colors.grey))),
    if (backups.isEmpty) const Padding(padding: EdgeInsets.all(30),
      child: Center(child: Text('还没有备份', style: TextStyle(color: Colors.grey)))),
    for (final b in backups)
      Card(child: ListTile(dense: true,
        leading: const Icon(Icons.contacts_outlined, size: 20),
        title: Text(DateTime.fromMillisecondsSinceEpoch(b['ts']).toString().substring(0, 19),
          style: const TextStyle(fontSize: 13)),
        subtitle: Text('${((b['size'] ?? 0) / 1024).toStringAsFixed(1)} KB', style: const TextStyle(fontSize: 10, color: Colors.grey)),
        trailing: const Icon(Icons.restore, size: 18),
        onTap: () => _restore(b),
        onLongPress: () async {
          try { await File(b['file']).delete(); } catch (_) {}
          _load();
        })),
  ]);
}

// ═══ 短信备份: 读取收件箱 → 本地 JSON + 关键词搜索 + 验证码提取 ═══
class SmsBackupPage extends StatefulWidget { const SmsBackupPage({super.key}); @override State<SmsBackupPage> createState() => _Sms(); }
class _Sms extends State<SmsBackupPage> {
  List<Map<String, dynamic>> msgs = [];
  bool busy = false;
  String msg = '';
  String query = '';
  bool onlyOtp = false;

  Future<void> _loadSms() async {
    setState(() { busy = true; msg = ''; });
    try {
      final granted = await Permission.sms.request();
      if (!granted.isGranted) throw Exception('需要短信读取权限');
      const ch = MethodChannel('thirdhub/sms');
      final list = await ch.invokeMethod<List<dynamic>>('inbox', 2000);
      if (list == null) throw Exception('读取失败');
      msgs = [for (final m in list) {
        'from': (m as Map)['address']?.toString() ?? '', 'body': m['body']?.toString() ?? '',
        'ts': (m['date'] as num?)?.toInt() ?? 0,
      }];
      // 存本地备份文件
      final ext = await getExternalStorageDirectory();
      final d = Directory('${ext!.path}/backups/sms'); if (!await d.exists()) await d.create(recursive: true);
      await File('${d.path}/sms-${DateTime.now().millisecondsSinceEpoch}.json')
        .writeAsString(jsonEncode(msgs));
      msg = '已归档 ${msgs.length} 条短信';
      final p = await SharedPreferences.getInstance();
      await p.setInt('sms_last_backup', DateTime.now().millisecondsSinceEpoch);
    } catch (e) { msg = '读取失败: $e'; }
    setState(() => busy = false);
  }

  static String? _otp(String body) {
    final m = RegExp(r'(?:验证码|code|Code|CODE)[^\d]{0,6}(\d{4,8})').firstMatch(body);
    if (m != null) return m.group(1);
    final m2 = RegExp(r'(?<!\d)(\d{6})(?!\d)').firstMatch(body);
    return m2?.group(1);
  }

  @override Widget build(BuildContext c) {
    var shown = msgs;
    if (onlyOtp) shown = shown.where((e) => _otp(e['body'] ?? '') != null).toList();
    if (query.isNotEmpty) shown = shown.where((e) => '${e['from']}${e['body']}'.contains(query)).toList();
    return Column(children: [
      Padding(padding: const EdgeInsets.all(12), child: Column(children: [
        SizedBox(width: double.infinity, child: FilledButton.icon(
          icon: const Icon(Icons.backup_outlined, size: 18),
          label: Text(busy ? '读取中…' : '读取并归档短信'), onPressed: busy ? null : _loadSms)),
        if (msg.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6),
          child: Text(msg, style: const TextStyle(fontSize: 12, color: Colors.teal))),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(child: TextField(decoration: const InputDecoration(hintText: '关键词搜索…', isDense: true,
            border: OutlineInputBorder(), prefixIcon: Icon(Icons.search, size: 18)),
            onChanged: (v) => setState(() => query = v))),
          const SizedBox(width: 6),
          FilterChip(label: const Text('只看验证码', style: TextStyle(fontSize: 11)), selected: onlyOtp,
            onSelected: (v) => setState(() => onlyOtp = v)),
        ]),
      ])),
      Expanded(child: msgs.isEmpty
        ? const Center(child: Text('点上方按钮读取短信\n数据只存本机, 不上传', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)))
        : ListView.builder(itemCount: shown.length > 300 ? 300 : shown.length, itemBuilder: (_, i) {
            final e = shown[i];
            final otp = _otp(e['body'] ?? '');
            return ListTile(dense: true,
              leading: CircleAvatar(radius: 15, child: Text((e['from'] as String).isEmpty ? '?' : (e['from'] as String)[0],
                style: const TextStyle(fontSize: 11))),
              title: Text(e['from'] ?? '', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              subtitle: Text(e['body'] ?? '', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
              trailing: otp != null ? TextButton(child: Text(otp, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                onPressed: () { Clipboard.setData(ClipboardData(text: otp));
                  ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text('验证码 $otp 已复制'))); }) : null,
            );
          })),
    ]);
  }
}
