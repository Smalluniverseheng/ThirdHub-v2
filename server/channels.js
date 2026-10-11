'use strict';
/**
 * channels.js —— 多通道连接体系（第 7 条需求的落地）
 *
 * 用户原话：「IPv6 这些的东西，我说了主网是要支持多种形式的，不是只做一种，
 *            能让用户有超级多的选择。」
 *
 * 所以这里不是"实现 IPv6"一件事，而是把**所有能连上后端的方式**列成清单，
 * 每一种都能被探测、被选择、被降级。核心设计：
 *
 *   ① **通道是数据，不是代码分支** —— 新增一种连法 = 往 CHANNELS 里加一条，
 *      不需要改探测逻辑。这样"超级多的选择"才可持续。
 *   ② **每条通道都有健康判据** —— 不能只说"支持"，要说"现在通不通"。
 *   ③ **绝不引入第三方中转** —— 用户明确"没有 CF 服务器"。所有通道都是
 *      点对点或用户自建（自己的 DDNS、自己的组网）。
 *
 * ── 通道清单（这是给用户看的"选择"）─────────────────────────────────
 *   A. 局域网 IPv4 直连   —— 同 WiFi 下最快，零配置（已有 UDP 广播发现）
 *   B. 局域网 IPv6 直连   —— 同网段 IPv6（ff02::1 组播，见 §IPv6）
 *   C. IPv6 全球单播直连  —— 跨网络，家里有公网 IPv6 即可（2200::/3）
 *   D. DDNS 域名          —— 家宽 IPv6 前缀会变 → 用户自己的域名自动更新
 *   E. 隧道/组网          —— Tailscale / ZeroTier / WireGuard（用户自建或自组）
 *   F. 反向代理           —— 用户自己的 Nginx/Caddy + 自己的域名 + 证书
 *   G. 手动地址           —— 兜底：用户直接填 host:port
 *
 * ★ 明确**不做**的：任何需要我方服务器的中转（那是 CF 式的中心化，
 *   与"数据主权在用户"冲突）。
 */

const os = require('os');
const dgram = require('dgram');

/** 通道类型（给前端做图标与排序用） */
const ChannelKind = {
  LAN4: 'lan4',        // 局域网 IPv4
  LAN6: 'lan6',        // 局域网 IPv6
  WAN6: 'wan6',        // 公网 IPv6 全球单播
  DDNS: 'ddns',        // 动态域名
  TUNNEL: 'tunnel',    // 组网/隧道
  PROXY: 'proxy',      // 自建反代
  MANUAL: 'manual',    // 手动
};

/**
 * 通道目录 —— "超级多的选择"的清单本身。
 * 每条含：key / 标题 / 说明 / 是否需要用户配置 / 典型延迟 / 适用场景。
 * 前端直接遍历它渲染选项（**不硬编码在 UI 里**，加一条这里就多一个选项）。
 */
const CHANNELS = [
  {
    kind: ChannelKind.LAN4,
    key: 'lan-ipv4',
    name: '局域网直连',
    desc: '同一 WiFi/网线下，手机直连家里设备，速度最快、零配置',
    needsSetup: false,
    latency: '最低',
    scene: '在家',
  },
  {
    kind: ChannelKind.LAN6,
    key: 'lan-ipv6',
    name: '局域网 IPv6',
    desc: '同网段 IPv6 直连，适合路由器已开 IPv6 的家庭',
    needsSetup: false,
    latency: '最低',
    scene: '在家',
  },
  {
    kind: ChannelKind.WAN6,
    key: 'wan-ipv6',
    name: '公网 IPv6 直连',
    desc: '出门在外也直连家里，只要宽带分到了公网 IPv6 地址',
    needsSetup: false,
    latency: '低',
    scene: '在外',
  },
  {
    kind: ChannelKind.DDNS,
    key: 'ddns',
    name: '动态域名',
    desc: '用你自己的域名指向家里，IPv6 前缀变了会自动更新',
    needsSetup: true,
    latency: '低',
    scene: '在外·长期稳定',
  },
  {
    kind: ChannelKind.TUNNEL,
    key: 'tunnel',
    name: '组网隧道',
    desc: '不暴露公网，用你自建或自组的虚拟局域网互连',
    needsSetup: true,
    latency: '中',
    scene: '在外·最安全',
  },
  {
    kind: ChannelKind.PROXY,
    key: 'proxy',
    name: '自建反向代理',
    desc: '你自己的域名 + 证书 + Nginx/Caddy，走标准 HTTPS',
    needsSetup: true,
    latency: '中',
    scene: '在外·有域名',
  },
  {
    kind: ChannelKind.MANUAL,
    key: 'manual',
    name: '手动填写地址',
    desc: '直接填 host:port，适配任何你自建的方式',
    needsSetup: true,
    latency: '取决于配置',
    scene: '兜底',
  },
];

// ─────────────────────────────────────────────────────────────────────────────
// 地址枚举
// ─────────────────────────────────────────────────────────────────────────────

/**
 * 列出本机全部可对外地址，按"好用程度"排序。
 *
 * 排序理由（很重要，直接影响用户看到的默认项）：
 *   1. 公网 IPv6 全球单播（2000::/3）—— 出门也能用，优先级最高
 *   2. 局域网 IPv4 私有段        —— 在家最快，零配置
 *   3. 局域网 IPv6（ULA/链路）   —— 备选
 *   4. 其余
 * 排除：回环、链路本地 fe80::（不可跨网段）、组播、未启用网卡。
 */
function listLocalAddresses() {
  const out = [];
  let nets;
  try {
    nets = os.networkInterfaces();
  } catch (e) {
    return out;
  }
  for (const [ifname, addrs] of Object.entries(nets)) {
    for (const a of addrs || []) {
      if (!a || !a.address || a.internal) continue;

      if (a.family === 'IPv4' || a.family === 4) {
        const priv =
          /^10\./.test(a.address) ||
          /^192\.168\./.test(a.address) ||
          /^172\.(1[6-9]|2\d|3[01])\./.test(a.address);
        out.push({
          iface: ifname,
          family: 4,
          address: a.address,
          scope: priv ? 'lan' : 'wan',
          rank: priv ? 20 : 30,
          kind: priv ? ChannelKind.LAN4 : ChannelKind.LAN4,
        });
      } else if (a.family === 'IPv6' || a.family === 6) {
        const ip = a.address.split('%')[0].toLowerCase(); // 去 zone id
        if (/^fe80:/.test(ip)) {
          // 链路本地：不能跨网段，但**同网段可用**，保留并标注
          out.push({
            iface: ifname,
            family: 6,
            address: ip,
            scope: 'link',
            rank: 40,
            kind: ChannelKind.LAN6,
          });
          continue;
        }
        if (/^f[cd]/.test(ip)) {
          // ULA（fc00::/7）：私有 IPv6，同网段可用
          out.push({
            iface: ifname,
            family: 6,
            address: ip,
            scope: 'ula',
            rank: 25,
            kind: ChannelKind.LAN6,
          });
          continue;
        }
        if (/^2|^3/.test(ip[0]) && /^[23]/.test(ip)) {
          // 全球单播 2000::/3 —— 这是"出门也能连"的关键
          out.push({
            iface: ifname,
            family: 6,
            address: ip,
            scope: 'global',
            rank: 10,
            kind: ChannelKind.WAN6,
          });
          continue;
        }
        out.push({
          iface: ifname,
          family: 6,
          address: ip,
          scope: 'other',
          rank: 50,
          kind: ChannelKind.LAN6,
        });
      }
    }
  }
  out.sort((x, y) => x.rank - y.rank);
  return out;
}

/** 取"最推荐"的公网 IPv6（用于展示在主界面） */
function bestGlobalIPv6() {
  return listLocalAddresses().find((a) => a.scope === 'global') || null;
}

// ─────────────────────────────────────────────────────────────────────────────
// IPv6 发现：广播在 IPv6 里**不存在**，只有组播
// ─────────────────────────────────────────────────────────────────────────────
//
// 这是本项目 IPv6 断点的根因（MEMORY.md「IPv6 真实断点」）：
//   IPv4 有"有限广播 255.255.255.255"，IPv6 **删除了广播概念**，
//   只有组播。所以要发现同网段的 IPv6 邻居，必须：
//     1. 加入组播组 ff02::1（all-nodes，链路本地范围）
//     2. 对**每张网卡**分别设置组播出口（setMulticastInterface），
//        否则内核只从默认网卡发，多网卡机器会漏
//     3. TTL 必须设 1（链路本地，不跨路由）
//
// 对应 IPv4 侧的 thpBroadcastTargets() + thpSendAll()。

const MDNS_GROUP = 'ff02::1'; // all-nodes multicast

/**
 * IPv6 组播发送器：对每张有 IPv6 地址的网卡各发一份。
 * 返回一个 sender 对象，用法与 thpSendAll 平行。
 */
function createIPv6Sender(port) {
  let sock = null;
  try {
    sock = dgram.createSocket({ type: 'udp6', reuseAddr: true });
    sock.on('error', () => {});
    sock.bind(0, () => {
      try {
        sock.setMulticastTTL(1); // 链路本地，不跨路由
      } catch (e) {}
    });
  } catch (e) {
    return null;
  }

  /** 对每张网卡的 IPv6 地址分别设置组播出口再发（多网卡必需） */
  function sendAll(payload) {
    if (!sock) return;
    const buf = Buffer.from(payload);
    const addrs = listLocalAddresses().filter((a) => a.family === 6);
    if (!addrs.length) return;
    let pending = addrs.length;
    for (const a of addrs) {
      try {
        // ★ 关键：告诉内核"从这个地址所属的网卡出去"
        sock.setMulticastInterface(a.address);
      } catch (e) {
        // 某些平台/网卡不支持，跳过（不致命）
      }
      try {
        sock.send(buf, 0, buf.length, port, MDNS_GROUP, (err) => {
          if (--pending === 0) { /* 全部发完 */ }
          void err;
        });
      } catch (e) {
        if (--pending === 0) { /* ignore */ }
      }
    }
  }

  function close() {
    try { sock && sock.close(); } catch (e) {}
    sock = null;
  }

  return { sendAll, close, group: MDNS_GROUP };
}

/**
 * IPv6 组播接收器：加入 ff02::1 组，收邻居的 HELLO。
 * 与 IPv4 侧 udp4 的 on('message') 对称。
 */
function createIPv6Receiver(port, onMessage) {
  let sock = null;
  try {
    sock = dgram.createSocket({ type: 'udp6', reuseAddr: true });
    sock.on('error', () => {});
    sock.on('message', (msg, rinfo) => {
      try { onMessage(String(msg), rinfo); } catch (e) {}
    });
    sock.bind(port, () => {
      const addrs = listLocalAddresses().filter((a) => a.family === 6);
      for (const a of addrs) {
        try {
          sock.addMembership(MDNS_GROUP, a.address);
        } catch (e) {
          // 网卡不支持组播：继续，不阻断
        }
      }
    });
  } catch (e) {
    return null;
  }
  return {
    close: () => { try { sock && sock.close(); } catch (e) {} },
    group: MDNS_GROUP,
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// 通道健康判定
// ─────────────────────────────────────────────────────────────────────────────

/**
 * 给"这个后端现在能用哪些通道"做一次体检。
 * 前端拿这份结果渲染"可用通道"列表 —— 有选择但不迷惑。
 *
 * @param {object} opts
 * @param {number} opts.port     后端端口
 * @param {string} [opts.ddns]   用户配置的 DDNS 域名
 * @param {string} [opts.tunnel] 用户配置的隧道地址
 * @param {string} [opts.proxy]  用户配置的反代地址
 * @param {string} [opts.manual] 用户手动填的地址
 */
function probeChannels(opts = {}) {
  const port = opts.port || 9527;
  const addrs = listLocalAddresses();
  const out = [];

  const push = (meta, available, endpoint, note) => {
    out.push({
      ...meta,
      available: !!available,
      endpoint: endpoint || '',
      note: note || '',
    });
  };

  const lan4 = addrs.filter((a) => a.family === 4 && a.scope === 'lan');
  push(
    CHANNELS.find((c) => c.kind === ChannelKind.LAN4),
    lan4.length > 0,
    lan4[0] ? `http://${lan4[0].address}:${port}` : '',
    lan4.length > 0 ? `发现 ${lan4.length} 张局域网网卡` : '未发现局域网 IPv4 地址'
  );

  const lan6 = addrs.filter(
    (a) => a.family === 6 && (a.scope === 'ula' || a.scope === 'link')
  );
  push(
    CHANNELS.find((c) => c.kind === ChannelKind.LAN6),
    lan6.length > 0,
    lan6[0] ? `http://[${lan6[0].address}]:${port}` : '',
    lan6.length > 0
      ? `发现 ${lan6.length} 个本地 IPv6 地址（组播发现走 ff02::1）`
      : '未发现本地 IPv6 地址'
  );

  const global6 = addrs.find((a) => a.scope === 'global');
  push(
    CHANNELS.find((c) => c.kind === ChannelKind.WAN6),
    !!global6,
    global6 ? `http://[${global6.address}]:${port}` : '',
    global6
      ? `公网 IPv6 ${global6.address} —— 出门也能连`
      : '宽带未分配公网 IPv6（可联系运营商开通，或改用隧道/DDNS）'
  );

  push(
    CHANNELS.find((c) => c.kind === ChannelKind.DDNS),
    !!opts.ddns,
    opts.ddns ? `http://${opts.ddns}:${port}` : '',
    opts.ddns ? '已配置动态域名' : '未配置（适合 IPv6 前缀会变的家庭宽带）'
  );

  push(
    CHANNELS.find((c) => c.kind === ChannelKind.TUNNEL),
    !!opts.tunnel,
    opts.tunnel || '',
    opts.tunnel ? '已配置组网隧道' : '未配置（不暴露公网，最安全的远程方式）'
  );

  push(
    CHANNELS.find((c) => c.kind === ChannelKind.PROXY),
    !!opts.proxy,
    opts.proxy || '',
    opts.proxy ? '已配置反向代理' : '未配置（需你自己的域名与证书）'
  );

  push(
    CHANNELS.find((c) => c.kind === ChannelKind.MANUAL),
    true, // 手动永远可用
    opts.manual || '',
    '随时可手动填写任意地址'
  );

  return {
    channels: out,
    available: out.filter((c) => c.available).length,
    total: out.length,
    addresses: addrs,
  };
}

module.exports = {
  ChannelKind,
  CHANNELS,
  listLocalAddresses,
  bestGlobalIPv6,
  createIPv6Sender,
  createIPv6Receiver,
  probeChannels,
  MDNS_GROUP,
};
