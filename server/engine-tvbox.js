// ThirdHub v4 TVBox 配置适配器: 导入TVBox接口配置(JSON) → 视频源
// 支持两类站点(免jar, Node可直接跑):
//   1) 采集类CMS接口(type 0/1, api为URL): ?ac=videolist&wd= 搜索 / &ids= 详情, 播放地址直出m3u8
//   2) drpy类(api含drpy或ext为JS): 交给内置drpy引擎
// jar爬虫类站点跳过(Node跑不了Java), 导入时报告数量
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/126.0.0.0 Safari/537.36';

async function fetchText(url) {
  const r = await fetch(url, { headers: { 'User-Agent': UA }, signal: AbortSignal.timeout(15000) });
  return await r.text();
}

// 导入: 输入 配置URL 或 JSON文本 → { added: [...], skipped: n }
async function importConfig(input) {
  let text = input.trim();
  if (/^https?:\/\//.test(text)) text = await fetchText(text);
  // TVBox配置有时是base64或带注释, 尝试提取JSON
  let cfg;
  try { cfg = JSON.parse(text); }
  catch (e) {
    try { cfg = JSON.parse(Buffer.from(text, 'base64').toString('utf8')); }
    catch (e2) {
      const m = text.match(/\{[\s\S]*"sites"[\s\S]*\}/);
      if (!m) throw new Error('无法解析TVBox配置');
      cfg = JSON.parse(m[0]);
    }
  }
  const sites = cfg.sites || cfg.site || [];
  const added = []; let skipped = 0;
  for (const s of sites) {
    const name = s.name || s.key || '未命名';
    const api = s.api || '';
    const ext = typeof s.ext === 'string' ? s.ext : '';
    if (s.jar) { skipped++; continue; } // jar爬虫跳过
    if (/drpy/i.test(api) || /\.js\b/.test(ext)) {
      // drpy类: ext是JS地址或内联代码
      try {
        const code = /^https?:/.test(ext) ? await fetchText(ext) : ext;
        if (code && code.length > 100) {
          added.push({ id: 'tvbox_' + (s.key || Math.random().toString(36).slice(2, 8)), name, kind: 'drpy', code });
          continue;
        }
      } catch (e) {}
      skipped++;
    } else if (/^https?:/.test(api)) {
      // CMS采集接口
      added.push({ id: 'tvbox_' + (s.key || Math.random().toString(36).slice(2, 8)), name, kind: 'tvbox-cms', api });
    } else skipped++;
  }
  return { added, skipped, total: sites.length };
}

// ── CMS 接口调用(返回与drpy引擎相同的原生结构, 复用同一IR归一) ──
async function cmsSearch(api, q) {
  const sep = api.includes('?') ? '&' : '?';
  const r = await fetch(`${api}${sep}ac=videolist&wd=${encodeURIComponent(q)}`,
    { headers: { 'User-Agent': UA }, signal: AbortSignal.timeout(15000) });
  const j = await r.json();
  return { list: j.list || [] };
}

async function cmsDetail(api, id) {
  const sep = api.includes('?') ? '&' : '?';
  const r = await fetch(`${api}${sep}ac=videolist&ids=${encodeURIComponent(id)}`,
    { headers: { 'User-Agent': UA }, signal: AbortSignal.timeout(15000) });
  const j = await r.json();
  return { list: j.list || [] };
}

// CMS 播放: vod_play_url 里的地址多为直链/m3u8, 直接返回
function cmsPlay(url) {
  return { url, parse: 0, header: { 'User-Agent': UA } };
}

module.exports = { importConfig, cmsSearch, cmsDetail, cmsPlay };
