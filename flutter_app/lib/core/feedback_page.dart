// 反馈中心（D-07）：应用内反馈，替代跳 GitHub issues。
// 文字 + 图片(≤6张, 单张≤5MB) + 联系方式(可选) → 后端 POST /v1/feedback → data/feedback/ 落盘。
// 后端未连接时进"待发送"队列（SharedPreferences），连上后进入本页自动补发。
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart' show Api, Updater;

class FeedbackPage extends StatefulWidget {
  const FeedbackPage({super.key});
  @override
  State<FeedbackPage> createState() => _Fb();
}

class _Fb extends State<FeedbackPage> {
  final _text = TextEditingController();
  final _contact = TextEditingController();
  final List<File> _imgs = [];
  bool _sending = false;
  String _msg = '';
  bool _msgOk = false;
  int _outbox = 0;

  @override
  void initState() {
    super.initState();
    _loadOutbox();
  }

  Future<void> _loadOutbox() async {
    final p = await SharedPreferences.getInstance();
    _outbox = (jsonDecode(p.getString('fb_outbox') ?? '[]') as List).length;
    if (mounted) setState(() {});
    if (_outbox > 0 && Api.base.isNotEmpty) _flush();
  }

  Future<void> _flush() async {
    final p = await SharedPreferences.getInstance();
    final list = (jsonDecode(p.getString('fb_outbox') ?? '[]') as List).cast<Map<String, dynamic>>();
    final keep = <Map<String, dynamic>>[];
    var sent = 0;
    for (final it in list) {
      try {
        await Api.postEncrypted('/v1/feedback', it);
        sent++;
      } catch (_) {
        keep.add(it);
      }
    }
    await p.setString('fb_outbox', jsonEncode(keep));
    _outbox = keep.length;
    if (mounted && sent > 0) {
      setState(() {
        _msg = '已补发 $sent 条待发送反馈';
        _msgOk = true;
      });
    }
  }

  Future<void> _pick() async {
    final xs = await ImagePicker().pickMultiImage(maxWidth: 1600, imageQuality: 82);
    for (final x in xs) {
      if (_imgs.length >= 6) break;
      final f = File(x.path);
      if (await f.length() > 5 * 1048576) continue;
      _imgs.add(f);
    }
    if (mounted) setState(() {});
  }

  Future<void> _submit() async {
    final text = _text.text.trim();
    if (text.isEmpty) {
      setState(() {
        _msg = '先写点内容再提交';
        _msgOk = false;
      });
      return;
    }
    if (text.length > 8000) {
      setState(() {
        _msg = '内容太长了（≤8000 字）';
        _msgOk = false;
      });
      return;
    }
    setState(() {
      _sending = true;
      _msg = '';
    });
    final images = <String>[];
    for (final f in _imgs) {
      try {
        images.add(base64Encode(await f.readAsBytes()));
      } catch (_) {}
    }
    final payload = <String, dynamic>{
      'text': text,
      'contact': _contact.text.trim(),
      'images': images,
      'version': Updater.currentVersion,
      'device': Platform.operatingSystem,
    };
    try {
      if (Api.base.isEmpty) throw Exception('未连接后端');
      await Api.postEncrypted('/v1/feedback', payload);
      _text.clear();
      _contact.clear();
      _imgs.clear();
      setState(() {
        _msg = '已收到，感谢反馈！我们会在管理后台查看。';
        _msgOk = true;
      });
    } catch (e) {
      // 后端未连/网络失败 → 进待发送队列（图片不落盘只留路径不可靠，直接存 base64 进队列）
      final p = await SharedPreferences.getInstance();
      final list = (jsonDecode(p.getString('fb_outbox') ?? '[]') as List).cast<Map<String, dynamic>>();
      list.add(payload);
      await p.setString('fb_outbox', jsonEncode(list));
      _outbox = list.length;
      setState(() {
        _msg = '当前未连接后端，已存为待发送（连上后端后自动补发）';
        _msgOk = false;
      });
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext c) {
    final cs = Theme.of(c).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('反馈中心')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (_outbox > 0)
          Card(
            color: cs.secondaryContainer,
            child: ListTile(
              leading: Icon(Icons.schedule, color: cs.onSecondaryContainer),
              title: Text('$_outbox 条反馈待发送', style: TextStyle(color: cs.onSecondaryContainer)),
              subtitle: Text('连接后端后自动补发',
                  style: TextStyle(fontSize: 12, color: cs.onSecondaryContainer.withValues(alpha: 0.7))),
              trailing: Api.base.isNotEmpty
                  ? TextButton(onPressed: _flush, child: const Text('立即补发'))
                  : null,
            ),
          ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('遇到了什么问题？有什么建议？', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              TextField(
                controller: _text,
                maxLines: 6,
                maxLength: 8000,
                decoration: InputDecoration(
                  hintText: '尽量说清楚：哪个模块、做了什么、期望怎样、实际怎样',
                  isDense: true,
                  filled: true,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                ),
              ),
            ]),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Text('截图（可选，最多 6 张）', style: TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                TextButton.icon(
                    icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
                    label: const Text('添加图片'),
                    onPressed: _pick),
              ]),
              if (_imgs.isNotEmpty)
                SizedBox(
                  height: 84,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _imgs.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (_, i) => Stack(children: [
                      ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.file(_imgs[i], width: 84, height: 84, fit: BoxFit.cover)),
                      Positioned(
                        right: 2,
                        top: 2,
                        child: GestureDetector(
                          onTap: () => setState(() => _imgs.removeAt(i)),
                          child: Container(
                            decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                            padding: const EdgeInsets.all(2),
                            child: const Icon(Icons.close, size: 14, color: Colors.white),
                          ),
                        ),
                      ),
                    ]),
                  ),
                ),
            ]),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _contact,
              decoration: InputDecoration(
                labelText: '联系方式（可选，方便回访）',
                hintText: 'QQ / 邮箱 / 都行',
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (_msg.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(children: [
              Icon(_msgOk ? Icons.check_circle : Icons.info_outline,
                  size: 18, color: _msgOk ? Colors.green : cs.error),
              const SizedBox(width: 6),
              Expanded(
                  child: Text(_msg,
                      style: TextStyle(fontSize: 13, color: _msgOk ? Colors.green : cs.error))),
            ]),
          ),
        FilledButton.icon(
          onPressed: _sending ? null : _submit,
          icon: _sending
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.send),
          label: Text(_sending ? '发送中…' : '提交反馈'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        ),
        const SizedBox(height: 8),
        const Text('反馈只发给你自己的后端，不经任何第三方服务器。图片随文字一起存储在后端 data/feedback/。',
            style: TextStyle(fontSize: 11, color: Colors.grey)),
      ]),
    );
  }
}
