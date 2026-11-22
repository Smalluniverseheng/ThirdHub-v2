'use strict';
// CBZ 生成器 + 媒体集合生成器。
//
// CBZ = ZIP 里放一堆图片，加一份 ComicInfo.xml。它是漫画界事实标准，
// 几乎所有阅读器（含本 App 的漫画阅读）都能直接打开。
// 用 CBZ 而不是「下载一个文件夹」的理由：单文件可校验、可续传、
// 移动端一次拿到就是完整的，不会出现「少了第 37 页」。

const path = require('path');
const { ZipWriter } = require('./zip');

const XML_ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;' };
const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => XML_ESC[c]);

const IMG_EXT = new Set(['.jpg', '.jpeg', '.png', '.webp', '.gif', '.avif', '.bmp']);
const MIME = {
  '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png',
  '.webp': 'image/webp', '.gif': 'image/gif', '.avif': 'image/avif', '.bmp': 'image/bmp',
};

/**
 * @param {object} comic
 * @param {string} comic.title
 * @param {string} [comic.author]
 * @param {string} [comic.summary]
 * @param {Array<{name:string, data:Buffer}>} comic.pages 按页序传入
 * @returns {Buffer}
 */
function buildCbz(comic) {
  const pages = (comic.pages || []).filter((p) => p && p.data && p.data.length);
  if (!pages.length) throw new Error('CBZ 至少需要一页图片');

  const z = new ZipWriter();
  const width = 4; // 001.jpg 这样定宽，阅读器按文件名字典序排页才不会乱

  pages.forEach((p, i) => {
    let ext = path.extname(p.name || '').toLowerCase();
    if (!IMG_EXT.has(ext)) ext = '.jpg';
    const seq = String(i + 1).padStart(width, '0');
    z.add(`${seq}${ext}`, p.data);
  });

  const info = `<?xml version="1.0" encoding="utf-8"?>
<ComicInfo xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <Title>${esc(comic.title || '')}</Title>
${comic.author ? '  <Writer>' + esc(comic.author) + '</Writer>\n' : ''}${comic.summary ? '  <Summary>' + esc(comic.summary) + '</Summary>\n' : ''}  <PageCount>${pages.length}</PageCount>
  <LanguageISO>zh</LanguageISO>
</ComicInfo>`;
  z.add('ComicInfo.xml', info);

  return z.build();
}

const AUDIO_EXT = new Set(['.mp3', '.m4a', '.aac', '.flac', '.ogg', '.opus', '.wav']);
const VIDEO_EXT = new Set(['.mp4', '.m4v', '.mkv', '.webm', '.mov']);

function extOf(name, fallback) {
  const e = path.extname(String(name || '')).toLowerCase();
  return e || fallback;
}

/**
 * 音频集合：保留原始压缩格式（**不转码**，转码只会二次损失音质），
 * 额外写一份 m3u 播放列表，任何播放器都能按顺序播。
 *
 * @param {object} album
 * @param {Array<{name:string, data:Buffer, title?:string}>} album.tracks
 * @returns {{files: Array<{name:string, data:Buffer}>, mime: string}}
 */
function buildAudioSet(album) {
  const tracks = (album.tracks || []).filter((t) => t && t.data && t.data.length);
  if (!tracks.length) throw new Error('音频集合至少需要一条');

  const files = [];
  const m3u = ['#EXTM3U'];
  tracks.forEach((t, i) => {
    let ext = extOf(t.name, '.mp3');
    if (!AUDIO_EXT.has(ext)) ext = '.mp3';
    const seq = String(i + 1).padStart(3, '0');
    const nm = `${seq} - ${sanitize(t.title || path.basename(String(t.name || ''), path.extname(String(t.name || ''))) || 'track')}${ext}`;
    files.push({ name: nm, data: t.data });
    m3u.push(nm);
  });
  files.push({ name: 'playlist.m3u', data: Buffer.from(m3u.join('\n') + '\n', 'utf8') });
  return { files, mime: 'audio/mpeg' };
}

/**
 * 视频：原样保留，不做转码。
 * 转码在手机侧得不偿失（本机解码能力足够），而桌面端若转码会烧 CPU 且损失画质。
 */
function buildVideo(one) {
  if (!one || !one.data || !one.data.length) throw new Error('视频文件为空');
  let ext = extOf(one.name, '.mp4');
  if (!VIDEO_EXT.has(ext)) ext = '.mp4';
  return { files: [{ name: 'video' + ext, data: one.data }], mime: 'video/mp4' };
}

/** 去掉路径分隔符与文件系统保留字符，防止写盘时越界。 */
function sanitize(s) {
  return String(s || '')
    .replace(/[\\/:*?"<>|\u0000-\u001f]/g, '_')
    .replace(/^\.+/, '')
    .slice(0, 120)
    .trim() || 'untitled';
}

module.exports = { buildCbz, buildAudioSet, buildVideo, sanitize, IMG_EXT, AUDIO_EXT, VIDEO_EXT, MIME };
