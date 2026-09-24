// 聊天协议端到端自检: 直接驱动 server/routes-data.js 的 handle(),
// 用假的 req/res/send 走一遍完整协议流程。不依赖后端服务是否在跑。
//
// 覆盖点(每一条都对应一个真会出问题的地方):
//   1) 上行 → 服务端分配会话内单调 seq
//   2) 同 cid 重发 → 幂等, 回原来那个 seq, 不产生重复消息     ← 离线补发的命门
//   3) since 增量拉取只返回更新的
//   4) 会话索引(count/lastSeq/lastTs)被正确带出来
//   5) 非法请求(缺 sid/cid)返回 400 而不是 500
'use strict';
const path = require('path');
const fs = require('fs');
const os = require('os');

const DATA = fs.mkdtempSync(path.join(os.tmpdir(), 'chatdata-'));
// ★ 路径要两种布局都能跑：仓库内脚本在 `server/` 里（同目录），
//   但**发布 zip 是平铺布局**（脚本和 routes-data.js 同级），此时 `../server/` 不存在 ——
//   历史后果：解包冒烟时这一项报 MODULE_NOT_FOUND，看着像"包坏了"，其实是测试自己找不到路。
const routesPath = fs.existsSync(path.join(__dirname, 'routes-data.js'))
  ? path.join(__dirname, 'routes-data.js')
  : path.join(__dirname, '..', 'server', 'routes-data.js');
const routes = require(routesPath);

let fails = 0;
function ck(name, cond, extra) {
  if (cond) {
    console.log('  OK   ' + name);
  } else {
    fails++;
    console.log('  FAIL ' + name + (extra ? '  -> ' + extra : ''));
  }
}

/** 造一次调用: 返回 {status, json} */
async function call(method, fullPath, obj) {
  const u = new URL('http://x' + fullPath);
  let out = null;
  const send = (code, payload) => { out = { status: code, json: payload }; return true; };
  const req = { method: method, headers: {} };
  const res = { writeHead() {}, end() {} };
  const body = obj === undefined ? '' : JSON.stringify(obj);
  const hit = await routes.handle(req, res, body, u, u.pathname, send, { DATA: DATA, SECRET: 'test' });
  return { hit: hit, out: out };
}

(async () => {
  console.log('== 1. 建会话 ==');
  let r = await call('POST', '/v1/chat/sessions', { id: 's1', title: '家里人', peer: 'family' });
  ck('建会话 200', r.out && r.out.status === 200, JSON.stringify(r.out && r.out.json));

  console.log('== 2. 上行三条消息, seq 必须 1/2/3 ==');
  const seqs = [];
  for (let i = 1; i <= 3; i++) {
    r = await call('POST', '/v1/chat/send', { v: 1, cid: 'c' + i, sid: 's1', ts: 1000 + i, from: '我', t: 'text', body: '第' + i + '句' });
    seqs.push(r.out && r.out.json && r.out.json.data && r.out.json.data.seq);
  }
  ck('seq = [1,2,3]', JSON.stringify(seqs) === '[1,2,3]', JSON.stringify(seqs));

  console.log('== 3. 幂等: 重发 c1 不能造出第四条 ==');
  r = await call('POST', '/v1/chat/send', { v: 1, cid: 'c1', sid: 's1', ts: 1000 + 1, from: '我', body: '第1句' });
  ck('重发回原 seq=1', r.out.json.data.seq === 1, JSON.stringify(r.out.json));
  ck('标记 dup=true', r.out.json.data.dup === true, JSON.stringify(r.out.json));
  r = await call('GET', '/v1/chat/messages?sid=s1');
  ck('消息总数仍为 3', r.out.json.data.messages.length === 3, '实际 ' + r.out.json.data.messages.length);

  console.log('== 4. since 增量 ==');
  r = await call('GET', '/v1/chat/messages?sid=s1&since=2');
  ck('since=2 只回 1 条(seq 3)', r.out.json.data.messages.length === 1 && r.out.json.data.messages[0].seq === 3,
    JSON.stringify(r.out.json.data.messages));

  console.log('== 5. 会话索引 ==');
  r = await call('GET', '/v1/chat/sessions');
  const s = r.out.json.data.sessions[0];
  ck('count=3', s.count === 3, JSON.stringify(s));
  ck('lastSeq=3', s.lastSeq === 3, JSON.stringify(s));
  ck('title 保留', s.title === '家里人' || s.title === '家里人', JSON.stringify(s));

  console.log('== 6. 非法请求 ==');
  r = await call('POST', '/v1/chat/send', { sid: 's1' });
  ck('缺 cid -> 400', r.out.status === 400, JSON.stringify(r.out));
  r = await call('POST', '/v1/chat/ack', {});
  ck('ack 缺 sid -> 400', r.out.status === 400, JSON.stringify(r.out));

  console.log('== 7. 未命中路径要交回主路由(false) ==');
  r = await call('GET', '/v1/不存在');
  ck('返回 false', r.hit === false, 'got ' + r.hit);

  console.log('== 8. ack 已读游标 ==');
  r = await call('POST', '/v1/chat/ack', { sid: 's1', seq: 3 });
  ck('ack 200 且回 seq=3', r.out.status === 200 && r.out.json.data.seq === 3, JSON.stringify(r.out.json));

  console.log('');
  console.log(fails === 0 ? '全部通过 (0 失败)' : (fails + ' 项失败'));
  try { fs.rmSync(DATA, { recursive: true, force: true }); } catch (e) {}
  process.exit(fails === 0 ? 0 : 1);
})().catch((e) => { console.log('异常: ' + (e && e.stack || e)); process.exit(1); });
