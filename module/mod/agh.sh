#!/system/bin/sh
# AdGuard Home 启停（逻辑参考 twoone3/AdGuardHomeForRoot 的 tool.sh / iptables.sh）
MODDIR=$(cd "${0%/*}/.." && pwd)
. "$MODDIR/mod/common.sh"

# 只认本模块的二进制：同名进程可能来自其他模块
is_our_pid() {
    [ -n "$1" ] && [ -r "/proc/$1/stat" ] || return 1
    [ "$(readlink "/proc/$1/exe" 2>/dev/null)" = "$AGH_BIN" ] || return 1
    read -r st < "/proc/$1/stat" 2>/dev/null || return 1
    st="${st##*) }"; [ "${st%% *}" != "Z" ]
}
our_pids() { for p in /proc/[0-9]*; do is_our_pid "${p#/proc/}" && echo "${p#/proc/}"; done; }

is_listening() {
    hex=$(printf '%04X' "$1")
    for f in /proc/net/udp /proc/net/udp6; do
        [ -r "$f" ] && awk -v pat=":$hex\$" 'NR>1 && $2 ~ pat {found=1} END {exit !found}' "$f" && return 0
    done
    return 1
}

detect_gid() {
    if busybox 2>&1 | grep -qw setuidgid; then USE_GID=1; else USE_GID=0; fi
}

dns_rules_remove() {
    for _ in 1 2 3; do ipt -t nat -D OUTPUT -j "$DNS_CHAIN" 2>/dev/null || break; done
    ipt -t nat -F "$DNS_CHAIN" 2>/dev/null; ipt -t nat -X "$DNS_CHAIN" 2>/dev/null
    for _ in 1 2 3; do ipt  -D OUTPUT -j "$DNSF_CHAIN" 2>/dev/null || break; done
    for _ in 1 2 3; do ip6t -D OUTPUT -j "$DNSF_CHAIN" 2>/dev/null || break; done
    ipt  -F "$DNSF_CHAIN" 2>/dev/null; ipt  -X "$DNSF_CHAIN" 2>/dev/null
    ip6t -F "$DNSF_CHAIN" 2>/dev/null; ip6t -X "$DNSF_CHAIN" 2>/dev/null
}

dns_rules_apply() {
    port=$1
    dns_rules_remove
    ipt -t nat -N "$DNS_CHAIN" || return 1
    # AdGuard 自己的上游查询不重定向
    if [ "$USE_GID" = 1 ]; then
        ipt -t nat -A "$DNS_CHAIN" -m owner --uid-owner 0 --gid-owner $NET_RAW_GID -j RETURN || return 1
    else
        ipt -t nat -A "$DNS_CHAIN" -m owner --uid-owner 0 -j RETURN || return 1
    fi
    ipt -t nat -A "$DNS_CHAIN" -p udp --dport 53 -j REDIRECT --to-ports "$port" || return 1
    ipt -t nat -A "$DNS_CHAIN" -p tcp --dport 53 -j REDIRECT --to-ports "$port" || return 1
    ipt -t nat -I OUTPUT 1 -j "$DNS_CHAIN" || return 1

    ipt -N "$DNSF_CHAIN"; ip6t -N "$DNSF_CHAIN"
    if [ "$USE_GID" = 1 ]; then
        ipt  -A "$DNSF_CHAIN" -m owner --uid-owner 0 --gid-owner $NET_RAW_GID -j RETURN
        ip6t -A "$DNSF_CHAIN" -m owner --uid-owner 0 --gid-owner $NET_RAW_GID -j RETURN
    else
        ipt  -A "$DNSF_CHAIN" -m owner --uid-owner 0 -j RETURN
        ip6t -A "$DNSF_CHAIN" -m owner --uid-owner 0 -j RETURN
    fi
    if [ "$AGH_BLOCK_IPV6_DNS" = 1 ]; then
        ip6t -A "$DNSF_CHAIN" -p udp --dport 53 -j REJECT
        ip6t -A "$DNSF_CHAIN" -p tcp --dport 53 -j REJECT --reject-with tcp-reset
    fi
    if [ "$AGH_BLOCK_DOT" = 1 ]; then
        ipt  -A "$DNSF_CHAIN" -p tcp --dport 853 -j REJECT --reject-with tcp-reset
        ipt  -A "$DNSF_CHAIN" -p udp --dport 853 -j REJECT
        ip6t -A "$DNSF_CHAIN" -p tcp --dport 853 -j REJECT --reject-with tcp-reset
        ip6t -A "$DNSF_CHAIN" -p udp --dport 853 -j REJECT
    fi
    ipt  -I OUTPUT 1 -j "$DNSF_CHAIN"
    ip6t -I OUTPUT 1 -j "$DNSF_CHAIN"
}

start() {
    [ "$ENABLE_AGH" = 1 ] || { log "AGH: 已在配置中关闭"; return 0; }
    if other_agh_module; then
        log "AGH: 检测到另一个 AdGuardHome 模块仍在启用，本模块的 AdGuard 不启动（避免冲突）"
        return 1
    fi
    [ -x "$AGH_BIN" ] && [ -f "$AGH_YAML" ] || { log "ERROR: AGH 文件缺失，请重新刷入模块"; return 1; }
    if [ -n "$(our_pids)" ]; then
        # 已在运行：确认 DNS 已接管，没接管就补上
        port=$(agh_port); [ -z "$port" ] && port=5591
        if ! ipt -t nat -C OUTPUT -j "$DNS_CHAIN" 2>/dev/null && is_listening "$port"; then
            detect_gid
            dns_rules_apply "$port" && log "AGH: 已在运行，补上 DNS 接管" || { dns_rules_remove; log "ERROR: 补 DNS 接管失败"; }
        fi
        return 0
    fi

    agh_ensure_yaml
    port=$(agh_port); [ -z "$port" ] && port=5591
    [ -f "$AGH_DIR/agh.log" ] && mv -f "$AGH_DIR/agh.log" "$AGH_DIR/agh.log.bak"

    export SSL_CERT_DIR=/system/etc/security/cacerts/
    export TZ=Asia/Shanghai
    cd "$AGH_DIR" || return 1
    detect_gid
    if [ "$USE_GID" = 1 ]; then
        nohup busybox setuidgid "root:net_raw" "$AGH_BIN" -c "$AGH_YAML" -w "$AGH_DIR" --no-check-update \
            > "$AGH_DIR/agh.log" 2>&1 &
    else
        log "AGH: 未找到 busybox setuidgid，改为以 root 运行（root 进程的 DNS 不经过 AdGuard）"
        nohup "$AGH_BIN" -c "$AGH_YAML" -w "$AGH_DIR" --no-check-update > "$AGH_DIR/agh.log" 2>&1 &
    fi
    pid=$!

    # 先等 nohup/busybox 真正 exec 成 AdGuardHome（v7.0 漏了这一步：
    # 刚 fork 时进程还不是 AdGuardHome，循环立刻退出，导致 DNS 从未接管）
    t=0
    while [ "$t" -lt 15 ] && ! is_our_pid "$pid" && kill -0 "$pid" 2>/dev/null; do
        sleep 1; t=$((t + 1))
    done
    # 再等它监听端口，之后才劫持 DNS，否则会断网
    t=0; ok=0
    while [ "$t" -lt "$AGH_STARTUP_TIMEOUT" ]; do
        is_our_pid "$pid" || break
        is_listening "$port" && { ok=1; break; }
        sleep 1; t=$((t + 1))
    done
    if [ "$ok" != 1 ]; then
        if is_our_pid "$pid"; then
            log "AGH: ${AGH_STARTUP_TIMEOUT}s 内未监听端口 $port，跳过 DNS 劫持以保持联网"
        else
            log "ERROR: AGH 启动失败，见 $AGH_DIR/agh.log"
            tail -5 "$AGH_DIR/agh.log" 2>/dev/null >> "$LOG"
        fi
        return 1
    fi
    echo "$pid" > "$AGH_DIR/agh.pid"
    if dns_rules_apply "$port"; then
        log "AGH: 运行中 pid=$pid 端口=$port，DNS 已接管"
    else
        dns_rules_remove
        log "ERROR: AGH DNS 规则应用失败，已回滚"
        return 1
    fi
}

stop() {
    dns_rules_remove
    pids=$(our_pids)
    [ -n "$pids" ] || { rm -f "$AGH_DIR/agh.pid"; return 0; }
    for p in $pids; do kill "$p" 2>/dev/null; done
    w=0; while [ "$w" -lt 5 ] && [ -n "$(our_pids)" ]; do sleep 1; w=$((w + 1)); done
    for p in $(our_pids); do kill -9 "$p" 2>/dev/null; done
    rm -f "$AGH_DIR/agh.pid"
    log "AGH: 已停止"
}

status() {
    pids=$(our_pids)
    if [ -n "$pids" ]; then
        echo "AdGuard Home 运行中（pid $pids），后台 http://$(agh_web)"
        ipt -t nat -C OUTPUT -j "$DNS_CHAIN" 2>/dev/null && echo "✅ DNS 已接管（端口 $(agh_port)）" || echo "❌ DNS 未接管"
    else
        echo "AdGuard Home 未运行"
    fi
}

case "$1" in
    start) start ;;
    stop) stop ;;
    status) status ;;
    *) echo "用法: $0 start|stop|status" ;;
esac
