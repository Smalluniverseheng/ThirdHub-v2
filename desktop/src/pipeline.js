'use strict';
// 任务执行器：抓取 → 转标准格式 → 落成品库。
//
// 这是一条**顺序流水线**，不并发跑多个任务：转码/打包是 CPU 活，
// 同时跑三个只会让每个都变慢，还会把机器内存顶满。
// 任务内部取件是并发的（默认 3 路），因为那是 IO 等待。
const fs = require('fs');
const path = require('path');

const { fetchBinary, htmlToText, guessTitle } = require('./net');
const { buildEpub } = require('./epub');
const { buildCbz, buildAudioSet, buildVideo, sanitize } = require('./convert');
const store = require('./store');

const CONCURRENCY = Math.max(1, parseInt(process.env.TH_FETCH_CONCURRENCY || '3', 10));
const MAX_ITEMS = Math.max(1, parseInt(process.env.TH_MAX_ITEMS || '400', 10));

/** 限并发 map。保持返回顺序与入参一致（页序不能乱）。 */
async function mapPool(items, limit, fn) {
  const out = new Array(items.length);
  let next = 0;
  const workers = new Array(Math.min(limit, items.length)).fill(0).map(async () => {
    for (;;) {
      const i = next++;
      if (i >= items.length) return;
      out[i] = await fn(items[i], i);
    }
  });
  await Promise.all(workers);
  return out;
}

function progress(taskId, done, total, note) {
  store.taskUpdate(taskId, { done, total, note: note || '' });
}

// ── 各类型的执行体 ───────────────────────────────────────────

async function runBook(task) {
  const chs = (task.chapters || []).slice(0, MAX_ITEMS);
  if (!chs.length) throw new Error('book 任务需要 chapters[{title,url}]');
  let done = 0;

  const chapters = await mapPool(chs, CONCURRENCY, async (c) => {
    try {
      const r = await fetchBinary(c.url, { referer: task.referer });
      const text = htmlToText(r.buf.toString('utf8'));
      const t = (c.title || '').trim() || guessTitle(r.buf.toString('utf8')) || `第 ${done + 1} 节`;
      done++;
      progress(task.id, done, chs.length, t);
      return { title: t, content: text || '（本节未取到正文）' };
    } catch (e) {
      done++;
      progress(task.id, done, chs.length, '失败：' + (c.title || c.url).slice(0, 40));
      return { title: (c.title || '未知章节') + '（抓取失败）', content: '原因：' + e.message };
    }
  });

  let cover = null;
  if (task.cover) {
    try {
      const r = await fetchBinary(task.cover, { referer: task.referer });
      const ext = (r.mime || '').includes('png') ? 'png' : 'jpg';
      cover = { name: 'cover.' + ext, data: r.buf, mediaType: r.mime || 'image/jpeg' };
    } catch (_) {
      /* 封面失败不该让整本书失败 */
    }
  }

  const buf = buildEpub({
    title: task.title || '未命名',
    author: task.author || '',
    language: task.language || 'zh-CN',
    chapters,
    cover,
  });
  return { buf, ext: '.epub', mime: 'application/epub+zip' };
}

async function runComic(task) {
  const pages = (task.pages || []).slice(0, MAX_ITEMS);
  if (!pages.length) throw new Error('comic 任务需要 pages[url]');
  let done = 0;

  const got = await mapPool(pages, CONCURRENCY, async (u) => {
    try {
      const r = await fetchBinary(u, { referer: task.referer });
      done++;
      progress(task.id, done, pages.length, '第 ' + done + ' 页');
      // 用 mime 决定扩展名，不信 URL 后缀（很多站给的是无后缀 CDN 链接）
      const mt = (r.mime || '').toLowerCase();
      const ext = mt.includes('png') ? '.png' : mt.includes('webp') ? '.webp' : mt.includes('gif') ? '.gif' : '.jpg';
      return { name: 'p' + ext, data: r.buf };
    } catch (e) {
      done++;
      progress(task.id, done, pages.length, '第 ' + done + ' 页失败');
      return null; // 单页失败跳过，不能因为一张图丢掉整本
    }
  });

  const ok = got.filter(Boolean);
  if (!ok.length) throw new Error('所有页面都抓取失败，检查地址或网络');

  const buf = buildCbz({
    title: task.title || '未命名',
    author: task.author || '',
    summary: task.summary || '',
    pages: ok,
  });
  return { buf, ext: '.cbz', mime: 'application/vnd.comicbook+zip', pages: ok.length };
}

async function runAudio(task) {
  const tracks = (task.tracks || []).slice(0, MAX_ITEMS);
  if (!tracks.length) throw new Error('audio 任务需要 tracks[{title,url}]');
  let done = 0;

  const got = await mapPool(tracks, CONCURRENCY, async (t) => {
    try {
      const r = await fetchBinary(t.url, { referer: task.referer });
      done++;
      progress(task.id, done, tracks.length, t.title || '');
      const mt = (r.mime || '').toLowerCase();
      const ext = mt.includes('flac') ? '.flac' : mt.includes('mp4') ? '.m4a' : mt.includes('ogg') ? '.ogg' : '.mp3';
      return { name: (t.title || 'track') + ext, title: t.title, data: r.buf };
    } catch (e) {
      done++;
      progress(task.id, done, tracks.length, '失败：' + (t.title || '').slice(0, 30));
      return null;
    }
  });

  const ok = got.filter(Boolean);
  if (!ok.length) throw new Error('所有音轨都抓取失败');

  const set = buildAudioSet({ tracks: ok });
  const zip = require('./zip').ZipWriter;
  const z = new zip();
  for (const f of set.files) z.add(f.name, f.data);
  return { buf: z.build(), ext: '.zip', mime: 'application/zip', tracks: ok.length };
}

async function runVideo(task) {
  const url = task.video || (task.pages || [])[0];
  if (!url) throw new Error('video 任务需要 video 地址');
  progress(task.id, 0, 1, '下载中');
  const r = await fetchBinary(url, { referer: task.referer });
  progress(task.id, 1, 1, '完成');
  const v = buildVideo({ name: url, data: r.buf });
  return { buf: v.files[0].data, ext: path.extname(v.files[0].name) || '.mp4', mime: 'video/mp4' };
}

const RUNNERS = { book: runBook, comic: runComic, audio: runAudio, video: runVideo };

/**
 * 执行一个任务。失败不抛给调用方 —— 写进任务记录，让 App 能显示原因。
 * @param {object} task
 */
async function runTask(task) {
  const fn = RUNNERS[task.kind];
  try {
    if (!fn) throw new Error('未知类型：' + task.kind);
    store.taskUpdate(task.id, { state: 'running', startedAt: Date.now() });
    const out = await fn(task);

    const id = store.newId('lib');
    const dir = path.join(store.LIB_DIR, id);
    fs.mkdirSync(dir, { recursive: true });
    const fileName = sanitize(task.title || 'untitled') + out.ext;
    store.writeAtomic(path.join(dir, fileName), out.buf);

    const meta = {
      id,
      title: task.title || '未命名',
      author: task.author || '',
      kind: task.kind,
      format: out.ext.replace('.', '').toUpperCase(),
      mime: out.mime,
      file: fileName,
      bytes: out.buf.length,
      pages: out.pages || 0,
      tracks: out.tracks || 0,
      // 来源声明：交付记录里必须写清「这份成品是谁抓的、原始地址是什么」，
      // 用户日后要主张权利或删除，有据可查。
      source: { taskId: task.id, origin: task.origin || '', note: task.note || '' },
      createdAt: Date.now(),
    };
    fs.writeFileSync(path.join(dir, 'meta.json'), JSON.stringify(meta, null, 2), 'utf8');
    store.libAdd(meta);

    store.taskUpdate(task.id, {
      state: 'done',
      libId: id,
      bytes: out.buf.length,
      finishedAt: Date.now(),
      error: '',
    });
    return meta;
  } catch (e) {
    store.taskUpdate(task.id, {
      state: 'failed',
      error: e.message || String(e),
      finishedAt: Date.now(),
    });
    return null;
  }
}

module.exports = { runTask, RUNNERS, mapPool };
