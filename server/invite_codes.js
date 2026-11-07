// server/invite_codes.js — 邀请码系统
// 管理员生成邀请码，分享给别人后可使用 NAS 的搜索/源能力。
// 权限级别：search（只能搜索）/ full（搜索+管理）
// 邀请码存 data/invite-codes.json
'use strict';
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const DATA = process.env.TH_DATA_DIR || path.join(__dirname, 'data');
const FILE = path.join(DATA, 'invite-codes.json');

function load() {
  try { return JSON.parse(fs.readFileSync(FILE, 'utf8')); } catch (e) { return []; }
}
function save(codes) {
  fs.writeFileSync(FILE, JSON.stringify(codes, null, 2));
}

class InviteCodes {
  constructor() {
    this.codes = load();
  }

  // 生成邀请码（管理员操作）
  generate(opts = {}) {
    const code = 'TH-' + crypto.randomBytes(4).toString('hex').toUpperCase();
    const rec = {
      code,
      permission: opts.permission || 'search',  // 'search' | 'full'
      note: opts.note || '',                    // 备注（给谁用的）
      createdBy: opts.createdBy || 'admin',
      createdAt: new Date().toISOString(),
      usedBy: [],       // [{deviceId, ip, at}]
      maxUses: opts.maxUses || 0,  // 0 = 不限次数
      expiresAt: opts.expiresAt || '',  // 空 = 不过期
      enabled: true,
    };
    this.codes.push(rec);
    save(this.codes);
    return rec;
  }

  // 验证邀请码（免鉴权端点调用）
  validate(code, deviceId, ip) {
    const rec = this.codes.find(c => c.code === code && c.enabled);
    if (!rec) return { ok: false, error: '邀请码无效或已禁用' };
    if (rec.expiresAt && new Date(rec.expiresAt) < new Date()) return { ok: false, error: '邀请码已过期' };
    if (rec.maxUses > 0 && rec.usedBy.length >= rec.maxUses) return { ok: false, error: '邀请码使用次数已满' };

    // 记录使用
    rec.usedBy.push({ deviceId: deviceId || 'unknown', ip: ip || '', at: new Date().toISOString() });
    save(this.codes);

    return {
      ok: true,
      permission: rec.permission,
      code: rec.code,
      note: rec.note,
    };
  }

  // 列出所有邀请码（管理员操作）
  list() {
    return this.codes.map(c => ({
      code: c.code,
      permission: c.permission,
      note: c.note,
      enabled: c.enabled,
      usedCount: c.usedBy.length,
      maxUses: c.maxUses,
      createdAt: c.createdAt,
      expiresAt: c.expiresAt,
      lastUsed: c.usedBy.length ? c.usedBy[c.usedBy.length - 1].at : null,
    }));
  }

  // 禁用/启用
  toggle(code, enabled) {
    const rec = this.codes.find(c => c.code === code);
    if (rec) { rec.enabled = enabled; save(this.codes); }
    return rec;
  }

  // 删除
  remove(code) {
    const idx = this.codes.findIndex(c => c.code === code);
    if (idx >= 0) { this.codes.splice(idx, 1); save(this.codes); return true; }
    return false;
  }
}

module.exports = InviteCodes;
