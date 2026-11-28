// 相册重做 + B站清晰度/预取的接线闸门（4.81.121）
//
// 为什么要有：这两处都是「看不见的接线 bug」——
//   · 相册只做一个 4 列网格就不会有时线/收藏/多选，用户说"难看"其实是没层级；
//   · DASH 播放器把清晰度画成一块死牌、列表卡没接 onLongPress，代码看着有功能，
//     用户按下却什么都不会发生。这类 bug 不报错、不崩，只能靠断言钉住。
import 'dart:io';

int pass = 0, fail = 0;
void ok(String name, bool cond) {
  if (cond) {
    pass++;
  } else {
    fail++;
    print('  FAIL $name');
  }
}

String read(String p) {
  final f = File(p);
  return f.existsSync() ? f.readAsStringSync() : '';
}

void main() {
  final base = Directory('lib').existsSync() ? '' : 'flutter_app/';
  final gallery = read('${base}lib/core/gallery_page.dart');
  final dash = read('${base}lib/core/bili_dash_player.dart');
  final video = read('${base}lib/core/bili_video_page.dart');
  final home = read('${base}lib/core/bili_home_page.dart');

  print('== 1. 相册四视图 ==');
  ok('TabController 长度 4', gallery.contains('TabController(length: 4'));
  for (final tab in ['相册', '照片', '时间线', '收藏']) {
    ok('有 $tab 视图', gallery.contains("Tab(text: tr('$tab'))"));
  }
  print('== 2. 相册操作 ==');
  ok('长按多选', gallery.contains('onLongPress:'));
  ok('多选删除', gallery.contains('_deleteSelected'));
  ok('收藏切换', gallery.contains('_favorite(') && gallery.contains('gallery_favs'));
  ok('按月分组时间线', gallery.contains('d.year') && gallery.contains('d.month'));
  ok('大图双击缩放', gallery.contains('InteractiveViewer(') && gallery.contains('maxScale: 5'));
  ok('排序菜单', gallery.contains('_openSortMenu'));
  ok('搜索', gallery.contains('_queryC'));

  print('== 3. B站清晰度 ==');
  ok('DASH 有 acceptQuality 参数', dash.contains('this.acceptQuality = const [80]'));
  ok('清晰度按钮可点', dash.contains('onTap: () => _pickQuality(context)'));
  ok('选择后回传 qn', dash.contains('Navigator.pop(c, v)'));
  ok('详情页接收 qn', video.contains('Future<void> _play(int idx, {int qn = 0})'));
  ok('带 qn 重新取流', video.contains(r"q.write('&qn=$qn')"));
  ok('重播用选中的清晰度', video.contains('_play(idx, qn: picked)'));
  ok('可用清晰度来自后端', video.contains("j?['acceptQuality'] as List?"));

  print('== 4. B站预取 ==');
  ok('有预取缓存', video.contains('static final Map<String, ({Map<String, dynamic> data, int at})> _prefetch'));
  ok('缓存 2 分钟', video.contains('Duration(minutes: 2)'));
  ok('命中缓存跳过 playurl', video.contains('? cached.data'));
  ok('列表长按触发预取', home.contains('onLongPress:'));
  ok('调用 prefetch', home.contains('BiliVideoPage.prefetch(widget.ctx, it)'));

  print('\n$pass 通过 / $fail 失败');
  if (fail > 0) exit(1);
}
