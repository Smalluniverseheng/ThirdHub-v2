// ThirdHub 社区云端同步（IO）：`community_posts` / `community_comments`。
//
// ★ 为什么需要这个文件（这是本轮核实出来的真实断层）：
//   App 的「社区」页把帖子存在 SharedPreferences 的 `community_posts` 键里，
//   而网页端读写的是 Supabase 的 `community_posts` **表**（全局公开信息流）。
//   **同名不同物** —— 手机上发的帖，网页端永远看不到；网页端 100 条热帖，
//   手机上一条也刷不出来。看起来"两边都有社区"，实际上是两个孤岛。
//
// 字段契约（照抄网页端 js/modules/community.js）：
//   posts:    user_id / nickname / avatar / category / content / likes / created_at
//   comments: post_id / user_id / avatar / nickname / content / created_at
// 映射函数在 `sync_contract.dart`（纯逻辑，有闸门），这里只负责收发。

import 'package:shared_preferences/shared_preferences.dart';

import 'cloud.dart';
import 'lab_logic.dart';
import 'sync_contract.dart';

class CommunitySync {
  static bool get enabled => Cloud.loggedIn;

  /// 发表时用的昵称/头像：与网页端一致（`me.nickname || me.email`）。
  static String get myName {
    final Object? n = Cloud.profileData['nickname'];
    final String nick = n == null ? '' : '$n'.trim();
    if (nick.isNotEmpty) return nick;
    return Cloud.email.isEmpty ? 'TH 用户' : Cloud.email.split('@').first;
  }

  static String get myAvatar => '${Cloud.profileData['avatar'] ?? ''}';

  /// 云端行 → App 的 [CommunityPost]。
  static CommunityPost fromCloud(Map<String, dynamic> r) {
    final String content = '${r['content'] ?? ''}';
    final String cat = '${r['category'] ?? ''}'.trim();
    return CommunityPost(
      id: '${r['id'] ?? ''}',
      title: postTitleOfContent(content),
      body: postBodyOfContent(content),
      kind: cat.isEmpty ? '心得' : cat,
      tags: postTagsOfContent(content),
      ts: tsOfIso('${r['created_at'] ?? ''}'),
      likes: (r['likes'] as num?)?.toInt() ?? 0,
      cloud: true,
      author: '${r['nickname'] ?? ''}'.trim(),
    );
  }

  /// 拉云端信息流（公开可读，按时间倒序，最多 [limit] 条）。
  static Future<List<CommunityPost>> feed({int limit = 40}) async {
    if (!enabled) return const <CommunityPost>[];
    final List<Map<String, dynamic>> rows = await Cloud.rowDown(
      'community_posts',
      query: 'select=*&order=created_at.desc',
      limit: limit,
    );
    return <CommunityPost>[
      for (final Map<String, dynamic> r in rows)
        if ('${r['id'] ?? ''}'.isNotEmpty) fromCloud(r)
    ];
  }

  /// 发帖。`content` 由标题+正文+#标签拼成一行（云端没有 title 列）。
  static Future<bool> publish(CommunityPost p) async {
    if (!enabled) return false;
    return Cloud.rowUp('community_posts', <String, dynamic>{
      'user_id': Cloud.userId,
      'nickname': myName,
      'avatar': myAvatar,
      'category': p.kind,
      'content': cloudContentOfPost(title: p.title, body: p.body, tags: p.tags),
      'likes': p.likes,
    });
  }

  /// 点赞数同步（整行覆盖成新值；RLS 允许本人写，别人的帖子会被拒 → 返回 false）。
  static Future<bool> setLikes(String id, int likes) =>
      enabled ? Cloud.rowPatch('community_posts', id, <String, dynamic>{'likes': likes < 0 ? 0 : likes}) : Future<bool>.value(false);

  /// 删帖（只有自己的能删；RLS 会拒绝别人的）。
  static Future<bool> remove(String id) =>
      enabled ? Cloud.rowDelete('community_posts', id) : Future<bool>.value(false);

  /// 某帖的评论（时间正序）。
  static Future<List<Map<String, dynamic>>> comments(String postId) async {
    if (!enabled || postId.isEmpty) return const <Map<String, dynamic>>[];
    return Cloud.rowDown(
      'community_comments',
      query: 'select=*&post_id=eq.${Uri.encodeQueryComponent(postId)}&order=created_at.asc',
      limit: 100,
    );
  }

  /// 发评论。
  static Future<bool> addComment(String postId, String text) async {
    final String t = text.trim();
    if (!enabled || postId.isEmpty || t.isEmpty) return false;
    return Cloud.rowUp('community_comments', <String, dynamic>{
      'post_id': postId,
      'user_id': Cloud.userId,
      'nickname': myName,
      'avatar': myAvatar,
      'content': t,
    });
  }

  /// 上次成功拉取云端信息流的时刻（界面上标"云端 · 刚刚"，也用于避免频繁拉取）。
  static const String _lastKey = 'community_cloud_at';
  static Future<int> lastPulledAt() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    return p.getInt(_lastKey) ?? 0;
  }

  static Future<void> markPulled() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setInt(_lastKey, DateTime.now().millisecondsSinceEpoch);
  }
}
