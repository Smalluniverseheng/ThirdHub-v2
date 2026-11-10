// server/services/adapters/navidrome.js — 音乐库适配器（Subsonic API）
//
// Navidrome 实现的是 Subsonic 协议，几乎所有第三方音乐客户端都通用，
// 所以这里按标准 Subsonic 写，换成 Airsonic/Gonic 也能直接跑。
// 未配账号时退回「网页可达」探活（/app/ 返回 200/302 即在线）。
'use strict';

const UA = 'ThirdHub/1.0';
const VER = '1.16.1';
const CLIENT = 'ThirdHub';

function base(svc) {
  return String(svc.baseUrl || '').replace(/\/+$/, '');
}

function authParams(svc) {
  const a = svc.auth || {};
  if (!a.username || !a.password) return null;
  // 内网明文即可（Subsonic 也支持 t=md5(pw+salt)，这里用明文更省事且不传错）
  return new URLSearchParams({
    u: a.username, p: a.password, v: VER, c: CLIENT, f: 'json',
  });
}

async function call(svc, endpoint, extra, timeoutMs = 10000) {
  const p = authParams(svc);
  if (!p) throw new Error('未配置音乐库账号');
  for (const [k, v] of Object.entries(extra || {})) p.set(k, String(v));
  const r = await fetch(base(svc) + '/rest/' + endpoint + '?' + p.toString(), {
    headers: { 'User-Agent': UA }, signal: AbortSignal.timeout(timeoutMs),
  });
  const t = await r.text();
  if (!r.ok) throw new Error('HTTP ' + r.status);
  let j;
  try { j = JSON.parse(t); } catch (e) { throw new Error('返回不是 JSON'); }
  const sr = j['subsonic-response'] || {};
  if (sr.status === 'failed') throw new Error(sr.error && sr.error.message || 'Subsonic 返回失败');
  return sr;
}

function songToEntry(s) {
  return {
    id: s.id,
    title: s.title || s.name || '',
    subtitle: [s.artist, s.album].filter(Boolean).join(' · '),
    cover: s.coverArt ? ('/rest/getCoverArt.view?id=' + s.coverArt) : '',
    kind: 'music',
    source: 'navidrome',
    extra: {
      artist: s.artist || '', album: s.album || '',
      duration: s.duration || 0, track: s.track || 0, year: s.year || null,
      suffix: s.suffix || '', size: s.size || 0,
    },
  };
}

module.exports = {
  async probe(svc, timeoutMs = 6000) {
    const t0 = Date.now();
    if (authParams(svc)) {
      try {
        const sr = await call(svc, 'ping.view', {}, timeoutMs);
        return { ok: sr.status === 'ok', ms: Date.now() - t0, info: { version: sr.version || '', auth: true } };
      } catch (e) {
        return { ok: false, ms: Date.now() - t0, error: String(e.message || e) };
      }
    }
    // 无账号：网页可达即在线
    const r = await fetch(base(svc) + '/app/', {
      headers: { 'User-Agent': UA }, redirect: 'manual', signal: AbortSignal.timeout(timeoutMs),
    });
    return { ok: r.status < 500, ms: Date.now() - t0, info: { needAuth: true, http: r.status } };
  },

  async search(svc, q) {
    const sr = await call(svc, 'search3.view', { query: String(q || ''), songCount: 20, albumCount: 5, artistCount: 5 });
    const out = [];
    const s3 = sr.searchResult3 || sr.searchResult || {};
    for (const s of (s3.song || [])) out.push(songToEntry(s));
    for (const al of (s3.album || [])) {
      out.push({
        id: al.id, title: al.name || '', subtitle: [al.artist, al.year].filter(Boolean).join(' · '),
        cover: al.coverArt ? ('/rest/getCoverArt.view?id=' + al.coverArt) : '',
        kind: 'music', source: 'navidrome',
        extra: { type: 'album', songCount: al.songCount || 0, duration: al.duration || 0 },
      });
    }
    return out;
  },

  /** 拿一首歌的直链（前端播放器用） */
  async streamUrl(svc, id) {
    const p = authParams(svc);
    if (!p) return '';
    p.set('id', String(id));
    return base(svc) + '/rest/stream.view?' + p.toString();
  },
};
