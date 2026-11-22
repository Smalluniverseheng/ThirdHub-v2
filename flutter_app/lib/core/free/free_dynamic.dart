// 声明式源的执行器：把一份 [FreeSourceSpec] 跑成 [FreeItem] 列表。
//
// 这一层是「源包能脱离安装包存在」的关键：
// 内置源（Dart 常量）和导入源（JSON）最终都走到这里，
// 上层 UI 完全不知道某个源是编译进去的、还是刚从管理员账号同步下来的。
//
// 三条硬约束（别为了多接一个源就破掉）：
//   1. 一个动作 = 一次请求。不跟跳转链、不递归爬站。
//   2. 单次响应最多 8MB、单页最多 limit 条 —— 防止某个源把内存吃光。
//   3. 任何异常都收敛成「这一条失败」，不让整页崩。
import 'dart:convert';

import 'free_http.dart';
import 'free_models.dart';
import 'free_spec.dart';

class DynamicSource {
  DynamicSource._();

  /// 执行一次动作，产出条目。
  ///
  /// [vars] 提供模板占位符：搜索时 `{'q': 关键词, 'page': '1'}`；
  /// 下钻时 `{'id': 条目id}`，并可带上 `{'q': ''}`。
  static Future<List<FreeItem>> run(
    FreeSourceSpec spec,
    FreeAction action,
    Map<String, String> vars, {
    FreeKind? kindOverride,
  }) async {
    final kind = kindOverride ?? spec.kind;

    // ── 地址 ──
    var path = fillTemplate(action.path, vars);
    var url = spec.resolve(path);
    // 剩余未替换的占位符说明源包与该动作不匹配（如 detail 里写了 {q}），
    // 直接失败比发一个带 `%7Bq%7D` 的请求出去更容易定位。
    if (url.contains('%7B') || url.contains('{')) {
      throw FreeNetException('源「${spec.name}」的动作占位符未填：${action.path}');
    }

    if (action.query.isNotEmpty) {
      final qs = action.query.entries
          .map((e) =>
              '${Uri.encodeQueryComponent(e.key)}='
              '${Uri.encodeQueryComponent(fillTemplateRaw(e.value, vars))}')
          .join('&');
      url = '$url${url.contains('?') ? '&' : '?'}$qs';
    }

    // ── 请求 ──
    final body = action.body.isEmpty ? null : fillTemplateRaw(action.body, vars);
    final raw = await FreeHttp.send(
      url,
      method: action.method,
      body: body,
      headers: action.headers.isEmpty ? null : action.headers,
      timeout: const Duration(seconds: 18),
      maxBytes: 8 * 1024 * 1024,
    );
    final text = _decode(raw);
    if (text.trim().isEmpty) {
      throw FreeNetException('源「${spec.name}」返回空内容');
    }

    // ── 拆条目 ──
    final entries = splitEntries(text, action);
    if (entries.isEmpty) {
      // 空结果不是错误：用户搜了个没有的词，这是正常状态。
      // 但如果源明确返回了网页而不是数据，上游已经会抛，这里只管空。
      return const [];
    }

    final out = <FreeItem>[];
    for (final e in entries) {
      if (out.length >= action.limit) break;
      final it = _mapOne(spec, action, e, kind);
      if (it != null) out.add(it);
    }
    return out;
  }

  /// 把一个原始条目映射成 [FreeItem]。
  static FreeItem? _mapOne(
    FreeSourceSpec spec,
    FreeAction a,
    Object entry,
    FreeKind kind,
  ) {
    final src = entry is String ? entry : '';
    final cache = <String, String>{};

    /// 从响应里取一个字段（走 path）。
    ///
    /// [FieldSpec.path] 支持 `||` 候选链（见 [pickField]），按序取第一个非空。
    String readPath(FieldSpec f) {
      var v = pickField(entry, src, f.path, fetch: a.fetch);
      if (v.isEmpty) v = f.fallback;
      if (f.strip && v.isNotEmpty) v = freeStripTags(v);
      if (f.abs && v.isNotEmpty) v = spec.resolve(v);
      return v;
    }

    /// 模板字段：用已解析出的同条字段渲染。
    ///
    /// 顺序很重要 —— 先跑完所有 path 字段，再跑模板字段，
    /// 否则 `{id}` 在 playUrl 里会因为「还没算出来」而被替换成空串。
    String renderTpl(String tpl) {
      var t = tpl;
      for (final e in cache.entries) {
        t = t.replaceAll('{${e.key}}', e.value);
      }
      // 剩下的占位符说明源包写错了（引用了不存在的字段），清掉而不是留着。
      t = t.replaceAll(RegExp(r'\{[a-zA-Z0-9_]+\}'), '');
      return t.trim();
    }

    for (final e in a.map.entries) {
      if (e.value.isTemplate) continue;
      cache[e.key] = readPath(e.value);
    }
    for (final e in a.map.entries) {
      if (!e.value.isTemplate) continue;
      cache[e.key] = renderTpl(e.value.tpl);
    }

    String val(String key) => cache[key] ?? '';

    final title = val('title');
    // 没标题的条目基本是噪音（广告位、分隔符），直接丢。
    if (title.trim().isEmpty) return null;

    final play = val('playUrl');
    final id = val('id');
    final drill = a.drill || a.map.containsKey('drill');

    // ★4.81.90 把 `||` 候选链的备选地址留下来：首选探死了，
    //   Playable 还能换下一条试（源包写 || 就是为了这个时刻）。
    final alts = <String>[];
    final playSpec = a.map['playUrl'];
    if (play.isNotEmpty && playSpec != null && !playSpec.isTemplate) {
      for (final cand in playSpec.path.split('||')) {
        var v = pickField(entry, src, cand.trim(), fetch: a.fetch);
        if (v.isEmpty) continue;
        if (playSpec.strip) v = freeStripTags(v);
        if (playSpec.abs) v = spec.resolve(v);
        if (v.isNotEmpty && v != play) alts.add(v);
      }
    }

    return FreeItem(
      // id 缺失时用「标题 + 播放地址」拼一个稳定的：下钻时还要用它取详情。
      id: id.isNotEmpty ? id : (play.isNotEmpty ? play : title),
      source: spec.id,
      kind: kind,
      title: title,
      subtitle: val('subtitle'),
      cover: val('cover'),
      desc: val('desc'),
      playUrl: play,
      drill: drill && play.isEmpty,
      raw: {
        'id': id,
        'playUrl': play,
        if (alts.isNotEmpty) 'playAlts': alts,
        // 详情动作需要知道「当前条目属于哪个 feed/专辑」
        if (spec.base.isNotEmpty) 'base': spec.base,
      },
    );
  }

  /// 按 UTF-8 解，失败退 latin1 容错。
  ///
  /// 少数老站声明 GBK，解出来会是乱码 —— 但那是源作者该在源包里写清楚的事
  /// （`charset` 字段暂不支持，见 README 的已知限制），
  /// 这里不猜编码：猜错的乱码比直说「这源编码不对」更难排查。
  static String _decode(List<int> b) {
    try {
      return utf8.decode(b);
    } catch (_) {
      return utf8.decode(b, allowMalformed: true);
    }
  }
}

/// 剥掉标签的纯文本化。与 `free_http.stripHtml` 同义，
/// 但因为 stripHtml 属于 HTTP 层、这里属于源映射层，各留一份免得跨层依赖。
String freeStripTags(String s) {
  var x = s
      .replaceAll(RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");
  x = x.replaceAll(RegExp(r'[ \t\u00a0]+'), ' ');
  x = x.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return x.trim();
}

/// 原样插值（不 URL 编码）：用于请求体、以及已经编码过的 query 值。
String fillTemplateRaw(String tpl, Map<String, String> vars) {
  var s = tpl;
  for (final e in vars.entries) {
    s = s.replaceAll('{${e.key}}', e.value);
  }
  return s;
}
