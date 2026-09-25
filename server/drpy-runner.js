// ─────────────────────────────────────────────────────────────────────────────
// drpy-runner.js — drpy 源脚本的**一次性子进程执行器**
//
// 为什么 drpy 不能在主进程里跑（两条都是实测踩出来的）：
//
//   1) **同步 HTTP 会冻住事件循环。**
//      drpy 的 `req()` 是同步的（源脚本都按同步写），实现它必须阻塞线程。
//      在主进程里阻塞 = 一次影视搜索期间整个后端不响应（心跳、其它请求全停）。
//      放进子进程，阻塞的只是这个一次性子进程。
//
//   2) **第三方源会把进程打死。**
//      源里 `(async()=>{ fetch(...) })()` 之类的异步异常脱离一切 try/catch，
//      Node 默认直接结束进程。实测导入音源时整脚本就被一条源的
//      `getaddrinfo ENOTFOUND` 打断过。子进程里怎么炸都只是"这一条源失败"。
//
// 协议：stdin 收一行 JSON `{code, method, args}` → stdout 输出一行 JSON 结果。
// 进程内走 `TH_DRPY_INPROC=1` 分支，调用 engine-drpy 的同步执行路径。
'use strict';
process.env.TH_DRPY_INPROC = '1';
// 子进程里的兜底：任何逃逸异常都不该变成"无输出"，否则父进程只能猜。
process.on('unhandledRejection', (e) => {
  process.stdout.write(JSON.stringify({ error: '未处理的异步异常: ' + String((e && e.message) || e) }) + '\n');
  process.exit(0);
});
process.on('uncaughtException', (e) => {
  process.stdout.write(JSON.stringify({ error: '未捕获异常: ' + String((e && e.message) || e) }) + '\n');
  process.exit(0);
});

let raw = '';
process.stdin.on('data', (d) => { raw += d; });
process.stdin.on('end', async () => {
  let job;
  try { job = JSON.parse(raw); } catch (e) {
    process.stdout.write(JSON.stringify({ error: '作业解析失败: ' + e.message }) + '\n');
    return process.exit(0);
  }
  let out;
  try {
    const drpy = require('./engine-drpy.js');
    out = await drpy.runSource(job.code, job.method, job.args || []);
  } catch (e) {
    out = { error: String((e && e.message) || e) };
  }
  try {
    process.stdout.write(JSON.stringify({ ok: true, result: out === undefined ? null : out }) + '\n');
  } catch (e) {
    process.stdout.write(JSON.stringify({ ok: false, error: '结果无法序列化: ' + e.message }) + '\n');
  }
  process.exit(0);
});
