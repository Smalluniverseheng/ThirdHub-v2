// 音频播放源挂 MediaItem 标签 → 通知栏/锁屏出现媒体控制组件(just_audio_background)。
// 规则: 凡是走 just_audio 的播放都必须过这里, 不要裸调 setUrl/setFilePath。
// 系统 TTS(flutter_tts)是系统引擎自己发声, 不吃这个, 属正常。
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart' show MediaItem;

AudioSource tagFile(String path, {required String title, String album = 'ThirdHub'}) =>
    AudioSource.file(path, tag: MediaItem(id: path, title: title, album: album));

AudioSource tagUrl(String url, {required String title, String album = 'ThirdHub'}) =>
    AudioSource.uri(Uri.parse(url), tag: MediaItem(id: url, title: title, album: album));
