// 源包（Bundle）：一份可以整包导入/导出/同步的源集合。
//
// ── 为什么要有「包」这一层，而不是一个个源单独存 ─────────────────
// 用户实际拿到的是一份文件（.json）或一个链接，里面往往有几十个源。
// 如果按源粒度存，就会出现「导入一半失败」「删了不知道剩几个」这类问题。
// 包是**原子单位**：整包校验、整包落盘、整包卸载。
//
// ── 格式（schema = 1）─────────────────────────────────────────
// {
//   "schema": 1,
//   "name": "我的扩展源",
//   "version": "2026.11.21",
//   "note": "给家里人用的",
//   "sources": [ { ...FreeSourceSpec... } ]
// }
//
// 单个源也可以直接当包导入（sources 只有一项时可省略外层包装）。
import 'dart:convert';

import 'free_models.dart';
import 'free_spec.dart';

class FreeSourceBundle {
  final int schema;
  final String name;
  final String version;
  final String note;
  final List<FreeSourceSpec> sources;

  /// 从哪来（内置/管理员同步/用户导入）。导入时由调用方给定，不从文件读。
  final SourceOrigin origin;

  /// 导入时间。用于设置页显示「上次同步」。
  final DateTime? importedAt;

  const FreeSourceBundle({
    required this.name,
    required this.sources,
    this.schema = kFreeSpecSchema,
    this.version = '',
    this.note = '',
    this.origin = SourceOrigin.user,
    this.importedAt,
  });

  int get count => sources.length;

  Map<String, dynamic> toJson() => {
        'schema': schema,
        'name': name,
        if (version.isNotEmpty) 'version': version,
        if (note.isNotEmpty) 'note': note,
        'sources': [for (final s in sources) s.toJson()],
      };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// 解析结果：包本体 + 逐个源的问题清单。
  ///
  /// 刻意**不因个别源出错就整包失败** —— 用户拿到的源包质量参差，
  /// 能用的先用起来，坏的在设置页标出来让他自己决定删不删。
  static BundleParse parse(String raw, {SourceOrigin origin = SourceOrigin.user}) {
    dynamic d;
    try {
      d = jsonDecode(raw);
    } catch (e) {
      return BundleParse.error('不是合法的 JSON：${_brief(e)}');
    }

    // 允许「单个源」直接当包。
    if (d is Map && d['sources'] == null && d['search'] != null) {
      d = {
        'schema': kFreeSpecSchema,
        'name': '${d['name'] ?? '单个源'}',
        'sources': [d]
      };
    }

    if (d is! Map) return BundleParse.error('顶层必须是对象');
    final sc = d['schema'];
    final schema = sc is num ? sc.toInt() : kFreeSpecSchema;
    if (schema > kFreeSpecSchema) {
      return BundleParse.error('源包版本 $schema 比当前 App 支持的'
          ' $kFreeSpecSchema 更新，请先升级 App');
    }

    final rawList = d['sources'];
    if (rawList is! List || rawList.isEmpty) {
      return BundleParse.error('sources 为空');
    }

    final ok = <FreeSourceSpec>[];
    final bad = <String>[];
    final seen = <String>{};
    for (final e in rawList) {
      final s = FreeSourceSpec.parse(e, origin: origin);
      if (s == null) {
        bad.add('一个源缺少 id / kind，已跳过');
        continue;
      }
      final errs = s.validate();
      if (errs.isNotEmpty) {
        bad.add('${s.name}（${s.id}）：${errs.first}');
        continue;
      }
      if (!seen.add(s.id)) {
        bad.add('${s.name}：id 重复（${s.id}）');
        continue;
      }
      ok.add(s);
    }
    if (ok.isEmpty) {
      return BundleParse.error(bad.isEmpty ? '没有可用源' : bad.first);
    }

    return BundleParse(
      FreeSourceBundle(
        name: '${d['name'] ?? '未命名源包'}'.trim(),
        version: '${d['version'] ?? ''}'.trim(),
        note: '${d['note'] ?? ''}'.trim(),
        schema: schema,
        sources: ok,
        origin: origin,
        importedAt: DateTime.now(),
      ),
      bad,
    );
  }

  static String _brief(Object e) {
    final s = '$e';
    return s.length > 60 ? '${s.substring(0, 60)}…' : s;
  }
}

/// 解析结果。[error] 非空表示整包不可用。
class BundleParse {
  final FreeSourceBundle? bundle;
  final String error;

  /// 逐个源的问题（不影响整包可用）。
  final List<String> warnings;

  const BundleParse(this.bundle, this.warnings) : error = '';

  const BundleParse.error(this.error)
      : bundle = null,
        warnings = const [];

  bool get ok => bundle != null;
}
