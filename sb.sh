#!/usr/bin/env bash
# =============================================================================
# Sing-box Script v1.3 By Merlin
# 支持入站: Shadowsocks(老版+2022) / VLESS+Reality / AnyTLS / Snell v4/v5/v6 (官方 snell-server)
#           SS / Snell v4 可选 ShadowTLS v3
# 支持出站: SS / VLESS-Reality / VLESS-WS-TLS / Hysteria2 / TUIC / Trojan / AnyTLS / Socks5
# 附加功能: Cloudflare DDNS (IPv4/IPv6) / 家宽 API 换 IP
# 系统:    Debian 12/13
# 调用:    sb
# =============================================================================

set -o pipefail

SCRIPT_VERSION="1.3.1"
SCRIPT_AUTHOR="Merlin"
SCRIPT_UPDATE_URL="https://raw.githubusercontent.com/merlin-node/sbox/main/sb.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; NC='\033[0m'

SB_DIR="/etc/sing-box"
SB_CONF="${SB_DIR}/config.json"
SB_NODES="${SB_DIR}/nodes.json"
SB_OUTBOUNDS="${SB_DIR}/outbounds.json"
SB_RULES="${SB_DIR}/rules.json"
SB_SETTINGS="${SB_DIR}/settings.json"
SB_CERT_DIR="${SB_DIR}/certs"
SB_BIN="/usr/local/bin/sing-box"
SB_SERVICE="/etc/systemd/system/sing-box.service"
SB_SCRIPT_PATH="/usr/local/bin/sb"
SB_LOG="/var/log/sing-box.log"

# ---- 客户端代理模式 (本地 SOCKS 出口，独立于服务端) ----
SB_CLIENT_CONF="${SB_DIR}/client.json"
SB_CLIENT_SERVICE="/etc/systemd/system/sing-box-client.service"
SB_CLIENT_LOG="/var/log/sing-box-client.log"
SB_CLIENT_META="${SB_DIR}/client_meta.json"

# ---- Cloudflare DDNS (独立于 sing-box) ----
CF_DDNS_DIR="/etc/sb-cloudflare-ddns"
CF_DDNS_CONF="${CF_DDNS_DIR}/config.json"
CF_DDNS_BIN="/usr/local/lib/sb-cloudflare-ddns"
CF_DDNS_SERVICE="/etc/systemd/system/sb-cloudflare-ddns.service"
CF_DDNS_TIMER="/etc/systemd/system/sb-cloudflare-ddns.timer"

# ---- 家宽换 IP (服务商 API，独立于 sing-box) ----
IPC_DIR="/etc/sb-ipchange"
IPC_CONF="${IPC_DIR}/config.json"
IPC_BIN="/usr/local/lib/sb-ipchange"
IPC_SERVICE="/etc/systemd/system/sb-ipchange.service"
IPC_TIMER="/etc/systemd/system/sb-ipchange.timer"

msg()  { echo -e "${GREEN}[*]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*"; }
ok()   { echo -e "${GREEN}[成功]${NC} $*"; }

# 取终端宽度，限制在 40-80 之间，默认 60
term_width() {
    local w
    w=$(tput cols 2>/dev/null || echo 60)
    (( w < 40 )) && w=40
    (( w > 80 )) && w=80
    echo "$w"
}

# 水平分割线，自适应宽度
hr() {
    local w; w=$(term_width)
    printf "${BLUE}%${w}s${NC}\n" '' | tr ' ' '='
}

# 居中带标题的分割线，自适应宽度（考虑中文宽度=2）

# 居中标题线：center_line <颜色> <标题>（中文按宽度 2 计）
center_line() {
    local color="$1" title="$2" w bytes chars side bar
    w=$(term_width)
    bytes=$(printf '%s' " ${title} " | wc -c)
    chars=$(printf '%s' " ${title} " | wc -m)
    # 中文在 UTF-8 中占 3 字节、显示宽度 2：可视宽度 = 字符数 + 中文字符数
    side=$(( (w - chars - (bytes - chars) / 2) / 2 ))
    (( side < 3 )) && side=3
    bar=$(printf "%${side}s" '' | tr ' ' '=')
    echo -e "${color}${bar} ${BOLD}${title}${NC}${color} ${bar}${NC}"
}

sec() { center_line "$BLUE" "$1"; }

sub()  { echo -e "${BLUE}>>> ${BOLD}$1${NC}"; }

pause() {
    echo
    read -rp "$(echo -e "${CYAN}按回车键继续...${NC}")" _ || true
}

need_root() {
    [[ $EUID -eq 0 ]] || { err "请用 root 运行"; exit 1; }
}

check_debian() {
    [[ -f /etc/os-release ]] || { err "无法识别系统"; exit 1; }
    . /etc/os-release
    if [[ "$ID" != "debian" ]]; then
        warn "本脚本仅在 Debian 12/13 测试过，当前: $ID $VERSION_ID"
        read -rp "仍要继续? [y/N]: " a
        [[ "$a" =~ ^[Yy]$ ]] || exit 0
    fi
}

install_deps() {
    msg "安装依赖..."
    apt-get update -y >/dev/null 2>&1
    apt-get install -y curl wget jq tar openssl ca-certificates \
        uuid-runtime iproute2 util-linux vnstat chrony >/dev/null 2>&1
    systemctl enable vnstat >/dev/null 2>&1 || true
    systemctl start vnstat >/dev/null 2>&1 || true
    systemctl enable chrony >/dev/null 2>&1 || true
    systemctl start chrony >/dev/null 2>&1 || true
    # apt 的输出被静音了，失败时要主动发现，否则后面所有 jq/curl 操作都会莫名失败
    local c missing=()
    for c in curl jq tar openssl uuidgen ss; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    if (( ${#missing[@]} > 0 )); then
        err "依赖安装失败，缺少: ${missing[*]}（请检查网络或 apt 源后重试）"
        exit 1
    fi
    ok "依赖安装完成"
}

# 检查时间是否同步（SS-2022/Reality 等协议对时间敏感，偏差 >30s 会拒绝连接）
# 返回 0 = 同步OK，1 = 未同步或偏差过大
check_time_sync() {
    if ! command -v chronyc >/dev/null 2>&1; then
        return 1
    fi
    if ! systemctl is-active --quiet chrony 2>/dev/null; then
        return 1
    fi
    # 取 System time 偏差（秒），绝对值 > 5 视为异常
    local offset
    # 行格式: "System time     : 0.000012345 seconds slow of NTP time"，数字是第 3 个字段
    offset=$(chronyc tracking 2>/dev/null | awk -F'[ :]+' '/System time/{print $3}')
    if [[ -z "$offset" ]]; then
        return 1
    fi
    # bash 不能直接处理浮点，借 awk 比较
    [[ "$offset" =~ ^[0-9.]+$ ]] || return 1
    if awk -v o="$offset" 'BEGIN{exit !(o+0 < 5)}'; then
        return 0
    fi
    return 1
}

# 一键修复时间同步
fix_time_sync() {
    msg "安装并启用 chrony..."
    apt-get install -y chrony >/dev/null 2>&1
    systemctl enable chrony >/dev/null 2>&1 || true
    systemctl restart chrony >/dev/null 2>&1 || true
    sleep 2
    msg "强制同步系统时间..."
    chronyc -a makestep 2>&1 | sed 's/^/  /'
    sleep 1
    echo
    echo -e "当前 UTC 时间: ${YELLOW}$(date -u)${NC}"
    if check_time_sync; then
        ok "时间同步正常"
    else
        warn "时间仍未完全同步，可能需要等待几秒后重试"
    fi
    # sing-box 在运行才重启
    if systemctl is-active --quiet sing-box; then
        msg "重启 sing-box..."
        systemctl restart sing-box
        ok "sing-box 已重启"
    fi
}

menu_time_sync() {
    clear; show_banner
    sec "时间同步状态"
    echo -e "  ${YELLOW}SS-2022 / Reality 等协议要求服务器与客户端时间偏差 < 30 秒${NC}"
    echo -e "  ${YELLOW}时间不同步会导致客户端连不上、握手失败${NC}"
    hr
    echo -e "  当前 UTC 时间: ${YELLOW}$(date -u)${NC}"
    if command -v chronyc >/dev/null 2>&1 && systemctl is-active --quiet chrony 2>/dev/null; then
        echo
        chronyc tracking 2>/dev/null | grep -E 'Reference ID|System time|Last offset|Leap status' | sed 's/^/  /'
        echo
        if check_time_sync; then
            echo -e "  ${GREEN}[√] 时间同步正常${NC}"
        else
            echo -e "  ${RED}[x] 时间偏差过大，建议执行下方修复${NC}"
        fi
    else
        echo
        echo -e "  ${RED}[x] chrony 未安装或未运行${NC}"
    fi
    hr
    echo "  1) 一键修复（安装 chrony + 强制同步 + 重启 sing-box）"
    echo "  0) 返回上一页"
    hr
    local c
    read -rp "$(echo -e "${CYAN}请选择 [0-1]: ${NC}")" c
    case "$c" in
        1) fix_time_sync; pause ;;
        0|"") return ;;
    esac
}

# 检查 BBR 是否已启用
check_bbr() {
    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    [[ "$cc" == "bbr" ]]
}

# 获取当前拥塞控制算法
current_cc() {
    sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown"
}

# 获取当前 qdisc
current_qdisc() {
    sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown"
}

enable_bbr() {
    # 内核是否支持 BBR
    if ! modprobe tcp_bbr 2>/dev/null && ! grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        err "当前内核不支持 BBR (需要 Linux 4.9+)"
        return 1
    fi
    msg "写入 sysctl 配置..."
    # Debian 13 开机不再读取 /etc/sysctl.conf，统一写到 /etc/sysctl.d 保证重启后仍生效
    [[ -f /etc/sysctl.conf ]] && sed -i '/^net\.core\.default_qdisc/d;/^net\.ipv4\.tcp_congestion_control/d' /etc/sysctl.conf
    mkdir -p /etc/sysctl.d
    printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' > /etc/sysctl.d/99-sb-bbr.conf
    sysctl -p /etc/sysctl.d/99-sb-bbr.conf >/dev/null 2>&1
    sleep 1
    if check_bbr; then
        ok "BBR 已启用"
        echo -e "  当前算法: ${GREEN}$(current_cc)${NC}    qdisc: ${GREEN}$(current_qdisc)${NC}"
    else
        err "BBR 启用失败，请检查内核支持"
        return 1
    fi
}

disable_bbr() {
    msg "切回默认拥塞控制 (cubic)..."
    [[ -f /etc/sysctl.conf ]] && sed -i '/^net\.core\.default_qdisc/d;/^net\.ipv4\.tcp_congestion_control/d' /etc/sysctl.conf
    rm -f /etc/sysctl.d/99-sb-bbr.conf
    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1
    sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1
    sleep 1
    ok "已切回 $(current_cc)"
}

menu_bbr() {
    while :; do
        clear; show_banner
        sec "BBR 拥塞控制"
        echo -e "  ${YELLOW}BBR 是 Linux 内核 TCP 拥塞控制算法，对跨境代理线路有显著加速${NC}"
        echo -e "  ${YELLOW}对 TCP 协议有效 (SS / Reality / Trojan 等)，对 UDP (Hysteria2/TUIC) 无影响${NC}"
        hr
        echo -e "  当前拥塞控制算法: ${YELLOW}$(current_cc)${NC}"
        echo -e "  当前 qdisc:        ${YELLOW}$(current_qdisc)${NC}"
        echo -e "  可用算法: ${CYAN}$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)${NC}"
        echo
        if check_bbr; then
            echo -e "  ${GREEN}[√] BBR 已启用${NC}"
        else
            echo -e "  ${RED}[x] BBR 未启用${NC}"
        fi
        hr
        echo "  1) 启用 BBR"
        echo "  2) 关闭 BBR (切回 cubic)"
        echo "  0) 返回上一页"
        hr
        local c
        read -rp "$(echo -e "${CYAN}请选择 [0-2]: ${NC}")" c
        case "$c" in
            1) enable_bbr; pause ;;
            2) disable_bbr; pause ;;
            0|"") return ;;
            *) err "无效"; sleep 1 ;;
        esac
    done
}

install_singbox() {
    local force="${1:-}" channel="${2:-stable}"
    if [[ -x "$SB_BIN" && "$force" != "force" ]]; then
        local cur
        cur=$("$SB_BIN" version 2>/dev/null | awk '/version/{print $3; exit}')
        msg "已安装 sing-box ${cur}"
        return 0
    fi

    local arch
    case "$(uname -m)" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l)  arch="armv7" ;;
        *) err "不支持的架构: $(uname -m)"; return 1 ;;
    esac

    local ver api_url url tmp
    if [[ "$channel" == "beta" ]]; then
        api_url="https://api.github.com/repos/SagerNet/sing-box/releases"
        ver=$(curl -fsSL "$api_url" | jq -r '[.[] | select(.prerelease==true)][0].tag_name' | sed 's/^v//')
    else
        api_url="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
        ver=$(curl -fsSL "$api_url" | jq -r '.tag_name' | sed 's/^v//')
    fi
    [[ -z "$ver" || "$ver" == "null" ]] && { err "获取版本失败"; return 1; }

    url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-${arch}.tar.gz"
    tmp=$(mktemp -d)
    msg "下载 sing-box v${ver} (${arch}, ${channel})..."
    if ! curl -fsSL "$url" -o "${tmp}/sb.tar.gz"; then
        err "下载失败"; rm -rf "$tmp"; return 1
    fi
    if ! tar -xzf "${tmp}/sb.tar.gz" -C "$tmp" \
       || ! install -m 755 "${tmp}/sing-box-${ver}-linux-${arch}/sing-box" "${SB_BIN}.new" \
       || ! mv -f "${SB_BIN}.new" "$SB_BIN"; then
        err "解压或安装失败，原有 sing-box 未改动"; rm -rf "$tmp"; rm -f "${SB_BIN}.new"; return 1
    fi
    rm -rf "$tmp"
    ok "sing-box v${ver} 已安装"
}

init_dirs() {
    mkdir -p "$SB_DIR" "$SB_CERT_DIR"
    chmod 700 "$SB_DIR"
    [[ -f "$SB_NODES" ]]     || echo '[]' > "$SB_NODES"
    [[ -f "$SB_OUTBOUNDS" ]] || echo '[]' > "$SB_OUTBOUNDS"
    [[ -f "$SB_RULES" ]]     || echo '[]' > "$SB_RULES"
    [[ -f "$SB_SETTINGS" ]]  || echo '{"ip_strategy":"prefer_ipv4","block_cn":false,"block_quic":false}' > "$SB_SETTINGS"
    # 老版本 settings.json 没有 block_quic，补上（默认关闭，保持原有行为）
    jq -e 'has("block_quic")' "$SB_SETTINGS" >/dev/null 2>&1 \
        || json_edit "$SB_SETTINGS" '.block_quic = false'
}

setup_logrotate() {
    cat > /etc/logrotate.d/sing-box <<EOF
${SB_LOG} ${SB_CLIENT_LOG} {
    size 10M
    rotate 3
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF
}

setup_service() {
    cat > "$SB_SERVICE" <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=${SB_BIN} -D ${SB_DIR} run -c ${SB_CONF}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/sing-box.conf <<EOF
[Journal]
SystemMaxUse=50M
SystemMaxFileSize=10M
EOF
    touch "$SB_LOG"
    chmod 640 "$SB_LOG"
    systemctl daemon-reload
    systemctl restart systemd-journald 2>/dev/null || true
    systemctl enable sing-box >/dev/null 2>&1
}

install_cmd() {
    if [[ "$(realpath "$0" 2>/dev/null)" != "$SB_SCRIPT_PATH" ]]; then
        install -m 755 "$0" "$SB_SCRIPT_PATH"
    fi
}

# ---------- 公共工具 ----------
port_in_use() {
    local port="$1"
    ss -Hltn "sport = :${port}" 2>/dev/null | grep -q ":${port}" && return 0
    ss -Hlun "sport = :${port}" 2>/dev/null | grep -q ":${port}" && return 0
    jq -e --arg p "$port" '.[] | select(.port == ($p|tonumber))' "$SB_NODES" >/dev/null 2>&1 && return 0
    return 1
}

get_ip() {
    local family="$1" ip=""
    if [[ "$family" == "6" ]]; then
        ip=$(curl -fsSL -m 5 -6 https://api64.ipify.org 2>/dev/null) \
            || ip=$(curl -fsSL -m 5 -6 https://ifconfig.co 2>/dev/null)
    else
        ip=$(curl -fsSL -m 5 -4 https://api.ipify.org 2>/dev/null) \
            || ip=$(curl -fsSL -m 5 -4 https://ifconfig.co 2>/dev/null)
    fi
    echo "$ip"
}

# 节点分享链接使用的连接地址：ip 模式返回本机公网 IP；
# ddns 模式直接使用所选 DDNS 记录的域名（由 menu_add_ddns 传入）。
get_node_address() {
    local family="$1" address_mode="${2:-ip}" hostname="${3:-}"
    if [[ "$address_mode" == "ddns" ]]; then
        [[ -n "$hostname" ]] && echo "$hostname"
        return 0
    fi
    get_ip "$family"
}

ip_for_url() {
    local ip="$1"
    [[ "$ip" == *:* ]] && echo "[${ip}]" || echo "$ip"
}

random_port() {
    local i p
    for (( i=0; i<50; i++ )); do
        # $RANDOM 最大只有 32767，拼两个才能覆盖到 65535
        p=$(( ((RANDOM << 15) | RANDOM) % 55536 + 10000 ))     # 10000-65535
        port_in_use "$p" || { echo "$p"; return 0; }
    done
    err "无法找到可用端口" >&2
    return 1
}

ask_port() {
    local prompt="$1" default="$2" min="${3:-1024}" port
    read -rp "$(echo -e "${CYAN}${prompt} [默认 ${default}]: ${NC}")" port
    port="${port:-$default}"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < min || port > 65535 )); then
        err "端口必须是 ${min}-65535 的整数" >&2
        return 1
    fi
    if port_in_use "$port"; then
        err "端口 ${port} 已占用" >&2
        return 1
    fi
    echo "$port"
}

# 同 ask_port,但允许排除指定端口（用于修改时排除自己当前端口）
ask_port_exclude() {
    local prompt="$1" default="$2" exclude="$3" port
    read -rp "$(echo -e "${CYAN}${prompt} [默认 ${default}]: ${NC}")" port
    port="${port:-$default}"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1024 || port > 65535 )); then
        err "端口必须是 1024-65535 的整数" >&2
        return 1
    fi
    if [[ "$port" != "$exclude" ]] && port_in_use "$port"; then
        err "端口 ${port} 已占用" >&2
        return 1
    fi
    echo "$port"
}

ask_remark() {
    local default="$1" remark
    read -rp "$(echo -e "${CYAN}请输入备注 (回车默认 ${default}): ${NC}")" remark
    echo "${remark:-$default}"
}

# URL 编码：用 jq @uri，对多字节 UTF-8 安全
urlencode() {
    printf '%s' "$1" | jq -sRr @uri
}

# 原子改写 JSON 文件：json_edit <文件> [jq 参数...] '<过滤器>'
# 临时文件放在目标同目录（mv 不跨文件系统），输出须为合法 JSON，并保留原文件权限
json_edit() {
    local file="$1" tmp
    shift
    tmp=$(mktemp "${file}.XXXXXX") || { err "无法写入 ${file}" >&2; return 1; }
    if jq "$@" "$file" > "$tmp" && jq -e . "$tmp" >/dev/null 2>&1; then
        chmod --reference="$file" "$tmp" 2>/dev/null
        mv -f "$tmp" "$file"
    else
        rm -f "$tmp"
        err "写入 ${file} 失败" >&2
        return 1
    fi
}

# 修改服务端数据文件 → 重建配置 → 重启 sing-box；任一步失败则恢复原文件
# 用法同 json_edit：sb_commit <文件> [jq 参数...] '<过滤器>'
sb_commit() {
    local file="$1" bak="${1}.bak"
    cp -f "$file" "$bak" || return 1
    json_edit "$@" || { rm -f "$bak"; return 1; }
    rebuild_config
    if restart_sb; then
        rm -f "$bak"
        return 0
    fi
    mv -f "$bak" "$file"
    rebuild_config && restart_sb >/dev/null
    err "已撤销本次更改"
    return 1
}

# ---- 通用输入 ----------------------------------------------------------------
# 必填项：ask_required <名称> → stdout；为空返回 1
ask_required() {
    local v
    read -rp "$(echo -e "${CYAN}请输入 $1: ${NC}")" v
    [[ -n "$v" ]] || { err "$1 不能为空" >&2; return 1; }
    printf '%s' "$v"
}

# 远端地址 + 端口 → "server|port"
ask_server_port() {
    local s p
    s=$(ask_required "服务器地址 (IP 或域名)") || return 1
    read -rp "$(echo -e "${CYAN}请输入端口: ${NC}")" p
    [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 )) || { err "端口无效" >&2; return 1; }
    echo "${s}|${p}"
}

# 是否跳过证书验证 → true / false
ask_insecure() {
    local a
    read -rp "$(echo -e "${CYAN}跳过证书验证? (自签证书选 y) [y/N]: ${NC}")" a
    [[ "$a" =~ ^[Yy]$ ]] && echo true || echo false
}

# Shadowsocks 加密方式（入站 / 出站 / 客户端共用）
SS_METHODS=(aes-128-gcm aes-256-gcm chacha20-ietf-poly1305 xchacha20-ietf-poly1305
            2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305)

# 选择加密方式：pick_ss_method [all|legacy|2022] → stdout；取消或无效返回 1
pick_ss_method() {
    local filter="${1:-all}" m c i=0
    local -a list=()
    for m in "${SS_METHODS[@]}"; do
        case "$filter" in
            legacy) [[ "$m" == 2022-* ]] && continue ;;
            2022)   [[ "$m" == 2022-* ]] || continue ;;
        esac
        list+=("$m")
    done
    echo "请选择加密方式:" >&2
    for m in "${list[@]}"; do i=$((i+1)); echo "  ${i}) ${m}" >&2; done
    echo "  0) 返回" >&2
    read -rp "$(echo -e "${CYAN}请选择 [0-${i}]: ${NC}")" c
    [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= i )) || return 1
    echo "${list[$((c-1))]}"
}

# 分流目标输入 "geosite:openai, claude.ai" → {"geosite":["openai"],"domain":["claude.ai"]}
parse_rule_input() {
    jq -cn --arg s "$1" '[$s | split(",")[] | gsub("\\s"; "") | select(length > 0)]
        | {geosite: map(select(startswith("geosite:")) | ltrimstr("geosite:")),
           domain:  map(select(startswith("geosite:") | not))}'
}

# 规则的可读描述：{"geosite":[..],"domain":[..]} → "geosite:x,a.com"
rule_desc() {
    jq -r '[(.geosite[]? | "geosite:\(.)"), .domain[]?] | join(",")' <<<"$1"
}

# 远程规则集定义：rule_sets_json <下载出口> <tag...>，tag 形如 geosite-xxx / geoip-xxx
rule_sets_json() {
    local detour="$1"
    shift
    printf '%s\n' "$@" | jq -Rs --arg d "$detour" '
        split("\n") | map(select(length > 0)) | unique
        | map((split("-")[0]) as $k | {
            type:"remote", tag:., format:"binary", download_detour:$d,
            url:"https://raw.githubusercontent.com/SagerNet/sing-\($k)/rule-set/\(.).srs"})'
}

# 生成不重复的节点 tag（改过端口的节点仍保留旧 tag，新节点可能撞名导致 sing-box 启动失败）
unique_node_tag() {
    local base="$1" tag="$1" i=2
    while jq -e --arg t "$tag" '.[] | select(.tag == $t)' "$SB_NODES" >/dev/null 2>&1; do
        tag="${base}-${i}"; i=$((i+1))
    done
    echo "$tag"
}

# listen 地址：v4 节点用 0.0.0.0，v6 节点用 ::
listen_addr() {
    [[ "$1" == "6" ]] && echo "::" || echo "0.0.0.0"
}

save_node() {
    local tag="$1" proto="$2" port="$3" family="$4" remark="$5" link="$6" extra="${7:-}"
    [[ -z "$extra" ]] && extra='{}'
    json_edit "$SB_NODES" \
        --arg tag "$tag" --arg proto "$proto" --argjson port "$port" \
        --arg family "$family" --arg remark "$remark" --arg link "$link" \
        --argjson extra "$extra" \
        '. += [{tag:$tag, protocol:$proto, port:$port, family:$family, remark:$remark, link:$link, extra:$extra, created:(now|todate)}]'
}

restart_sb() {
    if [[ -n "${REBUILD_ERR:-}" ]]; then
        err "配置未更新（上一步生成失败），sing-box 保持原配置运行"
        REBUILD_ERR=""
        return 1
    fi
    if ! "$SB_BIN" check -c "$SB_CONF" 2>/tmp/sb_check.err; then
        err "配置校验失败:"
        cat /tmp/sb_check.err
        return 1
    fi
    systemctl restart sing-box
    sleep 1
    if systemctl is-active --quiet sing-box; then
        ok "sing-box 已重启"
        return 0
    else
        err "sing-box 启动失败:"
        journalctl -u sing-box -n 10 --no-pager | tail -n 10
        return 1
    fi
}

# 查看日志：fallback 到 journalctl
view_log() {
    local lines="${1:-50}"
    if [[ -s "$SB_LOG" ]]; then
        tail -n "$lines" "$SB_LOG"
    else
        journalctl -u sing-box -n "$lines" --no-pager
    fi
}
# =============================================================================
# rebuild_config: 兼容 sing-box 1.13 的配置生成（Snell 节点由官方 snell-server 独立运行，不在此配置中）
# =============================================================================
rebuild_config() {
    local tmp; tmp=$(mktemp --suffix=.json)

    local inbounds outbounds
    # 过滤掉 extra.inbound 为 null 的脏数据，避免 sing-box 启动失败
    inbounds=$(jq '[.[] | .extra.inbound, (.extra.inbound_aux | if type == "array" then .[] else . end)
                     | select(. != null)]' "$SB_NODES")

    local ip_strategy block_cn block_quic
    ip_strategy=$(jq -r '.ip_strategy' "$SB_SETTINGS")
    block_cn=$(jq -r '.block_cn' "$SB_SETTINGS")
    block_quic=$(jq -r '.block_quic // false' "$SB_SETTINGS")

    # 用户自定义出站
    local user_outbounds
    user_outbounds=$(jq '[.[] | .outbound]' "$SB_OUTBOUNDS")

    # 出站：4 个内置 + 用户的
    # 注意：sing-box 1.13 已废弃 domain_strategy，改在 route 规则里用 resolve action
    outbounds=$(jq -n \
        --argjson uo "$user_outbounds" \
        '[
            {type:"direct", tag:"direct"},
            {type:"block",  tag:"block"},
            {type:"direct", tag:"ipv4-out"},
            {type:"direct", tag:"ipv6-out"}
         ] + $uo')

    # 用户分流规则
    local user_rules
    user_rules=$(jq '[.[] | {rule_set:[(.geosite[]? | "geosite-\(.)")], domain_list:(.domain // []), outbound}]' "$SB_RULES")

    # 大陆屏蔽规则
    local cn_block_rule="[]"
    if [[ "$block_cn" == "true" ]]; then
        cn_block_rule='[{"rule_set":["geosite-cn","geoip-cn"],"domain_list":[],"outbound":"block"}]'
    fi

    # 用到的 geosite/geoip → 远程规则集
    local rule_sets
    # shellcheck disable=SC2046
    rule_sets=$(rule_sets_json direct $(jq -nr --argjson u "$user_rules" --argjson c "$cn_block_rule" \
        '($u + $c)[] | .rule_set[]'))

    # 构造 route.rules（顺序很重要）:
    # 1) sniff    —— 嗅探协议/域名。没有它，protocol:quic 永远匹配不到；
    #                客户端发来的是 IP 时，域名/geosite 规则也匹配不到
    # 2) resolve  —— 全局 v4/v6 策略
    # 3) quic 阻断（可选）
    # 4) 用户规则 + cn 屏蔽
    local base_rules
    base_rules=$(jq -n --arg s "$ip_strategy" \
        '[{action:"sniff"}, {action:"resolve", strategy:$s}]')

    # 用户规则转换：
    # - 没有任何匹配条件的规则直接丢弃（否则会匹配全部流量）
    # - 去向 block    -> action:reject（block 出站在新版 sing-box 中已废弃）
    # - 去向 ipv4-out -> 先按同样条件 resolve ipv4_only，再 route（否则 ipv4-out 只是普通直连）
    # - 去向 ipv6-out -> 同上，ipv6_only
    local proxy_rules
    proxy_rules=$(jq -n --argjson u "$user_rules" --argjson c "$cn_block_rule" \
        '[($u + $c) | .[] |
            ((if (.rule_set | length) > 0 then {rule_set:.rule_set} else {} end) +
             (if (.domain_list | length) > 0 then {domain_suffix:.domain_list} else {} end)) as $m |
            select(($m | length) > 0) |
            if   .outbound == "block"    then ($m + {action:"reject"})
            elif .outbound == "ipv4-out" then ($m + {action:"resolve", strategy:"ipv4_only"}), ($m + {action:"route", outbound:"ipv4-out"})
            elif .outbound == "ipv6-out" then ($m + {action:"resolve", strategy:"ipv6_only"}), ($m + {action:"route", outbound:"ipv6-out"})
            else ($m + {action:"route", outbound:.outbound})
            end
        ]')

    # QUIC(HTTP/3) 阻断规则：依赖上面的 sniff；拒绝后浏览器/App 会回落到 HTTP/2 走 TCP
    local quic_rule="[]"
    if [[ "$block_quic" == "true" ]]; then
        quic_rule='[{"protocol":"quic","action":"reject"}]'
    fi

    # ShadowTLS 解包后转给本机 snell-server 的流量：最先命中，直接送达
    local fwd_rule
    fwd_rule=$(jq '[.[] | .extra.inbound_aux | if type == "array" then .[] else . end
                     | select(type == "object" and .type == "direct") | .tag]
        | if length > 0 then [{inbound:., action:"route", outbound:"direct"}] else [] end' "$SB_NODES")

    local all_rules
    all_rules=$(jq -n --argjson f "$fwd_rule" --argjson b "$base_rules" --argjson q "$quic_rule" --argjson p "$proxy_rules" \
        '$f + $b + $q + $p')

    local route
    route=$(jq -n \
        --argjson rs "$rule_sets" \
        --argjson rules "$all_rules" \
        '{rule_set:$rs, rules:$rules, final:"direct", auto_detect_interface:true}')

    # DNS 服务器（resolve action 需要）
    local dns
    dns=$(jq -n '{servers:[{type:"local", tag:"local"}]}')

    if ! jq -n \
        --argjson dns "$dns" \
        --argjson inbounds "$inbounds" \
        --argjson outbounds "$outbounds" \
        --argjson route "$route" \
        --arg log "$SB_LOG" \
        '{
            log:{level:"warn", output:$log, timestamp:true},
            dns:$dns,
            inbounds:$inbounds,
            outbounds:$outbounds,
            route:$route
        }' > "$tmp" || ! [[ -s "$tmp" ]]; then
        err "生成配置失败，保留原配置不变"
        rm -f "$tmp"
        REBUILD_ERR=1
        return 1
    fi

    # 先校验再替换：新配置有问题时不覆盖正在使用的配置
    if [[ -x "$SB_BIN" ]] && ! "$SB_BIN" check -c "$tmp" 2>/tmp/sb_check.err; then
        err "新配置校验失败，保留原配置不变:"
        cat /tmp/sb_check.err
        cp -f "$tmp" "${SB_CONF}.bad" 2>/dev/null
        rm -f "$tmp"
        REBUILD_ERR=1
        return 1
    fi

    [[ -f "$SB_CONF" ]] && cp -f "$SB_CONF" "${SB_CONF}.bak"
    mv "$tmp" "$SB_CONF"
    chmod 600 "$SB_CONF"
    REBUILD_ERR=""
}
# =============================================================================
# 添加节点：分类菜单（Shadowsocks / VLESS+Reality / AnyTLS / Snell）
# =============================================================================
menu_new_proto() {
    local family="$1"
    local address_mode="${2:-ip}"
    local node_address="${3:-}"
    local address_label="IPv${family}"
    [[ "$address_mode" == "ddns" ]] && address_label="DDNS 域名 (监听 IPv${family})"
    while :; do
        clear; show_banner
        sec "添加节点 → ${address_label} → 选择协议"
        echo "  1) Shadowsocks (含 2022)"
        echo
        echo "  2) VLESS + Reality"
        echo
        echo "  3) AnyTLS"
        echo
        echo "  4) Snell (v4 / v5 / v6，官方服务端)"
        echo
        echo "  0) 返回上一页"
        hr
        local c
        read -rp "$(echo -e "${CYAN}请选择 [0-4]: ${NC}")" c
        case "$c" in
            1) menu_ss_method "$family" "$address_mode" "$node_address"; return ;;
            2) create_reality "$family" "$address_mode" "$node_address"; return ;;
            3) create_anytls "$family" "$address_mode" "$node_address"; return ;;
            4) menu_snell_version "$family" "$address_mode" "$node_address"; return ;;
            0|"") return ;;
            *) err "无效选择"; sleep 1 ;;
        esac
    done
}

menu_ss_method() {
    local method
    clear; show_banner
    sec "Shadowsocks → 选择加密方式"
    method=$(pick_ss_method all) || return
    create_ss "$1" "$method" "${2:-ip}" "${3:-}"
}

create_ss() {
    local family="$1" method="$2"
    local address_mode="${3:-ip}"
    local node_address="${4:-}"
    local keylen=32 is2022=0 ans
    [[ "$method" == *128* ]] && keylen=16
    [[ "$method" == 2022-* ]] && is2022=1

    echo
    echo -e "  ${YELLOW}ShadowTLS: 伪装成访问真实网站，适合过墙的直连线路；专线 / 中转不需要${NC}"
    read -rp "$(echo -e "${CYAN}是否启用 ShadowTLS 伪装? [y/N]: ${NC}")" ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        create_ss_st "$family" "$method" "$address_mode" "$node_address"
        return
    fi

    local port pwd short_proto remark tag ip
    port=$(ask_port "请输入端口" "$(random_port)") || { pause; return; }
    if [[ $is2022 -eq 1 ]]; then
        # SS-2022 要求密钥为精确 keylen 字节，openssl rand -base64 N 生成 N 字节随机数据并 base64 编码，符合要求
        pwd=$(openssl rand -base64 "$keylen")
        short_proto="ss2022"
    else
        pwd=$(openssl rand -base64 16)
        short_proto="ss"
    fi
    remark=$(ask_remark "${short_proto}-${port}")
    tag=$(unique_node_tag "${short_proto}-${port}")

    ip=$(get_node_address "$family" "$address_mode" "$node_address")
    [[ -z "$ip" ]] && { err "无法获取所选连接地址，请检查公网 IP 或 DDNS 配置"; pause; return; }

    local listen
    listen=$(listen_addr "$family")

    local inbound
    inbound=$(jq -n --arg tag "$tag" --arg method "$method" --arg pwd "$pwd" \
        --arg listen "$listen" --argjson port "$port" \
        '{type:"shadowsocks", tag:$tag, listen:$listen, listen_port:$port, method:$method, password:$pwd}')

    # SS / SS-2022 统一使用 base64url(method:password) 格式，兼容性最好
    local link userinfo b64
    userinfo="${method}:${pwd}"
    b64=$(echo -n "$userinfo" | base64 -w0 | tr -d '=' | tr '/+' '_-')
    link="ss://${b64}@$(ip_for_url "$ip"):${port}#$(urlencode "$remark")"

    save_node "$tag" "$method" "$port" "$family" "$remark" "$link" \
        "$(jq -n --argjson ib "$inbound" '{inbound:$ib}')"
    rebuild_config
    restart_sb || return

    echo
    ok "节点创建成功: ${remark}"
    echo -e "${BOLD}分享链接:${NC}"
    echo -e "${GREEN}${link}${NC}"
    pause
}

create_reality() {
    local family="$1"
    local address_mode="${2:-ip}"
    local node_address="${3:-}"
    local port sni remark tag
    port=$(ask_port "请输入端口" "$(random_port)") || { pause; return; }
    ask_camo_target
    sni="$CAMO_SNI"

    # 选择传输模式
    echo
    echo -e "${BOLD}请选择传输模式:${NC}"
    echo "  1) Vision (xtls-rprx-vision) —— 兼容性最好,单线程速度受 RTT 限制"
    echo "  2) Brutal (h2mux + brutal)    —— 单线程接近多线程,远距离 VPS 推荐"
    echo
    echo -e "  ${YELLOW}说明: Brutal 模式按设定带宽强制发送,单流也能跑满,平时小流量正常不受影响${NC}"
    echo -e "  ${YELLOW}注意: 两种模式服务端都兼容,客户端按对应模式配置即可${NC}"
    local mode_choice mode brutal_up brutal_down
    read -rp "$(echo -e "${CYAN}请选择 [1-2,默认 1]: ${NC}")" mode_choice
    mode_choice="${mode_choice:-1}"
    if [[ "$mode_choice" == "2" ]]; then
        mode="brutal"
        echo
        echo -e "  ${YELLOW}Brutal 参数: 设定值不要超过线路实际能力,否则反而会因丢包变慢${NC}"
        read -rp "$(echo -e "${CYAN}下行带宽 Mbps (客户端 down,默认 500): ${NC}")" brutal_down
        brutal_down="${brutal_down:-500}"
        read -rp "$(echo -e "${CYAN}上行带宽 Mbps (客户端 up,默认 50): ${NC}")" brutal_up
        brutal_up="${brutal_up:-50}"
        if ! [[ "$brutal_down" =~ ^[0-9]+$ ]] || ! [[ "$brutal_up" =~ ^[0-9]+$ ]]; then
            err "带宽必须是整数"; pause; return
        fi
    else
        mode="vision"
    fi

    remark=$(ask_remark "reality-${mode}-${port}")
    tag=$(unique_node_tag "reality-${port}")

    local kp pubkey prvkey shortid uuid
    kp=$("$SB_BIN" generate reality-keypair) || { err "生成 keypair 失败"; pause; return; }
    prvkey=$(echo "$kp" | awk -F': *' '/PrivateKey/{print $2}')
    pubkey=$(echo "$kp" | awk -F': *' '/PublicKey/{print $2}')
    if [[ -z "$prvkey" || -z "$pubkey" ]]; then
        err "无法从 sing-box 输出中读取 Reality 密钥"
        echo "$kp"
        pause; return
    fi
    shortid=$(openssl rand -hex 4)
    uuid=$(uuidgen)

    local ip listen
    ip=$(get_node_address "$family" "$address_mode" "$node_address")
    [[ -z "$ip" ]] && { err "无法获取所选连接地址，请检查公网 IP 或 DDNS 配置"; pause; return; }
    listen=$(listen_addr "$family")

    # 根据模式生成 inbound:
    # vision 模式: users 带 flow,链接含 flow 参数
    # brutal 模式: users 不带 flow,服务端 multiplex.brutal 开启,客户端在 outbound 里配 mux+brutal
    local inbound link
    if [[ "$mode" == "brutal" ]]; then
        # 服务端 multiplex.brutal.enabled 让服务端接受客户端的 brutal 协商;
        # up_mbps/down_mbps 是服务端视角,即服务端的上行 = 客户端的下行
        inbound=$(jq -n --arg tag "$tag" --argjson port "$port" \
            --arg listen "$listen" \
            --arg uuid "$uuid" --arg sni "$sni" --arg prv "$prvkey" --arg sid "$shortid" \
            --arg hs "$CAMO_HS_SERVER" --argjson hsp "$CAMO_HS_PORT" \
            --argjson srv_up "$brutal_down" --argjson srv_down "$brutal_up" \
            '{type:"vless", tag:$tag, listen:$listen, listen_port:$port,
              users:[{uuid:$uuid}],
              multiplex:{enabled:true,
                brutal:{enabled:true, up_mbps:$srv_up, down_mbps:$srv_down}},
              tls:{enabled:true, server_name:$sni,
                reality:{enabled:true,
                  handshake:{server:$hs, server_port:$hsp},
                  private_key:$prv, short_id:[$sid]}}}')
        # 注意: VLESS 标准分享链接无法表达 mux+brutal,客户端必须用 sing-box 完整 JSON 配置
        # 这里给出基础 vless:// 链接(无 flow),仅供 sing-box 客户端导入后手动补 mux+brutal
        link="vless://${uuid}@$(ip_for_url "$ip"):${port}?encryption=none&security=reality&sni=${sni}&fp=chrome&pbk=${pubkey}&sid=${shortid}&type=tcp#$(urlencode "$remark")"
    else
        inbound=$(jq -n --arg tag "$tag" --argjson port "$port" \
            --arg listen "$listen" \
            --arg uuid "$uuid" --arg sni "$sni" --arg prv "$prvkey" --arg sid "$shortid" \
            --arg hs "$CAMO_HS_SERVER" --argjson hsp "$CAMO_HS_PORT" \
            '{type:"vless", tag:$tag, listen:$listen, listen_port:$port,
              users:[{uuid:$uuid, flow:"xtls-rprx-vision"}],
              tls:{enabled:true, server_name:$sni,
                reality:{enabled:true,
                  handshake:{server:$hs, server_port:$hsp},
                  private_key:$prv, short_id:[$sid]}}}')
        link="vless://${uuid}@$(ip_for_url "$ip"):${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pubkey}&sid=${shortid}&type=tcp#$(urlencode "$remark")"
    fi

    # extra 里存 mode 和 brutal 参数,方便后续展示客户端配置
    local extra
    if [[ "$mode" == "brutal" ]]; then
        extra=$(jq -n --argjson ib "$inbound" --arg pbk "$pubkey" --arg sid "$shortid" \
                --arg uuid "$uuid" --arg sni "$sni" --arg mode "$mode" \
                --argjson bu "$brutal_up" --argjson bd "$brutal_down" \
                '{inbound:$ib, public_key:$pbk, short_id:$sid, uuid:$uuid, sni:$sni,
                  mode:$mode, brutal_up:$bu, brutal_down:$bd}')
    else
        extra=$(jq -n --argjson ib "$inbound" --arg pbk "$pubkey" --arg sid "$shortid" \
                --arg uuid "$uuid" --arg sni "$sni" --arg mode "$mode" \
                '{inbound:$ib, public_key:$pbk, short_id:$sid, uuid:$uuid, sni:$sni, mode:$mode}')
    fi

    save_node "$tag" "vless-reality" "$port" "$family" "$remark" "$link" "$extra"
    rebuild_config
    restart_sb || return

    echo
    ok "节点创建成功: ${remark}  (模式: ${mode})"
    echo -e "${BOLD}分享链接:${NC}"
    echo -e "${GREEN}${link}${NC}"

    # Brutal 模式需要客户端额外配置,直接生成 sing-box 客户端 JSON outbound
    if [[ "$mode" == "brutal" ]]; then
        echo
        echo -e "${BOLD}${YELLOW}Brutal 模式客户端配置 (sing-box JSON outbound):${NC}"
        echo -e "${YELLOW}注意: 标准 vless:// 链接不支持 mux+brutal,必须用下方完整 JSON 导入${NC}"
        echo
        # 客户端 brutal: up_mbps=客户端上行=服务端下行=brutal_up
        #               down_mbps=客户端下行=服务端上行=brutal_down
        jq -n --arg tag "$remark" --arg srv "$ip" --argjson port "$port" \
            --arg uuid "$uuid" --arg sni "$sni" --arg pbk "$pubkey" --arg sid "$shortid" \
            --argjson up "$brutal_up" --argjson down "$brutal_down" \
            '{type:"vless", tag:$tag, server:$srv, server_port:$port, uuid:$uuid,
              tls:{enabled:true, server_name:$sni,
                utls:{enabled:true, fingerprint:"chrome"},
                reality:{enabled:true, public_key:$pbk, short_id:$sid}},
              multiplex:{enabled:true, protocol:"h2mux", max_streams:8, padding:true,
                brutal:{enabled:true, up_mbps:$up, down_mbps:$down}}}'
    fi

    pause
}

create_anytls() {
    local family="$1"
    local address_mode="${2:-ip}"
    local node_address="${3:-}"
    local port sni remark tag pwd
    port=$(ask_port "请输入端口" "$(random_port)") || { pause; return; }

    # 选择证书类型
    echo
    echo "请选择证书类型:"
    echo "  1) 自签证书      (无需域名，但客户端必须设置 insecure=1)"
    echo "  2) ACME 真实证书 (需要域名解析到本机，免费 Let's Encrypt)"
    local cert_type
    read -rp "$(echo -e "${CYAN}请选择 [1-2，默认 1]: ${NC}")" cert_type
    cert_type="${cert_type:-1}"

    local use_acme=0 acme_domain="" acme_email=""
    if [[ "$cert_type" == "2" ]]; then
        read -rp "$(echo -e "${CYAN}请输入已解析到本机的域名: ${NC}")" acme_domain
        [[ -z "$acme_domain" ]] && { err "域名不能为空"; pause; return; }
        read -rp "$(echo -e "${CYAN}请输入邮箱 (用于 Let's Encrypt 注册): ${NC}")" acme_email
        [[ -z "$acme_email" ]] && { err "邮箱不能为空"; pause; return; }
        use_acme=1
        sni="$acme_domain"
    else
        read -rp "$(echo -e "${CYAN}请输入伪装域名 (默认 addons.mozilla.org): ${NC}")" sni
        sni="${sni:-addons.mozilla.org}"
    fi

    remark=$(ask_remark "anytls-${port}")
    tag=$(unique_node_tag "anytls-${port}")
    pwd=$(openssl rand -base64 16)

    local ip listen
    ip=$(get_node_address "$family" "$address_mode" "$node_address")
    [[ -z "$ip" ]] && { err "无法获取所选连接地址，请检查公网 IP 或 DDNS 配置"; pause; return; }
    listen=$(listen_addr "$family")

    local inbound link
    if [[ $use_acme -eq 1 ]]; then
        # ACME: sing-box 自动申请并续期证书
        inbound=$(jq -n --arg tag "$tag" --argjson port "$port" --arg pwd "$pwd" \
            --arg listen "$listen" --arg sni "$sni" --arg email "$acme_email" \
            '{type:"anytls", tag:$tag, listen:$listen, listen_port:$port,
              users:[{name:"user", password:$pwd}],
              tls:{enabled:true, server_name:$sni,
                acme:{domain:[$sni], email:$email}}}')
        # 真实证书：客户端无需 insecure
        link="anytls://$(urlencode "$pwd")@$(ip_for_url "$ip"):${port}/?sni=${sni}#$(urlencode "$remark")"
    else
        # 自签证书
        local crt key
        crt="${SB_CERT_DIR}/${tag}.crt"
        key="${SB_CERT_DIR}/${tag}.key"
        openssl ecparam -genkey -name prime256v1 -out "$key" 2>/dev/null
        openssl req -new -x509 -days 3650 -key "$key" -out "$crt" -subj "/CN=${sni}" 2>/dev/null
        chmod 600 "$key"

        inbound=$(jq -n --arg tag "$tag" --argjson port "$port" --arg pwd "$pwd" \
            --arg listen "$listen" --arg sni "$sni" --arg crt "$crt" --arg key "$key" \
            '{type:"anytls", tag:$tag, listen:$listen, listen_port:$port,
              users:[{name:"user", password:$pwd}],
              tls:{enabled:true, server_name:$sni, certificate_path:$crt, key_path:$key}}')
        link="anytls://$(urlencode "$pwd")@$(ip_for_url "$ip"):${port}/?insecure=1&sni=${sni}#$(urlencode "$remark")"
    fi

    save_node "$tag" "anytls" "$port" "$family" "$remark" "$link" \
        "$(jq -n --argjson ib "$inbound" --arg pwd "$pwd" --arg sni "$sni" \
            '{inbound:$ib, password:$pwd, sni:$sni}')"
    rebuild_config
    restart_sb || return

    echo
    ok "节点创建成功: ${remark}"
    if [[ $use_acme -eq 1 ]]; then
        warn "首次申请 ACME 证书需要 80 端口可访问（HTTP-01 验证），请确保未被占用"
    fi
    echo -e "${BOLD}分享链接:${NC}"
    echo -e "${GREEN}${link}${NC}"
    pause
}

# =============================================================================
# Snell（官方 snell-server，独立于 sing-box 运行）
#
#   v4 / v5 → snell-server v5（v5 服务端兼容 v4 客户端；v5 的 QUIC 代理需放行 UDP）
#   v6      → snell-server v6（Beta，PSK 流量整形，无 obfs / QUIC 代理）
#   +ShadowTLS → snell-server v5 仅监听本机，由 sing-box 的 shadowtls 入站对外（见 create_snell_st）
#
# 每个节点一个 systemd 实例 snell<5|6>@<tag>，配置 /etc/snell/<tag>.conf。
# 节点记录里 extra.unit 非空即表示由 snell-server 承载（不写 extra.inbound，
# 所以不会进入 sing-box 配置）；配置文件参数全部存在 extra 中，随时可重建。
#
# link 存为 snell://<psk>@<host>:<port>?version=..#<备注>，仅供内部使用：
# 与其他协议同为 "@host:port" 结构，改端口 / 改备注 / 换 IP / DDNS 同步直接复用；
# 对外一律显示 Surge 配置行。
# =============================================================================
SNELL_DIR="/etc/snell"
declare -A SNELL_BIN=([5]="/usr/local/bin/snell-server" [6]="/usr/local/bin/snell-server-v6")
declare -A SNELL_VER=([5]="5.0.1" [6]="6.0.0rc2")

# 协议版本 → 服务端代数（v4 与 v5 共用 v5 服务端）
snell_gen() { [[ "$1" == "6" ]] && echo 6 || echo 5; }

# 安装官方 snell-server（含 systemd 模板单元）：install_snell_server <5|6>
install_snell_server() {
    local gen="$1" bin="${SNELL_BIN[$1]}" ver="${SNELL_VER[$1]}" arch tmp
    local tpl="/etc/systemd/system/snell${gen}@.service"

    if [[ ! -x "$bin" ]]; then
        case "$(uname -m)" in
            x86_64) arch="amd64" ;; aarch64) arch="aarch64" ;;
            armv7l) arch="armv7l" ;; i386|i686) arch="i386" ;;
            *) err "官方 snell-server 不支持此架构: $(uname -m)"; return 1 ;;
        esac
        [[ "$gen" == "6" && "$arch" == "armv7l" ]] && { err "官方 Snell v6 暂未提供 armv7l 版本"; return 1; }
        command -v unzip >/dev/null 2>&1 || apt-get install -y unzip >/dev/null 2>&1 \
            || { err "unzip 安装失败"; return 1; }

        tmp=$(mktemp -d)
        msg "下载官方 snell-server v${ver} (${arch})..."
        if ! curl -fsSL "https://dl.nssurge.com/snell/snell-server-v${ver}-linux-${arch}.zip" -o "${tmp}/s.zip" \
           || ! unzip -o -q "${tmp}/s.zip" -d "$tmp" \
           || ! install -m 755 "${tmp}/snell-server" "$bin"; then
            err "snell-server 下载或安装失败"; rm -rf "$tmp"; return 1
        fi
        rm -rf "$tmp"
        ok "snell-server v${ver} 已安装"
    fi

    if [[ ! -f "$tpl" ]]; then
        cat > "$tpl" <<UNIT
[Unit]
Description=Snell v${gen} server (%i)
After=network-online.target
Wants=network-online.target

[Service]
User=nobody
Group=nogroup
ExecStart=${bin} -c ${SNELL_DIR}/%i.conf
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload
    fi
    mkdir -p "$SNELL_DIR"
}

# 按 nodes.json 第 idx 个节点生成配置并（重）启实例；失败打印日志
snell_sync_idx() {
    local idx="$1" tag ver family port psk obfs mode unit inner listen strategy
    IFS=$'\t' read -r tag ver family port psk obfs mode unit inner < <(jq -r --argjson i "$idx" \
        '.[$i] | [.tag, .extra.version, .family, .port, .extra.psk,
                  (.extra.obfs // "none"), (.extra.mode // "default"), .extra.unit,
                  (.extra.inner_port // "")] | map(tostring) | @tsv' "$SB_NODES")

    if [[ -n "$inner" ]]; then
        listen="127.0.0.1:${inner}"        # 前面有 ShadowTLS，snell-server 不对外
    elif [[ "$family" == "6" ]]; then
        [[ "$ver" == "6" ]] && listen="[::]:${port}" || listen="::0:${port}"
    else
        listen="0.0.0.0:${port}"
    fi
    {
        echo "[snell-server]"
        echo "listen = ${listen}"
        echo "psk = ${psk}"
        # 出口 IPv4/IPv6 跟随全局策略（与监听用 v4 还是 v6 无关）
        strategy=$(jq -r '.ip_strategy // "prefer_ipv4"' "$SB_SETTINGS")
        if [[ "$ver" == "6" ]]; then
            echo "ipv6 = $([[ "$strategy" == "ipv4_only" ]] && echo false || echo true)"
            echo "dns-ip-preference = ${strategy//_/-}"
            [[ "$mode" != "default" ]] && echo "mode = ${mode}"
        else
            # v5 只有 ipv6 开关：仅当策略偏向 IPv6 时才允许 IPv6 出口
            echo "ipv6 = $([[ "$strategy" == *ipv6* ]] && echo true || echo false)"
            [[ "$obfs" == "http" ]] && echo "obfs = http"
        fi
    } > "${SNELL_DIR}/${tag}.conf"
    chown root:nogroup "${SNELL_DIR}/${tag}.conf" 2>/dev/null
    chmod 640 "${SNELL_DIR}/${tag}.conf"

    systemctl enable "$unit" >/dev/null 2>&1
    systemctl restart "$unit"
    sleep 1
    systemctl is-active --quiet "$unit" && return 0
    err "${unit} 启动失败:"
    journalctl -u "$unit" -n 10 --no-pager | tail -n 10
    return 1
}

# 全部 snell-server 节点按当前设置重新生成配置并重启（切换 IP 策略后调用）
snell_sync_all() {
    local i
    for i in $(jq -r 'to_entries[] | select(.value.extra.unit) | .key' "$SB_NODES"); do
        snell_sync_idx "$i" || warn "第 $((i+1)) 个节点的 snell-server 重启失败"
    done
}

# 停止并清理某个实例：snell_remove_unit <unit> <tag>
snell_remove_unit() {
    systemctl disable --now "$1" >/dev/null 2>&1
    rm -f "${SNELL_DIR}/${2}.conf"
}

# 卸载时清理全部官方 snell-server
snell_uninstall_all() {
    local u
    for u in $( { jq -r '.[].extra.unit // empty' "$SB_NODES" 2>/dev/null
                  systemctl list-units --all --plain --no-legend 'snell5@*' 'snell6@*' 2>/dev/null | awk '{print $1}'
                } | sort -u ); do
        systemctl disable --now "$u" >/dev/null 2>&1
    done
    rm -f /etc/systemd/system/snell5@.service /etc/systemd/system/snell6@.service \
          "${SNELL_BIN[5]}" "${SNELL_BIN[6]}"
    rm -rf "$SNELL_DIR"
    systemctl daemon-reload
}

# 百分号解码（配合 urlencode 使用）
urldecode() { printf '%b' "${1//%/\\x}"; }

menu_snell_version() {
    local family="$1" address_mode="${2:-ip}" node_address="${3:-}" c
    clear; show_banner
    sec "Snell → 选择协议版本 (官方 snell-server)"
    echo "  1) Snell v4  (可选 ShadowTLS 伪装；适合过墙的直连线路)"
    echo
    echo "  2) Snell v5  (支持 QUIC 代理，需放行 UDP；适合专线 / 不过墙的线路)"
    echo
    echo "  3) Snell v6  (Beta，PSK 流量整形；需 Surge iOS 5.20+ / Mac 6.7+)"
    echo
    echo "  0) 返回上一页"
    hr
    read -rp "$(echo -e "${CYAN}请选择 [0-3]: ${NC}")" c
    case "$c" in
        1|2|3) create_snell "$family" $((c + 3)) "$address_mode" "$node_address" ;;
        0|"") return ;;
        *) err "无效选择"; sleep 1 ;;
    esac
}

create_snell() {
    local family="$1" ver="$2" address_mode="${3:-ip}" node_address="${4:-}"
    local gen c SNELL_OBFS_PRESET=""; gen=$(snell_gen "$ver")
    if [[ "$ver" == "4" ]]; then
        echo
        echo "请选择伪装方式:"
        echo "  1) 不伪装      (专线 / 不过墙的线路)"
        echo "  2) HTTP 混淆   (较弱；Egern 唯一支持的 Snell 伪装)"
        echo "  3) ShadowTLS   (推荐过墙使用；仅 Surge 支持)"
        read -rp "$(echo -e "${CYAN}请选择 [1-3，默认 1]: ${NC}")" c
        case "${c:-1}" in
            1) SNELL_OBFS_PRESET="none" ;;
            2) SNELL_OBFS_PRESET="http" ;;
            3) create_snell_st "$family" "$address_mode" "$node_address"; return ;;
            *) err "无效选择"; pause; return ;;
        esac
    else
        SNELL_OBFS_PRESET=""
    fi
    install_snell_server "$gen" || { pause; return; }

    local port
    port=$(ask_port "请输入端口" "$(random_port)") || { pause; return; }

    # 版本专属参数：v4/v5 → HTTP 混淆；v6 → 流量整形模式
    local obfs="none" obfs_host="" mode="default" c
    echo
    if [[ "$ver" == "6" ]]; then
        echo "请选择流量整形模式:"
        echo "  1) default   (加密 + 流量整形，推荐)"
        echo "  2) unshaped  (仅加密，关闭整形，吞吐约高 10%)"
        read -rp "$(echo -e "${CYAN}请选择 [1-2，默认 1]: ${NC}")" c
        case "${c:-1}" in
            1) ;; 2) mode="unshaped" ;;
            *) err "无效选择"; pause; return ;;
        esac
    elif [[ -n "$SNELL_OBFS_PRESET" ]]; then
        # v4 已在前面选过
        if [[ "$SNELL_OBFS_PRESET" == "http" ]]; then
            obfs="http"
            read -rp "$(echo -e "${CYAN}请输入混淆 Host (默认 bing.com): ${NC}")" obfs_host
            obfs_host="${obfs_host:-bing.com}"
        fi
    else
        echo "请选择混淆方式:"
        echo "  1) 不混淆      (推荐：v5 适合不过墙的线路)"
        echo "  2) HTTP 混淆   (较弱；Egern 唯一支持的 Snell 伪装)"
        read -rp "$(echo -e "${CYAN}请选择 [1-2，默认 1]: ${NC}")" c
        case "${c:-1}" in
            1) ;;
            2) obfs="http"
               read -rp "$(echo -e "${CYAN}请输入混淆 Host (默认 bing.com): ${NC}")" obfs_host
               obfs_host="${obfs_host:-bing.com}" ;;
            *) err "无效选择"; pause; return ;;
        esac
    fi

    local remark tag psk ip unit
    remark=$(ask_remark "snell-v${ver}-${port}")
    tag=$(unique_node_tag "snell-v${ver}-${port}")
    unit="snell${gen}@${tag}"
    psk=$(openssl rand -hex 16)     # 32 位十六进制：满足 v6 要求，配置行中无需转义
    ip=$(get_node_address "$family" "$address_mode" "$node_address")
    [[ -z "$ip" ]] && { err "无法获取所选连接地址，请检查公网 IP 或 DDNS 配置"; pause; return; }

    local query="version=${ver}"
    [[ "$obfs" == "http" ]] && query+="&obfs=http&obfs-host=$(urlencode "$obfs_host")"
    [[ "$mode" != "default" ]] && query+="&mode=${mode}"
    local link="snell://${psk}@$(ip_for_url "$ip"):${port}?${query}#$(urlencode "$remark")"

    save_node "$tag" "snell-v${ver}" "$port" "$family" "$remark" "$link" \
        "$(jq -n --arg unit "$unit" --arg psk "$psk" --argjson ver "$ver" --arg obfs "$obfs" --arg mode "$mode" \
            '{unit:$unit, psk:$psk, version:$ver, obfs:$obfs, mode:$mode}')" || { pause; return; }

    # 启动失败则回滚：删实例、删刚写入的节点
    if ! snell_sync_idx "$(( $(jq 'length' "$SB_NODES") - 1 ))"; then
        snell_remove_unit "$unit" "$tag"
        json_edit "$SB_NODES" 'del(.[-1])'
        pause; return
    fi

    echo
    ok "节点创建成功: ${remark}"
    echo -e "${BOLD}节点配置 (整行复制到 Sub-Store / Surge):${NC}"
    echo -e "${GREEN}$(node_config_line "$link")${NC}"
    echo
    case "$ver" in
        5) warn "v5 的 QUIC 代理走 UDP：防火墙 / 安全组 / 中转机都要同时放行 ${port} 的 TCP 和 UDP" ;;
        6) warn "Snell v6 仍是 Beta：以后升级 Surge 时，记得同时更新服务端" ;;
    esac
    pause
}

# Snell + ShadowTLS v3：
#   公网端口 → sing-box shadowtls 入站（握手转发给真实网站，伪装成访问它）
#            → direct 入站（仅作 detour 目标）→ 本机 127.0.0.1:<内部端口> 的 snell-server
#   snell-server 只监听本机，不暴露在公网；UDP 也封装在 TCP 里走 TLS 伪装，
#   因此 Surge 端用 version=4（v5 的 QUIC 代理需要公网 UDP，无法伪装）。
create_snell_st() {
    local family="$1" address_mode="${2:-ip}" node_address="${3:-}"
    install_snell_server 5 || { pause; return; }

    local port sni inner
    # 默认随机高位端口；需要的话也可以手动填 443
    port=$(ask_port "请输入端口" "$(random_port)" 1) || { pause; return; }
    ask_camo_target
    sni="$CAMO_SNI"
    inner=$(random_port) || { pause; return; }

    local remark tag unit psk stpw ip
    remark=$(ask_remark "snell-st-${port}")
    tag=$(unique_node_tag "snell-st-${port}")
    unit="snell5@${tag}"
    psk=$(openssl rand -hex 16)
    stpw=$(openssl rand -hex 16)
    ip=$(get_node_address "$family" "$address_mode" "$node_address")
    [[ -z "$ip" ]] && { err "无法获取所选连接地址，请检查公网 IP 或 DDNS 配置"; pause; return; }

    local inbound aux
    aux=$(jq -n --arg tag "${tag}-fwd" --argjson inner "$inner" \
        '{type:"direct", tag:$tag, listen:"127.0.0.1",
          override_address:"127.0.0.1", override_port:$inner}')
    inbound=$(jq -n --arg tag "$tag" --arg listen "$(listen_addr "$family")" --argjson port "$port" \
        --arg pw "$stpw" --arg hs "$CAMO_HS_SERVER" --argjson hsp "$CAMO_HS_PORT" --arg detour "${tag}-fwd" \
        '{type:"shadowtls", tag:$tag, listen:$listen, listen_port:$port, version:3,
          users:[{name:"surge", password:$pw}],
          handshake:{server:$hs, server_port:$hsp},
          strict_mode:true, detour:$detour}')

    local link="snell://${psk}@$(ip_for_url "$ip"):${port}?version=4"
    link+="&shadow-tls-password=${stpw}&shadow-tls-sni=$(urlencode "$sni")&shadow-tls-version=3"
    link+="#$(urlencode "$remark")"

    save_node "$tag" "snell-st" "$port" "$family" "$remark" "$link" \
        "$(jq -n --arg unit "$unit" --arg psk "$psk" --argjson inner "$inner" \
            --arg stpw "$stpw" --arg sni "$sni" --argjson ib "$inbound" --argjson aux "$aux" \
            '{unit:$unit, psk:$psk, version:4, obfs:"none", inner_port:$inner,
              st_password:$stpw, sni:$sni, inbound:$ib, inbound_aux:$aux}')" || { pause; return; }

    # 先起 snell-server，再让 sing-box 加载 ShadowTLS；任一失败整体回滚
    if ! snell_sync_idx "$(( $(jq 'length' "$SB_NODES") - 1 ))"; then
        snell_remove_unit "$unit" "$tag"
        json_edit "$SB_NODES" 'del(.[-1])'
        pause; return
    fi
    rebuild_config
    if ! restart_sb; then
        snell_remove_unit "$unit" "$tag"
        json_edit "$SB_NODES" 'del(.[-1])'
        rebuild_config && restart_sb >/dev/null
        err "已撤销本次添加"
        pause; return
    fi

    echo
    ok "节点创建成功: ${remark}"
    echo -e "${BOLD}节点配置 (整行复制到 Sub-Store / Surge):${NC}"
    echo -e "${GREEN}$(node_config_line "$link")${NC}"
    echo
    warn "防火墙 / 安全组只需放行 ${port}/TCP；snell-server 只监听本机 ${inner} 端口，不对外"
    pause
}

# SS / SS-2022 + ShadowTLS v3（全部由 sing-box 实现）：
#   公网 TCP 端口 → shadowtls 入站（握手转发给伪装目标）→ 本机 shadowsocks 入站
#   UDP 不经过 ShadowTLS，单独开一个公网端口给 shadowsocks（客户端用 udp-port 指定）
create_ss_st() {
    local family="$1" method="$2" address_mode="${3:-ip}" node_address="${4:-}"
    local keylen=32 short_proto="ss" pwd
    [[ "$method" == *128* ]] && keylen=16
    if [[ "$method" == 2022-* ]]; then
        pwd=$(openssl rand -base64 "$keylen"); short_proto="ss2022"
    else
        pwd=$(openssl rand -base64 16)
    fi

    local port udp_port
    port=$(ask_port "请输入端口 (TCP，ShadowTLS)" "$(random_port)" 1) || { pause; return; }
    udp_port=$(random_port) || { pause; return; }
    ask_camo_target

    local remark tag stpw ip listen
    remark=$(ask_remark "${short_proto}-st-${port}")
    tag=$(unique_node_tag "${short_proto}-st-${port}")
    stpw=$(openssl rand -hex 16)
    ip=$(get_node_address "$family" "$address_mode" "$node_address")
    [[ -z "$ip" ]] && { err "无法获取所选连接地址，请检查公网 IP 或 DDNS 配置"; pause; return; }
    listen=$(listen_addr "$family")

    local inbound aux
    inbound=$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
        --arg pw "$stpw" --arg hs "$CAMO_HS_SERVER" --argjson hsp "$CAMO_HS_PORT" --arg detour "${tag}-ss" \
        '{type:"shadowtls", tag:$tag, listen:$listen, listen_port:$port, version:3,
          users:[{name:"user", password:$pw}],
          handshake:{server:$hs, server_port:$hsp}, strict_mode:true, detour:$detour}')
    aux=$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson up "$udp_port" \
        --arg m "$method" --arg pwd "$pwd" \
        '[{type:"shadowsocks", tag:($tag + "-ss"), listen:"127.0.0.1", network:"tcp", method:$m, password:$pwd},
          {type:"shadowsocks", tag:($tag + "-udp"), listen:$listen, listen_port:$up, network:"udp", method:$m, password:$pwd}]')

    local b64 link
    b64=$(echo -n "${method}:${pwd}" | base64 -w0 | tr -d '=' | tr '/+' '_-')
    link="ss://${b64}@$(ip_for_url "$ip"):${port}?udp-port=${udp_port}"
    link+="&shadow-tls-password=${stpw}&shadow-tls-sni=$(urlencode "$CAMO_SNI")&shadow-tls-version=3"
    link+="#$(urlencode "$remark")"

    save_node "$tag" "${short_proto}-st" "$port" "$family" "$remark" "$link" \
        "$(jq -n --argjson ib "$inbound" --argjson aux "$aux" --arg sni "$CAMO_SNI" --argjson up "$udp_port" \
            '{inbound:$ib, inbound_aux:$aux, sni:$sni, udp_port:$up}')" || { pause; return; }
    rebuild_config
    if ! restart_sb; then
        json_edit "$SB_NODES" 'del(.[-1])'
        rebuild_config && restart_sb >/dev/null
        err "已撤销本次添加"
        pause; return
    fi

    echo
    ok "节点创建成功: ${remark}"
    echo -e "${BOLD}节点配置 (整行复制到 Sub-Store / Surge):${NC}"
    echo -e "${GREEN}$(node_config_line "$link")${NC}"
    echo
    warn "防火墙 / 安全组放行: ${port}/TCP 和 ${udp_port}/UDP"
    pause
}

# 内部链接 → Surge [Proxy] 配置行（Snell 和带 ShadowTLS 的 SS 用；Sub-Store 能识别这种格式）
#   snell://<psk>@<host>:<port>?k=v&...#<备注>
#   ss://<base64url(method:password)>@<host>:<port>?k=v&...#<备注>
node_config_line() {
    local link="$1" scheme="${1%%://*}" body="${1#*://}" query="" frag="" cred hostport host port name kv
    [[ "$body" == *"#"* ]] && { frag="${body#*#}"; body="${body%%#*}"; }
    [[ "$body" == *"?"* ]] && { query="${body#*\?}"; body="${body%%\?*}"; }
    cred="${body%@*}"; hostport="${body##*@}"
    port="${hostport##*:}"; host="${hostport%:*}"
    host="${host#[}"; host="${host%]}"            # Surge 中 IPv6 不加方括号

    name=$(urldecode "$frag")
    name="${name//,/-}"; name="${name//=/-}"      # , 和 = 会破坏 Surge 配置行

    local line
    if [[ "$scheme" == "ss" ]]; then
        local b64="${cred//_//}" plain
        b64="${b64//-/+}"
        while (( ${#b64} % 4 )); do b64+="="; done
        plain=$(printf '%s' "$b64" | base64 -d 2>/dev/null)
        line="${name:-SS} = ss, ${host}, ${port}, encrypt-method=${plain%%:*}, password=${plain#*:}"
    else
        line="${name:-Snell} = snell, ${host}, ${port}, psk=${cred}"
    fi
    local -a pairs=()
    [[ -n "$query" ]] && IFS='&' read -ra pairs <<< "$query"
    for kv in "${pairs[@]}"; do
        line+=", ${kv%%=*}=$(urldecode "${kv#*=}")"
    done
    if [[ "$scheme" == "ss" ]]; then
        echo "${line}, udp-relay=true"
    else
        echo "${line}, reuse=true"
    fi
}

# 选择伪装目标（Reality / ShadowTLS 共用），结果写入全局变量：
#   CAMO_SNI       客户端使用的 SNI
#   CAMO_HS_SERVER 服务端握手转发到的地址
#   CAMO_HS_PORT   服务端握手转发到的端口
ask_camo_target() {
    local host
    read -rp "$(echo -e "${CYAN}请输入借用的网站 (需支持 TLS 1.3，默认 www.microsoft.com): ${NC}")" host
    CAMO_SNI="${host:-www.microsoft.com}"
    CAMO_HS_SERVER="$CAMO_SNI"
    CAMO_HS_PORT=443
}

menu_add_ddns() {
    local n idx host type family
    n=$(ddns_count)
    if (( n == 0 )); then
        err "尚未配置 DDNS 记录，请先在主菜单进入 d → 1 新增"
        pause; return
    fi
    clear; show_banner
    sec "DDNS 域名 → 选择记录"
    idx=$(ddns_pick) || return
    IFS=$'\t' read -r host type < <(jq -r --argjson i "$idx" \
        '.records[$i] | [.hostname, .type] | @tsv' "$CF_DDNS_CONF")
    [[ "$type" == "AAAA" ]] && family=6 || family=4
    menu_new_proto "$family" "ddns" "$host"
}

menu_add() {
    while :; do
        clear; show_banner
        sec "添加配置 → 选择节点连接地址"
        echo "  1) IPv4 地址"
        echo "  2) IPv6 地址"
        echo "  3) DDNS 域名"
        echo "  0) 返回上一页"
        hr
        local c
        read -rp "$(echo -e "${CYAN}请选择 [0-3]: ${NC}")" c
        case "$c" in
            1) menu_new_proto "4" "ip"; return ;;
            2) menu_new_proto "6" "ip"; return ;;
            3) menu_add_ddns; return ;;
            0|"") return ;;
            *) err "无效选择"; sleep 1 ;;
        esac
    done
}
# =============================================================================
# 查看 / 更改 / 删除 节点
# =============================================================================
view_nodes() {
    clear; show_banner
    sec "查看配置 (Nodes)"
    local n
    n=$(jq 'length' "$SB_NODES")
    if (( n == 0 )); then
        warn "暂无节点"
    else
        local i=0
        while IFS=$'\t' read -r tag remark proto port family link unit; do
            i=$((i+1))
            echo -e "${BOLD}[${i}] ${remark}${NC} ${YELLOW}(${tag})${NC}"
            echo -e "    协议: ${proto}    端口: ${port}    IPv${family}"
            if [[ "$link" == snell://* || "$link" == *shadow-tls-* ]]; then
                echo -e "    ${GREEN}$(node_config_line "$link")${NC}"
                if [[ -n "$unit" ]] && ! systemctl is-active --quiet "$unit"; then
                    echo -e "    ${RED}snell-server 未运行${NC} (journalctl -u ${unit} 查看原因)"
                fi
            else
                echo -e "    ${GREEN}${link}${NC}"
            fi
            echo
        done < <(jq -r '.[] | [.tag, .remark, .protocol, .port, .family, .link, (.extra.unit // "")] | @tsv' "$SB_NODES")
    fi
    hr
    pause
}

delete_node() {
    while :; do
        clear; show_banner
        sec "删除配置"
        local n; n=$(jq 'length' "$SB_NODES")
        if (( n == 0 )); then
            warn "暂无节点"; pause; return
        fi
        local i=0
        while IFS=$'\t' read -r tag remark proto port; do
            i=$((i+1))
            printf "  %d) %-22s %-32s 端口 %s\n" "$i" "$remark" "[$proto]" "$port"
        done < <(jq -r '.[] | [.tag, .remark, .protocol, .port] | @tsv' "$SB_NODES")
        echo "  0) 返回上一页"
        hr
        local c
        read -rp "$(echo -e "${CYAN}输入要删除的编号 [0-${n}]: ${NC}")" c
        [[ "$c" == "0" || -z "$c" ]] && return
        if ! [[ "$c" =~ ^[0-9]+$ ]] || (( c < 1 || c > n )); then
            err "无效编号"; sleep 1; continue
        fi
        local idx=$((c-1))
        local tag port remark
        tag=$(jq -r ".[${idx}].tag" "$SB_NODES")
        port=$(jq -r ".[${idx}].port" "$SB_NODES")
        remark=$(jq -r ".[${idx}].remark" "$SB_NODES")
        read -rp "$(echo -e "${YELLOW}确定删除 ${remark} (端口 ${port})? [y/N]: ${NC}")" y
        [[ "$y" =~ ^[Yy]$ ]] || continue
        [[ -f "${SB_CERT_DIR}/${tag}.crt" ]] && rm -f "${SB_CERT_DIR}/${tag}.crt" "${SB_CERT_DIR}/${tag}.key"
        local unit has_ib
        unit=$(jq -r ".[${idx}].extra.unit // empty" "$SB_NODES")
        has_ib=$(jq -r ".[${idx}].extra.inbound != null" "$SB_NODES")
        json_edit "$SB_NODES" --argjson i "$idx" 'del(.[$i])' || { pause; continue; }
        [[ -n "$unit" ]] && snell_remove_unit "$unit" "$tag"
        if [[ "$has_ib" == "true" ]]; then
            rebuild_config
            restart_sb && ok "已删除 ${remark}"
        else
            ok "已删除 ${remark}"     # 纯 snell-server 节点，不必重启 sing-box
        fi
        sleep 1
    done
}

modify_node() {
    while :; do
        clear; show_banner
        sec "更改配置"
        local n; n=$(jq 'length' "$SB_NODES")
        if (( n == 0 )); then
            warn "暂无节点"; pause; return
        fi
        local i=0
        while IFS=$'\t' read -r tag remark proto port; do
            i=$((i+1))
            printf "  %d) %-22s %-32s 端口 %s\n" "$i" "$remark" "[$proto]" "$port"
        done < <(jq -r '.[] | [.tag, .remark, .protocol, .port] | @tsv' "$SB_NODES")
        echo "  0) 返回上一页"
        hr
        local c
        read -rp "$(echo -e "${CYAN}选择要修改的节点 [0-${n}]: ${NC}")" c
        [[ "$c" == "0" || -z "$c" ]] && return
        if ! [[ "$c" =~ ^[0-9]+$ ]] || (( c < 1 || c > n )); then
            err "无效编号"; sleep 1; continue
        fi
        modify_node_detail $((c-1))
    done
}

modify_node_detail() {
    local idx="$1"
    while :; do
        clear; show_banner
        local tag remark proto port family link
        tag=$(jq -r ".[${idx}].tag" "$SB_NODES")
        remark=$(jq -r ".[${idx}].remark" "$SB_NODES")
        proto=$(jq -r ".[${idx}].protocol" "$SB_NODES")
        port=$(jq -r ".[${idx}].port" "$SB_NODES")
        family=$(jq -r ".[${idx}].family" "$SB_NODES")
        link=$(jq -r ".[${idx}].link" "$SB_NODES")
        sec "更改: ${remark}"
        echo "  备注: ${remark}"
        echo "  协议: ${proto}"
        echo "  端口: ${port}"
        echo "  出口: IPv${family}"
        if [[ "$link" == snell://* || "$link" == *shadow-tls-* ]]; then
            echo -e "  配置: ${GREEN}$(node_config_line "$link")${NC}"
        else
            echo -e "  链接: ${GREEN}${link}${NC}"
        fi
        hr
        echo "  1) 修改备注"
        echo "  2) 修改端口"
        echo "  0) 返回上一页"
        hr
        local c
        read -rp "$(echo -e "${CYAN}请选择 [0-2]: ${NC}")" c
        case "$c" in
            1) modify_remark "$idx" ;;
            2) modify_port "$idx" ;;
            0|"") return ;;
            *) err "无效选择"; sleep 1 ;;
        esac
    done
}

modify_remark() {
    local idx="$1" old new
    old=$(jq -r ".[${idx}].remark" "$SB_NODES")
    read -rp "$(echo -e "${CYAN}请输入新备注 (当前: ${old}): ${NC}")" new
    [[ -z "$new" ]] && return
    # 链接 # 后面是备注，一并更新
    json_edit "$SB_NODES" --argjson i "$idx" --arg r "$new" --arg e "$(urlencode "$new")" \
        '.[$i].remark = $r | .[$i].link |= (split("#")[0] + "#" + $e)' && ok "备注已更新"
    sleep 1
}

modify_port() {
    local idx="$1"
    local old new
    old=$(jq -r ".[${idx}].port" "$SB_NODES")
    new=$(ask_port_exclude "请输入新端口 (当前 ${old})" "$old" "$old") || { pause; return; }

    # 更新 port 和 inbound.listen_port（snell-server 节点没有 inbound）
    json_edit "$SB_NODES" --argjson p "$new" --argjson i "$idx" \
       '.[$i].port = $p | if .[$i].extra.inbound then .[$i].extra.inbound.listen_port = $p else . end' \
       || { pause; return; }

    # 重新生成 link：解析旧 link，替换 host 后的 port
    # 注意：host 可能是 IPv4 / [IPv6] / 域名；port 后面可能是 / 或 ? 或 # 或字符串结束
    local link new_link
    link=$(jq -r ".[${idx}].link" "$SB_NODES")
    new_link=$(awk -v old="$old" -v new="$new" '
        BEGIN {
            # 把 link 拆成: scheme://userinfo@host:port [rest]
            # 用 awk 处理 IPv6 中括号 + 普通 host 都安全
        }
        {
            line = $0
            # 找最后一个 @ 之后的部分（host:port[rest]）
            at = 0
            for (i = length(line); i >= 1; i--) {
                if (substr(line, i, 1) == "@") { at = i; break }
            }
            if (at == 0) { print line; next }
            prefix = substr(line, 1, at)
            rest = substr(line, at + 1)
            # rest 形如 host:port 或 [v6]:port 后面可能跟 /?#
            # 找到 port 部分：从右往左找第一个 : 但不在 [] 内
            in_bracket = 0
            port_pos = 0
            for (i = 1; i <= length(rest); i++) {
                c = substr(rest, i, 1)
                if (c == "[") in_bracket = 1
                else if (c == "]") in_bracket = 0
                else if (c == ":" && !in_bracket) port_pos = i
                else if ((c == "/" || c == "?" || c == "#") && !in_bracket) break
            }
            if (port_pos == 0) { print line; next }
            host_part = substr(rest, 1, port_pos)
            after = substr(rest, port_pos + 1)
            # after 形如 "12345/xxx" 或 "12345?xxx" 或 "12345#xxx" 或 "12345"
            # 提取连续数字作为旧端口
            num = ""
            i = 1
            while (i <= length(after) && substr(after, i, 1) ~ /[0-9]/) {
                num = num substr(after, i, 1)
                i++
            }
            tail = substr(after, i)
            if (num == old) {
                print prefix host_part new tail
            } else {
                print line
            }
        }
    ' <<< "$link")

    json_edit "$SB_NODES" --argjson i "$idx" --arg l "$new_link" '.[$i].link = $l'
    if [[ "$(jq -r ".[${idx}].extra.inbound != null" "$SB_NODES")" == "true" ]]; then
        rebuild_config
        restart_sb && ok "端口已改为 ${new}"
    else
        snell_sync_idx "$idx" && ok "端口已改为 ${new}"
    fi
    sleep 1
}
# =============================================================================
# 分流规则管理 - 添加分流出口（手动逐项输入）
# =============================================================================
add_outbound() {
    clear; show_banner
    sec "添加分流出口 (Outbound)"
    echo "  1. Shadowsocks"
    echo "  2. VLESS-REALITY"
    echo "  3. VLESS-WS-TLS"
    echo "  4. Hysteria2"
    echo "  5. Tuic-V5"
    echo "  6. Trojan"
    echo "  7. AnyTLS"
    echo "  8. Socks5"
    echo "  0. 返回"
    hr
    local c
    read -rp "$(echo -e "${CYAN}请选择 [0-8]: ${NC}")" c
    case "$c" in
        1) ob_shadowsocks ;;
        2) ob_vless_reality ;;
        3) ob_vless_ws_tls ;;
        4) ob_password_tls hysteria2 "Hysteria2-Out" ;;
        5) ob_tuic ;;
        6) ob_password_tls trojan "Trojan-Out" ;;
        7) ob_password_tls anytls "AnyTLS-Out" ;;
        8) ob_socks5 ;;
        0|"") return ;;
        *) err "无效选择"; sleep 1 ;;
    esac
}

# 公共：询问出口备注与标签
ask_ob_tag() {
    local default="$1"
    local tag
    while :; do
        read -rp "$(echo -e "${CYAN}请输入出口备注 (回车默认 ${default}): ${NC}")" tag
        tag="${tag:-$default}"
        if ! [[ "$tag" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            err "备注只能包含字母/数字/下划线/连字符" >&2
            continue
        fi
        if [[ "$tag" =~ ^(direct|block|ipv4-out|ipv6-out)$ ]]; then
            err "备注名与内置出口冲突" >&2
            continue
        fi
        if jq -e --arg t "$tag" '.[] | select(.tag == $t)' "$SB_OUTBOUNDS" >/dev/null 2>&1; then
            err "出口 ${tag} 已存在" >&2
            continue
        fi
        echo "$tag"
        return 0
    done
}

# 公共：保存出站（失败自动回滚）
save_outbound() {
    local tag="$1" proto="$2" outbound="$3"
    sb_commit "$SB_OUTBOUNDS" --arg tag "$tag" --arg proto "$proto" --argjson ob "$outbound" \
        '. += [{tag:$tag, protocol:$proto, outbound:$ob}]' && ok "已添加出口: ${tag}"
    pause
}

# 以下各协议：先收集参数，任一必填项为空即取消；server/port 由 ask_server_port 统一校验
ob_shadowsocks() {
    local tag sp pwd method
    tag=$(ask_ob_tag "Shadowsocks-Out")
    sp=$(ask_server_port) && pwd=$(ask_required "密码") || { pause; return; }
    echo
    method=$(pick_ss_method all) || return
    save_outbound "$tag" "shadowsocks" "$(jq -n --arg tag "$tag" --arg s "${sp%|*}" --argjson p "${sp#*|}" \
        --arg m "$method" --arg pw "$pwd" \
        '{type:"shadowsocks", tag:$tag, server:$s, server_port:$p, method:$m, password:$pw}')"
}

ob_vless_reality() {
    local tag sp uuid sni pbk sid fp
    tag=$(ask_ob_tag "Reality-Out")
    sp=$(ask_server_port) && uuid=$(ask_required "UUID") && sni=$(ask_required "SNI") \
        && pbk=$(ask_required "Reality public_key (pbk)") || { pause; return; }
    read -rp "$(echo -e "${CYAN}请输入 short_id (sid): ${NC}")" sid
    read -rp "$(echo -e "${CYAN}请输入指纹 fingerprint (回车默认 chrome): ${NC}")" fp
    save_outbound "$tag" "vless-reality" "$(jq -n --arg tag "$tag" --arg s "${sp%|*}" --argjson p "${sp#*|}" \
        --arg u "$uuid" --arg sni "$sni" --arg pbk "$pbk" --arg sid "$sid" --arg fp "${fp:-chrome}" \
        '{type:"vless", tag:$tag, server:$s, server_port:$p, uuid:$u, flow:"xtls-rprx-vision",
          tls:{enabled:true, server_name:$sni,
            utls:{enabled:true, fingerprint:$fp},
            reality:{enabled:true, public_key:$pbk, short_id:$sid}}}')"
}

ob_vless_ws_tls() {
    local tag sp uuid sni path host
    tag=$(ask_ob_tag "VLESS-WS-Out")
    sp=$(ask_server_port) && uuid=$(ask_required "UUID") && sni=$(ask_required "SNI") || { pause; return; }
    read -rp "$(echo -e "${CYAN}请输入 WS path (回车默认 /): ${NC}")" path
    read -rp "$(echo -e "${CYAN}请输入 WS Host (回车默认与 SNI 相同): ${NC}")" host
    save_outbound "$tag" "vless-ws-tls" "$(jq -n --arg tag "$tag" --arg s "${sp%|*}" --argjson p "${sp#*|}" \
        --arg u "$uuid" --arg sni "$sni" --arg path "${path:-/}" --arg host "${host:-$sni}" \
        '{type:"vless", tag:$tag, server:$s, server_port:$p, uuid:$u,
          tls:{enabled:true, server_name:$sni},
          transport:{type:"ws", path:$path, headers:{Host:$host}}}')"
}

# Hysteria2 / Trojan / AnyTLS：参数结构相同（密码 + TLS）
ob_password_tls() {
    local type="$1" tag sp pwd sni insec
    tag=$(ask_ob_tag "$2")
    sp=$(ask_server_port) && pwd=$(ask_required "密码") && sni=$(ask_required "SNI") || { pause; return; }
    insec=$(ask_insecure)
    save_outbound "$tag" "$type" "$(jq -n --arg type "$type" --arg tag "$tag" --arg s "${sp%|*}" --argjson p "${sp#*|}" \
        --arg pw "$pwd" --arg sni "$sni" --argjson insec "$insec" \
        '{type:$type, tag:$tag, server:$s, server_port:$p, password:$pw,
          tls:{enabled:true, server_name:$sni, insecure:$insec}}')"
}

ob_tuic() {
    local tag sp uuid pwd sni insec
    tag=$(ask_ob_tag "TUIC-Out")
    sp=$(ask_server_port) && uuid=$(ask_required "UUID") && pwd=$(ask_required "密码") \
        && sni=$(ask_required "SNI") || { pause; return; }
    insec=$(ask_insecure)
    save_outbound "$tag" "tuic" "$(jq -n --arg tag "$tag" --arg s "${sp%|*}" --argjson p "${sp#*|}" \
        --arg u "$uuid" --arg pw "$pwd" --arg sni "$sni" --argjson insec "$insec" \
        '{type:"tuic", tag:$tag, server:$s, server_port:$p, uuid:$u, password:$pw,
          congestion_control:"bbr",
          tls:{enabled:true, server_name:$sni, insecure:$insec, alpn:["h3"]}}')"
}

ob_socks5() {
    local tag sp user pwd
    tag=$(ask_ob_tag "Socks5-Out")
    sp=$(ask_server_port) || { pause; return; }
    read -rp "$(echo -e "${CYAN}请输入用户名 (无认证则回车): ${NC}")" user
    read -rp "$(echo -e "${CYAN}请输入密码 (无认证则回车): ${NC}")" pwd
    save_outbound "$tag" "socks5" "$(jq -n --arg tag "$tag" --arg s "${sp%|*}" --argjson p "${sp#*|}" \
        --arg u "$user" --arg pw "$pwd" \
        '{type:"socks", tag:$tag, server:$s, server_port:$p, version:"5"}
         + (if $u != "" then {username:$u, password:$pw} else {} end)')"
}

# ---------- 添加分流规则 ----------
add_rule() {
    clear; show_banner
    sub "添加分流规则"
    echo
    local input match
    read -rp "$(echo -e "${CYAN}请输入目标域名 (多个用逗号分隔，支持 geosite:xxx): ${NC}")" input
    [[ -z "$input" ]] && return
    match=$(parse_rule_input "$input")
    jq -e '(.geosite + .domain) | length > 0' <<<"$match" >/dev/null || { err "没有有效规则"; pause; return; }

    echo
    echo -e "${CYAN}请选择流量去向 (Target Outbound):${NC}"
    echo "  1. direct          (内置-直连)"
    echo "  2. block           (内置-屏蔽)"
    echo "  3. ipv4-out        (内置-IPv4 直连)"
    echo "  4. ipv6-out        (内置-IPv6 直连)"
    local outs=(direct block ipv4-out ipv6-out) i=4 tag proto c
    while IFS=$'\t' read -r tag proto; do
        i=$((i+1))
        printf "  %d. %-22s (%s)\n" "$i" "$tag" "$proto"
        outs+=("$tag")
    done < <(jq -r '.[] | [.tag, .protocol] | @tsv' "$SB_OUTBOUNDS")
    hr
    read -rp "$(echo -e "${CYAN}请选择 [1-${i}]: ${NC}")" c
    [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= i )) || { err "无效"; pause; return; }
    local out_tag="${outs[$((c-1))]}"

    sb_commit "$SB_RULES" --argjson m "$match" --arg out "$out_tag" '. += [$m + {outbound:$out}]' \
        && ok "已添加规则: [$(rule_desc "$match")] -> [${out_tag}]"
    pause
}

# 修改 settings.json 的一个字段并生效（失败自动撤销）：settings_set <键> <JSON 值>
settings_set() {
    sb_commit "$SB_SETTINGS" --arg k "$1" --argjson v "$2" '.[$k] = $v'
}

# 开关类设置的通用界面：toggle_setting <键> <名称> [说明行...]
toggle_setting() {
    local key="$1" label="$2" cur new act line c
    shift 2
    clear; show_banner
    sec "$label"
    cur=$(jq -r --arg k "$key" '.[$k] // false' "$SB_SETTINGS")
    if [[ "$cur" == "true" ]]; then
        echo -e "  当前: ${GREEN}已开启${NC}"; new=false; act="关闭"
    else
        echo -e "  当前: ${RED}未开启${NC}"; new=true; act="开启"
    fi
    for line in "$@"; do echo -e "  ${YELLOW}${line}${NC}"; done
    hr
    echo "  1) ${act}「${label}」"
    echo "  0) 返回"
    hr
    read -rp "$(echo -e "${CYAN}请选择 [0-1]: ${NC}")" c
    [[ "$c" == "1" ]] || return
    settings_set "$key" "$new" && ok "「${label}」已${act}"
    pause
}

# ---------- 查看 / 删除 规则与出口 ----------
view_del_rules() {
    while :; do
        clear; show_banner
        sec "当前分流规则 (Current Rules)"
        local rn; rn=$(jq 'length' "$SB_RULES")
        if (( rn == 0 )); then
            echo "  (无)"
        else
            local i=0
            while IFS=$'\t' read -r desc outbound; do
                i=$((i+1))
                echo -e "  ${BOLD}${i}.${NC} 规则: ${CYAN}${desc}${NC} -> ${YELLOW}[${outbound}]${NC}"
            done < <(jq -r '.[] |
                ([(.geosite[]? | "geosite:\(.)"), (.domain[]?)] | join(",")) as $d |
                [$d, .outbound] | @tsv' "$SB_RULES")
        fi
        local bcn; bcn=$(jq -r '.block_cn' "$SB_SETTINGS")
        if [[ "$bcn" == "true" ]]; then
            echo -e "  ${BOLD}*.${NC} 内置: ${CYAN}geosite:cn,geoip:cn${NC} -> ${RED}[block]${NC}"
        fi

        sec "自定义出口 (Outbounds)"
        echo -e "  ${YELLOW}N1.${NC} 节点: [direct]    (内置-直连)"
        echo -e "  ${YELLOW}N2.${NC} 节点: [block]     (内置-屏蔽)"
        echo -e "  ${YELLOW}N3.${NC} 节点: [ipv4-out]  (内置-IPv4)"
        echo -e "  ${YELLOW}N4.${NC} 节点: [ipv6-out]  (内置-IPv6)"
        local on; on=$(jq 'length' "$SB_OUTBOUNDS")
        local j=4
        if (( on > 0 )); then
            while IFS=$'\t' read -r tag proto; do
                j=$((j+1))
                echo -e "  ${YELLOW}N${j}.${NC} 节点: [${tag}]    (${proto})"
            done < <(jq -r '.[] | [.tag, .protocol] | @tsv' "$SB_OUTBOUNDS")
        fi
        hr
        echo "  1) 删除规则 (输入序号 1, 2...)"
        echo "  2) 删除出口节点 (输入序号 N5, N6...)"
        echo "  0) 返回"
        hr
        local c
        read -rp "$(echo -e "${CYAN}请选择 [0-2]: ${NC}")" c
        case "$c" in
            1) del_rule_by_index ;;
            2) del_outbound_by_index ;;
            0|"") return ;;
            *) err "无效选择"; sleep 1 ;;
        esac
    done
}

del_rule_by_index() {
    local rn c
    rn=$(jq 'length' "$SB_RULES")
    (( rn == 0 )) && { warn "无规则"; sleep 1; return; }
    read -rp "$(echo -e "${CYAN}输入要删除的规则序号 [1-${rn}]: ${NC}")" c
    [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= rn )) || { err "无效"; sleep 1; return; }
    sb_commit "$SB_RULES" --argjson i "$((c-1))" 'del(.[$i])' && ok "规则已删除"
    sleep 1
}

del_outbound_by_index() {
    local on c idx tag y
    on=$(jq 'length' "$SB_OUTBOUNDS")
    (( on == 0 )) && { warn "无自定义出口"; sleep 1; return; }
    read -rp "$(echo -e "${CYAN}输入要删除的出口序号 (例如 N5): ${NC}")" c
    c="${c#[Nn]}"
    [[ "$c" =~ ^[0-9]+$ ]] || { err "无效"; sleep 1; return; }
    idx=$((c - 5))      # N1-N4 是内置出口
    (( idx >= 0 && idx < on )) || { err "无效序号"; sleep 1; return; }
    tag=$(jq -r ".[${idx}].tag" "$SB_OUTBOUNDS")
    if jq -e --arg t "$tag" '.[] | select(.outbound == $t)' "$SB_RULES" >/dev/null; then
        err "出口 ${tag} 被分流规则引用，请先删除相关规则"
        sleep 2; return
    fi
    read -rp "$(echo -e "${YELLOW}确定删除出口 ${tag}? [y/N]: ${NC}")" y
    [[ "$y" =~ ^[Yy]$ ]] || return
    sb_commit "$SB_OUTBOUNDS" --argjson i "$idx" 'del(.[$i])' && ok "出口已删除"
    sleep 1
}

menu_routing() {
    while :; do
        clear; show_banner
        sec "分流规则管理 (Routing)"
        echo -e "  ${YELLOW}提示: 用户规则优先于"屏蔽大陆"，被用户规则命中的流量不会被屏蔽${NC}"
        hr
        echo "  1. 添加分流出口 (添加节点)"
        echo
        echo "  2. 添加域名规则 (指定分流)"
        echo
        echo "  3. 屏蔽 / 恢复 大陆"
        echo
        echo "  4. 查看 / 删除 配置"
        echo
        echo "  0. 返回上一页"
        hr
        local c
        read -rp "$(echo -e "${CYAN}请选择 [0-4]: ${NC}")" c
        case "$c" in
            1) add_outbound ;;
            2) add_rule ;;
            3) toggle_setting block_cn "屏蔽大陆流量" "用户规则优先：被用户规则命中的流量不会被屏蔽" ;;
            4) view_del_rules ;;
            0|"") return ;;
            *) err "无效选择"; sleep 1 ;;
        esac
    done
}

# =============================================================================
# 客户端代理模式：本地 SOCKS 出口 + 多落地出口 + 域名/geosite 分流
# 把本机变成客户端，落地一个本地 SOCKS5(127.0.0.1:port)，
# 内部按"目标域名/geosite -> 指定落地出口"分流，未匹配走 final(默认直连=本机)。
# 典型用途：Claude Code 走落地A，Codex 走落地B，其余网站直连或走落地C。
# 与服务端配置完全隔离：独立 config (client.json) + 独立 systemd 服务。
#
# 元信息结构 client_meta.json:
# {
#   "socks_port": 10808,
#   "final": "direct",                 # 默认出口 tag(direct 或某出口 tag)
#   "download_detour": "direct",       # 下载 geosite .srs 走哪个出口
#   "outbounds": [ {tag,proto,...各协议参数}, ... ],
#   "rules": [ {domain:[..], geosite:[..], outbound:"tag"}, ... ]
# }
# =============================================================================

# 解析 vless:// 链接 -> {server,port,uuid,sni,pbk,sid,flow,fp}
parse_vless_link() {
    local link="$1"
    [[ "$link" == vless://* ]] || { echo ""; return 1; }
    local body="${link#vless://}"
    body="${body%%#*}"
    local uuid rest hostport query host port
    uuid="${body%%@*}"
    rest="${body#*@}"
    if [[ "$rest" == *\?* ]]; then
        hostport="${rest%%\?*}"; query="${rest#*\?}"
    else
        hostport="$rest"; query=""
    fi
    hostport="${hostport%%/*}"   # 很多链接是 host:443/?type=... ，先去掉路径部分
    if [[ "$hostport" == \[*\]:* ]]; then
        host="${hostport%]:*}"; host="${host#[}"; port="${hostport##*:}"
    else
        host="${hostport%:*}"; port="${hostport##*:}"
    fi
    [[ "$body" == *@* && -n "$uuid" && -n "$host" && "$port" =~ ^[0-9]+$ ]] || { echo ""; return 1; }
    local sni="" pbk="" sid="" flow="" fp="chrome"
    local IFS='&' kv k v
    for kv in $query; do
        k="${kv%%=*}"; v="${kv#*=}"
        case "$k" in
            sni|peer) sni="$v" ;;
            pbk) pbk="$v" ;;
            sid) sid="$v" ;;
            flow) flow="$v" ;;
            fp) fp="$v" ;;
        esac
    done
    unset IFS
    jq -n --arg server "$host" --arg port "$port" --arg uuid "$uuid" \
          --arg sni "$sni" --arg pbk "$pbk" --arg sid "$sid" \
          --arg flow "$flow" --arg fp "$fp" \
        '{server:$server, port:($port|tonumber), uuid:$uuid, sni:$sni,
          pbk:$pbk, sid:$sid, flow:$flow, fp:$fp}'
}

setup_client_service() {
    cat > "$SB_CLIENT_SERVICE" <<EOF
[Unit]
Description=sing-box client (local SOCKS proxy, multi-outbound)
After=network.target nss-lookup.target

[Service]
ExecStart=${SB_BIN} run -c ${SB_CLIENT_CONF}
Restart=on-failure
RestartSec=10s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# ---- 元信息初始化/读写 ----
client_meta_init() {
    [[ -f "$SB_CLIENT_META" ]] && return 0
    jq -n '{socks_port:10808, final:"direct", download_detour:"direct",
            outbounds:[], rules:[]}' > "$SB_CLIENT_META"
}

# ---- 把单个出口元信息(含proto+参数)转成 sing-box outbound JSON ----
# 入参: 一段 JSON(含 tag, proto, 及各协议字段)。输出: sing-box outbound 对象。
client_ob_to_singbox() {
    jq -e '
        if .proto == "vless-reality" then
            {type:"vless", tag, server, server_port:.port, uuid,
             tls:{enabled:true, server_name:.sni,
                  utls:{enabled:true, fingerprint:(.fp // "chrome")},
                  reality:{enabled:true, public_key:.pbk, short_id:.sid}}}
            + (if (.flow // "") != "" then {flow} else {} end)
        elif .proto == "ss" or .proto == "ss2022" then
            {type:"shadowsocks", tag, server, server_port:.port, method, password}
        elif .proto == "anytls" then
            {type:"anytls", tag, server, server_port:.port, password,
             tls:{enabled:true, server_name:.sni, insecure:(.insecure // false)}}
        else empty end' <<<"$1" || { err "未知协议: $(jq -r '.proto' <<<"$1")" >&2; return 1; }
}

# ---- 由元信息生成 client.json（先校验再替换，失败不影响正在运行的配置）----
rebuild_client_config() {
    [[ -f "$SB_CLIENT_META" ]] || { err "无客户端配置元信息"; return 1; }

    local sport final dl_detour
    sport=$(jq -r '.socks_port' "$SB_CLIENT_META")
    final=$(jq -r '.final' "$SB_CLIENT_META")
    dl_detour=$(jq -r '.download_detour // "direct"' "$SB_CLIENT_META")

    # 1) 所有出口 + 内置 direct/block
    local all_obs="[]" ob sb_ob
    while IFS= read -r ob; do
        sb_ob=$(client_ob_to_singbox "$ob") || return 1
        all_obs=$(jq --argjson o "$sb_ob" '. + [$o]' <<<"$all_obs")
    done < <(jq -c '.outbounds[]' "$SB_CLIENT_META")
    all_obs=$(jq '. + [{type:"direct",tag:"direct"},{type:"block",tag:"block"}]' <<<"$all_obs")

    # 2) 用到的 geosite → 远程规则集
    local rule_sets
    # shellcheck disable=SC2046
    rule_sets=$(rule_sets_json "$dl_detour" $(jq -r '.rules[].geosite[]? | "geosite-\(.)"' "$SB_CLIENT_META"))

    # 3) 每条规则 -> {rule_set?/domain_suffix?} + route/reject
    local route_rules
    route_rules=$(jq '[.rules[] |
        (if (.geosite|length)>0 then {rule_set:[(.geosite[] | "geosite-\(.)")]} else {} end) +
        (if (.domain|length)>0 then {domain_suffix:.domain} else {} end) +
        (if .outbound == "block" then {action:"reject"} else {outbound:.outbound, action:"route"} end)
        | select(has("rule_set") or has("domain_suffix"))
    ]' "$SB_CLIENT_META")

    local tmp; tmp=$(mktemp --suffix=.json)
    jq -n \
        --argjson sport "$sport" \
        --argjson obs "$all_obs" \
        --argjson rsets "$rule_sets" \
        --argjson rules "$route_rules" \
        --arg final "$final" \
        --arg log "$SB_CLIENT_LOG" \
        '{
            log:{level:"warn", output:$log, timestamp:true},
            dns:{servers:[{type:"local", tag:"local"}]},
            inbounds:[{type:"mixed", tag:"mixed-in", listen:"127.0.0.1", listen_port:$sport}],
            outbounds:$obs,
            route:{rule_set:$rsets, rules:([{action:"sniff"}] + $rules), final:$final, auto_detect_interface:true}
        }' > "$tmp" || { rm -f "$tmp"; err "生成客户端配置失败"; return 1; }
    if ! "$SB_BIN" check -c "$tmp" 2>/tmp/sb_client_check.err; then
        err "客户端配置校验失败:"
        cat /tmp/sb_client_check.err
        rm -f "$tmp"
        return 1
    fi
    mv -f "$tmp" "$SB_CLIENT_CONF"
    chmod 600 "$SB_CLIENT_CONF"
}

restart_client() {
    # 确保 systemd 服务单元存在（首次添加出口时可能尚未创建）
    [[ -f "$SB_CLIENT_SERVICE" ]] || setup_client_service
    systemctl enable sing-box-client >/dev/null 2>&1
    systemctl restart sing-box-client
    sleep 1
    if systemctl is-active --quiet sing-box-client; then
        ok "客户端代理已启动"
        return 0
    fi
    err "客户端启动失败:"
    journalctl -u sing-box-client -n 10 --no-pager | tail -n 10
    return 1
}

# 修改客户端元信息 → 重建 → 重启；失败恢复原状（含服务原本的运行状态）
# 用法：client_commit [jq 参数...] '<过滤器>'
client_commit() {
    local bak="${SB_CLIENT_META}.bak" was_active=0
    systemctl is-active --quiet sing-box-client 2>/dev/null && was_active=1
    cp -f "$SB_CLIENT_META" "$bak" || return 1
    json_edit "$SB_CLIENT_META" "$@" || { rm -f "$bak"; return 1; }
    if rebuild_client_config && restart_client; then
        rm -f "$bak"
        return 0
    fi
    err "重载失败，已撤销本次更改"
    mv -f "$bak" "$SB_CLIENT_META"
    rebuild_client_config
    if (( was_active )); then
        restart_client >/dev/null 2>&1
    else
        systemctl stop sing-box-client >/dev/null 2>&1
    fi
    return 1
}

# ---- 分协议录入(输出含 proto 的 node json，不含 tag) ----
client_node_vless() {
    local node_json="" link="" src
    echo "  录入方式:" >&2
    echo "    1) 粘贴 vless:// 链接" >&2
    echo "    2) 手动逐项填写" >&2
    echo "    0) 返回" >&2
    read -rp "$(echo -e "${CYAN}请选择: ${NC}")" src
    case "$src" in
        1)
            read -rp "$(echo -e "${CYAN}粘贴 vless:// 链接: ${NC}")" link
            node_json=$(parse_vless_link "$link")
            ;;
        2)
            local sp uuid sni pbk sid flow fp
            sp=$(ask_server_port) || return 1
            read -rp "$(echo -e "${CYAN}UUID: ${NC}")" uuid
            read -rp "$(echo -e "${CYAN}SNI (server_name): ${NC}")" sni
            read -rp "$(echo -e "${CYAN}public_key (pbk): ${NC}")" pbk
            read -rp "$(echo -e "${CYAN}short_id (sid, 可空): ${NC}")" sid
            read -rp "$(echo -e "${CYAN}flow (一般 xtls-rprx-vision, 可空): ${NC}")" flow
            read -rp "$(echo -e "${CYAN}指纹 fp [默认 chrome]: ${NC}")" fp
            node_json=$(jq -n --arg server "${sp%|*}" --argjson port "${sp#*|}" --arg uuid "$uuid" \
                --arg sni "$sni" --arg pbk "$pbk" --arg sid "$sid" --arg flow "$flow" --arg fp "${fp:-chrome}" \
                '{server:$server, port:$port, uuid:$uuid, sni:$sni, pbk:$pbk, sid:$sid, flow:$flow, fp:$fp}')
            ;;
        *) return 1 ;;
    esac
    [[ -n "$node_json" ]] || { err "不是有效的 vless 链接" >&2; return 1; }
    jq -e '(.pbk // "") != ""' <<<"$node_json" >/dev/null || { err "缺少 public_key(pbk)" >&2; return 1; }
    jq '. + {proto:"vless-reality"}' <<<"$node_json"
}

client_node_ss() {
    local is2022="$1" sp method pwd
    sp=$(ask_server_port) || return 1
    method=$(pick_ss_method "$([[ "$is2022" == "1" ]] && echo 2022 || echo legacy)") || return 1
    pwd=$(ask_required "密码 (password / SS2022 base64 密钥)") || return 1
    jq -n --arg server "${sp%|*}" --argjson port "${sp#*|}" --arg method "$method" --arg password "$pwd" \
        --arg proto "$([[ "$is2022" == "1" ]] && echo ss2022 || echo ss)" \
        '{proto:$proto, server:$server, port:$port, method:$method, password:$password}'
}

client_node_anytls() {
    local sp pwd sni insec
    sp=$(ask_server_port) && pwd=$(ask_required "密码 (password)") || return 1
    read -rp "$(echo -e "${CYAN}SNI (server_name): ${NC}")" sni
    insec=$(ask_insecure)
    jq -n --arg server "${sp%|*}" --argjson port "${sp#*|}" \
        --arg password "$pwd" --arg sni "$sni" --argjson insecure "$insec" \
        '{proto:"anytls", server:$server, port:$port, password:$password, sni:$sni, insecure:$insecure}'
}

# ---- 出口管理 ----
client_outbound_add() {
    clear; show_banner
    sec "出口管理 → 添加落地出口"
    echo "  协议:"
    echo "    1) Shadowsocks (老版)"
    echo "    2) Shadowsocks 2022"
    echo "    3) VLESS + Reality"
    echo "    4) AnyTLS"
    echo "    0) 返回"
    hr
    local pc node="" tag
    read -rp "$(echo -e "${CYAN}请选择 [0-4]: ${NC}")" pc
    echo
    case "$pc" in
        1) node=$(client_node_ss 0) ;;
        2) node=$(client_node_ss 1) ;;
        3) node=$(client_node_vless) ;;
        4) node=$(client_node_anytls) ;;
        0|"") return ;;
        *) err "无效选择"; pause; return ;;
    esac
    [[ -z "$node" ]] && { pause; return; }

    while :; do
        read -rp "$(echo -e "${CYAN}给这个出口起个名字(tag,如 out-cc): ${NC}")" tag
        tag="${tag// /}"
        [[ -z "$tag" ]] && { err "不能为空"; continue; }
        [[ "$tag" == "direct" || "$tag" == "block" ]] && { err "tag 不能用保留字 direct/block"; continue; }
        jq -e --arg t "$tag" '.outbounds[] | select(.tag == $t)' "$SB_CLIENT_META" >/dev/null 2>&1 \
            && { err "tag 已存在"; continue; }
        break
    done

    client_commit --argjson node "$node" --arg tag "$tag" '.outbounds += [($node + {tag:$tag})]' \
        && ok "出口 ${tag} 已添加"
    pause
}

client_outbound_list_inline() {
    local n; n=$(jq '.outbounds|length' "$SB_CLIENT_META")
    if (( n==0 )); then
        echo -e "    ${CYAN}(无)${NC}"
        return
    fi
    jq -r '.outbounds[] | "  \(.tag)\t[\(.proto)]\t\(.server):\(.port)"' "$SB_CLIENT_META" \
        | nl -w3 -s'. ' | sed 's/^/  /'
}

client_outbound_del() {
    clear; show_banner
    sec "出口管理 → 删除出口"
    local n; n=$(jq '.outbounds|length' "$SB_CLIENT_META")
    (( n==0 )) && { warn "没有出口"; pause; return; }
    client_outbound_list_inline
    hr
    local idx; read -rp "$(echo -e "${CYAN}输入要删除的编号: ${NC}")" idx
    [[ "$idx" =~ ^[0-9]+$ ]] && (( idx>=1 && idx<=n )) || { err "无效编号"; pause; return; }
    local tag; tag=$(jq -r ".outbounds[$((idx-1))].tag" "$SB_CLIENT_META")
    # 检查是否被规则或 final 引用
    if jq -e --arg t "$tag" '.rules[]|select(.outbound==$t)' "$SB_CLIENT_META" >/dev/null 2>&1; then
        warn "出口 ${tag} 仍被分流规则引用，请先删除相关规则"; pause; return
    fi
    if [[ "$(jq -r '.final' "$SB_CLIENT_META")" == "$tag" ]]; then
        warn "出口 ${tag} 是当前默认出口(final)，请先改默认出口"; pause; return
    fi
    if [[ "$(jq -r '.download_detour // "direct"' "$SB_CLIENT_META")" == "$tag" ]]; then
        warn "出口 ${tag} 是 geosite 下载出口，请先在客户端设置里改掉"; pause; return
    fi
    client_commit --argjson i "$((idx-1))" 'del(.outbounds[$i])' && ok "已删除 ${tag}"
    pause
}

menu_client_outbounds() {
    while :; do
        clear; show_banner
        sec "出口管理 (落地节点)"
        echo -e "  当前出口:"
        client_outbound_list_inline
        hr
        echo "  1. 添加出口"
        echo "  2. 删除出口"
        echo "  0. 返回"
        hr
        local c; read -rp "$(echo -e "${CYAN}请选择: ${NC}")" c
        case "$c" in
            1) client_outbound_add ;;
            2) client_outbound_del ;;
            0|"") return ;;
            *) err "无效"; sleep 1 ;;
        esac
    done
}

# ---- 分流规则管理 ----
client_rule_list_inline() {
    local n; n=$(jq '.rules|length' "$SB_CLIENT_META")
    if (( n==0 )); then
        echo -e "    ${CYAN}(无规则,全部走 final)${NC}"
        return
    fi
    local i=0
    while IFS=$'\t' read -r match out; do
        i=$((i+1))
        printf "  %d. %s -> %s\n" "$i" "$match" "$out" | sed 's/^/  /'
    done < <(jq -r '.rules[] |
        ([ (.geosite[]? | "geosite:\(.)"), (.domain[]?) ] | join(",")) as $m |
        [$m, .outbound] | @tsv' "$SB_CLIENT_META")
}

client_rule_add() {
    clear; show_banner
    sec "分流规则 → 添加规则"
    local on input match t pick i=0
    on=$(jq '.outbounds|length' "$SB_CLIENT_META")
    (( on==0 )) && { warn "请先在「出口管理」添加至少一个出口"; pause; return; }

    read -rp "$(echo -e "${CYAN}目标域名(多个逗号分隔,支持 geosite:xxx): ${NC}")" input
    [[ -z "$input" ]] && return
    match=$(parse_rule_input "$input")
    jq -e '(.geosite + .domain) | length > 0' <<<"$match" >/dev/null || { err "无有效规则"; pause; return; }

    echo
    echo -e "  ${CYAN}这些流量走哪个出口?${NC}"
    local tags=()
    while IFS= read -r t; do
        i=$((i+1)); echo "    $i) $t"; tags+=("$t")
    done < <(jq -r '.outbounds[].tag' "$SB_CLIENT_META")
    hr
    read -rp "$(echo -e "${CYAN}选择出口编号: ${NC}")" pick
    [[ "$pick" =~ ^[0-9]+$ ]] && (( pick>=1 && pick<=i )) || { err "无效"; pause; return; }
    local out="${tags[$((pick-1))]}"

    client_commit --argjson m "$match" --arg out "$out" '.rules += [$m + {outbound:$out}]' \
        && ok "规则已添加 -> ${out}"
    pause
}

client_rule_del() {
    clear; show_banner
    sec "分流规则 → 删除规则"
    local n idx
    n=$(jq '.rules|length' "$SB_CLIENT_META")
    (( n==0 )) && { warn "没有规则"; pause; return; }
    client_rule_list_inline
    hr
    read -rp "$(echo -e "${CYAN}输入要删除的编号: ${NC}")" idx
    [[ "$idx" =~ ^[0-9]+$ ]] && (( idx>=1 && idx<=n )) || { err "无效编号"; pause; return; }
    client_commit --argjson i "$((idx-1))" 'del(.rules[$i])' && ok "已删除规则"
    pause
}

menu_client_rules() {
    while :; do
        clear; show_banner
        sec "分流规则管理 (域名/geosite -> 出口)"
        echo -e "  当前规则:"
        client_rule_list_inline
        echo
        echo -e "  ${YELLOW}未匹配的流量走 final(默认出口): ${CYAN}$(jq -r '.final' "$SB_CLIENT_META")${NC}"
        hr
        echo "  1. 添加规则"
        echo "  2. 删除规则"
        echo "  0. 返回"
        hr
        local c; read -rp "$(echo -e "${CYAN}请选择: ${NC}")" c
        case "$c" in
            1) client_rule_add ;;
            2) client_rule_del ;;
            0|"") return ;;
            *) err "无效"; sleep 1 ;;
        esac
    done
}

# ---- 端口 / 默认出口 / 下载detour 设置 ----
menu_client_settings() {
    while :; do
        clear; show_banner
        sec "客户端设置 (端口 / 默认出口)"
        local sport final dl
        sport=$(jq -r '.socks_port' "$SB_CLIENT_META")
        final=$(jq -r '.final' "$SB_CLIENT_META")
        dl=$(jq -r '.download_detour // "direct"' "$SB_CLIENT_META")
        echo -e "  本地 SOCKS 端口:   ${CYAN}${sport}${NC}"
        echo -e "  默认出口(final):   ${CYAN}${final}${NC}   ${YELLOW}(direct=本机直连)${NC}"
        echo -e "  geosite下载走:     ${CYAN}${dl}${NC}"
        hr
        echo "  1. 改本地 SOCKS 端口"
        echo "  2. 改默认出口 (final)"
        echo "  3. 改 geosite 下载出口"
        echo "  0. 返回"
        hr
        local c; read -rp "$(echo -e "${CYAN}请选择: ${NC}")" c
        case "$c" in
            1)
                local p; read -rp "$(echo -e "${CYAN}新端口 [1024-65535]: ${NC}")" p
                [[ "$p" =~ ^[0-9]+$ ]] && (( p>=1024 && p<=65535 )) || { err "非法"; sleep 1; continue; }
                if [[ "$p" != "$sport" ]] && port_in_use "$p"; then err "端口 ${p} 已被占用"; sleep 1; continue; fi
                client_commit --argjson p "$p" '.socks_port = $p' && ok "端口已改为 ${p}"
                pause ;;
            2|3)
                local field label
                if [[ "$c" == "2" ]]; then field="final"; label="默认出口"; else field="download_detour"; label="geosite下载出口"; fi
                echo
                echo "    0) direct (本机直连)"
                local tags=() i=0
                while IFS= read -r t; do
                    i=$((i+1)); echo "    $i) $t"; tags+=("$t")
                done < <(jq -r '.outbounds[].tag' "$SB_CLIENT_META")
                local pick; read -rp "$(echo -e "${CYAN}选 ${label} 编号(0=direct): ${NC}")" pick
                local val
                if [[ "$pick" == "0" ]]; then
                    val="direct"
                elif [[ "$pick" =~ ^[0-9]+$ ]] && (( pick>=1 && pick<=i )); then
                    val="${tags[$((pick-1))]}"
                else
                    err "无效"; sleep 1; continue
                fi
                client_commit --arg f "$field" --arg v "$val" '.[$f] = $v' && ok "${label} 已设为 ${val}"
                pause ;;
            0|"") return ;;
            *) err "无效"; sleep 1 ;;
        esac
    done
}

# ---- cc 快捷命令 ----
write_cc_alias() {
    clear; show_banner
    sec "写入 shell 快捷命令 (cc)"
    local sport; sport=$(jq -r '.socks_port' "$SB_CLIENT_META")
    local home_dir rc
    home_dir=$(eval echo "~${SUDO_USER:-root}")
    [[ -d "$home_dir" ]] || home_dir="$HOME"
    rc="${home_dir}/.bashrc"
    [[ -f "$rc" ]] || touch "$rc"
    sed -i '/# >>> sb claude-code proxy >>>/,/# <<< sb claude-code proxy <<</d' "$rc"
    cat >> "$rc" <<EOF
# >>> sb claude-code proxy >>>
# 敲 cc 即带代理跑 Claude Code（端口由 sb 脚本自动维护，请勿手改）
# 注意：Claude Code 不支持 socks5 代理，必须用 http 代理；
# 客户端入口是 mixed 类型，同一端口同时支持 socks5 和 http。
cc() {
    HTTPS_PROXY=http://127.0.0.1:${sport} \\
    HTTP_PROXY=http://127.0.0.1:${sport} \\
    ALL_PROXY= \\
    claude "\$@"
}
# 通用：cx <命令> 让任意命令走本地代理(如 cx codex / cx curl ...)
cx() {
    HTTPS_PROXY=http://127.0.0.1:${sport} \\
    HTTP_PROXY=http://127.0.0.1:${sport} \\
    ALL_PROXY=socks5h://127.0.0.1:${sport} \\
    "\$@"
}
# <<< sb claude-code proxy <<<
EOF
    ok "已写入 ${rc}"
    echo
    # 说明：sb 是子进程，无法替你正在用的终端 source（这是 shell 的限制，
    # 任何脚本都做不到）。下面这条命令让“当前已开着的终端”立即生效。
    echo -e "  ${YELLOW}▶ 让当前终端立即生效，复制执行这一条：${NC}"
    echo
    echo -e "      ${BOLD}${CYAN}source ${rc}${NC}"
    echo
    echo -e "  ${YELLOW}（只需一次。以后新开终端 / 重新 SSH 登录会自动生效，无需再做）${NC}"
    echo
    echo -e "  生效后用法: ${GREEN}cc${NC} 跑 Claude Code   ${GREEN}cx codex${NC} 让 codex 走代理"
    echo -e "  ${YELLOW}（若敲 cc 提示 command not found，就是还没执行上面那条 source）${NC}"
    pause
}

# ---- 连通性测试:逐个出口测出口IP ----
client_test() {
    clear; show_banner
    sec "客户端代理 → 连通性测试"
    local sport; sport=$(jq -r '.socks_port' "$SB_CLIENT_META")
    if ! systemctl is-active --quiet sing-box-client; then
        warn "客户端服务未运行，先启动"; systemctl start sing-box-client; sleep 1
    fi
    echo -e "  本机直连出口 IP (final=direct 时未匹配流量走这里):"
    echo -e "    ${YELLOW}$(curl -fsSL -m 8 https://api.ipify.org 2>/dev/null || echo 获取失败)${NC}"
    echo
    echo -e "  本地入口 ${CYAN}127.0.0.1:${sport}${NC} (mixed: socks5+http) 出口 IP:"
    echo -e "    socks5: ${GREEN}$(curl -fsSL -m 12 -x socks5://127.0.0.1:${sport} https://api.ipify.org 2>/dev/null || echo 获取失败)${NC}"
    echo -e "    http:   ${GREEN}$(curl -fsSL -m 12 -x http://127.0.0.1:${sport} https://api.ipify.org 2>/dev/null || echo 获取失败)${NC}"
    echo -e "    ${YELLOW}(注: ipify 不在分流规则里，默认走 final，IP 可能是本机直连)${NC}"
    hr
    echo -e "  ★ Claude API 可达性 (经本地 http 入口；走哪个出口取决于你的分流规则):"
    local code
    code=$(curl -sSL -m 12 -o /dev/null -w '%{http_code}' -x http://127.0.0.1:${sport} https://api.anthropic.com 2>/dev/null)
    [[ "$code" =~ ^[0-9]{3}$ ]] || code=000
    if [[ "$code" =~ ^(200|401|403|404|405)$ ]]; then
        echo -e "    ${GREEN}可达 (HTTP ${code}) —— Claude Code 能用${NC}"
    else
        echo -e "    ${RED}不可达 (HTTP ${code}) —— 检查落地/规则${NC}"
    fi
    pause
}

menu_client() {
    client_meta_init
    while :; do
        clear; show_banner
        sec "客户端代理模式 (本地 SOCKS 出口 + 多落地分流)"
        local running="${RED}未运行${NC}"
        systemctl is-active --quiet sing-box-client && running="${GREEN}运行中${NC}"
        local sport final on rn
        sport=$(jq -r '.socks_port' "$SB_CLIENT_META")
        final=$(jq -r '.final' "$SB_CLIENT_META")
        on=$(jq '.outbounds|length' "$SB_CLIENT_META")
        rn=$(jq '.rules|length' "$SB_CLIENT_META")
        echo -e "  服务: ${running}    本地SOCKS: ${CYAN}127.0.0.1:${sport}${NC}"
        echo -e "  出口数: ${CYAN}${on}${NC}   规则数: ${CYAN}${rn}${NC}   默认(final): ${CYAN}${final}${NC}"
        hr
        echo "  1. 出口管理 (增删落地节点)"
        echo
        echo "  2. 分流规则管理 (域名/geosite -> 出口)"
        echo
        echo "  3. 客户端设置 (本地端口 / 默认出口 final)"
        echo
        echo "  4. 连通性测试 (看出口 IP)"
        echo
        echo "  5. 写入 shell 快捷命令 cc / cx"
        echo
        echo "  6. 启动   7. 停止   8. 重启"
        echo
        echo "  9. 查看最近日志"
        echo
        echo "  d. 删除全部客户端配置"
        echo
        echo "  0. 返回上一页"
        hr
        local c; read -rp "$(echo -e "${CYAN}请选择: ${NC}")" c
        case "$c" in
            1) menu_client_outbounds ;;
            2) menu_client_rules ;;
            3) menu_client_settings ;;
            4) client_test ;;
            5) write_cc_alias ;;
            6) setup_client_service; rebuild_client_config && restart_client; pause ;;
            7) systemctl stop sing-box-client && ok "已停止"; sleep 1 ;;
            8) restart_client; pause ;;
            9) clear
               if [[ -s "$SB_CLIENT_LOG" ]]; then tail -n 50 "$SB_CLIENT_LOG"; else journalctl -u sing-box-client -n 50 --no-pager; fi
               pause ;;
            d|D) read -rp "$(echo -e "${YELLOW}确定删除全部客户端配置? [y/N]: ${NC}")" y
               if [[ "$y" =~ ^[Yy]$ ]]; then
                   systemctl stop sing-box-client 2>/dev/null
                   systemctl disable sing-box-client 2>/dev/null
                   rm -f "$SB_CLIENT_SERVICE" "$SB_CLIENT_CONF" "$SB_CLIENT_META" "$SB_CLIENT_LOG"
                   systemctl daemon-reload
                   local hd; hd=$(eval echo "~${SUDO_USER:-root}")
                   [[ -d "$hd" ]] || hd="$HOME"
                   [[ -f "${hd}/.bashrc" ]] && sed -i '/# >>> sb claude-code proxy >>>/,/# <<< sb claude-code proxy <<</d' "${hd}/.bashrc"
                   ok "已删除"
               fi
               sleep 1 ;;
            0|"") return ;;
            *) err "无效选择"; sleep 1 ;;
        esac
    done
}
# =============================================================================
# Cloudflare DDNS
#
# 结构
#   引擎  ${CF_DDNS_BIN}
#         独立的 bash 脚本（由下面的 ddns_write_engine 生成），是唯一调用
#         Cloudflare API 的地方。systemd 定时器调用它做同步，本菜单也调用它
#         做 Zone 识别 / 状态检查 / 删除记录。它不依赖 sb，因此卸载 sb 时
#         选择保留 DDNS，DDNS 仍会继续工作。
#   配置  ${CF_DDNS_CONF} (600)
#         {"version":2, "api_token":"...", "records":[
#            {"hostname":"kr4.example.com","type":"A",
#             "zone_id":"...","zone_name":"example.com","proxied":false}]}
#         一条记录 = (hostname, type)；Zone 由域名自动识别；proxied 逐条设置。
# =============================================================================

# ---- 文件部署 ---------------------------------------------------------------

# 内容从 stdin 读入，仅当与现有文件不同时才写入。返回 0=已写入 / 1=无变化
ddns_put() {
    local target="$1" mode="$2" tmp
    tmp=$(mktemp) || return 1
    cat > "$tmp"
    if cmp -s "$tmp" "$target" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
    install -D -m "$mode" "$tmp" "$target"
    rm -f "$tmp"
}

ddns_write_engine() {
    ddns_put "$CF_DDNS_BIN" 700 <<'SB_DDNS_ENGINE'
#!/usr/bin/env bash
# sb-cloudflare-ddns —— 由 sb 脚本生成，手动修改会在下次启动 sb 时被覆盖。
# 用法: sb-cloudflare-ddns [-v] [update | check | zone <域名> | purge <类型> <域名> <zone_id>]
#   update  把本机公网 IP 同步到配置中的所有记录（默认；无变化时不输出，-v 则输出）
#   check   只读对比：本机公网 IP 与 Cloudflare 当前记录
#   zone    查找域名所属的 Zone，输出 "zone_id<TAB>zone_name"
#   purge   删除 Cloudflare 上的一条记录
# 环境变量: CF_API_TOKEN 优先于配置文件里的 Token
set -o pipefail

CONF="/etc/sb-cloudflare-ddns/config.json"
API="${CF_API_BASE:-https://api.cloudflare.com/client/v4}"
read -ra IP_URLS <<<"${DDNS_IP_URLS:-https://www.cloudflare.com/cdn-cgi/trace https://api64.ipify.org https://icanhazip.com}"

VERBOSE=0
[[ "$1" == "-v" ]] && { VERBOSE=1; shift; }
CMD="${1:-update}"
(( $# > 0 )) && shift

log()  { printf '%s\n' "$*"; }
note() { (( VERBOSE )) && printf '%s\n' "$*"; return 0; }
warn() { printf '%s\n' "$*" >&2; }
die()  { warn "错误: $*"; exit 1; }

command -v curl >/dev/null 2>&1 || die "缺少 curl"
command -v jq   >/dev/null 2>&1 || die "缺少 jq"

TOKEN=""
load_token() {
    TOKEN="${CF_API_TOKEN:-}"
    if [[ -z "$TOKEN" ]]; then
        [[ -r "$CONF" ]] || die "配置文件不存在: ${CONF}"
        TOKEN=$(jq -er '.api_token' "$CONF") || die "配置中缺少 api_token"
    fi
}

# cf METHOD PATH [JSON]  成功时把响应体写到 stdout
cf() {
    local method="$1" path="$2" data="${3:-}" body code
    local -a opts=(-sS --connect-timeout 10 --max-time 30 -X "$method" -H 'Content-Type: application/json')
    [[ -n "$data" ]] && opts+=(--data "$data")
    body=$(mktemp) || return 1
    # Token 经 -K + 进程替换传入，不会出现在 ps 的命令行里
    code=$(curl "${opts[@]}" -o "$body" -w '%{http_code}' \
        -K <(printf 'header = "Authorization: Bearer %s"\n' "$TOKEN") \
        "${API}${path}") || { warn "无法连接 Cloudflare API"; rm -f "$body"; return 1; }
    if [[ "$code" != 2* ]] || ! jq -e '.success == true' "$body" >/dev/null 2>&1; then
        case "$code" in
            401|403) warn "Cloudflare 拒绝访问 (HTTP ${code})：Token 无效，或缺少 Zone:Read / DNS:Edit 权限" ;;
            429)     warn "Cloudflare API 触发限流 (HTTP 429)，稍后重试" ;;
            *)       warn "Cloudflare API 请求失败 (HTTP ${code})" ;;
        esac
        jq -r '.errors[]? | "  [\(.code)] \(.message)"' "$body" >&2 2>/dev/null
        rm -f "$body"
        return 1
    fi
    cat "$body"
    rm -f "$body"
}

# ---- 本机公网 IP -------------------------------------------------------------
valid_ip() {   # valid_ip 4|6 ADDR
    local ip="$2" o
    if [[ "$1" == 4 ]]; then
        [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
        for o in "${BASH_REMATCH[@]:1}"; do
            (( 10#$o <= 255 )) || return 1
        done
    else
        [[ "$ip" == *:* && "$ip" =~ ^[0-9a-fA-F:]+$ ]]
    fi
}

detect_ip() {   # detect_ip 4|6
    local fam="$1" url out ip
    for url in "${IP_URLS[@]}"; do
        out=$(curl -fsS "-${fam}" --connect-timeout 5 --max-time 10 "$url" 2>/dev/null) || continue
        ip=$(sed -n 's/^ip=//p' <<<"$out" | head -n1)      # cloudflare trace 格式
        [[ -n "$ip" ]] || ip=$(head -n1 <<<"$out")         # 纯文本格式
        ip="${ip//[[:space:]]/}"
        if valid_ip "$fam" "$ip"; then
            printf '%s' "$ip"
            return 0
        fi
    done
    return 1
}

# ---- 配置读取 ----------------------------------------------------------------
records() { jq -r '.records[]? | [.type, .hostname, .zone_id, (.proxied // false)] | @tsv' "$CONF"; }
has_type() { jq -e --arg t "$1" '.records[]? | select(.type == $t)' "$CONF" >/dev/null 2>&1; }

# 每种记录类型只探测一次本机 IP
declare -A IPS=()
detect_all() {
    local t fam
    for t in A AAAA; do
        has_type "$t" || continue
        fam=4; [[ "$t" == AAAA ]] && fam=6
        IPS[$t]=$(detect_ip "$fam") || warn "! 无法获取本机公网 IPv${fam} 地址 (${t} 记录将被跳过)"
    done
}

# ---- 子命令 ------------------------------------------------------------------
sync_record() {   # sync_record TYPE HOST ZONE_ID PROXIED IP
    local type="$1" host="$2" zone="$3" proxied="$4" ip="$5" resp n id cur cur_px payload
    if [[ -z "$ip" ]]; then
        warn "✗ ${host} (${type}) 没有可用的本机地址，已跳过"
        return 1
    fi
    resp=$(cf GET "/zones/${zone}/dns_records?type=${type}&name=${host}") || return 1
    n=$(jq '.result | length' <<<"$resp")

    if (( n == 0 )); then
        payload=$(jq -nc --arg t "$type" --arg n "$host" --arg c "$ip" --argjson p "$proxied" \
            '{type:$t, name:$n, content:$c, ttl:1, proxied:$p, comment:"managed by sb"}')
        cf POST "/zones/${zone}/dns_records" "$payload" >/dev/null || return 1
        log "+ ${host} (${type}) 已创建 -> ${ip}"
        return 0
    fi

    (( n > 1 )) && warn "! ${host} (${type}) 存在 ${n} 条同名记录，仅维护第一条"
    id=$(jq -r '.result[0].id' <<<"$resp")
    cur=$(jq -r '.result[0].content' <<<"$resp")
    cur_px=$(jq -r '.result[0].proxied // false' <<<"$resp")
    if [[ "${cur,,}" == "${ip,,}" && "$cur_px" == "$proxied" ]]; then
        note "= ${host} (${type}) ${ip} 无变化"
        return 0
    fi
    payload=$(jq -nc --arg c "$ip" --argjson p "$proxied" '{content:$c, proxied:$p}')
    cf PATCH "/zones/${zone}/dns_records/${id}" "$payload" >/dev/null || return 1
    log "~ ${host} (${type}) ${cur} -> ${ip}"
    [[ "${cur,,}" != "${ip,,}" ]] && CHANGED[$type]="${cur} -> ${ip}"
    return 0
}

# IP 变更时发 Telegram 通知（配置了 tg_bot_token / tg_chat_id 才发）
declare -A CHANGED=()
notify_ip_change() {
    (( ${#CHANGED[@]} )) || return 0
    local bot chat text t
    bot=$(jq -r '.tg_bot_token // empty' "$CONF")
    chat=$(jq -r '.tg_chat_id // empty' "$CONF")
    [[ -n "$bot" && -n "$chat" ]] || return 0
    text="IP 变更 [$(hostname)]"
    for t in A AAAA; do
        [[ -n "${CHANGED[$t]:-}" ]] && text+=$'\n'"${t}: ${CHANGED[$t]}"
    done
    curl -fsS --connect-timeout 10 --max-time 20 -o /dev/null \
        -K <(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$bot") \
        --data-urlencode "chat_id=${chat}" --data-urlencode "text=${text}" \
        || warn "Telegram 通知发送失败"
}

cmd_update() {
    [[ -r "$CONF" ]] || die "配置文件不存在: ${CONF}"
    load_token
    # 与定时器 / 手动执行互斥（锁在引擎脚本自身上）
    exec 9<"$0" && flock -w 120 9 || die "等待更新锁超时"
    detect_all
    local type host zone proxied status=0
    while IFS=$'\t' read -r type host zone proxied; do
        sync_record "$type" "$host" "$zone" "$proxied" "${IPS[$type]:-}" || status=1
    done < <(records)
    notify_ip_change
    exit "$status"
}

cmd_check() {
    [[ -r "$CONF" ]] || die "配置文件不存在: ${CONF}"
    load_token
    detect_all
    local type host zone proxied ip resp cur mode
    while IFS=$'\t' read -r type host zone proxied; do
        ip="${IPS[$type]:-}"
        mode="仅 DNS"; [[ "$proxied" == "true" ]] && mode="代理"
        if ! resp=$(cf GET "/zones/${zone}/dns_records?type=${type}&name=${host}"); then
            printf '  ? %-30s %-5s 查询失败\n' "$host" "$type"
            continue
        fi
        cur=$(jq -r '.result[0].content // empty' <<<"$resp")
        if [[ -z "$cur" ]]; then
            printf '  ✗ %-30s %-5s Cloudflare 上不存在，等待下次同步创建\n' "$host" "$type"
        elif [[ -z "$ip" ]]; then
            printf '  ? %-30s %-5s Cloudflare: %s（本机地址检测失败）\n' "$host" "$type" "$cur"
        elif [[ "${cur,,}" == "${ip,,}" ]]; then
            printf '  ✓ %-30s %-5s %s（%s）\n' "$host" "$type" "$ip" "$mode"
        else
            printf '  ✗ %-30s %-5s Cloudflare: %s ≠ 本机: %s\n' "$host" "$type" "$cur" "$ip"
        fi
    done < <(records)
    exit 0
}

# 从完整域名向上逐级尝试，最长匹配优先（正确处理 example.co.uk 这类多级后缀）
cmd_zone() {
    local host="${1,,}" cand resp id
    [[ -n "$host" ]] || die "用法: zone <域名>"
    load_token
    cand="$host"
    while [[ "$cand" == *.* ]]; do
        resp=$(cf GET "/zones?name=${cand}&status=active&per_page=1") || exit 1
        id=$(jq -r '.result[0].id // empty' <<<"$resp")
        if [[ -n "$id" ]]; then
            printf '%s\t%s\n' "$id" "$cand"
            exit 0
        fi
        cand="${cand#*.}"
    done
    warn "未找到 ${host} 所属的 Zone：请确认域名已托管在 Cloudflare，且 Token 有权访问该 Zone"
    exit 1
}

cmd_purge() {   # purge TYPE HOST ZONE_ID —— 只删第一条，与 update 的维护范围一致
    local type="$1" host="$2" zone="$3" resp id
    [[ -n "$type" && -n "$host" && -n "$zone" ]] || die "用法: purge <类型> <域名> <zone_id>"
    load_token
    resp=$(cf GET "/zones/${zone}/dns_records?type=${type}&name=${host}") || exit 1
    id=$(jq -r '.result[0].id // empty' <<<"$resp")
    if [[ -z "$id" ]]; then
        log "Cloudflare 上没有 ${host} (${type})，无需删除"
        exit 0
    fi
    cf DELETE "/zones/${zone}/dns_records/${id}" >/dev/null || exit 1
    log "已从 Cloudflare 删除 ${host} (${type})"
    exit 0
}

case "$CMD" in
    update) cmd_update ;;
    check)  cmd_check ;;
    zone)   cmd_zone "$@" ;;
    purge)  cmd_purge "$@" ;;
    *)      warn "用法: ${0##*/} [-v] [update | check | zone <域名> | purge <类型> <域名> <zone_id>]"; exit 2 ;;
esac
SB_DDNS_ENGINE
}

# systemd 单元。返回 0=有改动 / 1=无变化
ddns_write_units() {
    local rc=1
    ddns_put "$CF_DDNS_SERVICE" 644 <<EOF && rc=0
[Unit]
Description=Cloudflare DDNS updater (managed by sb)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=${CF_DDNS_BIN} update
TimeoutStartSec=180
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
EOF
    local min jitter acc
    min=$(ddns_interval)
    case "$min" in
        1) jitter=5s;  acc=5s  ;;
        2) jitter=10s; acc=5s  ;;
        *) jitter=20s; acc=10s ;;
    esac
    ddns_put "$CF_DDNS_TIMER" 644 <<EOF && rc=0
[Unit]
Description=Run Cloudflare DDNS updater every ${min} minute(s)

[Timer]
OnBootSec=30s
OnUnitActiveSec=${min}min
RandomizedDelaySec=${jitter}
AccuracySec=${acc}

[Install]
WantedBy=timers.target
EOF
    return $rc
}

# 部署引擎 + 单元并确保定时器在运行。幂等：内容没变就什么都不做。
ddns_deploy() {
    local reload=0
    install -d -m 700 "$CF_DDNS_DIR"
    ddns_write_engine
    ddns_write_units && reload=1
    if (( reload )); then
        systemctl daemon-reload
        systemctl try-restart sb-cloudflare-ddns.timer >/dev/null 2>&1 || true
    fi
    if ! systemctl is-enabled --quiet sb-cloudflare-ddns.timer 2>/dev/null \
       || ! systemctl is-active --quiet sb-cloudflare-ddns.timer 2>/dev/null; then
        systemctl enable --now sb-cloudflare-ddns.timer >/dev/null 2>&1 \
            || warn "DDNS 定时器启动失败，请检查: systemctl status sb-cloudflare-ddns.timer"
    fi
    return 0
}

ddns_remove() {
    systemctl disable --now sb-cloudflare-ddns.timer >/dev/null 2>&1 || true
    systemctl stop sb-cloudflare-ddns.service >/dev/null 2>&1 || true
    rm -f "$CF_DDNS_TIMER" "$CF_DDNS_SERVICE" "$CF_DDNS_BIN"
    rm -rf "$CF_DDNS_DIR"
    systemctl daemon-reload
    ok "Cloudflare DDNS 服务与本机配置（含 Token）已清除"
}

# ---- 配置读写 ----------------------------------------------------------------

ddns_count() { jq '(.records // []) | length' "$CF_DDNS_CONF" 2>/dev/null || echo 0; }
ddns_token() { jq -r '.api_token // empty' "$CF_DDNS_CONF"; }

# 同步间隔（分钟）：只允许 1 / 2 / 5，缺省或非法值按 5
ddns_interval() {
    local m
    m=$(jq -r '.interval_min // 5' "$CF_DDNS_CONF" 2>/dev/null)
    case "$m" in 1|2|5) echo "$m" ;; *) echo 5 ;; esac
}

# 原子改写配置：ddns_edit [jq 选项...] '过滤器'
ddns_edit() { json_edit "$CF_DDNS_CONF" "$@"; }

# 是否已存在 (域名, 类型) 这条记录
ddns_has() {
    jq -e --arg h "$1" --arg t "$2" \
        '.records[]? | select(.hostname == $h and .type == $t)' "$CF_DDNS_CONF" >/dev/null 2>&1
}

# 旧版配置 (无 version，含 hostname_v4/hostname_v6/全局 zone/全局 proxied 等) → v2。
# 旧文件备份为 config.json.v1.bak。
ddns_migrate_conf() {
    [[ -f "$CF_DDNS_CONF" ]] || return 0
    [[ "$(jq -r '.version // 1' "$CF_DDNS_CONF" 2>/dev/null)" == "2" ]] && return 0

    local tmp
    tmp=$(mktemp "${CF_DDNS_CONF}.XXXXXX") || return 1
    jq '
        . as $c
        | ($c.record_types // []) as $t
        | ($c.hostname // "") as $base
        | ($c.hostname_v4 // "") as $h4
        | ($c.hostname_v6 // "") as $h6
        | ($t | index("A") != null) as $hasA
        | ($t | index("AAAA") != null) as $hasAAAA
        | ($base | split(".")) as $p
        | (($p[0] // "") + "4." + ($p[1:] | join("."))) as $split4
        | (($p[0] // "") + "6." + ($p[1:] | join("."))) as $split6
        | (if (($c.records // []) | length) > 0
           then [ $c.records[] | {type: .type, hostname: .hostname} ]
           else [ (if $hasA
                   then {type: "A",
                         hostname: (if $h4 != "" then $h4 elif $hasAAAA then $split4 else $base end)}
                   else empty end),
                  (if $hasAAAA
                   then {type: "AAAA",
                         hostname: (if $h6 != "" then $h6 elif $hasA then $split6 else $base end)}
                   else empty end) ]
           end) as $old
        | {version: 2,
           api_token: $c.api_token,
           records: ($old
                     | map(select(.hostname != ""))
                     | map(. + {zone_id: $c.zone_id, zone_name: $c.zone_name, proxied: ($c.proxied // false)})
                     | unique_by([.hostname, .type]))}
    ' "$CF_DDNS_CONF" > "$tmp" || { rm -f "$tmp"; return 1; }

    cp -p "$CF_DDNS_CONF" "${CF_DDNS_CONF}.v1.bak" || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp" "${CF_DDNS_CONF}.v1.bak"
    mv -f "$tmp" "$CF_DDNS_CONF"
}

# 启动 sb 时调用：迁移旧配置，并保证引擎 / 单元是最新的（无变化则不动，也不触发同步）
ddns_bootstrap() {
    [[ -f "$CF_DDNS_CONF" ]] || return 0
    ddns_migrate_conf || { warn "DDNS 配置迁移失败，请检查 ${CF_DDNS_CONF}"; return 1; }
    ddns_deploy
}

# ---- 输入校验 ----------------------------------------------------------------

ddns_norm_host() {
    local h="${1,,}"
    h="${h//[[:space:]]/}"
    printf '%s' "${h%.}"
}

ddns_valid_host() {
    (( ${#1} <= 253 )) || return 1
    [[ "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

ddns_valid_token() { [[ "$1" =~ ^[A-Za-z0-9_-]{20,}$ ]]; }

# ---- 节点链接联动 ------------------------------------------------------------

# 使用某个域名的节点分享链接数量
ddns_link_count() {
    [[ -f "$SB_NODES" ]] || { echo 0; return; }
    jq --arg h "@$1:" '[.[] | select((.link // "") | contains($h))] | length' "$SB_NODES" 2>/dev/null || echo 0
}

# 把节点链接里的旧域名换成新域名
ddns_relink() {
    local old="$1" new="$2" n tmp ans
    n=$(ddns_link_count "$old")
    (( n > 0 )) || return 0
    read -rp "$(echo -e "${CYAN}有 ${n} 个节点的分享链接使用 ${old}，同步改为 ${new}? [Y/n]: ${NC}")" ans
    [[ "$ans" =~ ^[Nn]$ ]] && return 0
    tmp=$(mktemp) || return 1
    if jq --arg o "@${old}:" --arg n "@${new}:" \
        'map(if (.link // "") | contains($o) then .link |= (split($o) | join($n)) else . end)' \
        "$SB_NODES" > "$tmp"; then
        chmod --reference="$SB_NODES" "$tmp"
        mv -f "$tmp" "$SB_NODES"
        ok "已更新 ${n} 个节点的分享链接"
    else
        rm -f "$tmp"
        warn "节点链接更新失败，请手动修改"
    fi
}

# ---- 界面 --------------------------------------------------------------------

ddns_print_records() {
    local i=0 host type proxied mode
    while IFS=$'\t' read -r host type proxied; do
        i=$((i+1))
        mode="仅 DNS"; [[ "$proxied" == "true" ]] && mode="代理"
        printf "  %d) %-30s %-5s %s\n" "$i" "$host" "$type" "$mode"
    done < <(jq -r '.records[]? | [.hostname, .type, (.proxied // false)] | @tsv' "$CF_DDNS_CONF" 2>/dev/null)
}

# 列出记录并让用户选择；选中的 0 基下标写到 stdout（界面输出走 stderr）
ddns_pick() {
    local n c
    n=$(ddns_count)
    (( n > 0 )) || { err "尚未配置 DDNS 记录" >&2; return 1; }
    ddns_print_records >&2
    echo "  0) 返回上一页" >&2
    read -rp "$(echo -e "${CYAN}请选择 [0-${n}]: ${NC}")" c
    [[ -z "$c" || "$c" == "0" ]] && return 1
    [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= n )) || { err "无效选择" >&2; sleep 1; return 1; }
    echo $((c-1))
}

# 立即同步一次（直接运行引擎，-v 显示每条记录的结果）
ddns_run_now() {
    [[ -x "$CF_DDNS_BIN" ]] || { err "DDNS 引擎不存在"; return 1; }
    msg "正在同步..."
    if "$CF_DDNS_BIN" -v update; then
        ok "同步完成"
    else
        err "同步出现错误，详见上方输出"
        return 1
    fi
}

ddns_add() {
    clear; show_banner
    sec "新增 DDNS 记录"
    local fresh=0 token host type choice proxied=false ans zone_out zone_id zone_name

    if [[ -f "$CF_DDNS_CONF" ]]; then
        token=$(ddns_token)
    else
        fresh=1
        echo -e "  ${YELLOW}Token 需要权限: Zone / Zone / Read  +  Zone / DNS / Edit${NC}"
        echo -e "  ${YELLOW}Token 只保存在本机 ${CF_DDNS_CONF} (权限 600)${NC}"
        hr
        read -rsp "$(echo -e "${CYAN}Cloudflare API Token: ${NC}")" token
        echo
        ddns_valid_token "$token" || { err "Token 格式不正确"; pause; return; }
    fi

    read -rp "$(echo -e "${CYAN}DDNS 完整域名 (如 kr4.example.com): ${NC}")" host
    host=$(ddns_norm_host "$host")
    ddns_valid_host "$host" || { err "域名格式不正确"; pause; return; }

    echo "  1) IPv4 (A 记录)"
    echo "  2) IPv6 (AAAA 记录)"
    read -rp "$(echo -e "${CYAN}记录类型 [默认 1]: ${NC}")" choice
    case "${choice:-1}" in
        1) type="A" ;;
        2) type="AAAA" ;;
        *) err "无效选择"; pause; return ;;
    esac
    ddns_has "$host" "$type" && { err "已存在: ${host} (${type})"; pause; return; }

    read -rp "$(echo -e "${CYAN}启用 Cloudflare 代理(橙色云)? [y/N，节点请选 N]: ${NC}")" ans
    [[ "$ans" =~ ^[Yy]$ ]] && proxied=true

    ddns_write_engine    # 先放好引擎（下面的 Zone 识别要用它）
    msg "查找 ${host} 所属的 Zone..."
    zone_out=$(CF_API_TOKEN="$token" "$CF_DDNS_BIN" zone "$host") || { pause; return; }
    IFS=$'\t' read -r zone_id zone_name <<<"$zone_out"
    ok "Zone: ${zone_name}"

    if (( fresh )); then
        install -d -m 700 "$CF_DDNS_DIR"
        (umask 077; jq -n --arg t "$token" '{version:2, api_token:$t, records:[]}' > "$CF_DDNS_CONF") \
            || { err "写入 DDNS 配置失败"; pause; return; }
    fi
    if ! ddns_edit --arg h "$host" --arg t "$type" --arg zid "$zone_id" --arg z "$zone_name" --argjson p "$proxied" \
        '.records += [{hostname:$h, type:$t, zone_id:$zid, zone_name:$z, proxied:$p}]'; then
        (( fresh )) && rm -f "$CF_DDNS_CONF"
        pause; return
    fi
    token=""

    ddns_deploy
    ddns_run_now
    pause
}

ddns_rename() {   # ddns_rename IDX OLD_HOST TYPE OLD_ZONE
    local idx="$1" old="$2" type="$3" old_zone="$4" new zone_out zone_id zone_name ans purge=1
    read -rp "$(echo -e "${CYAN}新域名 [当前 ${old}]: ${NC}")" new
    new=$(ddns_norm_host "${new:-$old}")
    [[ "$new" == "$old" ]] && { warn "域名未改变"; return; }
    ddns_valid_host "$new" || { err "域名格式不正确"; return 1; }
    ddns_has "$new" "$type" && { err "已存在: ${new} (${type})"; return 1; }

    msg "查找 ${new} 所属的 Zone..."
    zone_out=$(CF_API_TOKEN="$(ddns_token)" "$CF_DDNS_BIN" zone "$new") || return 1
    IFS=$'\t' read -r zone_id zone_name <<<"$zone_out"

    read -rp "$(echo -e "${CYAN}同步成功后，删除 Cloudflare 上的旧记录 ${old}? [Y/n]: ${NC}")" ans
    [[ "$ans" =~ ^[Nn]$ ]] && purge=0

    ddns_edit --argjson i "$idx" --arg h "$new" --arg zid "$zone_id" --arg z "$zone_name" \
        '.records[$i] |= (.hostname = $h | .zone_id = $zid | .zone_name = $z)' || return 1
    # 先创建新记录，成功后才删旧记录，避免中途失败导致域名失效
    if ddns_run_now && (( purge )); then
        "$CF_DDNS_BIN" purge "$type" "$old" "$old_zone" || warn "旧记录未能删除，请到 Cloudflare 手动处理"
    fi
    ddns_relink "$old" "$new"
}

ddns_toggle_proxy() {   # ddns_toggle_proxy IDX CURRENT
    local idx="$1" cur="$2" new=true
    [[ "$cur" == "true" ]] && new=false
    if [[ "$new" == "true" ]]; then
        warn "开启代理后只有 HTTP(S) 流量会经 Cloudflare 转发，代理节点通常会因此无法连接"
    fi
    ddns_edit --argjson i "$idx" --argjson p "$new" '.records[$i].proxied = $p' || return 1
    ddns_run_now
}

ddns_edit_record() {
    (( $(ddns_count) > 0 )) || { err "尚未配置 DDNS 记录"; pause; return; }
    clear; show_banner
    sec "修改 DDNS 记录"
    local idx host type proxied zone c
    idx=$(ddns_pick) || return
    IFS=$'\t' read -r host type proxied zone < <(jq -r --argjson i "$idx" \
        '.records[$i] | [.hostname, .type, (.proxied // false), .zone_id] | @tsv' "$CF_DDNS_CONF")
    echo
    echo "  1) 修改域名"
    echo "  2) 切换代理状态 (橙色云)"
    echo "  0) 返回上一页"
    read -rp "$(echo -e "${CYAN}请选择 [0-2]: ${NC}")" c
    case "$c" in
        1) ddns_rename "$idx" "$host" "$type" "$zone" ;;
        2) ddns_toggle_proxy "$idx" "$proxied" ;;
        *) return ;;
    esac
    pause
}

ddns_delete_record() {
    (( $(ddns_count) > 0 )) || { err "尚未配置 DDNS 记录"; pause; return; }
    clear; show_banner
    sec "删除 DDNS 记录"
    local idx host type zone ans links
    idx=$(ddns_pick) || return
    IFS=$'\t' read -r host type zone < <(jq -r --argjson i "$idx" \
        '.records[$i] | [.hostname, .type, .zone_id] | @tsv' "$CF_DDNS_CONF")

    read -rp "$(echo -e "${YELLOW}删除 ${host} (${type})? [y/N]: ${NC}")" ans
    [[ "$ans" =~ ^[Yy]$ ]] || return
    links=$(ddns_link_count "$host")
    (( links > 0 )) && warn "有 ${links} 个节点的分享链接仍在使用 ${host}，删除后这些节点将无法解析"

    read -rp "$(echo -e "${CYAN}同时删除 Cloudflare 上的 DNS 记录? [Y/n]: ${NC}")" ans
    if [[ ! "$ans" =~ ^[Nn]$ ]]; then
        "$CF_DDNS_BIN" purge "$type" "$host" "$zone" \
            || { err "Cloudflare 记录删除失败，本地配置未改动"; pause; return; }
    fi
    ddns_edit --argjson i "$idx" 'del(.records[$i])' || { pause; return; }
    ok "已删除 ${host} (${type})"

    if (( $(ddns_count) == 0 )); then
        msg "已没有任何记录，自动卸载 DDNS 服务"
        ddns_remove
    fi
    pause
}

ddns_status() {
    clear; show_banner
    sec "DDNS 状态"
    if (( $(ddns_count) == 0 )); then
        warn "尚未配置 DDNS 记录"
        pause; return
    fi
    local active last result next
    active=$(systemctl is-active sb-cloudflare-ddns.timer 2>/dev/null)
    last=$(systemctl show sb-cloudflare-ddns.service -p ExecMainExitTimestamp --value 2>/dev/null)
    result=$(systemctl show sb-cloudflare-ddns.service -p Result --value 2>/dev/null)
    next=$(systemctl show sb-cloudflare-ddns.timer -p NextElapseUSecRealtime --value 2>/dev/null)
    echo -e "  定时器:   ${CYAN}${active:-未知}${NC}"
    echo -e "  上次同步: ${CYAN}${last:-—}${NC}  (结果: ${result:-—})"
    echo -e "  下次同步: ${CYAN}${next:-—}${NC}"
    echo
    echo -e "  ${BOLD}实时对比:${NC}"
    "$CF_DDNS_BIN" check
    echo
    echo -e "  ${BOLD}最近日志:${NC} ${YELLOW}(记录无变化时不写日志)${NC}"
    journalctl -u sb-cloudflare-ddns.service -n 10 --no-pager -o short-iso --no-hostname 2>/dev/null | sed 's/^/  /'
    pause
}

ddns_change_token() {
    (( $(ddns_count) > 0 )) || { err "尚未配置 DDNS 记录"; pause; return; }
    clear; show_banner
    sec "更换 API Token"
    local token host zid out
    read -rsp "$(echo -e "${CYAN}新的 Cloudflare API Token: ${NC}")" token
    echo
    ddns_valid_token "$token" || { err "Token 格式不正确"; pause; return; }

    msg "验证新 Token 能访问所有记录所在的 Zone..."
    while IFS=$'\t' read -r host zid; do
        out=$(CF_API_TOKEN="$token" "$CF_DDNS_BIN" zone "$host") \
            || { err "新 Token 无法访问 ${host} 所在的 Zone"; pause; return; }
        [[ "${out%%$'\t'*}" == "$zid" ]] \
            || { err "${host} 解析到的 Zone 与配置不一致，已取消"; pause; return; }
    done < <(jq -r '.records[] | [.hostname, .zone_id] | @tsv' "$CF_DDNS_CONF")

    ddns_edit --arg t "$token" '.api_token = $t' || { pause; return; }
    token=""
    ok "Token 已更换"
    ddns_run_now
    pause
}

ddns_sync_now() {
    (( $(ddns_count) > 0 )) || { err "尚未配置 DDNS 记录"; pause; return; }
    echo
    ddns_run_now
    pause
}

ddns_set_interval() {
    (( $(ddns_count) > 0 )) || { err "尚未配置 DDNS 记录"; pause; return; }
    clear; show_banner
    sec "同步间隔"
    local cur m c
    cur=$(ddns_interval)
    echo -e "  当前: ${CYAN}每 ${cur} 分钟${NC}"
    echo -e "  ${YELLOW}记录 TTL 为自动 (约 300 秒)，客户端最坏还要再等一个 TTL 才会拿到新 IP${NC}"
    hr
    echo "  1. 每 1 分钟"
    echo "  2. 每 2 分钟"
    echo "  3. 每 5 分钟 (默认)"
    echo "  0. 返回"
    hr
    read -rp "$(echo -e "${CYAN}请选择 [0-3]: ${NC}")" c
    case "$c" in
        1) m=1 ;; 2) m=2 ;; 3) m=5 ;;
        0|"") return ;;
        *) err "无效选择"; sleep 1; return ;;
    esac
    if [[ "$m" == "$cur" ]]; then
        ok "未变化"; sleep 1; return
    fi
    ddns_edit --argjson m "$m" '.interval_min = $m' || { pause; return; }
    ddns_deploy
    ok "已改为每 ${m} 分钟同步一次"
    sleep 1
}

ddns_set_tg() {
    (( $(ddns_count) > 0 )) || { err "尚未配置 DDNS 记录"; pause; return; }
    clear; show_banner
    sec "IP 变更通知 (Telegram)"
    local bot chat c
    chat=$(jq -r 'if (.tg_bot_token // "") != "" and (.tg_chat_id // "") != "" then .tg_chat_id else empty end' "$CF_DDNS_CONF")
    if [[ -n "$chat" ]]; then
        echo -e "  当前: ${GREEN}已开启${NC}  (Chat ID: ${chat})"
    else
        echo -e "  当前: ${YELLOW}未开启${NC}"
    fi
    hr
    echo "  1. 设置 / 修改"
    echo "  2. 清空 (关闭通知)"
    echo "  0. 返回"
    hr
    read -rp "$(echo -e "${CYAN}请选择 [0-2]: ${NC}")" c
    case "$c" in
        1)
            read -rsp "$(echo -e "${CYAN}Bot Token: ${NC}")" bot
            echo
            [[ "$bot" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || { err "Bot Token 格式不正确，未改动"; pause; return; }
            read -rp "$(echo -e "${CYAN}Chat ID (你的 TG user id): ${NC}")" chat
            [[ "$chat" =~ ^-?[0-9]+$ ]] || { err "Chat ID 应为数字，未改动"; pause; return; }
            ddns_edit --arg b "$bot" --arg c "$chat" '.tg_bot_token = $b | .tg_chat_id = $c' \
                && ok "已开启：IP 变更时发送通知"
            bot=""
            ;;
        2)
            ddns_edit 'del(.tg_bot_token, .tg_chat_id)' && ok "已清空，IP 变更通知已关闭"
            ;;
        *) return ;;
    esac
    pause
}

ddns_menu() {
    while :; do
        clear; show_banner
        sec "Cloudflare DDNS"
        local n timer="${RED}未运行${NC}"
        n=$(ddns_count)
        systemctl is-active --quiet sb-cloudflare-ddns.timer 2>/dev/null \
            && timer="${GREEN}运行中 (每 $(ddns_interval) 分钟)${NC}"
        if (( n == 0 )); then
            echo -e "  ${YELLOW}尚未配置记录${NC}"
        else
            echo -e "  定时器: ${timer}    记录: ${n} 条"
            ddns_print_records
        fi
        hr
        echo "  1. 新增记录"
        echo "  2. 修改记录"
        echo "  3. 删除记录"
        echo "  4. 状态检查"
        echo "  5. 立即同步"
        echo "  6. 更换 API Token"
        echo "  7. 同步间隔"
        echo "  8. IP 变更通知 (Telegram)"
        echo "  0. 返回上一页"
        hr
        local c
        read -rp "$(echo -e "${CYAN}请选择 [0-8]: ${NC}")" c
        case "$c" in
            1) ddns_add ;;
            2) ddns_edit_record ;;
            3) ddns_delete_record ;;
            4) ddns_status ;;
            5) ddns_sync_now ;;
            6) ddns_change_token ;;
            7) ddns_set_interval ;;
            8) ddns_set_tg ;;
            0|"") return ;;
            *) err "无效选择"; sleep 1 ;;
        esac
    done
}

# =============================================================================
# 家宽换 IP (服务商 API)
#
# 结构
#   引擎  ${IPC_BIN}
#         独立的 bash 脚本（由 ipc_write_engine 生成），是唯一调用服务商 API
#         的地方。流程: 调换 IP API → 等本机出口 IP 变化 → 立即同步 Cloudflare
#         DDNS（若已配置）→ 把节点分享链接里的旧 IP 换成新 IP。
#   服务  sb-ipchange.service (oneshot)。菜单里的「立即更换」也是启动这个服务，
#         这样即使 SSH 因换 IP 断开，任务仍由 systemd 在后台跑完。
#   定时  sb-ipchange.timer（可选）：每 N 小时 / 每天固定时间自动换一次。
#   配置  ${IPC_CONF} (600)
#         {"version":1, "change_url":"...", "show_url":"...", "schedule":"" | "6h" | "04:30"}
#   状态  ${IPC_DIR}/state.json：上次换 IP 的时间与结果，用于冷却（防止触发频率限制）
# =============================================================================

# ---- 文件部署（ddns_put 见 DDNS 段）-----------------------------------------

ipc_write_engine() {
    ddns_put "$IPC_BIN" 700 <<'SB_IPC_ENGINE'
#!/usr/bin/env bash
# sb-ipchange —— 由 sb 脚本生成，手动修改会在下次启动 sb 时被覆盖。
# 用法: sb-ipchange [show | change [-f]]
#   show    通过查询 API 输出当前公网 IPv4
#   change  调换 IP API → 等待新 IP → 同步 DDNS → 更新节点分享链接
#           -f  忽略冷却时间
# 环境变量: IPC_COOLDOWN (默认 120 秒)  IPC_WAIT_MAX (默认 180 秒)
set -o pipefail

CONF="/etc/sb-ipchange/config.json"
STATE="/etc/sb-ipchange/state.json"
NODES="/etc/sing-box/nodes.json"
DDNS_BIN="/usr/local/lib/sb-cloudflare-ddns"
DDNS_CONF="/etc/sb-cloudflare-ddns/config.json"
COOLDOWN="${IPC_COOLDOWN:-120}"
WAIT_MAX="${IPC_WAIT_MAX:-180}"

log() { printf '[%(%F %T)T] %s\n' -1 "$*"; }
die() { log "错误: $*" >&2; exit 1; }

command -v curl  >/dev/null 2>&1 || die "缺少 curl"
command -v jq    >/dev/null 2>&1 || die "缺少 jq"
command -v flock >/dev/null 2>&1 || die "缺少 flock (util-linux)"
[[ -r "$CONF" ]] || die "配置文件不存在: ${CONF}"

CHANGE_URL=$(jq -r '.change_url // empty' "$CONF")
SHOW_URL=$(jq -r '.show_url // empty' "$CONF")

# 从响应文本中取第一个合法的公网 IPv4（API 可能返回纯文本，也可能是 JSON）
pick_ipv4() {
    local c a b d e
    while read -r c; do
        IFS=. read -r a b d e <<<"$c"
        (( 10#$a <= 255 && 10#$b <= 255 && 10#$d <= 255 && 10#$e <= 255 )) || continue
        [[ "$c" =~ ^(0|10|127)\. || "$c" =~ ^192\.168\. || "$c" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] && continue
        echo "$c"; return 0
    done < <(grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}')
    return 1
}

# 查询 API 看到的 IP（有频率限制，只在必要时调用）
api_ip() {
    [[ -n "$SHOW_URL" ]] || return 1
    curl -fsS -m 10 "$SHOW_URL" 2>/dev/null | pick_ipv4
}

# 本机实际出口 IPv4（等待期间轮询用这个，不消耗服务商 API 次数）
local_ip() {
    curl -fsS -m 6 -4 https://api.ipify.org 2>/dev/null | pick_ipv4 \
        || curl -fsS -m 6 -4 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p' | pick_ipv4
}

save_state() {   # save_state 旧IP 新IP 结果
    local tmp
    tmp=$(mktemp "${STATE}.XXXXXX") || return 0
    if jq -n --arg o "$1" --arg n "$2" --arg r "$3" --argjson t "$(date +%s)" \
        '{last_ts:$t, last_old:$o, last_new:$n, last_result:$r}' > "$tmp"; then
        chmod 600 "$tmp"; mv -f "$tmp" "$STATE"
    else
        rm -f "$tmp"
    fi
}

sync_ddns() {
    [[ -x "$DDNS_BIN" && -f "$DDNS_CONF" ]] || return 0
    log "同步 Cloudflare DDNS..."
    if "$DDNS_BIN" -v update 2>&1 | sed 's/^/    /'; then
        log "DDNS 已同步"
    else
        log "DDNS 同步出错，DDNS 定时器会自动重试"
    fi
}

relink() {   # relink 旧IP 新IP：只替换 "@旧IP:" 形式，不会误伤包含相同数字的其他地址
    local old="$1" new="$2" n tmp
    [[ -n "$old" && -f "$NODES" ]] || return 0
    n=$(jq --arg h "@${old}:" '[.[] | select((.link // "") | contains($h))] | length' "$NODES" 2>/dev/null) || return 0
    (( n > 0 )) || return 0
    tmp=$(mktemp "${NODES}.XXXXXX") || return 0
    if jq --arg o "@${old}:" --arg n "@${new}:" \
        'map(if (.link // "") | contains($o) then .link |= (split($o) | join($n)) else . end)' \
        "$NODES" > "$tmp"; then
        chmod --reference="$NODES" "$tmp"
        mv -f "$tmp" "$NODES"
        log "已更新 ${n} 个节点分享链接: ${old} → ${new}"
    else
        rm -f "$tmp"
        log "节点分享链接更新失败，请在 sb 菜单里手动修改"
    fi
}

cmd_show() {
    [[ -n "$SHOW_URL" ]] || die "未配置查询 API"
    local ip
    ip=$(api_ip) || die "查询 API 未返回 IP"
    echo "$ip"
}

cmd_change() {
    local force=0
    [[ "${1:-}" == "-f" ]] && force=1
    [[ -n "$CHANGE_URL" ]] || die "未配置换 IP API"
    exec 9<"$0" && flock -n 9 || die "已有换 IP 任务在执行"

    local now last
    now=$(date +%s)
    last=$(jq -r '.last_ts // 0' "$STATE" 2>/dev/null) || last=0
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    if (( ! force && now - last < COOLDOWN )); then
        die "距上次换 IP 仅 $(( now - last )) 秒，需间隔 ${COOLDOWN} 秒（面板有频率限制）"
    fi

    local old new cur out code body rc i
    old=$(local_ip) || old=$(api_ip) || old=""
    log "当前 IP: ${old:-未知}"
    save_state "$old" "" "requested"   # 先记下时间戳，即便后面断线也会进入冷却

    log "调用换 IP API..."
    out=$(curl -sS -m 30 -w $'\n%{http_code}' "$CHANGE_URL" 2>&1); rc=$?
    code="${out##*$'\n'}"
    body=$(printf '%s' "${out%$'\n'*}" | tr -d '\r' | tr '\n' ' ' | sed 's/ *$//' | cut -c1-200)
    if (( rc != 0 )); then
        log "请求未正常返回 (curl ${rc})；线路重拨时连接断开属正常，继续等待..."
    elif [[ "$code" =~ ^[45] ]]; then
        log "API 拒绝请求 (HTTP ${code}): ${body:-<空>}"
        save_state "$old" "" "rejected"
        exit 1
    else
        log "API 返回 (HTTP ${code}): ${body:-<空>}"
    fi

    log "等待新 IP 生效（最长 ${WAIT_MAX} 秒）..."
    new=""
    sleep 10
    for (( i = 10; i < WAIT_MAX; i += 5 )); do
        cur=$(local_ip) || cur=""
        if [[ -n "$cur" && "$cur" != "$old" ]]; then new="$cur"; break; fi
        sleep 5
    done

    if [[ -z "$new" ]]; then
        cur=$(api_ip) || cur=""
        if [[ -n "$cur" && "$cur" != "$old" ]]; then
            new="$cur"   # 查询 API 显示已换，只是本机探测没跟上
        elif [[ -n "$cur" ]]; then
            log "IP 没有变化，仍是 ${cur}（可能分到了同一个 IP，或 API 未生效）"
            save_state "$old" "$cur" "unchanged"; exit 2
        else
            log "等待超时：无法获取公网 IP，网络可能还没恢复"
            save_state "$old" "" "timeout"; exit 3
        fi
    fi

    log "新 IP: ${new}"
    save_state "$old" "$new" "ok"
    sync_ddns
    relink "$old" "$new"
    log "完成"
}

case "${1:-show}" in
    show)   cmd_show ;;
    change) shift; cmd_change "$@" ;;
    *)      die "未知命令: $1" ;;
esac
SB_IPC_ENGINE
}

ipc_schedule() { jq -r '.schedule // empty' "$IPC_CONF" 2>/dev/null; }

ipc_schedule_desc() {
    local s; s=$(ipc_schedule)
    if [[ -z "$s" ]]; then echo "关闭"
    elif [[ "$s" =~ ^([0-9]+)h$ ]]; then echo "每 ${BASH_REMATCH[1]} 小时"
    else echo "每天 ${s}"
    fi
}

# systemd 单元。返回 0=有改动 / 1=无变化
ipc_write_units() {
    local rc=1 sched spec
    ddns_put "$IPC_SERVICE" 644 <<EOF && rc=0
[Unit]
Description=Home broadband IP change via provider API (managed by sb)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=${IPC_BIN} change
TimeoutStartSec=400
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
EOF
    sched=$(ipc_schedule)
    if [[ -z "$sched" ]]; then
        if [[ -f "$IPC_TIMER" ]]; then
            systemctl disable --now sb-ipchange.timer >/dev/null 2>&1 || true
            rm -f "$IPC_TIMER"
            rc=0
        fi
        return $rc
    fi
    if [[ "$sched" =~ ^([0-9]+)h$ ]]; then
        # 相对上次换 IP 计时：手动换过一次后，下次自动换会顺延
        spec="OnActiveSec=${BASH_REMATCH[1]}h"$'\n'"OnUnitActiveSec=${BASH_REMATCH[1]}h"
    else
        spec="OnCalendar=*-*-* ${sched}:00"
    fi
    ddns_put "$IPC_TIMER" 644 <<EOF && rc=0
[Unit]
Description=Scheduled home broadband IP change (managed by sb)

[Timer]
${spec}
RandomizedDelaySec=60s
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF
    return $rc
}

# 部署引擎 + 单元，按配置启停定时器。幂等：内容没变就什么都不做。
ipc_deploy() {
    local reload=0
    install -d -m 700 "$IPC_DIR"
    ipc_write_engine
    ipc_write_units && reload=1
    (( reload )) && systemctl daemon-reload
    if [[ -f "$IPC_TIMER" ]]; then
        (( reload )) && systemctl restart sb-ipchange.timer >/dev/null 2>&1
        if ! systemctl is-enabled --quiet sb-ipchange.timer 2>/dev/null \
           || ! systemctl is-active --quiet sb-ipchange.timer 2>/dev/null; then
            systemctl enable --now sb-ipchange.timer >/dev/null 2>&1 \
                || warn "换 IP 定时器启动失败，请检查: systemctl status sb-ipchange.timer"
        fi
    fi
    return 0
}

ipc_remove() {
    systemctl disable --now sb-ipchange.timer >/dev/null 2>&1 || true
    systemctl stop sb-ipchange.service >/dev/null 2>&1 || true
    rm -f "$IPC_TIMER" "$IPC_SERVICE" "$IPC_BIN"
    rm -rf "$IPC_DIR"
    systemctl daemon-reload
    ok "换 IP 服务与配置（含 API 链接）已清除"
}

# 启动 sb 时调用：保证引擎 / 单元是最新的
ipc_bootstrap() {
    [[ -f "$IPC_CONF" ]] || return 0
    ipc_deploy
}

# ---- 配置读写 ----------------------------------------------------------------

ipc_configured() { [[ -n "$(jq -r '.change_url // empty' "$IPC_CONF" 2>/dev/null)" ]]; }

ipc_edit() { json_edit "$IPC_CONF" "$@"; }

# 界面上隐藏 token：https://api.x.com/ipch/abcdefghij → https://api.x.com/ipch/abc****hij
ipc_mask() {
    local u="$1" t
    [[ -z "$u" ]] && { echo "—"; return; }
    t="${u##*/}"
    if (( ${#t} > 6 )); then
        echo "${u%/*}/${t:0:3}****${t: -3}"
    else
        echo "${u%/*}/****"
    fi
}

ipc_valid_url() { [[ "$1" =~ ^https?://[^[:space:]/]+(/[^[:space:]]*)?$ ]]; }

# 已配置的 IPv4 DDNS 域名（逗号分隔）
ipc_ddns_hosts() {
    jq -r '[.records[]? | select(.type == "A") | .hostname] | join(", ")' "$CF_DDNS_CONF" 2>/dev/null
}

# ---- 界面 --------------------------------------------------------------------

ipc_setup() {
    clear; show_banner
    sec "设置 / 修改换 IP API"
    echo "  到服务商面板「API接口信息」复制「更換IP API」的完整链接粘贴到这里。"
    echo -e "  ${YELLOW}链接里的 token 等同密码：拿到它的人都能换你的 IP。${NC}"
    echo -e "  ${YELLOW}如果之前截图 / 外发过，先在面板点「生成API」重新生成一组。${NC}"
    echo
    local cu su def y
    read -rp "$(echo -e "${CYAN}更换 IP API (回车取消): ${NC}")" cu
    cu="${cu//[[:space:]]/}"
    [[ -z "$cu" ]] && return
    ipc_valid_url "$cu" || { err "链接格式不对，应以 http:// 或 https:// 开头"; pause; return; }

    def=""
    [[ "$cu" == */ipch/* ]] && def="${cu/\/ipch\//\/show\/}"
    if [[ -n "$def" ]]; then
        echo -e "  已推导出查询 API: ${CYAN}$(ipc_mask "$def")${NC}"
        read -rp "$(echo -e "${CYAN}查询 IP API (回车使用上面这个): ${NC}")" su
    else
        read -rp "$(echo -e "${CYAN}查询 IP API (可留空): ${NC}")" su
    fi
    su="${su//[[:space:]]/}"
    [[ -z "$su" ]] && su="$def"
    if [[ -n "$su" ]] && ! ipc_valid_url "$su"; then
        err "查询 API 链接格式不对"; pause; return
    fi

    install -d -m 700 "$IPC_DIR"
    if [[ -f "$IPC_CONF" ]]; then
        ipc_edit --arg c "$cu" --arg s "$su" '.change_url = $c | .show_url = $s' || { pause; return; }
    else
        ( umask 077
          jq -n --arg c "$cu" --arg s "$su" \
              '{version:1, change_url:$c, show_url:$s, schedule:""}' > "$IPC_CONF" ) \
            || { err "写入配置失败"; pause; return; }
    fi
    cu=""; su=""
    ipc_deploy
    ok "已保存"

    if [[ -n "$(jq -r '.show_url // empty' "$IPC_CONF")" ]]; then
        msg "测试查询 API（不会换 IP）..."
        local ip
        if ip=$("$IPC_BIN" show 2>/dev/null); then
            ok "查询成功，面板显示当前 IP: ${ip}"
        else
            warn "查询 API 没有返回 IP。不影响换 IP，只是等待新 IP 时只能靠本机探测。"
        fi
    fi
    (( $(ddns_count) > 0 )) || warn "未配置 Cloudflare DDNS：换 IP 后节点地址会变，建议主菜单 d 配一个域名。"
    pause
}

ipc_change_now() {
    ipc_configured || { err "请先设置换 IP API (选项 3)"; pause; return; }
    clear; show_banner
    sec "立即更换 IP"
    if systemctl is-active --quiet sb-ipchange.service 2>/dev/null; then
        warn "已有换 IP 任务在执行，稍后再试"; pause; return
    fi
    local hosts; hosts=$(ipc_ddns_hosts)
    echo "  流程: 调用换 IP API → 等新 IP 生效 → 同步 DDNS → 更新节点分享链接"
    echo "  任务交给 systemd 在后台执行，终端断开不影响它完成。"
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        echo
        warn "你正在通过 SSH 连接本机，换 IP 后这个连接会断开。"
        if [[ -n "$hosts" ]]; then
            echo -e "  约 1-2 分钟后用域名重连: ${CYAN}${hosts}${NC}"
        else
            warn "没有配置 DDNS，断开后需要到服务商面板查看新 IP 再连回来。"
        fi
    fi
    echo
    local y
    read -rp "$(echo -e "${YELLOW}确定更换? [y/N]: ${NC}")" y
    [[ "$y" =~ ^[Yy]$ ]] || return

    local jpid i state started=0 result code stop=0
    trap 'stop=1' INT
    journalctl -u sb-ipchange.service -f -n 0 -o cat 2>/dev/null &
    jpid=$!
    sleep 1
    systemctl reset-failed sb-ipchange.service >/dev/null 2>&1 || true
    systemctl start --no-block sb-ipchange.service || { kill "$jpid" 2>/dev/null; err "启动任务失败"; pause; return; }
    for (( i = 0; i < 420; i++ )); do
        sleep 1
        (( stop )) && break
        state=$(systemctl show -p ActiveState --value sb-ipchange.service 2>/dev/null)
        if [[ "$state" == "activating" || "$state" == "active" ]]; then
            started=1
        elif (( started || i > 5 )); then
            break
        fi
    done
    sleep 1
    kill "$jpid" 2>/dev/null; wait "$jpid" 2>/dev/null
    trap - INT
    if (( stop )); then
        echo
        warn "已停止跟踪。换 IP 任务仍在后台执行，可稍后在选项 2 查看结果"
        pause; return
    fi
    result=$(systemctl show -p Result --value sb-ipchange.service 2>/dev/null)
    code=$(systemctl show -p ExecMainStatus --value sb-ipchange.service 2>/dev/null)
    echo
    case "$result:$code" in
        success:*)  ok "IP 已更换" ;;
        *:2)        warn "IP 没有变化，可稍后再试一次" ;;
        *)          err "换 IP 未成功，详见上方输出或选项 2 查看日志" ;;
    esac
    pause
}

ipc_status() {
    clear; show_banner
    sec "换 IP 状态"
    ipc_configured || { warn "尚未设置换 IP API"; pause; return; }
    local api_ip loc ts old new res next
    api_ip=$("$IPC_BIN" show 2>/dev/null) || api_ip="查询失败"
    loc=$(get_ip 4)
    echo -e "  换 IP API:  ${CYAN}$(ipc_mask "$(jq -r '.change_url' "$IPC_CONF")")${NC}"
    echo -e "  面板查询:   ${CYAN}${api_ip}${NC}"
    echo -e "  本机出口:   ${CYAN}${loc:-获取失败}${NC}"
    echo -e "  定时换 IP:  ${CYAN}$(ipc_schedule_desc)${NC}"
    if [[ -f "$IPC_TIMER" ]]; then
        next=$(systemctl show sb-ipchange.timer -p NextElapseUSecRealtime --value 2>/dev/null)
        echo -e "  下次执行:   ${CYAN}${next:-—}${NC}"
    fi
    if [[ -f "${IPC_DIR}/state.json" ]]; then
        IFS=$'\t' read -r ts old new res < <(jq -r \
            '[(.last_ts // 0), (.last_old // ""), (.last_new // ""), (.last_result // "")] | @tsv' \
            "${IPC_DIR}/state.json" 2>/dev/null)
        ts=$(date -d "@${ts:-0}" '+%F %T' 2>/dev/null)
        case "$res" in
            ok) res="${GREEN}成功${NC}" ;; unchanged) res="${YELLOW}IP 未变${NC}" ;;
            rejected) res="${RED}API 拒绝${NC}" ;; timeout) res="${RED}超时${NC}" ;;
            requested) res="${YELLOW}执行中/中断${NC}" ;;
        esac
        echo -e "  上次换 IP:  ${CYAN}${ts}${NC}  ${old:-?} → ${new:-?}  ${res}"
    fi
    echo
    echo -e "  ${BOLD}最近日志:${NC}"
    journalctl -u sb-ipchange.service -n 15 --no-pager -o cat 2>/dev/null | sed 's/^/  /'
    pause
}

ipc_schedule_menu() {
    ipc_configured || { err "请先设置换 IP API (选项 3)"; pause; return; }
    clear; show_banner
    sec "定时自动换 IP"
    echo -e "  当前: ${CYAN}$(ipc_schedule_desc)${NC}"
    echo -e "  ${YELLOW}换 IP 时节点会断线几十秒；间隔别太短，避免触发面板频率限制。${NC}"
    hr
    echo "  1) 每隔 N 小时"
    echo "  2) 每天固定时间"
    echo "  3) 关闭定时"
    echo "  0) 返回上一页"
    hr
    local c v s=""
    read -rp "$(echo -e "${CYAN}请选择 [0-3]: ${NC}")" c
    case "$c" in
        1) read -rp "$(echo -e "${CYAN}间隔小时数 [1-168]: ${NC}")" v
           [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1 && v <= 168 )) || { err "无效数字"; pause; return; }
           s="$((10#$v))h" ;;
        2) read -rp "$(echo -e "${CYAN}时间 (24 小时制 HH:MM，本机时区 $(date +%Z)): ${NC}")" v
           [[ "$v" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { err "格式应为 HH:MM，例如 04:30"; pause; return; }
           s="$v" ;;
        3) s="" ;;
        *) return ;;
    esac
    ipc_edit --arg s "$s" '.schedule = $s' || { pause; return; }
    ipc_deploy
    ok "定时换 IP: $(ipc_schedule_desc)"
    if [[ -f "$IPC_TIMER" ]]; then
        echo -e "  下次执行: ${CYAN}$(systemctl show sb-ipchange.timer -p NextElapseUSecRealtime --value 2>/dev/null)${NC}"
    fi
    pause
}

ipc_delete() {
    [[ -f "$IPC_CONF" || -f "$IPC_SERVICE" ]] || { warn "没有换 IP 配置"; pause; return; }
    local y
    read -rp "$(echo -e "${YELLOW}删除换 IP 配置、定时器与引擎? [y/N]: ${NC}")" y
    [[ "$y" =~ ^[Yy]$ ]] && ipc_remove
    pause
}

ipc_menu() {
    while :; do
        clear; show_banner
        sec "家宽换 IP (服务商 API)"
        if ipc_configured; then
            echo -e "  API:  ${CYAN}$(ipc_mask "$(jq -r '.change_url' "$IPC_CONF")")${NC}"
            echo -e "  定时: ${CYAN}$(ipc_schedule_desc)${NC}    DDNS 联动: $( (( $(ddns_count) > 0 )) && echo -e "${GREEN}已配置${NC}" || echo -e "${YELLOW}未配置${NC}")"
        else
            echo -e "  ${YELLOW}尚未设置换 IP API${NC}"
        fi
        hr
        echo "  1. 立即更换 IP"
        echo "  2. 状态 / 最近日志"
        echo "  3. 设置 / 修改 API"
        echo "  4. 定时自动换 IP"
        echo "  5. 删除换 IP 配置"
        echo "  0. 返回上一页"
        hr
        local c
        read -rp "$(echo -e "${CYAN}请选择 [0-5]: ${NC}")" c
        case "$c" in
            1) ipc_change_now ;;
            2) ipc_status ;;
            3) ipc_setup ;;
            4) ipc_schedule_menu ;;
            5) ipc_delete ;;
            0|"") return ;;
            *) err "无效选择"; sleep 1 ;;
        esac
    done
}

# =============================================================================
# IP 优先级
# =============================================================================
menu_ip_strategy() {
    while :; do
        clear; show_banner
        sec "IPv4 / IPv6 优先级与策略"
        local cur; cur=$(jq -r '.ip_strategy' "$SB_SETTINGS")
        echo -e "当前策略: ${YELLOW}${cur}${NC}"
        echo
        echo "  1) prefer_ipv4   优先 IPv4 (默认)"
        echo "  2) prefer_ipv6   优先 IPv6"
        echo "  3) ipv4_only     仅 IPv4"
        echo "  4) ipv6_only     仅 IPv6"
        echo
        local q; q=$(jq -r '.block_quic // false' "$SB_SETTINGS")
        if [[ "$q" == "true" ]]; then
            echo -e "  5) 阻断 QUIC(HTTP/3)   当前: ${GREEN}已阻断${NC}"
        else
            echo -e "  5) 阻断 QUIC(HTTP/3)   当前: ${RED}未阻断${NC}"
        fi
        echo "  0) 返回上一页"
        hr
        local c new
        read -rp "$(echo -e "${CYAN}请选择 [0-5]: ${NC}")" c
        case "$c" in
            1) new="prefer_ipv4" ;;
            2) new="prefer_ipv6" ;;
            3) new="ipv4_only" ;;
            4) new="ipv6_only" ;;
            5) toggle_setting block_quic "阻断 QUIC (HTTP/3)" \
                   "Claude / ChatGPT 等 App 会优先用 HTTP/3 (QUIC, UDP)，" \
                   "线路 UDP 质量差时表现为「页面能开、回答一直转圈」。" \
                   "阻断后会自动回落 HTTP/2 (TCP)，通常能解决卡顿。"
               continue ;;
            0|"") return ;;
            *) err "无效"; sleep 1; continue ;;
        esac
        if settings_set ip_strategy "\"${new}\""; then
            snell_sync_all      # snell-server 节点的出口策略也跟随
            ok "已切换为 ${new}"
            sleep 1
        else
            pause
        fi
    done
}

# =============================================================================
# 流量统计
# =============================================================================
menu_traffic() {
    while :; do
        clear; show_banner
        sec "流量使用情况 (vnstat)"
        if ! command -v vnstat >/dev/null 2>&1; then
            warn "vnstat 未安装"
            read -rp "是否安装? [Y/n]: " y
            if [[ ! "$y" =~ ^[Nn]$ ]]; then
                apt-get install -y vnstat >/dev/null 2>&1
                systemctl enable --now vnstat >/dev/null 2>&1
                ok "已安装，数据需要几分钟收集"
                sleep 2
                continue
            else
                return
            fi
        fi
        local iface; iface=$(ip route | awk '/default/ {print $5; exit}')
        echo -e "默认网卡: ${YELLOW}${iface}${NC}"
        hr
        echo "  1) 今日 / 昨日"
        echo "  2) 本月 / 上月"
        echo "  3) 总计"
        echo "  4) 实时速率"
        echo "  5) 所有网卡概览"
        echo "  0) 返回上一页"
        hr
        local c
        read -rp "$(echo -e "${CYAN}请选择 [0-5]: ${NC}")" c
        case "$c" in
            1) clear; vnstat -d -i "$iface" 2>/dev/null | head -n 20; pause ;;
            2) clear; vnstat -m -i "$iface" 2>/dev/null | head -n 20; pause ;;
            3) clear; vnstat -i "$iface" 2>/dev/null; pause ;;
            4) clear; echo "Ctrl+C 退出"; trap ':' INT; vnstat -l -i "$iface"; trap - INT ;;
            5) clear; vnstat; pause ;;
            0|"") return ;;
            *) err "无效"; sleep 1 ;;
        esac
    done
}

# =============================================================================
# sing-box 管理
# =============================================================================
menu_singbox() {
    while :; do
        clear; show_banner
        sec "sing-box 管理"
        local active="未运行" enabled="未启用" ver time_status bbr_status
        systemctl is-active --quiet sing-box && active="${GREEN}运行中${NC}"
        systemctl is-enabled --quiet sing-box 2>/dev/null && enabled="${GREEN}开机自启${NC}"
        ver=$("$SB_BIN" version 2>/dev/null | awk '/version/{print $3; exit}')
        if check_time_sync; then
            time_status="${GREEN}已同步${NC}"
        else
            time_status="${RED}未同步${NC}"
        fi
        if check_bbr; then
            bbr_status="${GREEN}已启用${NC}"
        else
            bbr_status="${RED}未启用${NC}"
        fi
        echo -e "  状态: ${active}    自启: ${enabled}    版本: ${ver:-未知}"
        echo -e "  时间: ${time_status}    (SS-2022/Reality 等协议要求时间偏差 < 30s)"
        echo -e "  BBR:  ${bbr_status}    (推荐启用,显著提升跨境线路速度)"
        hr
        echo "  1) 启动 sing-box"
        echo "  2) 停止 sing-box"
        echo "  3) 重启 sing-box"
        echo "  4) 查看 systemd 状态"
        echo "  5) 最近 50 行日志"
        echo "  6) 实时跟踪日志 (Ctrl+C 退出)"
        echo "  7) 清空日志文件"
        echo "  8) 更新 sing-box 到最新稳定版"
        echo "  9) 切换 / 安装 测试版 (Beta)"
        echo "  t) 时间同步状态 / 一键修复"
        echo "  b) BBR 拥塞控制 / 一键启用"
        echo "  0) 返回上一页"
        hr
        local c
        read -rp "$(echo -e "${CYAN}请选择 [0-9/t/b]: ${NC}")" c
        case "$c" in
            1) systemctl start sing-box && ok "已启动"; sleep 1 ;;
            2) systemctl stop sing-box && ok "已停止"; sleep 1 ;;
            3) restart_sb; pause ;;
            4) clear; systemctl status sing-box --no-pager -l | head -n 30; pause ;;
            5) clear; view_log 50; pause ;;
            6) clear; echo "Ctrl+C 退出"
               trap ':' INT
               if [[ -s "$SB_LOG" ]]; then
                   tail -f "$SB_LOG"
               else
                   journalctl -u sing-box -f
               fi
               trap - INT ;;
            7) : > "$SB_LOG"; ok "日志已清空"; sleep 1 ;;
            8) install_singbox force stable && restart_sb; pause ;;
            9) install_singbox force beta && restart_sb; pause ;;
            t|T) menu_time_sync ;;
            b|B) menu_bbr ;;
            0|"") return ;;
            *) err "无效"; sleep 1 ;;
        esac
    done
}

# =============================================================================
# 脚本管理
# =============================================================================
menu_script() {
    while :; do
        clear; show_banner
        sec "脚本管理"
        echo "  当前版本: v${SCRIPT_VERSION}  作者: ${SCRIPT_AUTHOR}"
        echo "  脚本路径: ${SB_SCRIPT_PATH}"
        echo "  更新源:   ${SCRIPT_UPDATE_URL}"
        hr
        echo "  1) 更新脚本"
        echo "  2) 一键卸载 (清除所有内容)"
        echo "  0) 返回上一页"
        hr
        local c
        read -rp "$(echo -e "${CYAN}请选择 [0-2]: ${NC}")" c
        case "$c" in
            1) update_script; pause ;;
            2) do_uninstall ;;
            0|"") return ;;
            *) err "无效"; sleep 1 ;;
        esac
    done
}

update_script() {
    msg "从 ${SCRIPT_UPDATE_URL} 下载新版..."
    local tmp; tmp=$(mktemp)
    if curl -fsSL "$SCRIPT_UPDATE_URL" -o "$tmp"; then
        if head -n 1 "$tmp" | grep -q '^#!/.*bash' && bash -n "$tmp" 2>/dev/null; then
            install -m 755 "$tmp" "$SB_SCRIPT_PATH"
            rm -f "$tmp"
            ok "脚本已更新，请重新执行 sb"
            exit 0
        else
            err "下载内容不是有效脚本"
            rm -f "$tmp"
        fi
    else
        err "下载失败，请检查 SCRIPT_UPDATE_URL"
        rm -f "$tmp"
    fi
}

do_uninstall() {
    clear; show_banner
    sec "${RED}一键卸载${NC}"
    echo "将删除: sing-box、官方 snell-server、配置、systemd 服务、日志、sb 命令"
    echo
    read -rp "$(echo -e "${YELLOW}确定卸载? 输入 ${BOLD}YES${NC}${YELLOW} 确认: ${NC}")" y
    [[ "$y" == "YES" ]] || { warn "已取消"; pause; return; }
    if [[ -f "$CF_DDNS_CONF" || -f "$CF_DDNS_TIMER" ]]; then
        echo
        read -rp "$(echo -e "${YELLOW}检测到 Cloudflare DDNS，是否一并卸载并删除 Token? [y/N]: ${NC}")" y
        if [[ "$y" =~ ^[Yy]$ ]]; then
            ddns_remove
        else
            warn "已保留 Cloudflare DDNS 服务和配置"
        fi
    fi
    if [[ -f "$IPC_CONF" || -f "$IPC_SERVICE" ]]; then
        echo
        read -rp "$(echo -e "${YELLOW}检测到家宽换 IP 配置，是否一并删除 (含 API 链接)? [y/N]: ${NC}")" y
        if [[ "$y" =~ ^[Yy]$ ]]; then
            ipc_remove
        else
            warn "已保留换 IP 服务和配置"
        fi
    fi
    snell_uninstall_all
    systemctl stop sing-box 2>/dev/null
    systemctl disable sing-box 2>/dev/null
    rm -f "$SB_SERVICE"
    systemctl stop sing-box-client 2>/dev/null
    systemctl disable sing-box-client 2>/dev/null
    rm -f "$SB_CLIENT_SERVICE" "$SB_CLIENT_LOG" "${SB_CLIENT_LOG}".*
    rm -f /etc/systemd/journald.conf.d/sing-box.conf
    rm -f /etc/logrotate.d/sing-box
    systemctl daemon-reload
    rm -rf "$SB_DIR"
    rm -f "$SB_BIN"
    rm -f "$SB_LOG" "${SB_LOG}".*
    rm -f "$SB_SCRIPT_PATH"
    ok "卸载完成，再见"
    exit 0
}

# =============================================================================
# Banner & 主菜单
# =============================================================================
show_banner() {
    REBUILD_ERR=""   # 生成失败标志只在单次操作内有效
    local sb_ver active node_count
    sb_ver=$("$SB_BIN" version 2>/dev/null | awk '/version/{print $3; exit}')
    if systemctl is-active --quiet sing-box; then
        active="${GREEN}running${NC}"
    else
        active="${RED}stopped${NC}"
    fi
    node_count=$(jq 'length' "$SB_NODES" 2>/dev/null || echo 0)
    center_line "$GREEN" "Sing-box Script v${SCRIPT_VERSION} By ${SCRIPT_AUTHOR}"
    echo
    echo -e "  sing-box: ${sb_ver:-未安装}"
    echo
    echo -e "  状态:     ${active}    节点数: ${node_count}"
    echo
    hr
}

main_menu() {
    while :; do
        clear; show_banner
        echo
        echo "  1. 添加配置"
        echo
        echo "  2. 更改配置"
        echo
        echo "  3. 查看配置"
        echo
        echo "  4. 删除配置"
        echo
        echo "  5. 分流规则管理"
        echo
        echo "  c. 客户端代理模式 (本地 SOCKS 出口)"
        echo
        echo "  d. Cloudflare DDNS (动态域名解析)"
        echo
        echo "  i. 家宽换 IP (服务商 API)"
        echo
        echo "  6. IPv4/IPv6 优先级与策略"
        echo
        echo "  7. 配置流量使用情况"
        echo
        echo "  8. sing-box 管理"
        echo
        echo "  9. 脚本管理"
        echo
        echo "  0. 退出"
        echo
        hr
        local c
        read -rp "$(echo -e "${CYAN}请输入选项 [0-9/c/d/i]: ${NC}")" c
        case "$c" in
            1) menu_add ;;
            2) modify_node ;;
            3) view_nodes ;;
            4) delete_node ;;
            5) menu_routing ;;
            c|C) menu_client ;;
            d|D) ddns_menu ;;
            i|I) ipc_menu ;;
            6) menu_ip_strategy ;;
            7) menu_traffic ;;
            8) menu_singbox ;;
            9) menu_script ;;
            0|"") clear; exit 0 ;;
            *) err "无效"; sleep 1 ;;
        esac
    done
}

first_install() {
    clear
    # sing-box 尚未安装，show_banner 不能用，只画标题
    center_line "$GREEN" "Sing-box Script v${SCRIPT_VERSION} By ${SCRIPT_AUTHOR}"
    echo
    sec "首次运行：开始安装"
    check_debian
    install_deps
    install_singbox || exit 1
    init_dirs
    setup_logrotate
    setup_service
    install_cmd
    rebuild_config
    systemctl restart sing-box 2>/dev/null || true
    hr
    # 时间同步检查（SS-2022/Reality 等协议对时间敏感）
    if check_time_sync; then
        ok "时间同步正常"
    else
        warn "系统时间未同步或偏差过大，SS-2022/Reality 等协议会拒绝连接"
        read -rp "$(echo -e "${CYAN}是否立即修复? [Y/n]: ${NC}")" y
        if [[ ! "$y" =~ ^[Nn]$ ]]; then
            fix_time_sync
        fi
    fi
    # BBR 检查（提升跨境线路速度，可选）
    if check_bbr; then
        ok "BBR 已启用"
    else
        warn "BBR 未启用，启用后可显著提升 TCP 协议跨境速度"
        read -rp "$(echo -e "${CYAN}是否立即启用 BBR? [Y/n]: ${NC}")" y
        if [[ ! "$y" =~ ^[Nn]$ ]]; then
            enable_bbr
        fi
    fi
    hr
    ok "安装完成。以后输入 ${BOLD}sb${NC} 即可呼出菜单。"
    hr
    pause
}

main() {
    need_root
    if [[ ! -x "$SB_BIN" ]]; then
        # sing-box 内核都没有：走完整首次安装
        first_install
    else
        # 内核已存在。可能是：已有服务端 / 仅想当纯客户端。
        # 不强制要求服务端 config 存在，确保基础设施就绪后直接进菜单。
        [[ -x "$SB_SCRIPT_PATH" ]] || install_cmd
        init_dirs
        setup_logrotate
        ddns_bootstrap || true
        ipc_bootstrap || true
        # 服务端 systemd 单元缺失则补上（仅当存在服务端配置时才需要它运行）
        [[ -f "$SB_SERVICE" ]] || setup_service
        # 若已有服务端节点但 config 丢失，重建一次
        if [[ -f "$SB_NODES" ]] && (( $(jq 'length' "$SB_NODES" 2>/dev/null || echo 0) > 0 )) && [[ ! -f "$SB_CONF" ]]; then
            rebuild_config
            systemctl restart sing-box 2>/dev/null || true
        fi
    fi
    main_menu
}

main "$@"
