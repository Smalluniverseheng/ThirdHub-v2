// ThirdHub v4 轻量 i18n: 中文为key, 切换语言全树立即重建
// 用法: tr('搜索') —— 字典缺失时回落原文(中文)
// 语言: zh/en/ja 完整; fr/ru/es/ar 核心词(逐步补全)
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

class I18n extends ChangeNotifier {
  static final I18n instance = I18n._();
  I18n._();
  String locale = 'zh';
  static const supported = ['zh', 'en', 'ja', 'fr', 'ru', 'es', 'ar'];
  static const names = {'zh': '中文', 'en': 'English', 'ja': '日本語', 'fr': 'Français', 'ru': 'Русский', 'es': 'Español', 'ar': 'العربية'};

  Future<void> setLocale(String l) async { locale = l; notifyListeners(); }

  // system → 系统语言映射(默认中文;  unsupported→en)
  static String resolve(String l) {
    if (l != 'system') return l;
    try {
      final code = WidgetsBinding.instance.platformDispatcher.locale.languageCode;
      if (code == 'zh') return 'zh';
      return supported.contains(code) ? code : 'en';
    } catch (_) { return 'zh'; }
  }

  static final Map<String, Map<String, String>> dict = {
    'en': {
      '搜索': 'Search', '书架': 'Shelf', '小说': 'Novels', '漫画': 'Comics', '视频': 'Videos',
      '音乐': 'Music', '资源库': 'Library Hub', '我的': 'Me', '后端': 'Backend',
      '源': 'Sources', '导入': 'Import', '取消': 'Cancel', '保存': 'Save', '确定': 'OK',
      '完成': 'Done', '错误': 'Error', '全部': 'All',
      '上一章': 'Prev', '下一章': 'Next', '上一话': 'Prev', '下一话': 'Next',
      '上一集': 'Prev ep', '下一集': 'Next ep', '继续阅读': 'Continue reading',
      '已加入书架': 'Added to shelf', '已同步': 'Synced',
      '主题外观': 'Theme', '强调色': 'Accent color', '开屏动画': 'Splash animation',
      '深色': 'Dark', '浅色': 'Light', '跟随系统': 'System',
      '悬浮球默认位置': 'Orb default side', '左侧': 'Left', '右侧': 'Right',
      '连接器管理': 'Connectors', '贤者模式（内容保护）': 'Sage mode (content lock)',
      '清理缓存': 'Clear cache', '已清理': 'Cleared', '版本与更新': 'Version & updates',
      '云存储': 'Cloud storage', '会员等级': 'Membership', '云端同步': 'Cloud sync',
      '阅读进度': 'Reading progress', '阅读设置': 'Reader', '字号': 'Font size',
      '阅读主题': 'Reader theme', '翻页模式': 'Page mode', '滚动': 'Scroll', '分页(开发中)': 'Paged (WIP)',
      '昵称': 'Nickname', '简介': 'Bio', '身份码': 'Identity code', '个人资料': 'Profile',
      '应用锁': 'App lock', '已锁定': 'Locked', '密码错误': 'Wrong PIN', '跳过': 'Skip',
      '下一页': 'Next', '开始连接': 'Get started', '连接资源库': 'Connect library hub',
      '资源库地址': 'Hub address', '密钥': 'Key', '连接中…': 'Connecting…',
      '设置PIN(4-6位)': 'Set PIN (4-6 digits)', '已开启': 'On', '已关闭': 'Off',
      '这个人很懒，什么都没写': 'This person is too lazy to write anything',
      '在线': 'online', '离线': 'offline', '待机': 'standby', '故障': 'error',
      '使用指南': 'User guide', '开源致谢': 'Open source credits',
      '历史': 'History', '发现': 'Discover', '片库': 'Library', '歌单': 'Playlist',
      '直播': 'Live', '浏览器': 'Browser', '引擎直连': 'Direct engine', '连接': 'Connect',
      '断开': 'Disconnect', '未连接引擎': 'No engine connected', '去连接引擎': 'Connect engine',
      '发现页需要先连接引擎': 'Connect an engine to use Discover',
      '排行榜': 'Rankings', '联网搜索': 'Web search', '厂商与密钥': 'Providers & keys',
      '自动识别 Key': 'Auto-identify key', '中转站 Key': 'Relay key', '自定义厂商': 'Custom provider',
      '加载中': 'Loading', '暂无任务': 'No tasks', '书源': 'Book sources',
      '影视源': 'Video sources', '图源': 'Comic sources', '音源': 'Music sources',
      '搜索测试': 'Search test', '导出全部(JSON备份)': 'Export all (JSON backup)',
      '已添加下载': 'Download added', '选集': 'Episodes', '歌单': 'Playlist',
      '选照片同步': 'Sync photos', '已同步': 'Synced',
      '存储服务': 'Storage services', '下载任务': 'Downloads', '网盘': 'Cloud disk',
      '引擎': 'Engines', '导航': 'Navigation', '底部导航栏': 'Bottom navigation', '回收站': 'Recycle bin', '网络引擎(局域网设备)': 'Network engines (LAN devices)',
      '内置引擎': 'Built-in engines', '能力': 'Capabilities',
    },
    'ja': {
      '搜索': '検索', '书架': '本棚', '小说': '小説', '漫画': '漫画', '视频': '動画',
      '音乐': '音楽', '资源库': 'ライブラリ', '我的': 'マイ', '后端': 'バックエンド',
      '源': 'ソース', '导入': 'インポート', '取消': 'キャンセル', '保存': '保存', '确定': 'OK',
      '完成': '完了', '错误': 'エラー', '全部': 'すべて',
      '上一章': '前へ', '下一章': '次へ', '上一话': '前へ', '下一话': '次へ',
      '继续阅读': '続きを読む', '已加入书架': '本棚に追加',
      '主题外观': 'テーマ', '深色': 'ダーク', '浅色': 'ライト', '跟随系统': 'システム',
      '字号': '文字サイズ', '阅读主题': '阅读テーマ', '翻页模式': 'ページめくり', '滚动': 'スクロール',
      '昵称': 'ニックネーム', '简介': '自己紹介', '应用锁': 'アプリロック',
      '在线': 'オンライン', '离线': 'オフライン', '底部导航栏': '下部ナビ', '书源': '書籍ソース', '图源': '漫画ソース',
    },
    // fr/ru/es/ar: 核心词逐步补全(缺失回落中文)
    'fr': { '搜索': 'Rechercher', '书架': 'Bibliothèque', '漫画': 'BD', '视频': 'Vidéos', '音乐': 'Musique', '我的': 'Moi', '取消': 'Annuler', '保存': 'Sauver' },
    'ru': { '搜索': 'Поиск', '书架': 'Полка', '漫画': 'Комиксы', '视频': 'Видео', '音乐': 'Музыка', '我的': 'Я', '取消': 'Отмена', '保存': 'Сохранить' },
    'es': { '搜索': 'Buscar', '书架': 'Estantería', '漫画': 'Cómics', '视频': 'Vídeos', '音乐': 'Música', '我的': 'Yo', '取消': 'Cancelar', '保存': 'Guardar' },
    'ar': { '搜索': 'بحث', '书架': 'الرف', '漫画': 'مانغا', '视频': 'فيديو', '音乐': 'موسيقى', '我的': 'أنا', '取消': 'إلغاء', '保存': 'حفظ' },
  };

  static String tr(String zh) => dict[instance.locale]?[zh] ?? zh;
}

String tr(String s) => I18n.tr(s);
