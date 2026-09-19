#!/usr/bin/env bash
# =============================================================================
# Sing-box Script v1.3 By Merlin
# 支持入站: Shadowsocks(老版+2022) / VLESS+Reality / AnyTLS
# 支持出站: SS / VLESS-Reality / VLESS-WS-TLS / Hysteria2 / TUIC / Trojan / AnyTLS / Socks5
# 附加功能: Cloudflare DDNS (IPv4/IPv6)
# 系统:    Debian 12/13
# 调用:    sb
# =============================================================================

set -o pipefail

SCRIPT_VERSION="1.3"
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
sec() {
    local title="$1" w side_eq
    w=$(term_width)
    # 估算可视宽度：bytes - chars = UTF-8 多字节累计，÷2 = 中文字符数
    local bytes chars non_ascii_chars ascii_chars visual
    bytes=$(printf '%s' " ${title} " | wc -c)
    chars=$(printf '%s' " ${title} " | wc -m)
    non_ascii_chars=$(( (bytes - chars) / 2 ))
    ascii_chars=$(( chars - non_ascii_chars ))
    visual=$(( ascii_chars + non_ascii_chars * 2 ))
    side_eq=$(( (w - visual) / 2 ))
    (( side_eq < 3 )) && side_eq=3
    local left right
    left=$(printf "%${side_eq}s" '' | tr ' ' '=')
    right=$(printf "%${side_eq}s" '' | tr ' ' '=')
    echo -e "${BLUE}${left} ${BOLD}${title}${NC}${BLUE} ${right}${NC}"
}

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
    offset=$(chronyc tracking 2>/dev/null | awk -F'[ :]+' '/System time/{print $4}')
    if [[ -z "$offset" ]]; then
        return 1
    fi
    # bash 不能直接处理浮点，借 awk 比较
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
    # 清掉旧的 BBR 相关配置（防止重复）
    sed -i '/^net\.core\.default_qdisc/d;/^net\.ipv4\.tcp_congestion_control/d' /etc/sysctl.conf
    echo 'net.core.default_qdisc=fq' >> /etc/sysctl.conf
    echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
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
    sed -i '/^net\.core\.default_qdisc/d;/^net\.ipv4\.tcp_congestion_control/d' /etc/sysctl.conf
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
    tar -xzf "${tmp}/sb.tar.gz" -C "$tmp"
    install -m 755 "${tmp}/sing-box-${ver}-linux-${arch}/sing-box" "$SB_BIN"
    rm -rf "$tmp"
    ok "sing-box v${ver} 已安装"
}

init_dirs() {
    mkdir -p "$SB_DIR" "$SB_CERT_DIR"
    chmod 700 "$SB_DIR"
    [[ -f "$SB_NODES" ]]     || echo '[]' > "$SB_NODES"
    [[ -f "$SB_OUTBOUNDS" ]] || echo '[]' > "$SB_OUTBOUNDS"
    [[ -f "$SB_RULES" ]]     || echo '[]' > "$SB_RULES"
    [[ -f "$SB_SETTINGS" ]]  || echo '{"ip_strategy":"prefer_ipv4","block_cn":false}' > "$SB_SETTINGS"
}

setup_logrotate() {
    cat > /etc/logrotate.d/sing-box <<EOF
${SB_LOG} {
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

# 从基础 DDNS 名称派生独立地址族名称。
# 例: kr.example.com -> kr4.example.com / kr6.example.com
ddns_split_hostname() {
    local hostname="$1" family="$2" first rest
    first="${hostname%%.*}"
    rest="${hostname#*.}"
    [[ "$family" == "6" ]] \
        && printf '%s6.%s\n' "$first" "$rest" \
        || printf '%s4.%s\n' "$first" "$rest"
}

ddns_record_summary() {
    local conf="$1"
    if jq -e '(.record_types | index("A") != null) and (.record_types | index("AAAA") != null)' \
        "$conf" >/dev/null 2>&1; then
        echo "IPv4 + IPv6（独立域名）"
    elif jq -e '.record_types | index("AAAA") != null' "$conf" >/dev/null 2>&1; then
        echo "IPv6（仅 AAAA）"
    else
        echo "IPv4（仅 A）"
    fi
}

# 节点分享链接使用的连接地址：按添加节点菜单所选模式返回纯 IP 或 DDNS 域名。
get_node_address() {
    local family="$1" address_mode="${2:-ip}" override="${3:-}" record_type hostname base dual=0
    if [[ "$address_mode" != "ddns" ]]; then
        get_ip "$family"
        return
    fi
    if [[ -n "$override" ]]; then
        echo "$override"
        return 0
    fi

    if [[ "$family" == "6" ]]; then
        record_type="AAAA"
    else
        record_type="A"
    fi

    if [[ -r "$CF_DDNS_CONF" ]] \
        && jq -e --arg t "$record_type" '.record_types | index($t) != null' \
            "$CF_DDNS_CONF" >/dev/null 2>&1; then
        base=$(jq -r '.hostname // empty' "$CF_DDNS_CONF" 2>/dev/null)
        jq -e '(.record_types | index("A") != null) and (.record_types | index("AAAA") != null)' \
            "$CF_DDNS_CONF" >/dev/null 2>&1 && dual=1
        if [[ "$family" == "6" ]]; then
            hostname=$(jq -r '.hostname_v6 // empty' "$CF_DDNS_CONF" 2>/dev/null)
        else
            hostname=$(jq -r '.hostname_v4 // empty' "$CF_DDNS_CONF" 2>/dev/null)
        fi
        if [[ -z "$hostname" ]]; then
            if (( dual == 1 )); then
                hostname=$(ddns_split_hostname "$base" "$family")
            else
                hostname="$base"
            fi
        fi
        if [[ -n "$hostname" ]]; then
            echo "$hostname"
            return 0
        fi
    fi
    return 1
}

ip_for_url() {
    local ip="$1"
    [[ "$ip" == *:* ]] && echo "[${ip}]" || echo "$ip"
}

random_port() {
    local i p
    for (( i=0; i<50; i++ )); do
        p=$(( RANDOM % 64512 + 1024 ))
        port_in_use "$p" || { echo "$p"; return 0; }
    done
    err "无法找到可用端口" >&2
    return 1
}

ask_port() {
    local prompt="$1" default="$2" port
    read -rp "$(echo -e "${CYAN}${prompt} [默认 ${default}]: ${NC}")" port
    port="${port:-$default}"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1024 || port > 65535 )); then
        err "端口必须是 1024-65535 的整数" >&2
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

# 原子写入 JSON 文件：jq 失败则保留原文件，临时文件自动清理
atomic_write() {
    local target="$1"
    shift
    local tmp
    tmp=$(mktemp) || return 1
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" RETURN
    if ! "$@" > "$tmp"; then
        err "atomic_write: 命令执行失败" >&2
        return 1
    fi
    if ! [[ -s "$tmp" ]]; then
        err "atomic_write: 输出为空，拒绝写入 $target" >&2
        return 1
    fi
    mv "$tmp" "$target"
}

# listen 地址：v4 节点用 0.0.0.0，v6 节点用 ::
listen_addr() {
    [[ "$1" == "6" ]] && echo "::" || echo "0.0.0.0"
}

save_node() {
    local tag="$1" proto="$2" port="$3" family="$4" remark="$5" link="$6" extra="$7"
    [[ -z "$extra" ]] && extra='{}'
    atomic_write "$SB_NODES" jq \
        --arg tag "$tag" --arg proto "$proto" --argjson port "$port" \
        --arg family "$family" --arg remark "$remark" --arg link "$link" \
        --argjson extra "$extra" \
        '. += [{tag:$tag, protocol:$proto, port:$port, family:$family, remark:$remark, link:$link, extra:$extra, created:(now|todate)}]' \
        "$SB_NODES"
}

restart_sb() {
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
# rebuild_config: 兼容 sing-box 1.13 的配置生成
# =============================================================================
rebuild_config() {
    local tmp; tmp=$(mktemp)

    local inbounds outbounds
    # 过滤掉 extra.inbound 为 null 的脏数据，避免 sing-box 启动失败
    inbounds=$(jq '[.[] | select(.extra.inbound != null) | .extra.inbound]' "$SB_NODES")

    local ip_strategy block_cn
    ip_strategy=$(jq -r '.ip_strategy' "$SB_SETTINGS")
    block_cn=$(jq -r '.block_cn' "$SB_SETTINGS")

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
    user_rules=$(jq '[.[] | {geosite:.geosite, domain:.domain, outbound:.outbound} |
        {
            rule_set:[(.geosite[]? | "geosite-\(.)")],
            domain_list:(.domain // []),
            outbound:.outbound
        }]' "$SB_RULES")

    # 大陆屏蔽规则
    local cn_block_rule="[]"
    if [[ "$block_cn" == "true" ]]; then
        cn_block_rule='[{"rule_set":["geosite-cn","geoip-cn"],"domain_list":[],"outbound":"block"}]'
    fi

    # 收集 rule_set
    local used_sets
    used_sets=$(jq -nr \
        --argjson u "$user_rules" \
        --argjson c "$cn_block_rule" \
        '[($u + $c) | .[] | .rule_set[]] | unique | .[]')

    local rule_sets="[]"
    if [[ -n "$used_sets" ]]; then
        local rs_arr="[" first=1
        while IFS= read -r tag; do
            [[ -z "$tag" ]] && continue
            local kind name url
            kind="${tag%%-*}"; name="${tag#*-}"
            if [[ "$kind" == "geosite" ]]; then
                url="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-${name}.srs"
            else
                url="https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-${name}.srs"
            fi
            [[ $first -eq 0 ]] && rs_arr+=","
            rs_arr+="{\"type\":\"remote\",\"tag\":\"${tag}\",\"format\":\"binary\",\"url\":\"${url}\",\"download_detour\":\"direct\"}"
            first=0
        done <<< "$used_sets"
        rs_arr+="]"
        rule_sets="$rs_arr"
    fi

    # 构造 route.rules:
    # 1) 第一条：resolve action（v4/v6 优先级）
    # 2) 用户规则
    # 3) cn 屏蔽规则
    local resolve_rule
    resolve_rule=$(jq -n --arg s "$ip_strategy" \
        '{action:"resolve", strategy:$s}')

    # 把用户规则与 cn 规则转成 sing-box 1.13 格式：
    # 有 domain 用 domain；有 rule_set 用 rule_set；都有就并列（OR）
    local proxy_rules
    proxy_rules=$(jq -n --argjson u "$user_rules" --argjson c "$cn_block_rule" \
        '[($u + $c) | .[] |
            (if (.rule_set | length) > 0 then {rule_set:.rule_set} else {} end) +
            (if (.domain_list | length) > 0 then {domain_suffix:.domain_list} else {} end) +
            {outbound:.outbound, action:"route"}
        ]')

    local all_rules
    all_rules=$(jq -n --argjson r "$resolve_rule" --argjson p "$proxy_rules" \
        '[$r] + $p')

    local route
    route=$(jq -n \
        --argjson rs "$rule_sets" \
        --argjson rules "$all_rules" \
        '{rule_set:$rs, rules:$rules, final:"direct", auto_detect_interface:true}')

    # DNS 服务器（resolve action 需要）
    local dns
    dns=$(jq -n '{servers:[{type:"local", tag:"local"}]}')

    jq -n \
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
        }' > "$tmp"

    mv "$tmp" "$SB_CONF"
}
# =============================================================================
# 添加节点：分类菜单（Shadowsocks / VLESS+Reality / AnyTLS）
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
        echo "  0) 返回上一页"
        hr
        local c
        read -rp "$(echo -e "${CYAN}请选择 [0-3]: ${NC}")" c
        case "$c" in
            1) menu_ss_method "$family" "$address_mode" "$node_address"; return ;;
            2) create_reality "$family" "$address_mode" "$node_address"; return ;;
            3) create_anytls "$family" "$address_mode" "$node_address"; return ;;
            0|"") return ;;
            *) err "无效选择"; sleep 1 ;;
        esac
    done
}

menu_ss_method() {
    local family="$1"
    local address_mode="${2:-ip}"
    local node_address="${3:-}"
    clear; show_banner
    sec "Shadowsocks → 选择加密方式"
    echo "  1) aes-128-gcm"
    echo "  2) aes-256-gcm"
    echo "  3) chacha20-ietf-poly1305"
    echo "  4) xchacha20-ietf-poly1305"
    echo "  5) 2022-blake3-aes-128-gcm"
    echo "  6) 2022-blake3-aes-256-gcm"
    echo "  7) 2022-blake3-chacha20-poly1305"
    echo "  0) 返回上一页"
    hr
    local c
    read -rp "$(echo -e "${CYAN}请选择 [0-7]: ${NC}")" c
    case "$c" in
        1) create_ss "$family" "aes-128-gcm" 16 "$address_mode" "$node_address" ;;
        2) create_ss "$family" "aes-256-gcm" 32 "$address_mode" "$node_address" ;;
        3) create_ss "$family" "chacha20-ietf-poly1305" 32 "$address_mode" "$node_address" ;;
        4) create_ss "$family" "xchacha20-ietf-poly1305" 32 "$address_mode" "$node_address" ;;
        5) create_ss "$family" "2022-blake3-aes-128-gcm" 16 "$address_mode" "$node_address" ;;
        6) create_ss "$family" "2022-blake3-aes-256-gcm" 32 "$address_mode" "$node_address" ;;
        7) create_ss "$family" "2022-blake3-chacha20-poly1305" 32 "$address_mode" "$node_address" ;;
        0|"") return ;;
        *) err "无效选择"; sleep 1 ;;
    esac
}

create_ss() {
    local family="$1" method="$2" keylen="$3"
    local address_mode="${4:-ip}"
    local node_address="${5:-}"
    local is2022=0
    [[ "$method" == 2022-* ]] && is2022=1

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
    tag="${short_proto}-${port}"

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
    read -rp "$(echo -e "${CYAN}请输入借用的真实网站域名 (默认 www.microsoft.com): ${NC}")" sni
    sni="${sni:-www.microsoft.com}"

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
    tag="reality-${port}"

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
            --argjson srv_up "$brutal_down" --argjson srv_down "$brutal_up" \
            '{type:"vless", tag:$tag, listen:$listen, listen_port:$port,
              users:[{uuid:$uuid}],
              multiplex:{enabled:true,
                brutal:{enabled:true, up_mbps:$srv_up, down_mbps:$srv_down}},
              tls:{enabled:true, server_name:$sni,
                reality:{enabled:true,
                  handshake:{server:$sni, server_port:443},
                  private_key:$prv, short_id:[$sid]}}}')
        # 注意: VLESS 标准分享链接无法表达 mux+brutal,客户端必须用 sing-box 完整 JSON 配置
        # 这里给出基础 vless:// 链接(无 flow),仅供 sing-box 客户端导入后手动补 mux+brutal
        link="vless://${uuid}@$(ip_for_url "$ip"):${port}?encryption=none&security=reality&sni=${sni}&fp=chrome&pbk=${pubkey}&sid=${shortid}&type=tcp#$(urlencode "$remark")"
    else
        inbound=$(jq -n --arg tag "$tag" --argjson port "$port" \
            --arg listen "$listen" \
            --arg uuid "$uuid" --arg sni "$sni" --arg prv "$prvkey" --arg sid "$shortid" \
            '{type:"vless", tag:$tag, listen:$listen, listen_port:$port,
              users:[{uuid:$uuid, flow:"xtls-rprx-vision"}],
              tls:{enabled:true, server_name:$sni,
                reality:{enabled:true,
                  handshake:{server:$sni, server_port:443},
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
        jq -n --arg tag "$remark" --arg srv "$(ip_for_url "$ip")" --argjson port "$port" \
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
    tag="anytls-${port}"
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

menu_add_ddns() {
    if [[ ! -r "$CF_DDNS_CONF" ]]; then
        err "尚未配置 Cloudflare DDNS，请先在主菜单进入 d → 1"
        pause; return
    fi

    migrate_cf_ddns_split_config || { err "DDNS 配置迁移失败"; pause; return; }
    local count i=0 c idx name type hostname family
    count=$(jq '(.records // []) | length' "$CF_DDNS_CONF")
    (( count > 0 )) || { err "暂无 DDNS 配置，请先在 DDNS 菜单新增"; pause; return; }
    clear; show_banner
    sec "DDNS 域名 → 选择配置"
    while IFS=$'\t' read -r name type hostname; do
        i=$((i+1))
        printf "  %d) %-18s %-5s %s\n" "$i" "$name" "$type" "$hostname"
    done < <(jq -r '.records[] | [.name,.type,.hostname] | @tsv' "$CF_DDNS_CONF")
    echo "  0) 返回上一页"
    hr
    read -rp "$(echo -e "${CYAN}请选择 [0-${count}]: ${NC}")" c
    [[ "$c" == "0" || -z "$c" ]] && return
    [[ "$c" =~ ^[0-9]+$ ]] && (( c>=1 && c<=count )) || { err "无效选择"; sleep 1; return; }
    idx=$((c-1))
    type=$(jq -r ".records[$idx].type" "$CF_DDNS_CONF")
    hostname=$(jq -r ".records[$idx].hostname" "$CF_DDNS_CONF")
    [[ "$type" == "AAAA" ]] && family=6 || family=4
    menu_new_proto "$family" "ddns" "$hostname"
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
        while IFS=$'\t' read -r tag remark proto port family link; do
            i=$((i+1))
            echo -e "${BOLD}[${i}] ${remark}${NC} ${YELLOW}(${tag})${NC}"
            echo -e "    协议: ${proto}    端口: ${port}    IPv${family}"
            echo -e "    ${GREEN}${link}${NC}"
            echo
        done < <(jq -r '.[] | [.tag, .remark, .protocol, .port, .family, .link] | @tsv' "$SB_NODES")
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
        local tmp; tmp=$(mktemp)
        jq "del(.[${idx}])" "$SB_NODES" > "$tmp" && mv "$tmp" "$SB_NODES"
        rebuild_config
        restart_sb
        ok "已删除 ${remark}"
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
        echo -e "  链接: ${GREEN}${link}${NC}"
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
    local idx="$1"
    local old new
    old=$(jq -r ".[${idx}].remark" "$SB_NODES")
    read -rp "$(echo -e "${CYAN}请输入新备注 (当前: ${old}): ${NC}")" new
    [[ -z "$new" ]] && return
    local tmp; tmp=$(mktemp)
    jq --arg r "$new" ".[${idx}].remark = \$r" "$SB_NODES" > "$tmp" && mv "$tmp" "$SB_NODES"
    local link new_link
    link=$(jq -r ".[${idx}].link" "$SB_NODES")
    new_link="${link%#*}#$(urlencode "$new")"
    tmp=$(mktemp)
    jq --arg l "$new_link" ".[${idx}].link = \$l" "$SB_NODES" > "$tmp" && mv "$tmp" "$SB_NODES"
    ok "备注已更新"
    sleep 1
}

modify_port() {
    local idx="$1"
    local old new
    old=$(jq -r ".[${idx}].port" "$SB_NODES")
    new=$(ask_port_exclude "请输入新端口 (当前 ${old})" "$old" "$old") || { pause; return; }

    # 更新 port 和 inbound.listen_port
    local tmp; tmp=$(mktemp)
    jq --argjson p "$new" \
       ".[${idx}].port = \$p | .[${idx}].extra.inbound.listen_port = \$p" \
       "$SB_NODES" > "$tmp" && mv "$tmp" "$SB_NODES"

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

    tmp=$(mktemp)
    jq --arg l "$new_link" ".[${idx}].link = \$l" "$SB_NODES" > "$tmp" && mv "$tmp" "$SB_NODES"
    rebuild_config
    restart_sb
    ok "端口已改为 ${new}"
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
        4) ob_hysteria2 ;;
        5) ob_tuic ;;
        6) ob_trojan ;;
        7) ob_anytls ;;
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
            err "备注只能包含字母/数字/下划线/连字符"
            continue
        fi
        if [[ "$tag" =~ ^(direct|block|ipv4-out|ipv6-out)$ ]]; then
            err "备注名与内置出口冲突"
            continue
        fi
        if jq -e --arg t "$tag" '.[] | select(.tag == $t)' "$SB_OUTBOUNDS" >/dev/null 2>&1; then
            err "出口 ${tag} 已存在"
            continue
        fi
        echo "$tag"
        return 0
    done
}

# 公共：保存出站
save_outbound() {
    local tag="$1" proto="$2" outbound="$3"
    local tmp; tmp=$(mktemp)
    jq --arg tag "$tag" --arg proto "$proto" --argjson ob "$outbound" \
       '. += [{tag:$tag, protocol:$proto, outbound:$ob}]' \
       "$SB_OUTBOUNDS" > "$tmp" && mv "$tmp" "$SB_OUTBOUNDS"
    rebuild_config
    if restart_sb; then
        ok "已添加出口: ${tag}"
    else
        err "添加失败，已回滚"
        tmp=$(mktemp)
        jq 'del(.[-1])' "$SB_OUTBOUNDS" > "$tmp" && mv "$tmp" "$SB_OUTBOUNDS"
        rebuild_config
        restart_sb
    fi
    pause
}

# ---------- Shadowsocks ----------
ob_shadowsocks() {
    local tag; tag=$(ask_ob_tag "Shadowsocks-Out")
    local server port pwd
    read -rp "$(echo -e "${CYAN}请输入服务器 IP/域名: ${NC}")" server
    [[ -z "$server" ]] && { err "不能为空"; pause; return; }
    read -rp "$(echo -e "${CYAN}请输入端口: ${NC}")" port
    [[ ! "$port" =~ ^[0-9]+$ ]] && { err "端口无效"; pause; return; }
    read -rp "$(echo -e "${CYAN}请输入密码: ${NC}")" pwd
    [[ -z "$pwd" ]] && { err "密码不能为空"; pause; return; }

    echo
    echo "请选择加密方式:"
    echo "  1. aes-128-gcm"
    echo "  2. aes-256-gcm"
    echo "  3. chacha20-ietf-poly1305"
    echo "  4. xchacha20-ietf-poly1305"
    echo "  5. 2022-blake3-aes-128-gcm"
    echo "  6. 2022-blake3-aes-256-gcm"
    echo "  7. 2022-blake3-chacha20-poly1305"
    echo "  0. 返回"
    local mc method
    read -rp "$(echo -e "${CYAN}请选择 [0-7]: ${NC}")" mc
    case "$mc" in
        1) method="aes-128-gcm" ;;
        2) method="aes-256-gcm" ;;
        3) method="chacha20-ietf-poly1305" ;;
        4) method="xchacha20-ietf-poly1305" ;;
        5) method="2022-blake3-aes-128-gcm" ;;
        6) method="2022-blake3-aes-256-gcm" ;;
        7) method="2022-blake3-chacha20-poly1305" ;;
        0|"") return ;;
        *) err "无效"; pause; return ;;
    esac

    local outbound
    outbound=$(jq -n --arg tag "$tag" --arg s "$server" --argjson p "$port" \
        --arg m "$method" --arg pw "$pwd" \
        '{type:"shadowsocks", tag:$tag, server:$s, server_port:$p, method:$m, password:$pw}')
    save_outbound "$tag" "shadowsocks" "$outbound"
}

# ---------- VLESS Reality ----------
ob_vless_reality() {
    local tag; tag=$(ask_ob_tag "Reality-Out")
    local server port uuid sni pbk sid fp
    read -rp "$(echo -e "${CYAN}请输入服务器 IP/域名: ${NC}")" server
    [[ -z "$server" ]] && { err "不能为空"; pause; return; }
    read -rp "$(echo -e "${CYAN}请输入端口: ${NC}")" port
    [[ ! "$port" =~ ^[0-9]+$ ]] && { err "端口无效"; pause; return; }
    read -rp "$(echo -e "${CYAN}请输入 UUID: ${NC}")" uuid
    [[ -z "$uuid" ]] && { err "UUID 不能为空"; pause; return; }
    read -rp "$(echo -e "${CYAN}请输入 SNI: ${NC}")" sni
    [[ -z "$sni" ]] && { err "SNI 不能为空"; pause; return; }
    read -rp "$(echo -e "${CYAN}请输入 Reality public_key (pbk): ${NC}")" pbk
    [[ -z "$pbk" ]] && { err "pbk 不能为空"; pause; return; }
    read -rp "$(echo -e "${CYAN}请输入 short_id (sid): ${NC}")" sid
    read -rp "$(echo -e "${CYAN}请输入指纹 fingerprint (回车默认 chrome): ${NC}")" fp
    fp="${fp:-chrome}"

    local outbound
    outbound=$(jq -n --arg tag "$tag" --arg s "$server" --argjson p "$port" \
        --arg u "$uuid" --arg sni "$sni" --arg pbk "$pbk" --arg sid "$sid" --arg fp "$fp" \
        '{type:"vless", tag:$tag, server:$s, server_port:$p, uuid:$u, flow:"xtls-rprx-vision",
          tls:{enabled:true, server_name:$sni,
            utls:{enabled:true, fingerprint:$fp},
            reality:{enabled:true, public_key:$pbk, short_id:$sid}}}')
    save_outbound "$tag" "vless-reality" "$outbound"
}

# ---------- VLESS WS TLS ----------
ob_vless_ws_tls() {
    local tag; tag=$(ask_ob_tag "VLESS-WS-Out")
    local server port uuid sni path host
    read -rp "$(echo -e "${CYAN}请输入服务器 IP/域名: ${NC}")" server
    [[ -z "$server" ]] && { err "不能为空"; pause; return; }
    read -rp "$(echo -e "${CYAN}请输入端口 (通常 443): ${NC}")" port
    [[ ! "$port" =~ ^[0-9]+$ ]] && { err "端口无效"; pause; return; }
    read -rp "$(echo -e "${CYAN}请输入 UUID: ${NC}")" uuid
    [[ -z "$uuid" ]] && { err "UUID 不能为空"; pause; return; }
    read -rp "$(echo -e "${CYAN}请输入 SNI: ${NC}")" sni
    [[ -z "$sni" ]] && { err "SNI 不能为空"; pause; return; }
    read -rp "$(echo -e "${CYAN}请输入 WS path (回车默认 /): ${NC}")" path
    path="${path:-/}"
    read -rp "$(echo -e "${CYAN}请输入 WS Host (回车默认与 SNI 相同): ${NC}")" host
    host="${host:-$sni}"

    local outbound
    outbound=$(jq -n --arg tag "$tag" --arg s "$server" --argjson p "$port" \
        --arg u "$uuid" --arg sni "$sni" --arg path "$path" --arg host "$host" \
        '{type:"vless", tag:$tag, server:$s, server_port:$p, uuid:$u,
          tls:{enabled:true, server_name:$sni},
          transport:{type:"ws", path:$path, headers:{Host:$host}}}')
    save_outbound "$tag" "vless-ws-tls" "$outbound"
}

# ---------- Hysteria2 ----------
ob_hysteria2() {
    local tag; tag=$(ask_ob_tag "Hysteria2-Out")
    local server port pwd sni insec
    read -rp "$(echo -e "${CYAN}请输入服务器 IP/域名: ${NC}")" server
    [[ -z "$server" ]] && { err "不能为空"; pause; return; }
    read -rp "$(echo -e "${CYAN}请输入端口: ${NC}")" port
    [[ ! "$port" =~ ^[0-9]+$ ]] && { err "端口无效"; pause; return; }
    read -rp "$(echo -e "${CYAN}请输入密码: ${NC}")" pwd
    [[ -z "$pwd" ]] && { err "密码不能为空"; pause; return; }
    read -rp "$(echo -e "${CYAN}请输入 SNI: ${NC}")" sni
    [[ -z "$sni" ]] && { err "SNI 不能为空"; pause; return; }
    read -rp "$(echo -e "${CYAN}跳过证书验证? [y/N]: ${NC}")" insec
    local insec_bool=false
    [[ "$insec" =~ ^[Yy]$ ]] && insec_bool=true

    local outbound
    outbound=$(jq -n --arg tag "$tag" --arg s "$server" --argjson p "$port" \
        --arg pw "$pwd" --arg sni "$sni" --argjson insec "$insec_bool" \
        '{type:"hysteria2", tag:$tag, server:$s, server_port:$p, password:$pw,
          tls:{enabled:true, server_name:$sni, insecure:$insec}}')
    save_outbound "$tag" "hysteria2" "$outbound"
}

# ---------- TUIC v5 ----------
ob_tuic() {
    local tag; tag=$(ask_ob_tag "TUIC-Out")
    local server port uuid pwd sni insec
    read -rp "$(echo -e "${CYAN}请输入服务器 IP/域名: ${NC}")" server
    [[ -z "$server" ]] && { err "不能为空"; pause; return; }
    read -rp "$(echo -e "${CYAN}请输入端口: ${NC}")" port
    [[ ! "$port" =~ ^[0-9]+$ ]] && { err "端口无效"; pause; return; }
    read -rp "$(echo -e "${CYAN}请输入 UUID: ${NC}")" uuid
    [[ -z "$uuid" ]] && { err "UUID 不能为空"; pause; return; }
    read -rp "$(echo -e "${CYAN}请输入密码: ${NC}")" pwd
    [[ -z "$pwd" ]] && { err "密码不能为空"; pause; return; }
    read -rp "$(echo -e "${CYAN}请输入 SNI: ${NC}")" sni
    [[ -z "$sni" ]] && { err "SNI 不能为空"; pause; return; }
    read -rp "$(echo -e "${CYAN}跳过证书验证? [y/N]: ${NC}")" insec
    local insec_bool=false
    [[ "$insec" =~ ^[Yy]$ ]] && insec_bool=true

    local outbound
    outbound=$(jq -n --arg tag "$tag" --arg s "$server" --argjson p "$port" \
        --arg u "$uuid" --arg pw "$pwd" --arg sni "$sni" --argjson insec "$insec_bool" \
        '{type:"tuic", tag:$tag, server:$s, server_port:$p, uuid:$u, password:$pw,
          congestion_control:"bbr",
          tls:{enabled:true, server_name:$sni, insecure:$insec, alpn:["h3"]}}')
    save_outbound "$tag" "tuic" "$outbound"
}

# ---------- Trojan ----------
ob_trojan() {
    local tag; tag=$(ask_ob_tag "Trojan-Out")
    local server port pwd sni insec
    read -rp "$(echo -e "${CYAN}请输入服务器 IP/域名: ${NC}")" server
    [[ -z "$server" ]] && { err "不能为空"; pause; return; }
    read -rp "$(echo -e "${CYAN}请输入端口 (通常 443): ${NC}")" port
    [[ ! "$port" =~ ^[0-9]+$ ]] && { err "端口无效"; pause; return; }
    read -rp "$(echo -e "${CYAN}请输入密码: ${NC}")" pwd
    [[ -z "$pwd" ]] && { err "密码不能为空"; pause; return; }
    read -rp "$(echo -e "${CYAN}请输入 SNI: ${NC}")" sni
    [[ -z "$sni" ]] && { err "SNI 不能为空"; pause; return; }
    read -rp "$(echo -e "${CYAN}跳过证书验证? [y/N]: ${NC}")" insec
    local insec_bool=false
    [[ "$insec" =~ ^[Yy]$ ]] && insec_bool=true

    local outbound
    outbound=$(jq -n --arg tag "$tag" --arg s "$server" --argjson p "$port" \
        --arg pw "$pwd" --arg sni "$sni" --argjson insec "$insec_bool" \
        '{type:"trojan", tag:$tag, server:$s, server_port:$p, password:$pw,
          tls:{enabled:true, server_name:$sni, insecure:$insec}}')
    save_outbound "$tag" "trojan" "$outbound"
}

# ---------- AnyTLS ----------
ob_anytls() {
    local tag; tag=$(ask_ob_tag "AnyTLS-Out")
    local server port pwd sni insec
    read -rp "$(echo -e "${CYAN}请输入服务器 IP/域名: ${NC}")" server
    [[ -z "$server" ]] && { err "不能为空"; pause; return; }
    read -rp "$(echo -e "${CYAN}请输入端口: ${NC}")" port
    [[ ! "$port" =~ ^[0-9]+$ ]] && { err "端口无效"; pause; return; }
    read -rp "$(echo -e "${CYAN}请输入密码: ${NC}")" pwd
    [[ -z "$pwd" ]] && { err "密码不能为空"; pause; return; }
    read -rp "$(echo -e "${CYAN}请输入 SNI: ${NC}")" sni
    [[ -z "$sni" ]] && { err "SNI 不能为空"; pause; return; }
    read -rp "$(echo -e "${CYAN}跳过证书验证? [y/N]: ${NC}")" insec
    local insec_bool=false
    [[ "$insec" =~ ^[Yy]$ ]] && insec_bool=true

    local outbound
    outbound=$(jq -n --arg tag "$tag" --arg s "$server" --argjson p "$port" \
        --arg pw "$pwd" --arg sni "$sni" --argjson insec "$insec_bool" \
        '{type:"anytls", tag:$tag, server:$s, server_port:$p, password:$pw,
          tls:{enabled:true, server_name:$sni, insecure:$insec}}')
    save_outbound "$tag" "anytls" "$outbound"
}

# ---------- Socks5 ----------
ob_socks5() {
    local tag; tag=$(ask_ob_tag "Socks5-Out")
    local server port user pwd
    read -rp "$(echo -e "${CYAN}请输入服务器 IP/域名: ${NC}")" server
    [[ -z "$server" ]] && { err "不能为空"; pause; return; }
    read -rp "$(echo -e "${CYAN}请输入端口: ${NC}")" port
    [[ ! "$port" =~ ^[0-9]+$ ]] && { err "端口无效"; pause; return; }
    read -rp "$(echo -e "${CYAN}请输入用户名 (无认证则回车): ${NC}")" user
    read -rp "$(echo -e "${CYAN}请输入密码 (无认证则回车): ${NC}")" pwd

    local outbound
    if [[ -n "$user" ]]; then
        outbound=$(jq -n --arg tag "$tag" --arg s "$server" --argjson p "$port" \
            --arg u "$user" --arg pw "$pwd" \
            '{type:"socks", tag:$tag, server:$s, server_port:$p, version:"5", username:$u, password:$pw}')
    else
        outbound=$(jq -n --arg tag "$tag" --arg s "$server" --argjson p "$port" \
            '{type:"socks", tag:$tag, server:$s, server_port:$p, version:"5"}')
    fi
    save_outbound "$tag" "socks5" "$outbound"
}

# ---------- 添加分流规则 ----------
add_rule() {
    clear; show_banner
    sub "添加分流规则"
    echo

    read -rp "$(echo -e "${CYAN}请输入目标域名 (多个用逗号分隔，支持 geosite:xxx): ${NC}")" rules_input
    [[ -z "$rules_input" ]] && return

    local geosite_arr="[]" domain_arr="[]"
    local IFS=','
    local item
    for item in $rules_input; do
        item="${item// /}"
        [[ -z "$item" ]] && continue
        if [[ "$item" == geosite:* ]]; then
            local name="${item#geosite:}"
            geosite_arr=$(echo "$geosite_arr" | jq --arg n "$name" '. + [$n]')
        else
            # 当作域名后缀处理
            domain_arr=$(echo "$domain_arr" | jq --arg n "$item" '. + [$n]')
        fi
    done
    unset IFS

    if [[ "$(echo "$geosite_arr" | jq 'length')" == "0" && "$(echo "$domain_arr" | jq 'length')" == "0" ]]; then
        err "没有有效规则"; pause; return
    fi

    echo
    echo -e "${CYAN}请选择流量去向 (Target Outbound):${NC}"
    echo "  1. direct          (内置-直连)"
    echo "  2. block           (内置-屏蔽)"
    echo "  3. ipv4-out        (内置-IPv4 直连)"
    echo "  4. ipv6-out        (内置-IPv6 直连)"
    local outs=(direct block ipv4-out ipv6-out)
    local i=4
    while IFS=$'\t' read -r tag proto; do
        i=$((i+1))
        printf "  %d. %-22s (%s)\n" "$i" "$tag" "$proto"
        outs+=("$tag")
    done < <(jq -r '.[] | [.tag, .protocol] | @tsv' "$SB_OUTBOUNDS")
    hr
    local c
    read -rp "$(echo -e "${CYAN}请选择 [1-${i}]: ${NC}")" c
    if ! [[ "$c" =~ ^[0-9]+$ ]] || (( c < 1 || c > i )); then
        err "无效"; pause; return
    fi
    local out_tag="${outs[$((c-1))]}"

    local tmp; tmp=$(mktemp)
    jq --argjson gs "$geosite_arr" --argjson dm "$domain_arr" --arg out "$out_tag" \
       '. += [{geosite:$gs, domain:$dm, outbound:$out}]' \
       "$SB_RULES" > "$tmp" && mv "$tmp" "$SB_RULES"

    rebuild_config
    if restart_sb; then
        local desc=""
        if [[ "$(echo "$geosite_arr" | jq 'length')" -gt 0 ]]; then
            desc+="geosite:$(echo "$geosite_arr" | jq -r 'join(",geosite:")')"
        fi
        if [[ "$(echo "$domain_arr" | jq 'length')" -gt 0 ]]; then
            [[ -n "$desc" ]] && desc+=","
            desc+="$(echo "$domain_arr" | jq -r 'join(",")')"
        fi
        ok "已添加规则: [${desc}] -> [${out_tag}]"
    else
        tmp=$(mktemp)
        jq 'del(.[-1])' "$SB_RULES" > "$tmp" && mv "$tmp" "$SB_RULES"
        rebuild_config; restart_sb
    fi
    pause
}

# ---------- 屏蔽/恢复 大陆 ----------
toggle_block_cn() {
    clear; show_banner
    sec "屏蔽 / 恢复 大陆"
    local cur; cur=$(jq -r '.block_cn' "$SB_SETTINGS")
    if [[ "$cur" == "true" ]]; then
        echo -e "当前状态: ${RED}已屏蔽${NC}"
        echo "  1) 恢复大陆流量"
    else
        echo -e "当前状态: ${GREEN}未屏蔽${NC}"
        echo "  1) 屏蔽大陆流量"
    fi
    echo "  0) 返回"
    hr
    local c
    read -rp "$(echo -e "${CYAN}请选择 [0-1]: ${NC}")" c
    [[ "$c" != "1" ]] && return
    local new_val
    [[ "$cur" == "true" ]] && new_val=false || new_val=true
    local tmp; tmp=$(mktemp)
    jq --argjson v "$new_val" '.block_cn = $v' "$SB_SETTINGS" > "$tmp" && mv "$tmp" "$SB_SETTINGS"
    rebuild_config
    restart_sb || return
    [[ "$new_val" == "true" ]] && ok "已屏蔽大陆" || ok "已恢复大陆"
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
    local rn; rn=$(jq 'length' "$SB_RULES")
    if (( rn == 0 )); then warn "无规则"; sleep 1; return; fi
    read -rp "$(echo -e "${CYAN}输入要删除的规则序号 [1-${rn}]: ${NC}")" c
    if ! [[ "$c" =~ ^[0-9]+$ ]] || (( c < 1 || c > rn )); then
        err "无效"; sleep 1; return
    fi
    local idx=$((c-1))
    local tmp; tmp=$(mktemp)
    jq "del(.[${idx}])" "$SB_RULES" > "$tmp" && mv "$tmp" "$SB_RULES"
    rebuild_config; restart_sb
    ok "规则已删除"; sleep 1
}

del_outbound_by_index() {
    local on; on=$(jq 'length' "$SB_OUTBOUNDS")
    if (( on == 0 )); then warn "无自定义出口"; sleep 1; return; fi
    read -rp "$(echo -e "${CYAN}输入要删除的出口序号 (例如 N5): ${NC}")" c
    c="${c#N}"; c="${c#n}"
    if ! [[ "$c" =~ ^[0-9]+$ ]]; then err "无效"; sleep 1; return; fi
    local idx=$((c - 5))
    if (( idx < 0 || idx >= on )); then err "无效序号"; sleep 1; return; fi
    local tag; tag=$(jq -r ".[${idx}].tag" "$SB_OUTBOUNDS")
    if jq -e --arg t "$tag" '.[] | select(.outbound == $t)' "$SB_RULES" >/dev/null; then
        err "出口 ${tag} 被分流规则引用，请先删除相关规则"
        sleep 2; return
    fi
    read -rp "$(echo -e "${YELLOW}确定删除出口 ${tag}? [y/N]: ${NC}")" y
    [[ "$y" =~ ^[Yy]$ ]] || return
    local tmp; tmp=$(mktemp)
    jq "del(.[${idx}])" "$SB_OUTBOUNDS" > "$tmp" && mv "$tmp" "$SB_OUTBOUNDS"
    rebuild_config; restart_sb
    ok "出口已删除"; sleep 1
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
            3) toggle_block_cn ;;
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
    if [[ "$hostport" == \[*\]:* ]]; then
        host="${hostport%]:*}"; host="${host#[}"; port="${hostport##*:}"
    else
        host="${hostport%:*}"; port="${hostport##*:}"
    fi
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
    local ob="$1"
    local proto tag
    proto=$(echo "$ob" | jq -r '.proto')
    tag=$(echo "$ob" | jq -r '.tag')
    case "$proto" in
        vless-reality)
            echo "$ob" | jq '{
                type:"vless", tag:.tag, server:.server, server_port:.port, uuid:.uuid,
                tls:{enabled:true, server_name:.sni,
                     utls:{enabled:true, fingerprint:(.fp // "chrome")},
                     reality:{enabled:true, public_key:.pbk, short_id:.sid}}
            } | if ((.flow|not) or (.flow=="")) then . else . end' \
            | jq --argjson src "$ob" 'if (($src.flow // "")|length)>0 then .flow=$src.flow else . end'
            ;;
        ss|ss2022)
            echo "$ob" | jq '{
                type:"shadowsocks", tag:.tag, server:.server, server_port:.port,
                method:.method, password:.password
            }'
            ;;
        anytls)
            echo "$ob" | jq '{
                type:"anytls", tag:.tag, server:.server, server_port:.port,
                password:.password,
                tls:{enabled:true, server_name:.sni, insecure:(.insecure // false)}
            }'
            ;;
        *)
            err "未知协议: $proto" >&2; return 1 ;;
    esac
}

# ---- 由元信息生成 client.json ----
rebuild_client_config() {
    [[ -f "$SB_CLIENT_META" ]] || { err "无客户端配置元信息"; return 1; }

    local sport final dl_detour
    sport=$(jq -r '.socks_port' "$SB_CLIENT_META")
    final=$(jq -r '.final' "$SB_CLIENT_META")
    dl_detour=$(jq -r '.download_detour // "direct"' "$SB_CLIENT_META")

    # 1) 生成所有出口的 sing-box outbound
    local proxy_obs="[]"
    local n i
    n=$(jq '.outbounds | length' "$SB_CLIENT_META")
    for (( i=0; i<n; i++ )); do
        local ob sb_ob
        ob=$(jq -c ".outbounds[$i]" "$SB_CLIENT_META")
        sb_ob=$(client_ob_to_singbox "$ob") || return 1
        proxy_obs=$(echo "$proxy_obs" | jq --argjson o "$sb_ob" '. + [$o]')
    done
    # 追加内置 direct/block
    local all_obs
    all_obs=$(echo "$proxy_obs" | jq '. + [{type:"direct",tag:"direct"},{type:"block",tag:"block"}]')

    # 2) 收集用到的 geosite,生成 rule_set 定义(remote .srs)
    local used_geosite
    used_geosite=$(jq -r '[.rules[].geosite[]?] | unique | .[]' "$SB_CLIENT_META")
    local rule_sets="[]"
    if [[ -n "$used_geosite" ]]; then
        local rs="[" first=1 name url
        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            url="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-${name}.srs"
            [[ $first -eq 0 ]] && rs+=","
            rs+="{\"type\":\"remote\",\"tag\":\"geosite-${name}\",\"format\":\"binary\",\"url\":\"${url}\",\"download_detour\":\"${dl_detour}\"}"
            first=0
        done <<< "$used_geosite"
        rs+="]"
        rule_sets="$rs"
    fi

    # 3) 生成 route.rules:每条规则 -> {domain_suffix?/rule_set?, outbound, action:route}
    local route_rules
    route_rules=$(jq '[.rules[] |
        (if (.geosite|length)>0 then {rule_set:[(.geosite[] | "geosite-\(.)")]} else {} end) +
        (if (.domain|length)>0 then {domain_suffix:.domain} else {} end) +
        {outbound:.outbound, action:"route"}
        | select((has("rule_set")) or (has("domain_suffix")))
    ]' "$SB_CLIENT_META")

    # DNS(resolve 需要;这里给 local 即可)
    local dns; dns=$(jq -n '{servers:[{type:"local", tag:"local"}]}')

    jq -n \
        --argjson sport "$sport" \
        --argjson obs "$all_obs" \
        --argjson rsets "$rule_sets" \
        --argjson rules "$route_rules" \
        --arg final "$final" \
        --argjson dns "$dns" \
        --arg log "$SB_CLIENT_LOG" \
        '{
            log:{level:"warn", output:$log, timestamp:true},
            dns:$dns,
            inbounds:[{type:"mixed", tag:"mixed-in", listen:"127.0.0.1", listen_port:$sport}],
            outbounds:$obs,
            route:{rule_set:$rsets, rules:$rules, final:$final, auto_detect_interface:true}
        }' > "$SB_CLIENT_CONF"
}

restart_client() {
    # 确保 systemd 服务单元存在（首次添加出口时可能尚未创建）
    [[ -f "$SB_CLIENT_SERVICE" ]] || setup_client_service
    if ! "$SB_BIN" check -c "$SB_CLIENT_CONF" 2>/tmp/sb_client_check.err; then
        err "客户端配置校验失败:"
        cat /tmp/sb_client_check.err
        return 1
    fi
    systemctl enable sing-box-client >/dev/null 2>&1
    systemctl restart sing-box-client
    sleep 1
    if systemctl is-active --quiet sing-box-client; then
        ok "客户端代理已启动"
        return 0
    else
        err "客户端启动失败:"
        journalctl -u sing-box-client -n 10 --no-pager | tail -n 10
        return 1
    fi
}

# ---- 分协议录入(输出含 proto 的 node json，不含 tag) ----
_ask_server_port() {
    local _s _p
    read -rp "$(echo -e "${CYAN}落地服务器地址 (IP 或域名): ${NC}")" _s
    [[ -z "$_s" ]] && { err "地址不能为空" >&2; return 1; }
    read -rp "$(echo -e "${CYAN}端口: ${NC}")" _p
    [[ "$_p" =~ ^[0-9]+$ ]] && (( _p>=1 && _p<=65535 )) || { err "端口非法" >&2; return 1; }
    echo "${_s}|${_p}"
}

client_node_vless() {
    local node_json="" link=""
    echo "  录入方式:" >&2
    echo "    1) 粘贴 vless:// 链接" >&2
    echo "    2) 手动逐项填写" >&2
    echo "    0) 返回" >&2
    local src; read -rp "$(echo -e "${CYAN}请选择: ${NC}")" src
    case "$src" in
        1)
            read -rp "$(echo -e "${CYAN}粘贴 vless:// 链接: ${NC}")" link
            [[ "$link" == vless://* ]] || { err "不是有效的 vless 链接" >&2; return 1; }
            node_json=$(parse_vless_link "$link")
            ;;
        2)
            local sp server port uuid sni pbk sid flow fp
            sp=$(_ask_server_port) || return 1
            server="${sp%|*}"; port="${sp#*|}"
            read -rp "$(echo -e "${CYAN}UUID: ${NC}")" uuid
            read -rp "$(echo -e "${CYAN}SNI (server_name): ${NC}")" sni
            read -rp "$(echo -e "${CYAN}public_key (pbk): ${NC}")" pbk
            read -rp "$(echo -e "${CYAN}short_id (sid, 可空): ${NC}")" sid
            read -rp "$(echo -e "${CYAN}flow (一般 xtls-rprx-vision, 可空): ${NC}")" flow
            read -rp "$(echo -e "${CYAN}指纹 fp [默认 chrome]: ${NC}")" fp; fp="${fp:-chrome}"
            node_json=$(jq -n --arg server "$server" --argjson port "$port" --arg uuid "$uuid" \
                --arg sni "$sni" --arg pbk "$pbk" --arg sid "$sid" --arg flow "$flow" --arg fp "$fp" \
                '{server:$server, port:$port, uuid:$uuid, sni:$sni, pbk:$pbk, sid:$sid, flow:$flow, fp:$fp}')
            ;;
        0|"") return 1 ;;
        *) err "无效选择" >&2; return 1 ;;
    esac
    [[ -z "$node_json" ]] && { err "解析失败" >&2; return 1; }
    local pbk; pbk=$(echo "$node_json" | jq -r '.pbk // empty')
    [[ -z "$pbk" || "$pbk" == "null" ]] && { err "缺少 public_key(pbk)" >&2; return 1; }
    echo "$node_json" | jq '. + {proto:"vless-reality"}'
}

client_node_ss() {
    local is2022="$1"
    local sp server port method pwd
    sp=$(_ask_server_port) || return 1
    server="${sp%|*}"; port="${sp#*|}"
    echo "  加密方式:" >&2
    if [[ "$is2022" == "1" ]]; then
        echo "    1) 2022-blake3-aes-128-gcm" >&2
        echo "    2) 2022-blake3-aes-256-gcm" >&2
        echo "    3) 2022-blake3-chacha20-poly1305" >&2
        local m; read -rp "$(echo -e "${CYAN}选择 [1-3]: ${NC}")" m
        case "$m" in
            1) method="2022-blake3-aes-128-gcm" ;;
            2) method="2022-blake3-aes-256-gcm" ;;
            3) method="2022-blake3-chacha20-poly1305" ;;
            *) err "无效" >&2; return 1 ;;
        esac
    else
        echo "    1) aes-128-gcm" >&2
        echo "    2) aes-256-gcm" >&2
        echo "    3) chacha20-ietf-poly1305" >&2
        echo "    4) xchacha20-ietf-poly1305" >&2
        local m; read -rp "$(echo -e "${CYAN}选择 [1-4]: ${NC}")" m
        case "$m" in
            1) method="aes-128-gcm" ;;
            2) method="aes-256-gcm" ;;
            3) method="chacha20-ietf-poly1305" ;;
            4) method="xchacha20-ietf-poly1305" ;;
            *) err "无效" >&2; return 1 ;;
        esac
    fi
    read -rp "$(echo -e "${CYAN}密码 (password / SS2022 base64 密钥): ${NC}")" pwd
    [[ -z "$pwd" ]] && { err "密码不能为空" >&2; return 1; }
    local proto; [[ "$is2022" == "1" ]] && proto="ss2022" || proto="ss"
    jq -n --arg server "$server" --argjson port "$port" \
        --arg method "$method" --arg password "$pwd" --arg proto "$proto" \
        '{proto:$proto, server:$server, port:$port, method:$method, password:$password}'
}

client_node_anytls() {
    local sp server port pwd sni insec
    sp=$(_ask_server_port) || return 1
    server="${sp%|*}"; port="${sp#*|}"
    read -rp "$(echo -e "${CYAN}密码 (password): ${NC}")" pwd
    [[ -z "$pwd" ]] && { err "密码不能为空" >&2; return 1; }
    read -rp "$(echo -e "${CYAN}SNI (server_name): ${NC}")" sni
    read -rp "$(echo -e "${CYAN}跳过证书验证? (自签填 y) [y/N]: ${NC}")" insec
    [[ "$insec" =~ ^[Yy]$ ]] && insec="true" || insec="false"
    jq -n --arg server "$server" --argjson port "$port" \
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
    local pc node=""
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

    # 取 tag(唯一)
    local tag
    while :; do
        read -rp "$(echo -e "${CYAN}给这个出口起个名字(tag,如 out-cc): ${NC}")" tag
        tag="${tag// /}"
        [[ -z "$tag" ]] && { err "不能为空"; continue; }
        [[ "$tag" == "direct" || "$tag" == "block" ]] && { err "tag 不能用保留字 direct/block"; continue; }
        if jq -e --arg t "$tag" '.outbounds[]|select(.tag==$t)' "$SB_CLIENT_META" >/dev/null 2>&1; then
            err "tag 已存在"; continue
        fi
        break
    done

    local tmp; tmp=$(mktemp)
    jq --argjson node "$node" --arg tag "$tag" \
        '.outbounds += [($node + {tag:$tag})]' "$SB_CLIENT_META" > "$tmp" && mv "$tmp" "$SB_CLIENT_META"
    rebuild_client_config && restart_client && ok "出口 ${tag} 已添加" || err "重载失败(请检查参数)"
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
    local tmp; tmp=$(mktemp)
    jq "del(.outbounds[$((idx-1))])" "$SB_CLIENT_META" > "$tmp" && mv "$tmp" "$SB_CLIENT_META"
    rebuild_client_config && restart_client && ok "已删除 ${tag}" || err "重载失败"
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
    local on; on=$(jq '.outbounds|length' "$SB_CLIENT_META")
    (( on==0 )) && { warn "请先在「出口管理」添加至少一个出口"; pause; return; }

    read -rp "$(echo -e "${CYAN}目标域名(多个逗号分隔,支持 geosite:xxx): ${NC}")" input
    [[ -z "$input" ]] && return
    local geo="[]" dom="[]"
    local IFS=',' item
    for item in $input; do
        item="${item// /}"; [[ -z "$item" ]] && continue
        if [[ "$item" == geosite:* ]]; then
            geo=$(echo "$geo" | jq --arg n "${item#geosite:}" '. + [$n]')
        else
            dom=$(echo "$dom" | jq --arg n "$item" '. + [$n]')
        fi
    done
    unset IFS
    [[ "$(echo "$geo" | jq 'length')" == "0" && "$(echo "$dom" | jq 'length')" == "0" ]] && { err "无有效规则"; pause; return; }

    echo
    echo -e "  ${CYAN}这些流量走哪个出口?${NC}"
    local tags=() i=0
    while IFS= read -r t; do
        i=$((i+1)); echo "    $i) $t"; tags+=("$t")
    done < <(jq -r '.outbounds[].tag' "$SB_CLIENT_META")
    hr
    local pick; read -rp "$(echo -e "${CYAN}选择出口编号: ${NC}")" pick
    [[ "$pick" =~ ^[0-9]+$ ]] && (( pick>=1 && pick<=i )) || { err "无效"; pause; return; }
    local out="${tags[$((pick-1))]}"

    local tmp; tmp=$(mktemp)
    jq --argjson geo "$geo" --argjson dom "$dom" --arg out "$out" \
        '.rules += [{domain:$dom, geosite:$geo, outbound:$out}]' "$SB_CLIENT_META" > "$tmp" && mv "$tmp" "$SB_CLIENT_META"
    rebuild_client_config && restart_client && ok "规则已添加 -> ${out}" || err "重载失败"
    pause
}

client_rule_del() {
    clear; show_banner
    sec "分流规则 → 删除规则"
    local n; n=$(jq '.rules|length' "$SB_CLIENT_META")
    (( n==0 )) && { warn "没有规则"; pause; return; }
    client_rule_list_inline
    hr
    local idx; read -rp "$(echo -e "${CYAN}输入要删除的编号: ${NC}")" idx
    [[ "$idx" =~ ^[0-9]+$ ]] && (( idx>=1 && idx<=n )) || { err "无效编号"; pause; return; }
    local tmp; tmp=$(mktemp)
    jq "del(.rules[$((idx-1))])" "$SB_CLIENT_META" > "$tmp" && mv "$tmp" "$SB_CLIENT_META"
    rebuild_client_config && restart_client && ok "已删除规则" || err "重载失败"
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
                local tmp; tmp=$(mktemp)
                jq --argjson p "$p" '.socks_port=$p' "$SB_CLIENT_META" > "$tmp" && mv "$tmp" "$SB_CLIENT_META"
                rebuild_client_config && restart_client && ok "端口已改为 ${p}" || err "失败"
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
                local tmp; tmp=$(mktemp)
                jq --arg f "$field" --arg v "$val" '.[$f]=$v' "$SB_CLIENT_META" > "$tmp" && mv "$tmp" "$SB_CLIENT_META"
                rebuild_client_config && restart_client && ok "${label} 已设为 ${val}" || err "失败"
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
    ALL_PROXY=socks5://127.0.0.1:${sport} \\
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
    echo -e "  ★ Claude API 可达性 (命中 anthropic 规则，走落地，用 http 入口):"
    local code
    code=$(curl -fsSL -m 12 -o /dev/null -w '%{http_code}' -x http://127.0.0.1:${sport} https://api.anthropic.com 2>/dev/null || echo 000)
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
# =============================================================================
cf_ddns_api() {
    local token="$1" method="$2" endpoint="$3" data="${4:-}"
    local body http_code
    body=$(mktemp)
    local -a args=(
        -sS -o "$body" -w '%{http_code}'
        -X "$method"
        -H "Authorization: Bearer ${token}"
        -H "Content-Type: application/json"
    )
    [[ -n "$data" ]] && args+=(--data "$data")

    if ! http_code=$(curl "${args[@]}" "https://api.cloudflare.com/client/v4${endpoint}"); then
        rm -f "$body"
        err "无法连接 Cloudflare API" >&2
        return 1
    fi
    if [[ ! "$http_code" =~ ^2 ]] || ! jq -e '.success == true' "$body" >/dev/null 2>&1; then
        err "Cloudflare API 请求失败 (HTTP ${http_code})" >&2
        jq -r '.errors[]? | "  [\(.code // "-")] \(.message // "未知错误")"' "$body" 2>/dev/null >&2
        rm -f "$body"
        return 1
    fi
    cat "$body"
    rm -f "$body"
}

install_cf_ddns_runner() {
    install -d -m 700 "$CF_DDNS_DIR"
    install -d -m 755 "$(dirname "$CF_DDNS_BIN")"
    cat > "$CF_DDNS_BIN" <<'CF_DDNS_RUNNER'
#!/usr/bin/env bash
set -o pipefail

CONF="/etc/sb-cloudflare-ddns/config.json"
API_BASE="https://api.cloudflare.com/client/v4"

log() { echo "[$(date '+%F %T')] $*"; }
fail() { log "错误: $*" >&2; exit 1; }

[[ -r "$CONF" ]] || fail "配置文件不存在: ${CONF}"
command -v curl >/dev/null 2>&1 || fail "缺少 curl"
command -v jq >/dev/null 2>&1 || fail "缺少 jq"
command -v flock >/dev/null 2>&1 || fail "缺少 flock (util-linux)"

TOKEN=$(jq -er '.api_token' "$CONF") || fail "配置中缺少 api_token"
ZONE_ID=$(jq -er '.zone_id' "$CONF") || fail "配置中缺少 zone_id"
BASE_FQDN=$(jq -er '.hostname' "$CONF") || fail "配置中缺少 hostname"
PROXIED=$(jq -r '.proxied // false' "$CONF")

split_hostname() {
    local hostname="$1" family="$2" first rest
    first="${hostname%%.*}"
    rest="${hostname#*.}"
    [[ "$family" == "6" ]] \
        && printf '%s6.%s\n' "$first" "$rest" \
        || printf '%s4.%s\n' "$first" "$rest"
}

HAS_A=$(jq -r '(.record_types | index("A") != null)' "$CONF")
HAS_AAAA=$(jq -r '(.record_types | index("AAAA") != null)' "$CONF")
FQDN4=$(jq -r '.hostname_v4 // empty' "$CONF")
FQDN6=$(jq -r '.hostname_v6 // empty' "$CONF")
if [[ "$HAS_A" == "true" && "$HAS_AAAA" == "true" ]]; then
    [[ -n "$FQDN4" ]] || FQDN4=$(split_hostname "$BASE_FQDN" 4)
    [[ -n "$FQDN6" ]] || FQDN6=$(split_hostname "$BASE_FQDN" 6)
else
    [[ -n "$FQDN4" ]] || FQDN4="$BASE_FQDN"
    [[ -n "$FQDN6" ]] || FQDN6="$BASE_FQDN"
fi

LOCK_DIR="/run/sb-cloudflare-ddns"
mkdir -p "$LOCK_DIR" || fail "无法创建锁目录: ${LOCK_DIR}"
chmod 700 "$LOCK_DIR" 2>/dev/null || true
exec 9>"${LOCK_DIR}/update.lock" || fail "无法创建更新锁"
flock -n 9 || { log "已有更新任务运行，跳过"; exit 0; }

api() {
    local method="$1" endpoint="$2" data="${3:-}"
    local body http_code
    body=$(mktemp)
    local -a args=(
        -sS -o "$body" -w '%{http_code}'
        -X "$method"
        -H "Authorization: Bearer ${TOKEN}"
        -H "Content-Type: application/json"
    )
    [[ -n "$data" ]] && args+=(--data "$data")
    if ! http_code=$(curl "${args[@]}" "${API_BASE}${endpoint}"); then
        rm -f "$body"
        return 1
    fi
    if [[ ! "$http_code" =~ ^2 ]] || ! jq -e '.success == true' "$body" >/dev/null 2>&1; then
        log "Cloudflare API 请求失败 (HTTP ${http_code})" >&2
        jq -r '.errors[]? | "[\(.code // "-")] \(.message // "未知错误")"' "$body" >&2
        rm -f "$body"
        return 1
    fi
    cat "$body"
    rm -f "$body"
}

public_ip() {
    local type="$1" ip=""
    if [[ "$type" == "A" ]]; then
        ip=$(curl -fsSL --max-time 10 -4 https://api.ipify.org 2>/dev/null) \
            || ip=$(curl -fsSL --max-time 10 -4 https://ifconfig.co/ip 2>/dev/null) \
            || return 1
        [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    else
        ip=$(curl -fsSL --max-time 10 -6 https://api64.ipify.org 2>/dev/null) \
            || ip=$(curl -fsSL --max-time 10 -6 https://ifconfig.co/ip 2>/dev/null) \
            || return 1
        [[ "$ip" == *:* ]] || return 1
    fi
    printf '%s' "$ip"
}

update_record() {
    local config_name="$1" type="$2" fqdn="$3" ip result count record_id old_ip old_proxied payload
    if ! ip=$(public_ip "$type"); then
        log "${config_name} (${type}): 未检测到可用公网地址，跳过"
        return 0
    fi

    result=$(api GET "/zones/${ZONE_ID}/dns_records?type=${type}&name=${fqdn}") \
        || return 1
    count=$(jq '.result | length' <<<"$result")
    if (( count > 1 )); then
        log "${config_name} (${type}): 找到多个同名记录，仅更新第一条"
    fi

    payload=$(jq -nc \
        --arg type "$type" --arg name "$fqdn" --arg content "$ip" \
        --argjson proxied "$PROXIED" \
        '{type:$type,name:$name,content:$content,ttl:1,proxied:$proxied}')

    if (( count == 0 )); then
        api POST "/zones/${ZONE_ID}/dns_records" "$payload" >/dev/null || return 1
        log "${config_name} (${type}): 已创建 ${fqdn} -> ${ip}"
        return 0
    fi

    record_id=$(jq -r '.result[0].id' <<<"$result")
    old_ip=$(jq -r '.result[0].content' <<<"$result")
    old_proxied=$(jq -r '.result[0].proxied // false' <<<"$result")
    if [[ "$old_ip" == "$ip" && "$old_proxied" == "$PROXIED" ]]; then
        log "${config_name} (${type}): 地址未变化 (${ip})"
        return 0
    fi

    api PUT "/zones/${ZONE_ID}/dns_records/${record_id}" "$payload" >/dev/null || return 1
    log "${config_name} (${type}): 已更新 ${old_ip} -> ${ip}"
}

status=0
while IFS=$'\t' read -r config_name type fqdn; do
    case "$type" in
        A|AAAA) update_record "$config_name" "$type" "$fqdn" || status=1 ;;
        *) log "忽略未知记录类型: ${type}" ;;
    esac
done < <(jq -r '
    if ((.records // []) | length) > 0 then
      .records[] | [.name,.type,.hostname] | @tsv
    else
      .record_types[] as $t |
      [if $t=="A" then "IPv4" else "IPv6" end,
       $t,
       if $t=="A" then $fqdn4 else $fqdn6 end] | @tsv
    end
' --arg fqdn4 "$FQDN4" --arg fqdn6 "$FQDN6" "$CONF")
exit "$status"
CF_DDNS_RUNNER
    chmod 700 "$CF_DDNS_BIN"
}

install_cf_ddns_units() {
    cat > "$CF_DDNS_SERVICE" <<EOF
[Unit]
Description=Cloudflare DDNS updater managed by sb
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=${CF_DDNS_BIN}
User=root
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
RuntimeDirectory=sb-cloudflare-ddns
RuntimeDirectoryMode=0700

[Install]
WantedBy=multi-user.target
EOF

    cat > "$CF_DDNS_TIMER" <<'EOF'
[Unit]
Description=Run Cloudflare DDNS updater every 5 minutes

[Timer]
OnBootSec=30s
OnUnitActiveSec=5min
RandomizedDelaySec=30s
Persistent=true
Unit=sb-cloudflare-ddns.service

[Install]
WantedBy=timers.target
EOF
    chmod 644 "$CF_DDNS_SERVICE" "$CF_DDNS_TIMER"
    systemctl daemon-reload
}

setup_cf_ddns() {
    local requested_family="${1:-}"
    clear; show_banner
    sec "配置 Cloudflare DDNS"
    echo -e "  ${YELLOW}Token 权限需要: Zone / DNS / Edit + Zone / Zone / Read${NC}"
    echo -e "  ${YELLOW}Token 只保存在本机 ${CF_DDNS_CONF} (权限 600)${NC}"
    hr

    local token hostname config_name zone_name verify zone_result zone_id mode proxied_answer proxied=false old_umask
    read -rsp "$(echo -e "${CYAN}Cloudflare API Token: ${NC}")" token
    echo
    [[ -n "$token" ]] || { err "Token 不能为空"; pause; return; }

    msg "验证 API Token..."
    verify=$(cf_ddns_api "$token" GET "/user/tokens/verify") || { pause; return; }
    [[ "$(jq -r '.result.status' <<<"$verify")" == "active" ]] \
        || { err "Token 当前不是 active 状态"; pause; return; }

    read -rp "$(echo -e "${CYAN}DDNS 完整域名 (如 kr.example.com): ${NC}")" hostname
    hostname="${hostname,,}"; hostname="${hostname%.}"
    if [[ ! "$hostname" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; then
        err "域名格式不正确"
        pause; return
    fi
    read -rp "$(echo -e "${CYAN}配置名称 (如 韩国 IPv4): ${NC}")" config_name
    config_name="${config_name:-${hostname%%.*}}"

    local default_zone
    default_zone=$(awk -F. '{print $(NF-1)"."$NF}' <<<"$hostname")
    read -rp "$(echo -e "${CYAN}Cloudflare Zone/根域名 [默认 ${default_zone}]: ${NC}")" zone_name
    zone_name="${zone_name:-$default_zone}"; zone_name="${zone_name,,}"; zone_name="${zone_name%.}"
    [[ "$hostname" == "$zone_name" || "$hostname" == *."$zone_name" ]] \
        || { err "DDNS 域名不属于 Zone ${zone_name}"; pause; return; }

    msg "查找 Cloudflare Zone..."
    zone_result=$(cf_ddns_api "$token" GET "/zones?name=${zone_name}&status=active&per_page=1") \
        || { pause; return; }
    zone_id=$(jq -r '.result[0].id // empty' <<<"$zone_result")
    [[ -n "$zone_id" ]] || { err "找不到 Zone，请检查根域名及 Token 权限"; pause; return; }

    if [[ "$requested_family" == "6" ]]; then
        mode=2
    elif [[ "$requested_family" == "4" ]]; then
        mode=1
    else
        echo
        echo "  1) IPv4 DDNS (仅 A)"
        echo "  2) IPv6 DDNS (仅 AAAA)"
        read -rp "$(echo -e "${CYAN}记录类型 [默认 1]: ${NC}")" mode
        mode="${mode:-1}"
    fi
    local record_types hostname_v4="" hostname_v6=""
    case "$mode" in
        1) record_types='["A"]'; hostname_v4="$hostname" ;;
        2) record_types='["AAAA"]'; hostname_v6="$hostname" ;;
        *) err "无效选择"; pause; return ;;
    esac

    read -rp "$(echo -e "${CYAN}启用 Cloudflare 代理(橙色云)? [y/N，节点请选 N]: ${NC}")" proxied_answer
    [[ "$proxied_answer" =~ ^[Yy]$ ]] && proxied=true

    install -d -m 700 "$CF_DDNS_DIR"
    old_umask=$(umask)
    umask 077
    if ! jq -n \
        --arg token "$token" --arg zone_id "$zone_id" --arg zone_name "$zone_name" \
        --arg hostname "$hostname" --arg hostname_v4 "$hostname_v4" --arg hostname_v6 "$hostname_v6" \
        --arg config_name "$config_name" --arg record_type "$( [[ "$mode" == "1" ]] && echo A || echo AAAA )" \
        --argjson record_types "$record_types" \
        --argjson proxied "$proxied" \
        '{api_token:$token,zone_id:$zone_id,zone_name:$zone_name,hostname:$hostname,
          hostname_v4:$hostname_v4,hostname_v6:$hostname_v6,
          records:[{name:$config_name,type:$record_type,hostname:$hostname}],
          record_types:$record_types,proxied:$proxied}' \
        > "$CF_DDNS_CONF"; then
        umask "$old_umask"
        err "写入 DDNS 配置失败"
        pause; return
    fi
    umask "$old_umask"
    chmod 600 "$CF_DDNS_CONF"
    token=""

    install_cf_ddns_runner
    install_cf_ddns_units
    systemctl enable --now sb-cloudflare-ddns.timer >/dev/null 2>&1

    msg "立即执行首次更新..."
    if systemctl start sb-cloudflare-ddns.service; then
        ok "DDNS 已配置: ${hostname}，每 5 分钟检查一次"
        journalctl -u sb-cloudflare-ddns.service -n 8 --no-pager 2>/dev/null | sed 's/^/  /'
    else
        err "首次更新失败，请在 DDNS 菜单查看日志"
    fi
    pause
}

save_cf_ddns_json() {
    local source_file="$1"
    if ! jq -e . "$source_file" >/dev/null 2>&1; then
        err "新的 DDNS 配置不是有效 JSON"
        rm -f "$source_file"
        return 1
    fi
    install -d -m 700 "$CF_DDNS_DIR"
    install -m 600 "$source_file" "$CF_DDNS_CONF"
    rm -f "$source_file"
}

# 兼容旧版配置：迁移为可命名的 DDNS 记录列表。
migrate_cf_ddns_split_config() {
    [[ -f "$CF_DDNS_CONF" ]] || return 0
    jq -e '((.records // []) | length) > 0' "$CF_DDNS_CONF" >/dev/null 2>&1 && return 0

    local base h4 h6 label tmp
    base=$(jq -r '.hostname // empty' "$CF_DDNS_CONF")
    [[ -n "$base" ]] || return 1
    label="${base%%.*}"
    h4=$(jq -r '.hostname_v4 // empty' "$CF_DDNS_CONF")
    h6=$(jq -r '.hostname_v6 // empty' "$CF_DDNS_CONF")
    if jq -e '(.record_types | index("A") != null) and (.record_types | index("AAAA") != null)' \
        "$CF_DDNS_CONF" >/dev/null 2>&1; then
        [[ -n "$h4" ]] || h4=$(ddns_split_hostname "$base" 4)
        [[ -n "$h6" ]] || h6=$(ddns_split_hostname "$base" 6)
    else
        jq -e '.record_types | index("A") != null' "$CF_DDNS_CONF" >/dev/null 2>&1 \
            && h4="${h4:-$base}"
        jq -e '.record_types | index("AAAA") != null' "$CF_DDNS_CONF" >/dev/null 2>&1 \
            && h6="${h6:-$base}"
    fi

    tmp=$(mktemp) || return 1
    jq --arg h4 "$h4" --arg h6 "$h6" --arg label "$label" '
        .hostname_v4=$h4 | .hostname_v6=$h6 |
        .records = ([
          if ($h4|length)>0 then {name:($label+" IPv4"),type:"A",hostname:$h4} else empty end,
          if ($h6|length)>0 then {name:($label+" IPv6"),type:"AAAA",hostname:$h6} else empty end
        ])
    ' "$CF_DDNS_CONF" > "$tmp" && save_cf_ddns_json "$tmp"
}

# 把旧节点链接中的双记录基础域名改为对应的独立地址族域名。
migrate_ddns_node_links() {
    [[ -f "$CF_DDNS_CONF" && -f "$SB_NODES" ]] || return 0
    jq -e '(.record_types | index("A") != null) and (.record_types | index("AAAA") != null)' \
        "$CF_DDNS_CONF" >/dev/null 2>&1 || return 0

    local base h4 h6 tmp
    base=$(jq -r '.hostname // empty' "$CF_DDNS_CONF")
    h4=$(jq -r '.hostname_v4 // empty' "$CF_DDNS_CONF")
    h6=$(jq -r '.hostname_v6 // empty' "$CF_DDNS_CONF")
    [[ -n "$base" && -n "$h4" && -n "$h6" ]] || return 1

    tmp=$(mktemp) || return 1
    if jq --arg base "$base" --arg h4 "$h4" --arg h6 "$h6" '
        map(
          if ((.link // "") | contains("@" + $base + ":")) then
            (.link | split("@")) as $parts |
            ($parts[1] | index(":")) as $colon |
            .link = ($parts[0] + "@" +
                     (if .family == "6" then $h6 else $h4 end) +
                     ($parts[1] | .[$colon:]))
          else . end
        )
    ' "$SB_NODES" > "$tmp"; then
        mv "$tmp" "$SB_NODES"
    else
        rm -f "$tmp"
        return 1
    fi
}

apply_cf_ddns_changes() {
    migrate_cf_ddns_split_config || { err "DDNS 独立域名迁移失败"; return 1; }
    install_cf_ddns_runner
    install_cf_ddns_units
    systemctl enable --now sb-cloudflare-ddns.timer >/dev/null 2>&1
    msg "正在应用配置并立即更新..."
    if systemctl start sb-cloudflare-ddns.service; then
        ok "DDNS 配置已更新"
        journalctl -u sb-cloudflare-ddns.service -n 8 --no-pager 2>/dev/null | sed 's/^/  /'
    else
        err "配置已保存，但更新失败，请查看日志"
    fi
}

normalize_cf_record_fields() {
    local source_file="$1" target_file="$2"
    jq '
      .record_types=([.records[].type] | unique) |
      .hostname_v4=([.records[] | select(.type=="A") | .hostname][0] // "") |
      .hostname_v6=([.records[] | select(.type=="AAAA") | .hostname][0] // "") |
      .hostname=(.records[0].hostname // .hostname)
    ' "$source_file" > "$target_file"
}

add_cf_ddns_record() {
    if [[ ! -f "$CF_DDNS_CONF" ]]; then
        setup_cf_ddns
        return
    fi
    local name type_choice type hostname zone_name tmp normalized
    read -rp "$(echo -e "${CYAN}配置名称 (如 韩国 IPv4): ${NC}")" name
    [[ -n "$name" ]] || { err "名称不能为空"; pause; return; }
    echo "  1) IPv4 (A)"
    echo "  2) IPv6 (AAAA)"
    read -rp "$(echo -e "${CYAN}请选择 [1-2]: ${NC}")" type_choice
    case "$type_choice" in 1) type="A" ;; 2) type="AAAA" ;; *) err "无效选择"; pause; return ;; esac
    read -rp "$(echo -e "${CYAN}DDNS 完整域名: ${NC}")" hostname
    hostname="${hostname,,}"; hostname="${hostname%.}"
    [[ "$hostname" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] \
        || { err "域名格式不正确"; pause; return; }
    zone_name=$(jq -r '.zone_name' "$CF_DDNS_CONF")
    [[ "$hostname" == "$zone_name" || "$hostname" == *."$zone_name" ]] \
        || { err "DDNS 域名不属于 Zone ${zone_name}"; pause; return; }
    jq -e --arg n "$name" '.records[]? | select(.name==$n)' "$CF_DDNS_CONF" >/dev/null 2>&1 \
        && { err "配置名称已存在"; pause; return; }
    jq -e --arg h "$hostname" --arg t "$type" '.records[]? | select(.hostname==$h and .type==$t)' "$CF_DDNS_CONF" >/dev/null 2>&1 \
        && { err "相同域名和类型已经存在"; pause; return; }

    tmp=$(mktemp); normalized=$(mktemp)
    jq --arg n "$name" --arg t "$type" --arg h "$hostname" \
        '.records += [{name:$n,type:$t,hostname:$h}]' "$CF_DDNS_CONF" > "$tmp" \
        && normalize_cf_record_fields "$tmp" "$normalized" \
        && save_cf_ddns_json "$normalized"
    rm -f "$tmp"
    apply_cf_ddns_changes
    pause
}

select_cf_ddns_record() {
    local count i=0 choice
    count=$(jq '(.records // []) | length' "$CF_DDNS_CONF")
    (( count > 0 )) || { err "暂无 DDNS 配置" >&2; return 1; }
    while IFS=$'\t' read -r name type hostname; do
        i=$((i+1)); printf "  %d) %-18s %-5s %s\n" "$i" "$name" "$type" "$hostname" >&2
    done < <(jq -r '.records[] | [.name,.type,.hostname] | @tsv' "$CF_DDNS_CONF")
    read -rp "$(echo -e "${CYAN}请选择 [1-${count}]: ${NC}")" choice
    [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=count )) || return 1
    echo $((choice-1))
}

edit_cf_ddns_record() {
    [[ -f "$CF_DDNS_CONF" ]] || { err "尚未配置 DDNS"; pause; return; }
    local idx old_name old_host type name hostname zone_name tmp normalized
    idx=$(select_cf_ddns_record) || { pause; return; }
    old_name=$(jq -r ".records[$idx].name" "$CF_DDNS_CONF")
    old_host=$(jq -r ".records[$idx].hostname" "$CF_DDNS_CONF")
    type=$(jq -r ".records[$idx].type" "$CF_DDNS_CONF")
    read -rp "$(echo -e "${CYAN}配置名称 [${old_name}]: ${NC}")" name; name="${name:-$old_name}"
    read -rp "$(echo -e "${CYAN}DDNS 域名 [${old_host}]: ${NC}")" hostname; hostname="${hostname:-$old_host}"
    hostname="${hostname,,}"; hostname="${hostname%.}"
    zone_name=$(jq -r '.zone_name' "$CF_DDNS_CONF")
    [[ "$hostname" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ \
       && ( "$hostname" == "$zone_name" || "$hostname" == *."$zone_name" ) ]] \
        || { err "域名格式或 Zone 不正确"; pause; return; }
    tmp=$(mktemp); normalized=$(mktemp)
    jq --argjson i "$idx" --arg n "$name" --arg h "$hostname" \
        '.records[$i].name=$n | .records[$i].hostname=$h' "$CF_DDNS_CONF" > "$tmp" \
        && normalize_cf_record_fields "$tmp" "$normalized" \
        && save_cf_ddns_json "$normalized"
    rm -f "$tmp"
    [[ "$old_host" != "$hostname" ]] && warn "旧 DNS 记录未自动删除: ${old_host}"
    apply_cf_ddns_changes
    pause
}

delete_cf_ddns_record() {
    [[ -f "$CF_DDNS_CONF" ]] || { err "尚未配置 DDNS"; pause; return; }
    local idx name type hostname answer result record_id tmp normalized
    idx=$(select_cf_ddns_record) || { pause; return; }
    name=$(jq -r ".records[$idx].name" "$CF_DDNS_CONF")
    type=$(jq -r ".records[$idx].type" "$CF_DDNS_CONF")
    hostname=$(jq -r ".records[$idx].hostname" "$CF_DDNS_CONF")
    read -rp "$(echo -e "${YELLOW}删除 ${name} (${hostname})? [y/N]: ${NC}")" answer
    [[ "$answer" =~ ^[Yy]$ ]] || return
    result=$(cf_ddns_api "$(jq -r '.api_token' "$CF_DDNS_CONF")" GET \
        "/zones/$(jq -r '.zone_id' "$CF_DDNS_CONF")/dns_records?type=${type}&name=${hostname}") || { pause; return; }
    record_id=$(jq -r '.result[0].id // empty' <<<"$result")
    [[ -z "$record_id" ]] || cf_ddns_api "$(jq -r '.api_token' "$CF_DDNS_CONF")" DELETE \
        "/zones/$(jq -r '.zone_id' "$CF_DDNS_CONF")/dns_records/${record_id}" >/dev/null || { pause; return; }
    tmp=$(mktemp); normalized=$(mktemp)
    jq --argjson i "$idx" 'del(.records[$i])' "$CF_DDNS_CONF" > "$tmp" \
        && normalize_cf_record_fields "$tmp" "$normalized" \
        && save_cf_ddns_json "$normalized"
    rm -f "$tmp"
    ok "已删除 ${name}"
    if (( $(jq '(.records // []) | length' "$CF_DDNS_CONF") == 0 )); then
        remove_cf_ddns
    else
        apply_cf_ddns_changes
    fi
    pause
}

modify_cf_ddns() {
    [[ -f "$CF_DDNS_CONF" ]] || { err "尚未配置 DDNS，请先新增配置"; pause; return; }
    while :; do
        clear; show_banner
        sec "修改 Cloudflare DDNS 配置"
        echo -e "  域名:     ${CYAN}$(jq -r '.hostname' "$CF_DDNS_CONF")${NC}"
        [[ -n "$(jq -r '.hostname_v4 // empty' "$CF_DDNS_CONF")" ]] \
            && echo -e "  IPv4 域名:${CYAN} $(jq -r '.hostname_v4' "$CF_DDNS_CONF")${NC}"
        [[ -n "$(jq -r '.hostname_v6 // empty' "$CF_DDNS_CONF")" ]] \
            && echo -e "  IPv6 域名:${CYAN} $(jq -r '.hostname_v6' "$CF_DDNS_CONF")${NC}"
        echo -e "  Zone:     ${CYAN}$(jq -r '.zone_name' "$CF_DDNS_CONF")${NC}"
        echo -e "  记录类型: ${CYAN}$(ddns_record_summary "$CF_DDNS_CONF")${NC}"
        echo -e "  代理状态: ${CYAN}$(jq -r 'if .proxied then "开启" else "关闭（仅 DNS）" end' "$CF_DDNS_CONF")${NC}"
        hr
        echo "  1. 修改域名 / Zone"
        echo "  2. 修改记录类型 (A / AAAA)"
        echo "  3. 修改代理状态 (橙色云)"
        echo "  4. 更换 API Token"
        echo "  0. 返回上一页"
        hr
        local c tmp token hostname zone_name zone_result zone_id mode record_types answer current
        read -rp "$(echo -e "${CYAN}请选择 [0-4]: ${NC}")" c
        case "$c" in
            1)
                token=$(jq -r '.api_token' "$CF_DDNS_CONF")
                current=$(jq -r '.hostname' "$CF_DDNS_CONF")
                read -rp "$(echo -e "${CYAN}DDNS 完整域名 [当前 ${current}]: ${NC}")" hostname
                hostname="${hostname:-$current}"; hostname="${hostname,,}"; hostname="${hostname%.}"
                if [[ ! "$hostname" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; then
                    err "域名格式不正确"; pause; continue
                fi
                current=$(jq -r '.zone_name' "$CF_DDNS_CONF")
                read -rp "$(echo -e "${CYAN}Cloudflare Zone/根域名 [当前 ${current}]: ${NC}")" zone_name
                zone_name="${zone_name:-$current}"; zone_name="${zone_name,,}"; zone_name="${zone_name%.}"
                [[ "$hostname" == "$zone_name" || "$hostname" == *."$zone_name" ]] \
                    || { err "DDNS 域名不属于 Zone ${zone_name}"; pause; continue; }
                msg "验证 Zone..."
                zone_result=$(cf_ddns_api "$token" GET "/zones?name=${zone_name}&status=active&per_page=1") \
                    || { pause; continue; }
                zone_id=$(jq -r '.result[0].id // empty' <<<"$zone_result")
                [[ -n "$zone_id" ]] || { err "找不到 Zone，请检查域名及 Token 权限"; pause; continue; }
                tmp=$(mktemp)
                jq --arg h "$hostname" --arg z "$zone_name" --arg zid "$zone_id" \
                    '.hostname=$h | .zone_name=$z | .zone_id=$zid |
                     .hostname_v4="" | .hostname_v6=""' "$CF_DDNS_CONF" > "$tmp" \
                    && save_cf_ddns_json "$tmp" || { rm -f "$tmp"; pause; continue; }
                warn "旧域名的 DNS 记录不会自动删除，如不再使用请在 Cloudflare 手动删除"
                apply_cf_ddns_changes; pause ;;
            2)
                echo "  1) IPv4 DDNS (仅 A)"
                echo "  2) IPv6 DDNS (仅 AAAA)"
                read -rp "$(echo -e "${CYAN}记录类型 [1-2]: ${NC}")" mode
                hostname=$(jq -r '.hostname' "$CF_DDNS_CONF")
                case "$mode" in
                    1) record_types='["A"]' ;;
                    2) record_types='["AAAA"]' ;;
                    *) err "无效选择"; pause; continue ;;
                esac
                tmp=$(mktemp)
                jq --argjson types "$record_types" --arg h "$hostname" --arg mode "$mode" \
                    '.record_types=$types |
                     if $mode=="1" then .hostname_v4=$h | .hostname_v6=""
                     else .hostname_v4="" | .hostname_v6=$h end' \
                    "$CF_DDNS_CONF" > "$tmp" \
                    && save_cf_ddns_json "$tmp" || { rm -f "$tmp"; pause; continue; }
                apply_cf_ddns_changes; pause ;;
            3)
                current=$(jq -r '.proxied // false' "$CF_DDNS_CONF")
                if [[ "$current" == "true" ]]; then
                    read -rp "$(echo -e "${CYAN}启用 Cloudflare 代理? [Y/n，节点建议 n]: ${NC}")" answer
                    [[ "$answer" =~ ^[Nn]$ ]] && current=false || current=true
                else
                    read -rp "$(echo -e "${CYAN}启用 Cloudflare 代理? [y/N，节点建议 N]: ${NC}")" answer
                    [[ "$answer" =~ ^[Yy]$ ]] && current=true || current=false
                fi
                tmp=$(mktemp)
                jq --argjson p "$current" '.proxied=$p' "$CF_DDNS_CONF" > "$tmp" \
                    && save_cf_ddns_json "$tmp" || { rm -f "$tmp"; pause; continue; }
                apply_cf_ddns_changes; pause ;;
            4)
                read -rsp "$(echo -e "${CYAN}新的 Cloudflare API Token: ${NC}")" token
                echo
                [[ -n "$token" ]] || { err "Token 不能为空"; pause; continue; }
                msg "验证新的 API Token..."
                local verify
                verify=$(cf_ddns_api "$token" GET "/user/tokens/verify") || { pause; continue; }
                [[ "$(jq -r '.result.status' <<<"$verify")" == "active" ]] \
                    || { err "Token 当前不是 active 状态"; pause; continue; }
                zone_name=$(jq -r '.zone_name' "$CF_DDNS_CONF")
                zone_result=$(cf_ddns_api "$token" GET "/zones?name=${zone_name}&status=active&per_page=1") \
                    || { pause; continue; }
                zone_id=$(jq -r '.result[0].id // empty' <<<"$zone_result")
                [[ -n "$zone_id" ]] || { err "新 Token 无权访问当前 Zone"; pause; continue; }
                tmp=$(mktemp)
                jq --arg t "$token" --arg zid "$zone_id" '.api_token=$t | .zone_id=$zid' \
                    "$CF_DDNS_CONF" > "$tmp" \
                    && save_cf_ddns_json "$tmp" || { rm -f "$tmp"; pause; continue; }
                token=""
                apply_cf_ddns_changes; pause ;;
            0|"") return ;;
            *) err "无效选择"; sleep 1 ;;
        esac
    done
}

show_cf_ddns_status() {
    clear; show_banner
    sec "Cloudflare DDNS 状态"
    if [[ ! -f "$CF_DDNS_CONF" ]]; then
        warn "尚未配置 DDNS"
        pause; return
    fi
    echo -e "  ${BOLD}DDNS 配置:${NC}"
    local i=0
    while IFS=$'\t' read -r name type hostname; do
        i=$((i+1)); printf "  %d) %-18s %-5s %s\n" "$i" "$name" "$type" "$hostname"
    done < <(jq -r '.records[]? | [.name,.type,.hostname] | @tsv' "$CF_DDNS_CONF")
    echo -e "  Zone:     ${CYAN}$(jq -r '.zone_name' "$CF_DDNS_CONF")${NC}"
    echo -e "  记录类型: ${CYAN}$(ddns_record_summary "$CF_DDNS_CONF")${NC}"
    echo -e "  代理状态: ${CYAN}$(jq -r 'if .proxied then "开启" else "关闭（仅 DNS）" end' "$CF_DDNS_CONF")${NC}"
    echo -e "  定时器:   ${CYAN}$(systemctl is-active sb-cloudflare-ddns.timer 2>/dev/null || true)${NC}"
    echo
    systemctl list-timers sb-cloudflare-ddns.timer --no-pager 2>/dev/null | sed 's/^/  /'
    echo
    echo -e "  ${YELLOW}最近日志:${NC}"
    journalctl -u sb-cloudflare-ddns.service -n 10 --no-pager 2>/dev/null | sed 's/^/  /'
    pause
}

remove_cf_ddns() {
    systemctl disable --now sb-cloudflare-ddns.timer >/dev/null 2>&1 || true
    systemctl stop sb-cloudflare-ddns.service >/dev/null 2>&1 || true
    rm -f "$CF_DDNS_TIMER" "$CF_DDNS_SERVICE" "$CF_DDNS_BIN"
    rm -rf "$CF_DDNS_DIR"
    systemctl daemon-reload
    ok "Cloudflare DDNS 已卸载"
}

menu_cf_ddns() {
    while :; do
        clear; show_banner
        sec "Cloudflare DDNS"
        local configured="${RED}未配置${NC}" timer_status="${RED}未运行${NC}" i=0
        [[ -f "$CF_DDNS_CONF" ]] && configured="${GREEN}已配置${NC}"
        systemctl is-active --quiet sb-cloudflare-ddns.timer 2>/dev/null \
            && timer_status="${GREEN}运行中${NC}"
        echo -e "  配置: ${configured}    定时器: ${timer_status}"
        if [[ -f "$CF_DDNS_CONF" ]]; then
            migrate_cf_ddns_split_config || true
            while IFS=$'\t' read -r name type hostname; do
                i=$((i+1)); printf "  %d) %-18s %-5s %s\n" "$i" "$name" "$type" "$hostname"
            done < <(jq -r '.records[]? | [.name,.type,.hostname] | @tsv' "$CF_DDNS_CONF")
        fi
        hr
        echo "  1. 新增 DDNS"
        echo "  2. 查看 DDNS"
        echo "  3. 修改 DDNS"
        echo "  4. 删除 DDNS"
        echo "  0. 返回上一页"
        hr
        local c
        read -rp "$(echo -e "${CYAN}请选择 [0-4]: ${NC}")" c
        case "$c" in
            1) add_cf_ddns_record ;;
            2) show_cf_ddns_status ;;
            3) edit_cf_ddns_record ;;
            4) delete_cf_ddns_record ;;
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
        echo "  0) 返回上一页"
        hr
        local c new
        read -rp "$(echo -e "${CYAN}请选择 [0-4]: ${NC}")" c
        case "$c" in
            1) new="prefer_ipv4" ;;
            2) new="prefer_ipv6" ;;
            3) new="ipv4_only" ;;
            4) new="ipv6_only" ;;
            0|"") return ;;
            *) err "无效"; sleep 1; continue ;;
        esac
        local tmp; tmp=$(mktemp)
        jq --arg s "$new" '.ip_strategy = $s' "$SB_SETTINGS" > "$tmp" && mv "$tmp" "$SB_SETTINGS"
        rebuild_config
        restart_sb && ok "已切换为 ${new}"
        sleep 1
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
            4) clear; echo "Ctrl+C 退出"; vnstat -l -i "$iface" ;;
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
               if [[ -s "$SB_LOG" ]]; then
                   tail -f "$SB_LOG"
               else
                   journalctl -u sing-box -f
               fi ;;
            7) : > "$SB_LOG"; ok "日志已清空"; sleep 1 ;;
            8) rm -f "$SB_BIN"; install_singbox force stable && restart_sb; pause ;;
            9) rm -f "$SB_BIN"; install_singbox force beta && restart_sb; pause ;;
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
        if head -n 1 "$tmp" | grep -q '^#!/.*bash'; then
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
    echo "将删除: sing-box、配置、systemd 服务、日志、sb 命令"
    echo
    read -rp "$(echo -e "${YELLOW}确定卸载? 输入 ${BOLD}YES${NC}${YELLOW} 确认: ${NC}")" y
    [[ "$y" == "YES" ]] || { warn "已取消"; pause; return; }
    if [[ -f "$CF_DDNS_CONF" || -f "$CF_DDNS_TIMER" ]]; then
        echo
        read -rp "$(echo -e "${YELLOW}检测到 Cloudflare DDNS，是否一并卸载并删除 Token? [y/N]: ${NC}")" y
        if [[ "$y" =~ ^[Yy]$ ]]; then
            remove_cf_ddns
        else
            warn "已保留 Cloudflare DDNS 服务和配置"
        fi
    fi
    systemctl stop sing-box 2>/dev/null
    systemctl disable sing-box 2>/dev/null
    rm -f "$SB_SERVICE"
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
    local sb_ver active node_count
    sb_ver=$("$SB_BIN" version 2>/dev/null | awk '/version/{print $3; exit}')
    if systemctl is-active --quiet sing-box; then
        active="${GREEN}running${NC}"
    else
        active="${RED}stopped${NC}"
    fi
    node_count=$(jq 'length' "$SB_NODES" 2>/dev/null || echo 0)
    # 标题分割线（绿色版的 sec，居中自适应）
    local title="Sing-box Script v${SCRIPT_VERSION} By ${SCRIPT_AUTHOR}"
    local w side_eq bytes chars non_ascii_chars ascii_chars visual
    w=$(term_width)
    bytes=$(printf '%s' " ${title} " | wc -c)
    chars=$(printf '%s' " ${title} " | wc -m)
    non_ascii_chars=$(( (bytes - chars) / 2 ))
    ascii_chars=$(( chars - non_ascii_chars ))
    visual=$(( ascii_chars + non_ascii_chars * 2 ))
    side_eq=$(( (w - visual) / 2 ))
    (( side_eq < 3 )) && side_eq=3
    local left right
    left=$(printf "%${side_eq}s" '' | tr ' ' '=')
    right=$(printf "%${side_eq}s" '' | tr ' ' '=')
    echo -e "${GREEN}${left} ${BOLD}${title}${NC}${GREEN} ${right}${NC}"
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
        read -rp "$(echo -e "${CYAN}请输入选项 [0-9/c/d]: ${NC}")" c
        case "$c" in
            1) menu_add ;;
            2) modify_node ;;
            3) view_nodes ;;
            4) delete_node ;;
            5) menu_routing ;;
            c|C) menu_client ;;
            d|D) menu_cf_ddns ;;
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
    # 复用 show_banner 的标题逻辑（但此时 sing-box 尚未安装，banner 不能直接调用）
    local title="Sing-box Script v${SCRIPT_VERSION} By ${SCRIPT_AUTHOR}"
    local w side_eq bytes chars non_ascii_chars ascii_chars visual
    w=$(term_width)
    bytes=$(printf '%s' " ${title} " | wc -c)
    chars=$(printf '%s' " ${title} " | wc -m)
    non_ascii_chars=$(( (bytes - chars) / 2 ))
    ascii_chars=$(( chars - non_ascii_chars ))
    visual=$(( ascii_chars + non_ascii_chars * 2 ))
    side_eq=$(( (w - visual) / 2 ))
    (( side_eq < 3 )) && side_eq=3
    local left right
    left=$(printf "%${side_eq}s" '' | tr ' ' '=')
    right=$(printf "%${side_eq}s" '' | tr ' ' '=')
    echo -e "${GREEN}${left} ${BOLD}${title}${NC}${GREEN} ${right}${NC}"
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
        if [[ -f "$CF_DDNS_CONF" ]]; then
            migrate_cf_ddns_split_config || true
            migrate_ddns_node_links || true
            install_cf_ddns_runner
            install_cf_ddns_units
            systemctl enable --now sb-cloudflare-ddns.timer >/dev/null 2>&1 || true
            systemctl start sb-cloudflare-ddns.service >/dev/null 2>&1 || true
        fi
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
