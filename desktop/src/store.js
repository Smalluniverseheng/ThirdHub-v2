'use strict';
// 成品库 + 任务持久化。
//
// 目录约定
//   /data/lib/<id>/meta.json     成品元数据（标题、格式、字节数、来源声明）
//   /data/lib/<id>/<file>        成品文件（EPUB / CBZ / MP3 集合 / MP4）
//   /data/lib/index.json         成品索引（进页面不用扫盘）
//   /data/tasks.json             任务记录（含失败原因）
//
// 全部走「先写临时文件再 rename」：断电/容器被杀时不会留下半个文件，
// 手机端也永远不会拉到一份没写完的成品。
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const DATA_DIR = process.env.TH_DATA_DIR || '/data';
const LIB_DIR = path.join(DATA_DIR, 'lib');
const TASKS_FILE = path.join(DATA_DIR, 'tasks.json');

function ensureDirs() {
  fs.mkdirSync(LIB_DIR, { recursive: true });
}

function newId(prefix) {
  return (
    (prefix || 'x') + '-' + Date.now().toString(36) + '-' + crypto.randomBytes(3).toString('hex')
  );
}

function readJson(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (_) {
    return fallback;
  }
}

/** 原子写：临时文件 + rename，避免读到半截 JSON。 */
function writeJson(file, obj) {
  const tmp = file + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(obj, null, 2), 'utf8');
  fs.renameSync(tmp, file);
}

function writeAtomic(file, buf) {
  const tmp = file + '.part';
  fs.writeFileSync(tmp, buf);
  fs.renameSync(tmp, file);
}

// ── 成品库 ───────────────────────────────────────────────────
function libIndex() {
  return readJson(path.join(LIB_DIR, 'index.json'), { items: [] });
}

function libList() {
  return libIndex().items.slice().sort((a, b) => (b.createdAt || 0) - (a.createdAt || 0));
}

function libGet(id) {
  if (!/^[a-z0-9-]{3,64}$/i.test(String(id || ''))) return null;
  const dir = path.join(LIB_DIR, String(id));
  const meta = readJson(path.join(dir, 'meta.json'), null);
  if (!meta) return null;
  return { ...meta, dir, filePath: path.join(dir, meta.file) };
}

function libAdd(meta) {
  const idx = libIndex();
  idx.items = idx.items.filter((x) => x.id !== meta.id);
  idx.items.unshift(meta);
  writeJson(path.join(LIB_DIR, 'index.json'), idx);
  return meta;
}

function libRemove(id) {
  const it = libGet(id);
  if (!it) return false;
  const idx = libIndex();
  idx.items = idx.items.filter((x) => x.id !== id);
  writeJson(path.join(LIB_DIR, 'index.json'), idx);
  try {
    fs.rmSync(it.dir, { recursive: true, force: true });
  } catch (_) {
    /* 目录被占/只读时索引已删，文件残留不影响一致性 */
  }
  return true;
}

// ── 任务 ─────────────────────────────────────────────────────
function tasksAll() {
  return readJson(TASKS_FILE, { tasks: [] });
}

function taskAdd(t) {
  const db = tasksAll();
  db.tasks.unshift(t);
  if (db.tasks.length > 200) db.tasks = db.tasks.slice(0, 200);
  writeJson(TASKS_FILE, db);
}

function taskUpdate(id, patch) {
  const db = tasksAll();
  const i = db.tasks.findIndex((x) => x.id === id);
  if (i < 0) return null;
  db.tasks[i] = { ...db.tasks[i], ...patch, updatedAt: Date.now() };
  writeJson(TASKS_FILE, db);
  return db.tasks[i];
}

module.exports = {
  DATA_DIR, LIB_DIR, ensureDirs, newId,
  libList, libGet, libAdd, libRemove,
  tasksAll, taskAdd, taskUpdate,
  writeAtomic, writeJson, readJson,
};
