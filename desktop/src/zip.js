'use strict';
// 极简 ZIP 写入器（只实现 EPUB / CBZ 需要的部分）。
//
// 为什么不引第三方包：
//   镜像体积和供应链风险。一个 ZIP 只需要 local header + central directory +
//   EOCD 三块结构，自己写 80 行比拉一个包更可控 —— 也不会有人往你的
//   docker 镜像里塞 postinstall 脚本。
//
// 支持：deflate / store 两种方法、UTF-8 文件名（走 flag bit 11）、
//       DOS 时间戳、CRC32。不支持 ZIP64（单个 EPUB 超 4GB 本来也不合法）。

const zlib = require('zlib');

// ── CRC32 ────────────────────────────────────────────────────
const CRC_TABLE = (() => {
  const t = new Int32Array(256);
  for (let i = 0; i < 256; i++) {
    let c = i;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[i] = c;
  }
  return t;
})();

function crc32(buf) {
  let c = -1;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
}

// ── DOS 时间 ─────────────────────────────────────────────────
function dosTime(d) {
  const time = ((d.getHours() & 0x1f) << 11) | ((d.getMinutes() & 0x3f) << 5) | ((d.getSeconds() / 2) & 0x1f);
  const date = (((d.getFullYear() - 1980) & 0x7f) << 9) | (((d.getMonth() + 1) & 0x0f) << 5) | (d.getDate() & 0x1f);
  return { time, date };
}

class ZipWriter {
  constructor() {
    this.entries = [];
  }

  /**
   * @param {string} name 归档内路径（用 / 分隔，不要以 / 开头）
   * @param {Buffer|string} data
   * @param {{store?: boolean}} [opt] store=true 表示不压缩（EPUB 的 mimetype 必须这样）
   */
  add(name, data, opt) {
    const store = !!(opt && opt.store);
    const raw = Buffer.isBuffer(data) ? data : Buffer.from(String(data), 'utf8');
    const crc = crc32(raw);
    const body = store ? raw : zlib.deflateRawSync(raw, { level: 9 });
    this.entries.push({ name: Buffer.from(name, 'utf8'), method: store ? 0 : 8, crc, raw: raw.length, body });
    return this;
  }

  build() {
    const now = new Date();
    const { time, date } = dosTime(now);
    const locals = [];
    const centrals = [];
    let offset = 0;

    for (const e of this.entries) {
      const nameLen = e.name.length;
      const lh = Buffer.alloc(30);
      lh.writeUInt32LE(0x04034b50, 0);        // local file header signature
      lh.writeUInt16LE(20, 4);                // version needed
      lh.writeUInt16LE(0x0800, 6);            // flags: UTF-8 name
      lh.writeUInt16LE(e.method, 8);
      lh.writeUInt16LE(time, 10);
      lh.writeUInt16LE(date, 12);
      lh.writeUInt32LE(e.crc, 14);
      lh.writeUInt32LE(e.body.length, 18);
      lh.writeUInt32LE(e.raw, 22);
      lh.writeUInt16LE(nameLen, 26);
      lh.writeUInt16LE(0, 28);                // extra len
      locals.push(lh, e.name, e.body);

      const ch = Buffer.alloc(46);
      ch.writeUInt32LE(0x02014b50, 0);        // central directory signature
      ch.writeUInt16LE(20, 4);                // version made by
      ch.writeUInt16LE(20, 6);                // version needed
      ch.writeUInt16LE(0x0800, 8);
      ch.writeUInt16LE(e.method, 10);
      ch.writeUInt16LE(time, 12);
      ch.writeUInt16LE(date, 14);
      ch.writeUInt32LE(e.crc, 16);
      ch.writeUInt32LE(e.body.length, 20);
      ch.writeUInt32LE(e.raw, 24);
      ch.writeUInt16LE(nameLen, 28);
      ch.writeUInt16LE(0, 30);                // extra
      ch.writeUInt16LE(0, 32);                // comment
      ch.writeUInt16LE(0, 34);                // disk start
      ch.writeUInt16LE(0, 36);                // internal attrs
      ch.writeUInt32LE(0, 38);                // external attrs
      ch.writeUInt32LE(offset, 42);           // local header offset
      centrals.push(ch, e.name);

      offset += 30 + nameLen + e.body.length;
    }

    const cdBuf = Buffer.concat(centrals);
    const eocd = Buffer.alloc(22);
    eocd.writeUInt32LE(0x06054b50, 0);
    eocd.writeUInt16LE(0, 4);
    eocd.writeUInt16LE(0, 6);
    eocd.writeUInt16LE(this.entries.length, 8);
    eocd.writeUInt16LE(this.entries.length, 10);
    eocd.writeUInt32LE(cdBuf.length, 12);
    eocd.writeUInt32LE(offset, 16);
    eocd.writeUInt16LE(0, 20);

    return Buffer.concat([...locals, cdBuf, eocd]);
  }
}

module.exports = { ZipWriter, crc32 };
