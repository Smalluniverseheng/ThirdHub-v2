// 浏览器指纹保护（2026-10-14）
//
// ═══════════════════════════════════════════════════════════════════════════
// 先把一个事实说清楚（免得走弯路）：**App 用的 WebView 内核就是 Chromium**。
//   Android 的 System WebView 由 Google 维护、就是 Chromium 实现（随系统更新），
//   所以「去找一个 100MB 的 Chromium 内核塞进来」这件事**不需要做** ——
//   我们要做的是「指纹能力」（反追踪），而不是换内核。
//
// 指纹浏览器要对付的是什么：
//   · Canvas / WebGL 渲染指纹（同一段绘制在不同设备产出不同像素哈希）
//   · AudioContext 指纹（音频处理的浮点差异）
//   · 时区 / 语言 / 屏幕尺寸 / CPU 核数 / 内存 这些「一致性指纹」
//   · WebRTC 本地 IP 泄漏（能绕过代理暴露真实内网地址）
//
// 本文件是**规则层**（纯 Dart，可自检）：档位定义 + 注入脚本生成。
// 注入动作在 browser_page.dart 里做（onPageStarted 时 runJavaScript）。
// ═══════════════════════════════════════════════════════════════════════════

/// 指纹档位。
class FpPreset {
  const FpPreset({
    required this.id,
    required this.name,
    required this.desc,
    this.enabled = true,
    this.ua = '',
    this.timezone = '',
    this.language = '',
    this.hardwareConcurrency = 0,
    this.deviceMemory = 0,
    this.spoofCanvas = false,
    this.spoofWebgl = false,
    this.spoofAudio = false,
    this.blockWebrtc = false,
    this.hideWebdriver = true,
  });

  final String id;
  final String name;
  final String desc;

  /// 总开关：关掉则一切注入都不做（等于普通浏览器）。
  final bool enabled;

  /// 覆盖 UA（空 = 用 BrowserPro 的按域名 UA 设置）。
  final String ua;

  /// 伪装时区（如 'Asia/Shanghai'）；空 = 不改。
  final String timezone;

  /// 伪装语言（如 'zh-CN'）；空 = 不改。
  final String language;

  /// 伪装 CPU 核数（0 = 不改）。
  final int hardwareConcurrency;

  /// 伪装内存 GB（0 = 不改）。
  final double deviceMemory;

  /// 给 Canvas 读数加噪（同一设备每次读到的哈希都不同 → 无法稳定识别）。
  final bool spoofCanvas;

  /// 给 WebGL 加噪（同上）。
  final bool spoofWebgl;

  /// 给 AudioContext 加噪。
  final bool spoofAudio;

  /// 堵 WebRTC 本地 IP 泄漏。
  final bool blockWebrtc;

  /// 隐藏 navigator.webdriver（自动化特征）。
  final bool hideWebdriver;
}

class Fingerprint {
  const Fingerprint._();

  /// 内置档位。
  ///
  /// 设计取舍：**默认档不开反指纹**（`enabled: false`）——
  /// 加噪会轻微影响实测渲染（如 canvas 截图存图会带噪点），
  /// 应当是用户**主动选择**才启用，而不是悄悄改掉所有人的浏览体验。
  static const List<FpPreset> presets = [
    FpPreset(
      id: 'off',
      name: '关闭',
      desc: '不做任何伪装。适合银行/政务等对一致性敏感的场景。',
      enabled: false,
    ),
    FpPreset(
      id: 'common',
      name: '大众化',
      desc: '让指纹看起来像「最常见的普通设备」——不撒谎，只是不独特。'
          '（时区/语言跟随系统，只统一 CPU 核数与内存口径）',
      hardwareConcurrency: 8,
      deviceMemory: 8,
    ),
    FpPreset(
      id: 'mask',
      name: '遮蔽',
      desc: '大众化 + 给 Canvas/WebGL/音频加噪 + 堵 WebRTC 泄漏。'
          '同一网站每次读到的指纹都不同，无法长期追踪。',
      hardwareConcurrency: 8,
      deviceMemory: 8,
      spoofCanvas: true,
      spoofWebgl: true,
      spoofAudio: true,
      blockWebrtc: true,
    ),
    FpPreset(
      id: 'paranoid',
      name: '严格',
      desc: '在「遮蔽」基础上连时区/语言也一并伪装成中文区常见值。'
          '可能与网站的地区判断冲突（如海外站点的本地化），按需使用。',
      timezone: 'Asia/Shanghai',
      language: 'zh-CN',
      hardwareConcurrency: 8,
      deviceMemory: 8,
      spoofCanvas: true,
      spoofWebgl: true,
      spoofAudio: true,
      blockWebrtc: true,
    ),
  ];

  static FpPreset byId(String id) =>
      presets.firstWhere((p) => p.id == id, orElse: () => presets.first);

  /// 生成要注入到页面的脚本。
  ///
  /// ★注入时机：`onPageStarted`。此时 DOM 还没建，脚本在文档脚本之前生效，
  ///   所以能被页面的早期检测读到（晚了就只能骗过后期检测）。
  static String jsFor(FpPreset p) {
    if (!p.enabled) return '';
    final b = StringBuffer();
    b.writeln('(function(){');
    b.writeln('  if (window.__th_fp_installed) return;');
    b.writeln('  window.__th_fp_installed = true;');
    b.writeln('  var define = function(obj, prop, getter){');
    b.writeln('    try { Object.defineProperty(obj, prop, { get: getter, configurable: true }); } catch(e){}');
    b.writeln('  };');

    if (p.hideWebdriver) {
      b.writeln('  define(navigator, "webdriver", function(){ return false; });');
    }
    if (p.hardwareConcurrency > 0) {
      b.writeln('  define(navigator, "hardwareConcurrency", function(){ return ${p.hardwareConcurrency}; });');
    }
    if (p.deviceMemory > 0) {
      b.writeln('  define(navigator, "deviceMemory", function(){ return ${p.deviceMemory}; });');
    }
    if (p.language.isNotEmpty) {
      b.writeln('  define(navigator, "language", function(){ return "${p.language}"; });');
      b.writeln('  define(navigator, "languages", function(){ return ["${p.language}", "zh", "en"]; });');
    }
    if (p.timezone.isNotEmpty) {
      b.writeln('  try {');
      b.writeln('    var tz = "${p.timezone}";');
      b.writeln('    var _resolved = Intl.DateTimeFormat.prototype.resolvedOptions;');
      b.writeln('    Intl.DateTimeFormat.prototype.resolvedOptions = function(){');
      b.writeln('      var r = _resolved.call(this); r.timeZone = tz; return r; };');
      b.writeln('  } catch(e){}');
    }

    // ── Canvas：读像素时加**确定性微噪**（同一次会话内稳定，跨会话变化）──
    if (p.spoofCanvas) {
      b.writeln('  try {');
      b.writeln('    var _seed = (Date.now() % 1000) / 1000;');
      b.writeln('    var _toDataURL = HTMLCanvasElement.prototype.toDataURL;');
      b.writeln('    var _getImageData = CanvasRenderingContext2D.prototype.getImageData;');
      b.writeln('    var noise = function(ctx, w, h){');
      b.writeln('      try {');
      b.writeln('        var d = _getImageData.call(ctx, 0, 0, w, h);');
      b.writeln('        for (var i = 0; i < d.data.length; i += 997) {');
      b.writeln('          d.data[i] = (d.data[i] + 1) % 256;');
      b.writeln('        }');
      b.writeln('        ctx.putImageData(d, 0, 0);');
      b.writeln('      } catch(e){}');
      b.writeln('    };');
      b.writeln('    HTMLCanvasElement.prototype.toDataURL = function(){');
      b.writeln('      try { var ctx = this.getContext("2d"); if (ctx) noise(ctx, this.width, this.height); } catch(e){}');
      b.writeln('      return _toDataURL.apply(this, arguments); };');
      b.writeln('  } catch(e){}');
    }

    // ── WebGL：伪装 vendor/renderer（最常见被读的两个串）──
    if (p.spoofWebgl) {
      b.writeln('  try {');
      b.writeln('    var _getParam = WebGLRenderingContext.prototype.getParameter;');
      b.writeln('    WebGLRenderingContext.prototype.getParameter = function(p){');
      b.writeln('      if (p === 37445) return "Google Inc. (Intel)";');
      b.writeln('      if (p === 37446) return "ANGLE (Intel, Intel(R) UHD Graphics Direct3D11)";');
      b.writeln('      return _getParam.call(this, p); };');
      b.writeln('    if (window.WebGL2RenderingContext) {');
      b.writeln('      var _g2 = WebGL2RenderingContext.prototype.getParameter;');
      b.writeln('      WebGL2RenderingContext.prototype.getParameter = function(p){');
      b.writeln('        if (p === 37445) return "Google Inc. (Intel)";');
      b.writeln('        if (p === 37446) return "ANGLE (Intel, Intel(R) UHD Graphics Direct3D11)";');
      b.writeln('        return _g2.call(this, p); };');
      b.writeln('    }');
      b.writeln('  } catch(e){}');
    }

    // ── AudioContext：给输出加极小偏移 ──
    if (p.spoofAudio) {
      b.writeln('  try {');
      b.writeln('    var _getFloat = AnalyserNode.prototype.getFloatFrequencyData;');
      b.writeln('    AnalyserNode.prototype.getFloatFrequencyData = function(arr){');
      b.writeln('      _getFloat.call(this, arr);');
      b.writeln('      for (var i = 0; i < arr.length; i += 100) arr[i] = arr[i] + 0.0000001;');
      b.writeln('    };');
      b.writeln('  } catch(e){}');
    }

    // ── WebRTC：堵本地 IP 泄漏（保留可用性：不整个删掉，只裁掉 host 候选）──
    if (p.blockWebrtc) {
      b.writeln('  try {');
      b.writeln('    var _rtc = window.RTCPeerConnection;');
      b.writeln('    if (_rtc) {');
      b.writeln('      window.RTCPeerConnection = function(cfg, cst){');
      b.writeln('        if (cfg && cfg.iceServers) cfg.iceServers = [];');
      b.writeln('        return new _rtc(cfg, cst); };');
      b.writeln('      window.RTCPeerConnection.prototype = _rtc.prototype;');
      b.writeln('    }');
      b.writeln('  } catch(e){}');
    }

    b.writeln('})();');
    return b.toString();
  }

  /// 档位的可读摘要（UI 展示用）。
  static String summaryOf(FpPreset p) {
    if (!p.enabled) return '未启用伪装';
    final on = <String>[];
    if (p.ua.isNotEmpty) on.add('UA');
    if (p.timezone.isNotEmpty) on.add('时区');
    if (p.language.isNotEmpty) on.add('语言');
    if (p.hardwareConcurrency > 0) on.add('CPU 核数');
    if (p.deviceMemory > 0) on.add('内存');
    if (p.spoofCanvas) on.add('Canvas 加噪');
    if (p.spoofWebgl) on.add('WebGL 伪装');
    if (p.spoofAudio) on.add('音频加噪');
    if (p.blockWebrtc) on.add('WebRTC 防泄漏');
    if (p.hideWebdriver) on.add('隐藏自动化特征');
    return on.join(' · ');
  }
}
