// 厂商品牌图标(与网站 vendors.js 同源): lobehub CDN PNG, 失败回退品牌色字母徽标
import 'package:flutter/material.dart';

const Map<String, (int, String?, String)> kVendorBrands = {
  'openai': (0xFF10A37F, 'openai', 'AI'),
  'anthropic': (0xFFD97757, 'anthropic', 'C'),
  'google': (0xFF4285F4, 'gemini-color', 'G'),
  'xai': (0xFF111111, 'grok', 'X'),
  'deepseek': (0xFF4D6BFE, 'deepseek-color', 'DS'),
  'aliyun': (0xFFFF6A00, 'qwen-color', 'QY'),
  'tencent': (0xFF07C160, 'hunyuan-color', 'HY'),
  'baidu': (0xFF2932E1, 'wenxin-color', 'WX'),
  'bytedance': (0xFF325AB4, 'doubao-color', 'DB'),
  'moonshot': (0xFF000000, 'kimi-color', 'K'),
  'zhipu': (0xFF2B5CE6, 'chatglm-color', 'GLM'),
  'yi': (0xFF111111, 'yi-color', 'Yi'),
  'sensechat': (0xFF0052CC, 'sensetime-color', 'SL'),
  'minimax': (0xFF111111, 'minimax-color', 'MM'),
  'xiaomi': (0xFFFF6900, 'xiaomimimo', 'MI'),
  'siliconflow': (0xFF6D28D9, 'siliconflow-color', 'SF'),
  'baichuan': (0xFF2B5CE6, 'baichuan-color', 'BC'),
  'stepfun': (0xFF4F46E5, 'stepfun-color', 'JY'),
  'spark': (0xFF2B5CE6, 'spark-color', 'XF'),
  'tiangong': (0xFF6D28D9, 'tiangong-color', 'TG'),
  'qihoo': (0xFF22C55E, null, '360'),
  'mistral': (0xFFFF7000, 'mistral-color', 'M'),
  'cohere': (0xFF39594D, 'cohere-color', 'Co'),
  'perplexity': (0xFF1FB8CD, null, 'P'),
  'groq': (0xFFF55036, 'groq-color', 'GQ'),
  'together': (0xFF0F6FDE, 'together-color', 'T'),
  'fireworks': (0xFF6720FF, 'fireworks-color', 'FW'),
  'replicate': (0xFF1F2937, 'replicate-color', 'R'),
  'stability': (0xFFA855F7, 'stabilityai-color', 'S'),
  'midjourney': (0xFF1E293B, 'midjourney-color', 'MJ'),
  'openrouter': (0xFF6366F1, 'openrouter-color', 'OR'),
  'azure': (0xFF0078D4, 'azure-color', 'Az'),
  'nvidia': (0xFF76B900, 'nvidia-color', 'NV'),
  'cloudflare': (0xFFF6821F, 'cloudflare-color', 'CF'),
  'opencode-zen': (0xFF0F172A, null, 'Z'),
  'custom': (0xFF64748B, null, '…'),
};

class VendorIcon extends StatelessWidget {
  final String id; final double size;
  const VendorIcon(this.id, {super.key, this.size = 28});
  @override Widget build(BuildContext c) {
    final b = kVendorBrands[id] ?? kVendorBrands['custom']!;
    final lobe = b.$2;
    final letter = b.$3; final color = Color(b.$1);
    Widget fallback() => Container(width: size, height: size,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(size * 0.24)),
      alignment: Alignment.center,
      child: Text(letter, style: TextStyle(color: Colors.white, fontSize: size * 0.4, fontWeight: FontWeight.bold)));
    if (lobe == null) return fallback();
    return ClipRRect(borderRadius: BorderRadius.circular(size * 0.24),
      child: Image.network('https://cdn.jsdelivr.net/npm/@lobehub/icons-static-png@latest/light/$lobe.png',
        width: size, height: size, fit: BoxFit.contain, errorBuilder: (_, __, ___) => fallback(),
        loadingBuilder: (_, child, p) => p == null ? child : fallback()));
  }
}
