// ─────────────────────────────────────────────────────────────────────────────
// drpy-http-sync.js — 给 drpy 源脚本用的**同步** HTTP
//
// 为什么必须是同步的：
//   drpy 引擎里写着
//       function request(url,obj){ ...; let res = req(url, obj); let html = res.content || ""; ... }
//   注意 `req` 的返回值**没有 await** —— 在原版 drpy 里 `req` 是宿主 App 提供的
//   **阻塞式** HTTP（JNI 调用）。源脚本的写法全都建立在这个前提上：
//   `js:` 解析规则里常见 `let html = getHtml(url)`，后面直接当字符串用。
//   换成 async 就得把所有源脚本一起改写 —— 那等于放弃整个源生态。
//
// 怎么做到同步：
//   开一个常驻 Worker 线程去做真正的 fetch；主线程用 `Atomics.wait` 阻塞等待，
//   完成后用 `receiveMessageOnPort` 同步取回结果。这是 Node 里实现同步调用的
//   标准做法（等价于 deasync）：主线程确实会停住，但请求是发生在 Worker 里的。
//
// ★ 使用前提（很重要）：
//   本模块会**阻塞调用它的线程**。所以它只在
//   `drpy-runner.js`（一次性子进程）里使用 —— 后端主进程不会被冻住，
//   源脚本就算卡死/崩掉也只影响那个子进程。
//   绝不要在 server/index.js 的请求路径上直接 require 本模块。
'use strict';
const { Worker, MessageChannel, receiveMessageOnPort } = require('worker_threads');

const WORKER_SRC = `
const { parentPort } = require('worker_threads');
let out = null;
parentPort.on('message', async (msg) => {
  if (msg && msg.__init) { out = msg.port; return; }
  const { id, sab, url, options } = msg;
  const i32 = new Int32Array(sab);
  let res;
  try {
    const ac = options.timeoutMs ? AbortSignal.timeout(options.timeoutMs) : undefined;
    const r = await fetch(url, {
      method: options.method || 'GET',
      headers: options.headers || {},
      body: options.body,
      signal: ac,
      redirect: 'follow',
    });
    const buf = Buffer.from(await r.arrayBuffer());
    res = {
      status: r.status,
      headers: Object.fromEntries(r.headers.entries()),
      bodyBase64: buf.toString('base64'),
    };
  } catch (e) {
    // 把 cause 一起带出来：undici 的 "fetch failed" 本身没有信息量，
    // 真因（ENOTFOUND / ECONNREFUSED / 证书 / 代理）都在 cause 里。
    // 注：本段位于 WORKER_SRC 模板字符串内，**不要出现反引号**。
    const c = e && e.cause;
    res = { error: String((e && e.message) || e) + (c ? ' [' + String(c.code || c.message || c) + ']' : '') };
  }
  // 顺序很重要：先把结果放进端口队列，再置位共享内存唤醒主线程。
  // 反过来会出现"被唤醒时消息还没入队"的竞态。
  out.postMessage({ id, res });
  Atomics.store(i32, 0, 1);
  Atomics.notify(i32, 0);
});
`;

let worker = null;
let ch = null;
let seq = 0;

function ensureWorker() {
  if (worker) return;
  ch = new MessageChannel();
  worker = new Worker(WORKER_SRC, { eval: true });
  worker.unref();
  worker.postMessage({ __init: true, port: ch.port2 }, [ch.port2]);
}

function killWorker() {
  try { if (worker) worker.terminate(); } catch (_) { }
  worker = null; ch = null;
}

/**
 * 同步抓取。
 * @param {string} url
 * @param {{method?:string, headers?:object, body?:any, timeoutMs?:number}} [options]
 * @returns {{status:number, headers:object, body:string}|{error:string}}
 */
function syncFetch(url, options = {}) {
  const timeoutMs = Number(options.timeoutMs) || 12000;
  let body = options.body;
  if (body != null && typeof body !== 'string') {
    if (body instanceof URLSearchParams) body = body.toString();
    else if (Buffer.isBuffer(body)) body = body;
    else body = JSON.stringify(body);
  }
  ensureWorker();
  const id = ++seq;
  const sab = new SharedArrayBuffer(4);
  const i32 = new Int32Array(sab);
  try {
    worker.postMessage({ id, sab, url, options: { ...options, body, timeoutMs } });
  } catch (e) {
    killWorker();
    return { error: '同步 HTTP worker 不可用: ' + String(e.message || e) };
  }
  // 多给 2s：worker 里的 AbortSignal 负责超时，这里只是兜底防永久挂住
  const r = Atomics.wait(i32, 0, 0, timeoutMs + 2000);
  if (r === 'timed-out') {
    // 超时说明 worker 卡住了 —— 直接换掉，别让后面的请求继续排队等它
    killWorker();
    return { error: '同步 HTTP 超时(' + timeoutMs + 'ms): ' + String(url).slice(0, 120) };
  }
  let msg = null;
  for (let i = 0; i < 200 && !msg; i++) {
    const got = receiveMessageOnPort(ch.port1);
    if (got && got.message) {
      if (got.message.id === id) { msg = got.message; break; }
      continue;   // 上一个作业的残留消息，丢掉继续找自己那条
    }
    // 队列暂时空：极短自旋再试（正常路径下第一次就该命中）
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 2);
  }
  if (!msg) { killWorker(); return { error: '同步 HTTP 取回结果失败（端口无消息）' }; }
  const res = msg.res;
  if (res.error) return { error: res.error };
  return {
    status: res.status,
    headers: res.headers,
    body: Buffer.from(res.bodyBase64, 'base64').toString('utf8'),
  };
}

module.exports = { syncFetch };
