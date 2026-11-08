// server/engine-cms.js — 苹果CMS(视频采集)引擎
//
// 为什么单独写这个引擎（2026-11-09）：
//   现有 133 个影视源全是 drpy(HTML 解析) 类。实测 348电影网 的搜索页返回的
//   是「域名已失效，请访问 www.2tv.app」的错误页 —— **源站改版，规则全废**。
//   这类源一改版就得跟着改选择器，长期不可维护。
//
//   苹果CMS 采集接口不一样：它返回标准 JSON（ac=videolist&wd=关键词），
//   字段固定（vod_id / vod_name / vod_pic / vod_play_url ...），源站换皮也不影响。
//   实测 4 个公共接口可用（量子 / 非凡 / 无尽 / 极速），这类才是能长期跑的。
//
// 接口契约（苹果CMS v10 标准）：
//   搜索: {base}?ac=videolist&wd={关键词}&pg={页}   → {page,pagecount,limit,total,list:[...]}
//   详情: {base}?ac=videolist&ids={id}              → {list:[{vod_play_url,vod_play_from,...}]}
//   选集: vod_play_url = "集名$地址#集名$地址"，多条线路用 "$$$" 分隔，
//         线路名在 vod_play_from 里同样用 "$$$" 分隔。
'use strict';

const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/126.0.0.0 Safari/537.36';

function joinUrl(base, qs) {
  const b = String(base || '').replace(/\/+$/, '');
  if (!b) return '';
  return b + (b.includes('?') ? '&' : '?') + qs;
}

async function getJson(url, timeoutMs = 12000) {
  const r = await fetch(url, {
    headers: { 'User-Agent': UA, Accept: 'application/json,text/plain,*/*' },
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (!r.ok) throw new Error('HTTP ' + r.status);
  const t = await r.text();
  const s = t.trim();
  if (!s.startsWith('{') && !s.startsWith('[')) {
    throw new Error('返回不是 JSON（可能是拦截页）: ' + s.slice(0, 60).replace(/\s+/g, ' '));
  }
  return JSON.parse(s);
}

const stripTags = (s) => String(s || '').replace(/<[^>]+>/g, '').replace(/\s+/g, ' ').trim();

// 搜索：返回 {items, maxPage, total}
async function search(base, q, page = 1) {
  const url = joinUrl(base, 'ac=videolist&wd=' + encodeURIComponent(String(q)) + '&pg=' + (page || 1));
  const j = await getJson(url);
  const list = Array.isArray(j.list) ? j.list : [];
  return {
    items: list.map((v) => ({
      id: String(v.vod_id || ''),
      name: v.vod_name || '',
      coverUrl: v.vod_pic || '',
      type: v.vod_type || v.type_name || '',
      year: String(v.vod_year || ''),
      intro: stripTags(v.vod_content).slice(0, 200),
      remarks: v.vod_remarks || '',
    })),
    maxPage: Number(j.pagecount || 1),
    total: Number(j.total || 0),
  };
}

// 详情：返回 {id,title,coverUrl,description,year,type,area,remarks,lines:[{name,episodes:[{name,url}]}]}
async function detail(base, id) {
  const url = joinUrl(base, 'ac=videolist&ids=' + encodeURIComponent(String(id)));
  const j = await getJson(url);
  const v = (Array.isArray(j.list) ? j.list : [])[0];
  if (!v) return { error: '没有该影片' };

  const froms = String(v.vod_play_from || '').split('$$$');
  const lines = [];
  String(v.vod_play_url || '').split('$$$').forEach((seg, idx) => {
    const eps = String(seg || '')
      .split('#')
      .filter(Boolean)
      .map((e) => {
        const i = e.lastIndexOf('$');
        return i > 0 ? { name: e.slice(0, i), url: e.slice(i + 1) } : { name: e, url: '' };
      })
      .filter((x) => x.url);
    if (eps.length) lines.push({ name: froms[idx] || '线路' + (idx + 1), episodes: eps });
  });

  return {
    id: String(v.vod_id || id),
    title: v.vod_name || '',
    coverUrl: v.vod_pic || '',
    description: stripTags(v.vod_content),
    year: String(v.vod_year || ''),
    type: v.vod_type || '',
    area: v.vod_area || '',
    remarks: v.vod_remarks || '',
    lines,
  };
}

module.exports = { search, detail };
