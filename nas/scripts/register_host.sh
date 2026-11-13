#!/bin/bash
# 把本机（NAS）的当前访问地址登记到云端
# 由 crontab 每 5 分钟执行一次
#
# 两件事一起做：
#   ① 写账号私有绑定（th_shared，含主密钥）—— 给「本人在账号里读」的老通道兜底
#   ② 写公开地址清单（Storage backend.json，只含只读令牌）—— App 找后端的主通道
#      ② 必须做：App 读不到 ①（行级权限挡着），而 ② 免登录免权限，谁来都能读。
#
# ★ 2026-11-11 修正：只上报**主网卡**（有线）的 IPv6。
#   原来把所有网卡（含有线+无线）的地址全报上去，结果：
#     · 无线网卡的地址排在前面，App 先试它 → 入站走错网卡，白等超时；
#     · 4 个地址里 2 个是死路，探活时间翻倍。
#   现在按「固定后缀（DHCPv6）优先 → SLAAC 次之」排序，且只取主网卡。
set -u
. /vol1/docker/thirdhub/supabase.env

PORT=9527
PUBLIC_TOKEN="thpub_81011c20f9287b353bc69b2a159ca8836aab39f1"

# ── 选主网卡：优先有线（en*），没有才用无线 ──
PRIMARY_IF=""
for i in $(ls /sys/class/net | grep -E '^(en|eth)'); do
  [ "$(cat /sys/class/net/$i/operstate 2>/dev/null)" = "up" ] && PRIMARY_IF="$i" && break
done
if [ -z "$PRIMARY_IF" ]; then
  for i in $(ls /sys/class/net | grep -E '^(wl|wlan)'); do
    [ "$(cat /sys/class/net/$i/operstate 2>/dev/null)" = "up" ] && PRIMARY_IF="$i" && break
  done
fi

# ── 取该网卡的全局 IPv6（2000::/3）──
# /128 的通常是 DHCPv6 分配（后缀固定，前缀变了也能靠 DDNS 跟上）→ 排前面
# /64 的通常是 SLAAC（基于 MAC 生成）→ 排后面
STABLE=""
TEMP=""
if [ -n "$PRIMARY_IF" ]; then
  STABLE=$(ip -6 addr show dev "$PRIMARY_IF" 2>/dev/null \
    | awk '/inet6/{print $2}' | grep '/128' | cut -d/ -f1 | grep -E '^2[0-9a-f]|^3' | sort -u)
  TEMP=$(ip -6 addr show dev "$PRIMARY_IF" 2>/dev/null \
    | awk '/inet6/{print $2}' | grep -v '/128' | cut -d/ -f1 | grep -E '^2[0-9a-f]|^3' | sort -u)
fi

JSON_IPS=""
add_ip() {
  local ip="$1"
  [ -z "$ip" ] && return
  case ",$JSON_IPS," in *"[$ip]"*) return ;; esac
  [ -n "$JSON_IPS" ] && JSON_IPS="$JSON_IPS,"
  JSON_IPS="$JSON_IPS\"https://[$ip]:$PORT\""
}
for ip in $STABLE; do add_ip "$ip"; done
for ip in $TEMP;   do add_ip "$ip"; done

# ── Tailscale 地址（远程访问的确定通道；未授权时为空）──
# 为什么要塞进 ipv6 数组：App 的候选地址就是遍历这个数组逐个探活，
# 追加进去它就自动会试。外网时前面的局域网/公网 IPv6 都失败，最后命中这条。
TS4=$(docker exec tailscale tailscale ip -4 2>/dev/null | head -1 | tr -d '\r\n')
TS_URL=""
[ -n "$TS4" ] && TS_URL="https://$TS4:$PORT" && add_ip "$TS4"

# ── 内网地址也取主网卡 ──
LAN=""
if [ -n "$PRIMARY_IF" ]; then
  LAN=$(ip -4 addr show dev "$PRIMARY_IF" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
fi
[ -z "$LAN" ] && LAN=$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 \
  | grep -E '^(192\.168|10\.|172\.(1[6-9]|2[0-9]|3[01]))\.' | head -1)
LAN_URL=""
[ -n "$LAN" ] && LAN_URL="https://$LAN:$PORT"

TOKEN=$(cat /vol1/docker/thirdhub/data/secret 2>/dev/null | tr -d "\n")
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
HOSTN=$(hostname)

# ── ① 账号私有绑定（含主密钥）──
BODY="[{\"user_id\":\"$TH_OWNER_UID\",\"kind\":\"backend\",\"name\":\"main\",\"payload\":{\"lan\":\"$LAN_URL\",\"ipv6\":[$JSON_IPS],\"port\":$PORT,\"host\":\"$HOSTN\",\"updatedAt\":\"$NOW\",\"token\":\"$TOKEN\"}}]"

curl -s --max-time 20 -X POST \
  -H "apikey: $SUPABASE2_SERVICE_ROLE_KEY" \
  -H "Authorization: Bearer $SUPABASE2_SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" \
  -H "Prefer: resolution=merge-duplicates,return=minimal" \
  --data "$BODY" \
  "$SUPABASE2_URL/rest/v1/th_shared?on_conflict=user_id,kind,name" > /dev/null 2>&1

# ── ② 公开地址清单（App 主通道；不含主密钥）──
# 额外带上 if 字段，方便以后排障「这条地址来自哪块网卡」
MANIFEST="{\"v\":2,\"name\":\"$HOSTN\",\"if\":\"$PRIMARY_IF\",\"lan\":\"$LAN_URL\",\"ipv6\":[$JSON_IPS],\"port\":$PORT,\"publicToken\":\"$PUBLIC_TOKEN\",\"ts\":\"$TS_URL\",\"note\":\"公开只读令牌：只能搜索与阅读，不能修改任何配置\",\"updatedAt\":\"$NOW\"}"
echo "$MANIFEST" > /tmp/thirdhub_backend.json

curl -s --max-time 20 -X POST \
  -H "Authorization: Bearer $SUPABASE2_SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" \
  -H "x-upsert: true" \
  --data-binary @/tmp/thirdhub_backend.json \
  "$SUPABASE2_URL/storage/v1/object/downloads/thirdhub/backend.json" > /tmp/thirdhub_backend_upload.log 2>&1

rm -f /tmp/thirdhub_backend.json
