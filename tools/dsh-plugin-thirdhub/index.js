/**
 * dsh-plugin-thirdhub —— ThirdHub 桥接插件（DSH / cordis 插件）
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 它解决什么：
 *   让**手机上的 ThirdHub App** 通过「同一账号」自动发现并连接本机 DSH。
 *   装好并重启 DSH 后，这台电脑会持续出现在手机端的设备列表里（在线状态、
 *   局域网地址、DSH 能力全部自报），App 端自动配对、不用扫码、不用手输地址。
 *
 * 为什么是插件而不是独立脚本（用户明确要求）：
 *   · 插件挂在 DSH 进程里 —— DSH 起它就起、DSH 停它就停，生命周期一致；
 *   · 资源（定时器/网络）通过 ctx.effect 注册，卸载时自动清理，不会遗留进程；
 *   · 配置走 cordis patch 层（和 DSH 其它插件同一套），可在 profile 里覆盖；
 *   · 用 dsh plugin add / remove 管理，与生态一致。
 *
 * 配置（见 cordis.patch.yml，可在 profile 的 patch 里覆盖）：
 *   hubUrl     ThirdHub 中枢地址（默认 http://127.0.0.1:9527，即桌面端后端）
 *   account    与手机 App 相同的账号（自动配对的关键）
 *   password   账号密码
 *   name       显示在手机设备列表里的名字（默认取主机名）
 *   lanUrl     本机对局域网暴露的 DSH 地址（默认自动探测 本机IP:DSH端口）
 *   dshPort    本机 DSH 的端口（默认 3080）
 *   intervalMs 心跳间隔（默认 30000 毫秒）
 * ═══════════════════════════════════════════════════════════════════════════
 */
import os from 'node:os'
import fs from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'

/** cordis 约定：插件名（用作 composition 里的唯一 id，也是 patch 定位用的名字） */
export const name = 'thirdhub-bridge'

/** 依赖声明：本插件不消费 DSH 内部服务（只走网络），因此不 inject 任何服务。 */
export const inject = []

export function apply(ctx, config = {}) {
  const hub = String(config.hubUrl || 'http://127.0.0.1:9527').replace(/\/+$/, '')
  const account = String(config.account || '')
  const password = String(config.password || '')
  const dshPort = String(config.dshPort || '3080')
  const intervalMs = Number(config.intervalMs || 30000)

  // 设备名：配置 > 主机名
  const devName = String(config.name || os.hostname() || '电脑')

  // 局域网地址：配置 > 自动探测「本机 IPv4 + DSH 端口」
  const lanUrl = String(config.lanUrl || '') || (() => {
    for (const list of Object.values(os.networkInterfaces())) {
      for (const n of list || []) {
        if (!n.internal && n.family === 'IPv4' && !n.address.startsWith('169.254.')) {
          return `http://${n.address}:${dshPort}`
        }
      }
    }
    return ''
  })()

  // iid / peerToken 落在 DSH_HOME（或用户目录）下 —— 重启 DSH 不换身份，
  // 这样手机端认得是同一台电脑，不会每次重启都多出一个"新设备"。
  const stateDir = process.env.DSH_HOME
    ? path.join(process.env.DSH_HOME, 'thirdhub-bridge')
    : path.join(os.homedir(), '.dsh', 'thirdhub-bridge')
  const iidFile = path.join(stateDir, 'iid')
  const tokenFile = path.join(stateDir, 'token')

  let iid = ''
  let peerToken = ''
  try {
    fs.mkdirSync(stateDir, { recursive: true })
    iid = fs.readFileSync(iidFile, 'utf8').trim()
  } catch { /* 首次运行 */ }
  if (!iid) {
    iid = crypto.randomUUID()
    try { fs.writeFileSync(iidFile, iid) } catch { /* 只读环境也允许 */ }
  }
  try { peerToken = fs.readFileSync(tokenFile, 'utf8').trim() } catch { /* 未登录过 */ }

  let joined = false
  let stopped = false

  const log = (m) => ctx.logger?.info?.(`[thirdhub-bridge] ${m}`) ?? console.log(`[thirdhub-bridge] ${m}`)
  const warn = (m) => ctx.logger?.warn?.(`[thirdhub-bridge] ${m}`) ?? console.warn(`[thirdhub-bridge] ${m}`)

  async function post(p, body) {
    const r = await fetch(hub + p, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...(peerToken ? { 'X-TH-Peer': peerToken } : {}),
      },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(9000),
    })
    const text = await r.text()
    let j = null
    try { j = JSON.parse(text) } catch { /* 非 JSON */ }
    return { ok: r.ok, code: r.status, j, text }
  }

  async function join() {
    if (!account) {
      warn('未配置 account —— 请在 cordis.patch.yml 的 config 里填上（要与手机 App 登录的同一账号）')
      return false
    }
    const body = {
      kind: 'dsa',                       // 「DSH Agent」端类型（App 端按它认领电脑）
      name: devName,
      url: lanUrl,                       // 手机直连首选（局域网）
      caps: ['dsh', `dsh:${lanUrl || `http://127.0.0.1:${dshPort}`}`],
      tools: [],
      iid,
      ...(peerToken ? { peerToken } : { account, password }),
    }
    try {
      const r = await post('/agent/peer/join', body)
      if (!r.ok) { warn(`join 失败 HTTP ${r.code}（${String(r.j?.error?.message || r.text).slice(0, 100)}）`); return false }
      const t = r.j?.data?.peerToken || r.j?.peerToken || ''
      if (t) {
        peerToken = t
        try { fs.writeFileSync(tokenFile, t) } catch { /* 忽略 */ }
      }
      joined = true
      const on = r.j?.data?.online ?? r.j?.online
      log(`已接入中枢 · 设备名「${devName}」· 在线端=${on ?? '?'} · 地址=${lanUrl || '(未探测到，手机将走 ipv6/tunnel)'}`)
      return true
    } catch (e) {
      warn(`join 异常：${e?.message || e}（中枢未起或地址不对；稍后自动重试）`)
      return false
    }
  }

  async function beat() {
    if (stopped) return
    if (!joined) { await join(); return }
    try {
      const r = await post('/agent/peer/beat', {
        peerToken,
        url: lanUrl,
        caps: ['dsh', `dsh:${lanUrl || `http://127.0.0.1:${dshPort}`}`],
      })
      if (!r.ok) { joined = false; warn(`心跳失败 HTTP ${r.code} —— 下一轮重新加入`) }
    } catch {
      joined = false /* 下轮重 join（中枢重启/网络抖动都会走这条） */
    }
  }

  // ★ 用 ctx.effect 注册：DSH 卸载/重启插件时自动清掉定时器，不留残余进程。
  ctx.effect(() => {
    void join()
    const timer = setInterval(() => { void beat() }, intervalMs)
    return () => {
      stopped = true
      clearInterval(timer)
    }
  })

  log(`已加载（中枢 ${hub} · 心跳 ${intervalMs / 1000}s${account ? '' : ' · 待配置 account'}）`)
}
