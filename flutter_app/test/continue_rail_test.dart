// 「继续上次」数据层的边界测试。
//
// 只测纯函数（RecentEntry 的解析与派生），不测 Widget：
// 组件依赖 SharedPreferences 与帧调度，放在这里跑会让 CI 不稳定
// （见 MEMORY 里的教训：widget 测试别直接挂真实帧调度）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thirdhub_app/core/continue_rail.dart';

void main() {
  group('RecentEntry.fromMap', () {
    test('完整记录逐字段解析', () {
      final e = RecentEntry.fromMap(const {
        'kind': 'video',
        'title': '  测试影片  ',
        'sub': ' 第 3 集 ',
        'target': '/media/a.mp4',
        'at': '2026-11-21T10:00',
      });
      expect(e.kind, 'video');
      expect(e.title, '测试影片', reason: '标题必须去掉首尾空白');
      expect(e.sub, '第 3 集');
      expect(e.target, '/media/a.mp4');
      expect(e.at, '2026-11-21T10:00');
      expect(e.hasTarget, isTrue);
    });

    test('缺字段不抛异常，一律降级为空串', () {
      final e = RecentEntry.fromMap(const {});
      expect(e.kind, '');
      expect(e.title, '');
      expect(e.sub, '');
      expect(e.target, '');
      expect(e.at, '');
      expect(e.hasTarget, isFalse);
      expect(e.caption, '', reason: '没有副标题也没有时间时，角标行应为空而不是 null');
    });

    test('hasTarget 决定"能不能真续播"', () {
      const withTarget = RecentEntry(
          kind: 'music', title: 'x', sub: '', target: 'http://a/b.mp3', at: '');
      const noTarget = RecentEntry(
          kind: 'audiobook', title: 'y', sub: '', target: '', at: '');
      expect(withTarget.hasTarget, isTrue);
      expect(noTarget.hasTarget, isFalse);
    });

    test('caption 优先副标题，副标题为空才回落时间', () {
      const a = RecentEntry(kind: 'music', title: 't', sub: '周杰伦', target: '', at: '10:00');
      const b = RecentEntry(kind: 'music', title: 't', sub: '', target: '', at: '10:00');
      expect(a.caption, '周杰伦');
      expect(b.caption, '10:00');
    });
  });

  group('kind → 图标', () {
    test('四种已知类型的图标互不相同（防止复制粘贴写重）', () {
      const icons = <String, IconData>{
        'music': Icons.music_note,
        'video': Icons.play_circle_outline,
        'audiobook': Icons.headphones,
        'radio': Icons.radio,
      };
      final mapped = [
        for (final k in icons.keys)
          RecentEntry(kind: k, title: 't', sub: '', target: '', at: '').icon
      ];
      expect(mapped.toSet().length, icons.length);
    });

    test('未知类型回落到通用播放图标，而不是崩溃或空白', () {
      const e = RecentEntry(kind: 'unknown', title: 't', sub: '', target: '', at: '');
      expect(e.icon, Icons.play_arrow);
    });
  });
}
