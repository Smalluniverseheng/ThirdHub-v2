// ThirdHub v4 轻量 i18n: 中文为key, 切换语言全树立即重建
// 用法: tr('搜索')
//
// ★ 第十五轮改动（在此之前这里是「假完成」）：
//   旧注释写「zh/en/ja 完整; fr/ru/es/ar 核心词(逐步补全)」，而实际是
//   **fr/ru/es/ar 每语言只有 8 个词**（只有模块名旁边那几句），缺词回落中文 ——
//   于是切到法语/俄语/西语/阿语，屏幕上除少数几个词以外**全是中文**。
//   现在改成：
//     ① 译文集中在 `i18n_extra.dart`（fr/ru/es/ar 各 186 条，与 en 的键集逐条对齐），
//        在这里合并进来 —— 不动下面那个大 literal，避免碰坏既有 5 种语言；
//     ② 查找链改成 **当前语言 → 英文 → 中文原文**。加「英文」这一跳之后，
//        以后新增中文 key 即使忘了补译文，最差也只是显示英文，
//        不会再出现"选了外语还是满屏中文"的割裂感。
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'i18n_extra.dart';

class I18n extends ChangeNotifier {
  static final I18n instance = I18n._();
  I18n._();
  String locale = 'zh';
  static const supported = ['zh', 'en', 'ja', 'fr', 'ru', 'es', 'ar'];
  static const names = {
    'zh': '中文',
    'en': 'English',
    'ja': '日本語',
    'fr': 'Français',
    'ru': 'Русский',
    'es': 'Español',
    'ar': 'العربية'
  };

  Future<void> setLocale(String l) async {
    locale = l;
    notifyListeners();
  }

  // system → 系统语言映射(默认中文;  unsupported→en)
  static String resolve(String l) {
    if (l != 'system') return l;
    try {
      final code =
          WidgetsBinding.instance.platformDispatcher.locale.languageCode;
      if (code == 'zh') return 'zh';
      return supported.contains(code) ? code : 'en';
    } catch (_) {
      return 'zh';
    }
  }

  static final Map<String, Map<String, String>> dict = _mergeExtra({
    'en': {
      '搜索': 'Search', '书架': 'Shelf', '小说': 'Novels', '漫画': 'Comics',
      '视频': 'Videos',
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
      '阅读主题': 'Reader theme', '翻页模式': 'Page mode', '滚动': 'Scroll',
      '分页(开发中)': 'Paged (WIP)',
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
      '断开': 'Disconnect', '未连接引擎': 'No engine connected',
      '去连接引擎': 'Connect engine',
      '发现页需要先连接引擎': 'Connect an engine to use Discover',
      '排行榜': 'Rankings', '联网搜索': 'Web search', '厂商与密钥': 'Providers & keys',
      '自动识别 Key': 'Auto-identify key', '中转站 Key': 'Relay key',
      '自定义厂商': 'Custom provider',
      '加载中': 'Loading', '暂无任务': 'No tasks', '书源': 'Book sources',
      '影视源': 'Video sources', '图源': 'Comic sources', '音源': 'Music sources',
      '搜索测试': 'Search test', '导出全部(JSON备份)': 'Export all (JSON backup)',
      '已添加下载': 'Download added', '选集': 'Episodes',
      '选照片同步': 'Sync photos',
      '存储服务': 'Storage services', '下载任务': 'Downloads', '网盘': 'Cloud disk',
      '引擎': 'Engines', '导航': 'Navigation', '底部导航栏': 'Bottom navigation',
      '回收站': 'Recycle bin', '网络引擎(局域网设备)': 'Network engines (LAN devices)',
      '内置引擎': 'Built-in engines', '能力': 'Capabilities',
      'AI': 'AI',
      'Markdown': 'Markdown',
      '书签': 'Bookmarks',
      '二维码': 'QR Code',
      '代码片段': 'Snippets',
      '传感器': 'Sensors',
      '自动化任务': 'Automation',
      '学习中心': 'Study Hub',
      '音频中心': 'Audio Hub',
      '记录中心': 'Notes Hub',
      '备份迁移': 'Backup & Migration',
      '健康记录': 'Health',
      '共享清单': 'Shared Lists',
      '共享相册': 'Shared Album',
      '剪贴板': 'Clipboard',
      '壁纸': 'Wallpapers',
      '天气与快递': 'Weather & Express',
      '记忆卡': 'Flashcards',
      '家庭中心': 'Family Hub',
      '家庭影院': 'Home Cinema',
      '家庭日历': 'Family Calendar',
      '家庭音乐库': 'Home Music',
      '工具箱': 'Toolbox',
      '广播': 'Radio',
      '录音机': 'Recorder',
      '待办': 'To-do',
      '悬浮便签': 'Sticky Notes',
      '扫描仪': 'Scanner',
      '提醒中心': 'Reminders',
      '摄像头': 'Cameras',
      '播客': 'Podcasts',
      '文件': 'Files',
      '文件互传': 'File Share',
      '文本工具箱': 'Text Tools',
      '日历': 'Calendar',
      '日记': 'Diary',
      '智能家居': 'Smart Home',
      '有声书': 'Audiobooks',
      '游戏': 'Games',
      '白板': 'Whiteboard',
      '相册': 'Gallery',
      '短信备份': 'SMS Backup',
      '短剧': 'Short Drama',
      '社区': 'Community',
      '笔记': 'Notes',
      '翻译': 'Translate',
      '聊天': 'Chat',
      '菜谱': 'Recipes',
      '计算器': 'Calculator',
      '记账': 'Ledger',
      '论坛': 'Forum',
      '设备互联': 'Device Link',
      '课程表': 'Timetable',
      '资讯': 'News',
      '远程打印': 'Remote Print',
      '通讯录备份': 'Contacts Backup',
      '视频设置': 'Video Settings',
      '新会话': 'New Chat',
      // 4.40.0 进阶模块
      '进阶': 'Advanced', '阅读进阶': 'Reader Pro', '影音进阶': 'Casting & Media',
      '相册闭环': 'Gallery Suite',
      'AI 工作台': 'AI Workbench', '系统与生态': 'System & Ecosystem', '数据': 'Data',
      '换源 · 批注 · 摘抄 · 追更': 'Sources · Annotations · Clips · Updates',
      '投屏 DLNA · 下载归一': 'DLNA cast · Unified downloads',
      '备份 · 秒传 · 加密柜 · 分享链': 'Backup · Instant upload · Vault · Share links',
      '工具 · 确认队列 · 定时 · 审计': 'Tools · Confirm queue · Cron · Audit',
      '模块 · 多后端 · 迁移 · 授权': 'Modules · Multi-backend · Migration · Grants',
      // 4.41.0 进阶模块补充(PiP / 照片地图 / 聊天)
      '投屏 DLNA · 下载归一 · 画中画': 'DLNA cast · Unified downloads · PiP',
      '备份 · 秒传 · 地图 · 加密柜 · 分享链': 'Backup · Instant upload · Map · Vault · Share links',
      '离线优先 · 多设备同步 · AI 摘要': 'Offline-first · Multi-device sync · AI summary',
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
      '在线': 'オンライン', '离线': 'オフライン', '底部导航栏': '下部ナビ', '书源': '書籍ソース',
      '图源': '漫画ソース',
      '书签': 'ブックマーク',
      '二维码': 'QRコード',
      '自动化任务': '自動化タスク',
      '学习中心': '学習ハブ',
      '音频中心': 'オーディオ',
      '记录中心': 'ノート',
      '备份迁移': 'バックアップ',
      '健康记录': '健康記録',
      '共享清单': '共有リスト',
      '共享相册': '共有アルバム',
      '剪贴板': 'クリップボード',
      '壁纸': '壁紙',
      '天气与快递': '天気・宅配',
      '记忆卡': '暗記カード',
      '家庭中心': 'ファミリー',
      '家庭影院': 'ホームシネマ',
      '家庭日历': '家族カレンダー',
      '家庭音乐库': 'ホーム音楽',
      '工具箱': 'ツール箱',
      '广播': 'ラジオ',
      '录音机': 'レコーダー',
      '待办': 'ToDo',
      '悬浮便签': '付箋',
      '扫描仪': 'スキャナー',
      '提醒中心': 'リマインダー',
      '摄像头': 'カメラ',
      '播客': 'ポッドキャスト',
      '文件': 'ファイル',
      '文件互传': 'ファイル共有',
      '文本工具箱': 'テキスト工具',
      '日历': 'カレンダー',
      '日记': '日記',
      '智能家居': 'スマートホーム',
      '有声书': 'オーディオブック',
      '游戏': 'ゲーム',
      '白板': 'ホワイトボード',
      '短信备份': 'SMSバックアップ',
      '短剧': '短編ドラマ',
      '社区': 'コミュニティ',
      '笔记': 'ノート',
      '翻译': '翻訳',
      '聊天': 'チャット',
      '菜谱': 'レシピ',
      '计算器': '電卓',
      '记账': '家計簿',
      '论坛': 'フォーラム',
      '设备互联': 'デバイス連携',
      '课程表': '時間割',
      '资讯': 'ニュース',
      '远程打印': 'リモート印刷',
      '通讯录备份': '連絡先バックアップ',
      '新会话': '新規チャット',
      // 4.40.0 进阶模块
      '进阶': '詳細設定', '阅读进阶': 'リーダー拡張', '影音进阶': 'キャスト・メディア', '相册闭环': 'アルバム統合',
      'AI 工作台': 'AIワークベンチ', '系统与生态': 'システム・エコ', '数据': 'データ',
      '换源 · 批注 · 摘抄 · 追更': 'ソース · 注釈 · 抜粋 · 更新',
      '投屏 DLNA · 下载归一': 'DLNAキャスト · ダウンロード統合',
      '备份 · 秒传 · 加密柜 · 分享链': 'バックアップ · 即時転送 · 金庫 · 共有リンク',
      '工具 · 确认队列 · 定时 · 审计': 'ツール · 確認キュー · 定期 · 監査',
      '模块 · 多后端 · 迁移 · 授权': 'モジュール · マルチバックエンド · 移行 · 認可',
      // 4.41.0 进阶模块补充(PiP / 照片地图 / 聊天)
      '投屏 DLNA · 下载归一 · 画中画': 'DLNAキャスト · DL統合 · ピクチャインピクチャ',
      '备份 · 秒传 · 地图 · 加密柜 · 分享链': 'バックアップ · 即時転送 · 地図 · 金庫 · 共有リンク',
      '离线优先 · 多设备同步 · AI 摘要': 'オフライン優先 · マルチデバイス同期 · AI要約',
    },
    // fr/ru/es/ar: 核心词逐步补全(缺失回落中文)
    'fr': {
      '搜索': 'Rechercher',
      '书架': 'Bibliothèque',
      '漫画': 'BD',
      '视频': 'Vidéos',
      '音乐': 'Musique',
      '我的': 'Moi',
      '取消': 'Annuler',
      '保存': 'Sauver'
    },
    'ru': {
      '搜索': 'Поиск',
      '书架': 'Полка',
      '漫画': 'Комиксы',
      '视频': 'Видео',
      '音乐': 'Музыка',
      '我的': 'Я',
      '取消': 'Отмена',
      '保存': 'Сохранить'
    },
    'es': {
      '搜索': 'Buscar',
      '书架': 'Estantería',
      '漫画': 'Cómics',
      '视频': 'Vídeos',
      '音乐': 'Música',
      '我的': 'Yo',
      '取消': 'Cancelar',
      '保存': 'Guardar'
    },
    'ar': {
      '搜索': 'بحث',
      '书架': 'الرف',
      '漫画': 'مانغا',
      '视频': 'فيديو',
      '音乐': 'موسيقى',
      '我的': 'أنا',
      '取消': 'إلغاء',
      '保存': 'حفظ'
    },
  });

  /// 把 `i18n_extra.dart` 的补充译文合并进基础字典（补充的覆盖基础的）。
  ///
  /// 单独抽这一步而不是把译文直接写进上面那个 literal，理由：上面那个 literal 是
  /// 5 种语言混在一起的大块数据，直接改容易碰坏已有译文；这里只做一次浅合并，
  /// `dict` 的类型与所有既有用法完全不变。
  static Map<String, Map<String, String>> _mergeExtra(
      Map<String, Map<String, String>> base) {
    final out = <String, Map<String, String>>{
      for (final e in base.entries) e.key: Map<String, String>.from(e.value),
    };
    i18nExtra.forEach((lang, words) {
      out[lang] = <String, String>{...?out[lang], ...words};
    });
    return out;
  }

  /// 查找链：**当前语言 → 英文 → 中文原文**。
  ///
  /// 中间那跳「英文」是第十五轮加的：此前缺词直接落回中文，而 fr/ru/es/ar
  /// 只有 8 个词，切过去就是满屏中文（用户体感：选了外语根本没生效）。
  /// 加上英文兜底后，最差是英文，不会再有"半屏中文"的割裂感。
  static String tr(String zh) {
    final d = dict[instance.locale];
    return d?[zh] ?? dict['en']?[zh] ?? zh;
  }
}

String tr(String s) => I18n.tr(s);

/// 分段控件（`SegmentedButton`）专用标签：**强制单行 + 超出省略**。
///
/// 为什么单独来一个：`Text(tr('书架'))` 在法语下是 `Bibliothèque`（12 字符）。
/// 四个分段并排放在 360dp 宽的手机上，每段可用宽度只有 ~78dp，而 Flutter 的
/// `Text` **默认允许换行** —— 于是一个按钮被折成 `Bibli` / `othè` / `que` 三行，
/// 分段条从 40dp 被撑到 ~90dp，整页排版跟着往下跳（Android 模拟器实测，法语/俄语必现）。
/// 分段按钮的语义是「若干并列的互斥选项」，**它不该换行**；放不下就省略。
Widget segLabel(String zh, {double fontSize = 12.5}) => Text(
      tr(zh),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      softWrap: false,
      style: TextStyle(fontSize: fontSize),
    );
