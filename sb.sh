#!/usr/bin/env bash
# =============================================================================
# Sing-box Script v1.2 By Merlin
# 支持入站: Shadowsocks(老版+2022) / VLESS+Reality / AnyTLS
# 支持出站: SS / VLESS-Reality / VLESS-WS-TLS / Hysteria2 / TUIC / Trojan / AnyTLS / Socks5
# 系统:    Debian 12/13
# 调用:    sb
# =============================================================================

set -o pipefail

SCRIPT_VERSION="1.2"
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
        uuid-runtime iproute2 vnstat chrony >/dev/null 2>&1
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
    while :; do
        clear; show_banner
        sec "添加节点 → IPv${family} → 选择协议"
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
            1) menu_ss_method "$family"; return ;;
            2) create_reality "$family"; return ;;
            3) create_anytls "$family"; return ;;
            0|"") return ;;
            *) err "无效选择"; sleep 1 ;;
        esac
    done
}

menu_ss_method() {
    local family="$1"
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
        1) create_ss "$family" "aes-128-gcm" 16 ;;
        2) create_ss "$family" "aes-256-gcm" 32 ;;
        3) create_ss "$family" "chacha20-ietf-poly1305" 32 ;;
        4) create_ss "$family" "xchacha20-ietf-poly1305" 32 ;;
        5) create_ss "$family" "2022-blake3-aes-128-gcm" 16 ;;
        6) create_ss "$family" "2022-blake3-aes-256-gcm" 32 ;;
        7) create_ss "$family" "2022-blake3-chacha20-poly1305" 32 ;;
        0|"") return ;;
        *) err "无效选择"; sleep 1 ;;
    esac
}

create_ss() {
    local family="$1" method="$2" keylen="$3"
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

    ip=$(get_ip "$family")
    [[ -z "$ip" ]] && { err "无法获取 IPv${family} 地址"; pause; return; }

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
    shortid=$(openssl rand -hex 4)
    uuid=$(uuidgen)

    local ip listen
    ip=$(get_ip "$family")
    [[ -z "$ip" ]] && { err "无法获取 IPv${family} 地址"; pause; return; }
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
    ip=$(get_ip "$family")
    [[ -z "$ip" ]] && { err "无法获取 IPv${family} 地址"; pause; return; }
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

menu_add() {
    while :; do
        clear; show_banner
        sec "添加配置 → 选择出口 IP 协议"
        echo "  1) IPv4"
        echo "  2) IPv6"
        echo "  0) 返回上一页"
        hr
        local c
        read -rp "$(echo -e "${CYAN}请选择 [0-2]: ${NC}")" c
        case "$c" in
            1) menu_new_proto "4"; return ;;
            2) menu_new_proto "6"; return ;;
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
            inbounds:[{type:"socks", tag:"socks-in", listen:"127.0.0.1", listen_port:$sport}],
            outbounds:$obs,
            route:{rule_set:$rsets, rules:$rules, final:$final, auto_detect_interface:true}
        }' > "$SB_CLIENT_CONF"
}

restart_client() {
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
cc() {
    ALL_PROXY=socks5://127.0.0.1:${sport} \\
    HTTPS_PROXY=socks5://127.0.0.1:${sport} \\
    HTTP_PROXY=socks5://127.0.0.1:${sport} \\
    claude "\$@"
}
# 通用：cx <命令> 让任意命令走本地代理(如 cx codex / cx curl ...)
cx() {
    ALL_PROXY=socks5://127.0.0.1:${sport} \\
    HTTPS_PROXY=socks5://127.0.0.1:${sport} \\
    HTTP_PROXY=socks5://127.0.0.1:${sport} \\
    "\$@"
}
# <<< sb claude-code proxy <<<
EOF
    ok "已写入 ${rc}"
    echo -e "  ${CYAN}source ${rc}${NC} 后:  ${GREEN}cc${NC} 跑 Claude Code,  ${GREEN}cx codex${NC} 让 codex 走代理"
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
    echo -e "  本地 SOCKS 总入口 ${CYAN}127.0.0.1:${sport}${NC} 出口 IP:"
    echo -e "    ${GREEN}$(curl -fsSL -m 12 -x socks5://127.0.0.1:${sport} https://api.ipify.org 2>/dev/null || echo 获取失败)${NC}"
    echo -e "    ${YELLOW}(注: 这个IP取决于 api.ipify.org 命中了哪条规则/final)${NC}"
    hr
    echo -e "  各出口单独连通(直接测试每个落地是否可用):"
    local n i; n=$(jq '.outbounds|length' "$SB_CLIENT_META")
    if (( n==0 )); then echo "    (无出口)"; fi
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
        read -rp "$(echo -e "${CYAN}请输入选项 [0-9/c]: ${NC}")" c
        case "$c" in
            1) menu_add ;;
            2) modify_node ;;
            3) view_nodes ;;
            4) delete_node ;;
            5) menu_routing ;;
            c|C) menu_client ;;
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
