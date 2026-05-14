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
SCRIPT_UPDATE_URL="https://example.com/sb.sh"

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
    remark=$(ask_remark "reality-${port}")
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

    local inbound
    inbound=$(jq -n --arg tag "$tag" --argjson port "$port" \
        --arg listen "$listen" \
        --arg uuid "$uuid" --arg sni "$sni" --arg prv "$prvkey" --arg sid "$shortid" \
        '{type:"vless", tag:$tag, listen:$listen, listen_port:$port,
          users:[{uuid:$uuid, flow:"xtls-rprx-vision"}],
          tls:{enabled:true, server_name:$sni,
            reality:{enabled:true,
              handshake:{server:$sni, server_port:443},
              private_key:$prv, short_id:[$sid]}}}')

    local link
    link="vless://${uuid}@$(ip_for_url "$ip"):${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pubkey}&sid=${shortid}&type=tcp#$(urlencode "$remark")"

    save_node "$tag" "vless-reality" "$port" "$family" "$remark" "$link" \
        "$(jq -n --argjson ib "$inbound" --arg pbk "$pubkey" --arg sid "$shortid" \
                --arg uuid "$uuid" --arg sni "$sni" \
                '{inbound:$ib, public_key:$pbk, short_id:$sid, uuid:$uuid, sni:$sni}')"
    rebuild_config
    restart_sb || return

    echo
    ok "节点创建成功: ${remark}"
    echo -e "${BOLD}分享链接:${NC}"
    echo -e "${GREEN}${link}${NC}"
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
        local active="未运行" enabled="未启用" ver time_status
        systemctl is-active --quiet sing-box && active="${GREEN}运行中${NC}"
        systemctl is-enabled --quiet sing-box 2>/dev/null && enabled="${GREEN}开机自启${NC}"
        ver=$("$SB_BIN" version 2>/dev/null | awk '/version/{print $3; exit}')
        if check_time_sync; then
            time_status="${GREEN}已同步${NC}"
        else
            time_status="${RED}未同步${NC}"
        fi
        echo -e "  状态: ${active}    自启: ${enabled}    版本: ${ver:-未知}"
        echo -e "  时间: ${time_status}    (SS-2022/Reality 等协议要求时间偏差 < 30s)"
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
        echo "  0) 返回上一页"
        hr
        local c
        read -rp "$(echo -e "${CYAN}请选择 [0-9/t]: ${NC}")" c
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
        read -rp "$(echo -e "${CYAN}请输入选项 [0-9]: ${NC}")" c
        case "$c" in
            1) menu_add ;;
            2) modify_node ;;
            3) view_nodes ;;
            4) delete_node ;;
            5) menu_routing ;;
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
    hr
    ok "安装完成。以后输入 ${BOLD}sb${NC} 即可呼出菜单。"
    hr
    pause
}

main() {
    need_root
    if [[ ! -x "$SB_BIN" || ! -f "$SB_CONF" ]]; then
        first_install
    else
        [[ -x "$SB_SCRIPT_PATH" ]] || install_cmd
        init_dirs
    fi
    main_menu
}

main "$@"
