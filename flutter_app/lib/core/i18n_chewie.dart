// Chewie 播放器菜单的多语言。
//
// ── 为什么需要这个文件 ──
// 用户截图里那个「Playback speed / Cancel」的弹层是 **Chewie 内部**画的，
// 它的文案写死在包里（`material_controls.dart:164` 的 `'Playback speed'`），
// 不读 MaterialLocalizations，也不读我们的 `tr()`。
// chewie 1.13 给了唯一的口子：`ChewieController.optionsTranslation`。
// 不传 → 中文界面里固定冒英文；传了 → 跟随 App 语言。
//
// ★这类「第三方组件自带的文案」是最容易被漏掉的一类混排来源：
//   自己写的 UI 都包了 tr()，只剩这些包内字面量在漏。以后接新包要专门确认
//   它有没有 `xxxTranslations` 之类的注入点。
import 'package:chewie/chewie.dart';

import 'i18n.dart';

const _words = <String, Map<String, String>>{
  'zh': {
    'speed': '播放速度',
    'subtitle': '字幕',
    'cancel': '取消',
  },
  'en': {
    'speed': 'Playback speed',
    'subtitle': 'Subtitles',
    'cancel': 'Cancel',
  },
  'ja': {
    'speed': '再生速度',
    'subtitle': '字幕',
    'cancel': 'キャンセル',
  },
  'fr': {
    'speed': 'Vitesse de lecture',
    'subtitle': 'Sous-titres',
    'cancel': 'Annuler',
  },
  'ru': {
    'speed': 'Скорость воспроизведения',
    'subtitle': 'Субтитры',
    'cancel': 'Отмена',
  },
  'es': {
    'speed': 'Velocidad de reproducción',
    'subtitle': 'Subtítulos',
    'cancel': 'Cancelar',
  },
  'ar': {
    'speed': 'سرعة التشغيل',
    'subtitle': 'الترجمة',
    'cancel': 'إلغاء',
  },
};

/// 按当前 App 语言返回 Chewie 的菜单译文。
/// 查不到（理论上不会）→ 用英文，**绝不回落中文**：
/// 外语用户看到一行英文能接受，看到一行中文就是「你没做国际化」。
OptionsTranslation chewieTranslation() {
  final d = _words[I18n.instance.locale] ?? _words['en']!;
  return OptionsTranslation(
    playbackSpeedButtonText: d['speed'],
    subtitlesButtonText: d['subtitle'],
    cancelButtonText: d['cancel'],
  );
}
