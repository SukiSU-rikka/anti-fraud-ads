#!/system/bin/sh
# 公共定义。持久数据放在 /data/adb/afa（更新模块时保留，卸载时清理）
[ -z "$MODDIR" ] && MODDIR=/data/adb/modules/anti_fraud_ads
PERSIST=/data/adb/afa
AGH_DIR=$PERSIST/agh
AGH_BIN=$AGH_DIR/AdGuardHome
AGH_YAML=$AGH_DIR/AdGuardHome.yaml
AGH_FILTER=$AGH_DIR/userfilters/antifraud.txt
AGH_FILTER_ID=1900000001
LOG=$PERSIST/module.log
CHAIN=AFA_OUT          # filter：反诈拦截
DNS_CHAIN=AFA_DNS      # nat：DNS 重定向到 AdGuard
DNSF_CHAIN=AFA_DNSF    # filter：DoT / IPv6 DNS 拦截
NET_RAW_GID=3004

for d in /data/adb/ksu/bin /data/adb/ap/bin /data/adb/magisk; do
    [ -d "$d" ] && PATH="$d:$PATH"
done
export PATH

. "$MODDIR/mod/config.prop"
[ -f "$PERSIST/user.conf" ] && . "$PERSIST/user.conf"

mkdir -p "$PERSIST" 2>/dev/null
log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }
ipt()  { iptables  -w 5 "$@"; }
ip6t() { ip6tables -w 5 "$@"; }

pkg_uid() { awk -v p="$1" '$1==p {print $2; exit}' /data/system/packages.list 2>/dev/null; }

# ---------------- 网络拦截（filter 表自建链）----------------
# AFA_OUT：断网应用 / HTTPDNS / QUIC，并跳转到下面两条子链
# AFA_SNI：按 TLS SNI / HTTP Host 拦域名（规则热更新时只重建它和 AFA_IP，不动其他）
# AFA_IP ：按 IP 拦截
SNI_CHAIN=AFA_SNI
IP_CHAIN=AFA_IP
RULES=$PERSIST/rules          # 用户规则（WebUI / 手动编辑 / 导入），更新模块时保留
CACHE=$PERSIST/cache          # 合并后的规则（自动生成）

rules_active() { ipt -C OUTPUT -j "$CHAIN" 2>/dev/null; }
rule_count() {
    c=0
    for ch in "$CHAIN" "$SNI_CHAIN" "$IP_CHAIN"; do
        c=$((c + $(ipt -S "$ch" 2>/dev/null | grep '^-A' | grep -vc -- '-j AFA_')))
    done
    echo "$c"
}

rules_remove() {
    for t in ipt ip6t; do
        for _ in 1 2 3 4 5; do $t -D OUTPUT -j "$CHAIN" 2>/dev/null || break; done
        for ch in "$CHAIN" "$SNI_CHAIN" "$IP_CHAIN"; do $t -F "$ch" 2>/dev/null; done
        for ch in "$CHAIN" "$SNI_CHAIN" "$IP_CHAIN"; do $t -X "$ch" 2>/dev/null; done
    done
}

# ---- 规则合并：内置 + 我的规则 + 订阅，减去放行名单 ----
# 归类规则：纯域名 → 拦截域名（SNI，同时自动生成 DNS 规则）；||x^ 等 AdGuard 语法 → DNS；
#           IPv4/CIDR → IP；@@ 开头 → DNS 放行并从 SNI 里排除；[sni] [dns] [ip] [allow] 可强制分区
classify() {   # 读 stdin，输出 "类型<TAB>内容"
    tr -d '\r' | awk '
        function trim(x) { gsub(/^[ \t]+|[ \t]+$/, "", x); return x }
        { l = trim($0) }
        l == "" { next }
        tolower(l) ~ /^\[(sni|dns|ip|allow)\]$/ { mode = tolower(substr(l, 2, length(l) - 2)); next }
        l ~ /^#/ { next }
        l ~ /^!/ { next }
        {
            if (mode == "sni" || mode == "allow") {
                d = l; sub(/^\|\|/, "", d); sub(/\^.*$/, "", d); sub(/^@@\|\|/, "", d)
                if (d ~ /^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$/) print mode "\t" tolower(d)
                next
            }
            if (mode == "ip") { if (l ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/) print "ip\t" l; next }
            if (length(l) > 1024) next
            if (mode == "dns") { print "dns\t" l; next }
            if (l ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/) { print "ip\t" l; next }
            if (l ~ /^(0\.0\.0\.0|127\.0\.0\.1|::)[ \t]+[A-Za-z0-9.-]+$/) { n = split(l, f, /[ \t]+/); print "dns\t||" tolower(f[n]) "^"; next }
            if (l ~ /^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$/) { print "sni\t" tolower(l); next }
            if (l ~ /^@@\|\|[A-Za-z0-9.-]+\^/) { d = l; sub(/^@@\|\|/, "", d); sub(/\^.*$/, "", d); print "allow\t" tolower(d); print "dns\t" l; next }
            print "dns\t" l
        }'
}

# 生成 $CACHE/{sni,ip,dns,allow}.list；DNS 有变化时返回 0
rules_build() {
    mkdir -p "$RULES" "$CACHE" "$RULES/sub"
    t=$CACHE/.all
    {
        echo "[sni]"; cat "$MODDIR/mod/sni_block.txt" 2>/dev/null; echo
        echo "[allow]"; cat "$MODDIR/mod/allow.txt" 2>/dev/null; echo
        echo "[dns]"; cat "$MODDIR/mod/antifraud_rules.txt" 2>/dev/null; echo
        if [ "$BLOCK_IP_LIST" = 1 ]; then echo "[ip]"; cat "$MODDIR/mod/ip_list.txt"; echo; fi
        if [ "$BLOCK_COLOROS_IP" = 1 ]; then echo "[ip]"; cat "$MODDIR/mod/ip_coloros.txt"; echo; fi
        for f in sni dns ip allow; do
            echo "[$f]"; cat "$RULES/$f.txt" 2>/dev/null; echo
            echo "[$f]"; cat "$RULES/sub/$f.txt" 2>/dev/null; echo
        done
    } | classify > "$t"
    # 自检：内置名单至少有几十个域名，一个都没解析出来说明 awk 出了问题，记下来方便排查
    grep -q '^sni' "$t" || log "ERROR: 规则解析结果为空（awk: $(command -v awk)）"
    popup_build
    awk -F'\t' '$1=="allow"{print $2}' "$t" | sort -u > "$CACHE/allow.list"
    # SNI：去重、去掉放行名单（放行 a.com 也会放行 x.a.com 的拦截条目）
    awk -F'\t' 'NR==FNR { allow[$1]=1; next }
        $1=="sni" { d=$2; ok=1
            for (a in allow) if (d==a || (length(d)>length(a) && substr(d, length(d)-length(a)) == "." a)) ok=0
            if (ok && !seen[d]++) print d }' "$CACHE/allow.list" "$t" > "$CACHE/sni.list"
    awk -F'\t' '$1=="ip" && !seen[$2]++ {print $2}' "$t" > "$CACHE/ip.list"
    old=$(md5sum "$CACHE/dns.list" 2>/dev/null | cut -d' ' -f1)
    {
        echo "! 由模块自动生成：内置规则 + 我的规则 + 订阅。不要直接改这个文件，改 /data/adb/afa/rules/ 里的"
        awk -F'\t' '$1=="dns" && !seen[$2]++ {print $2}' "$t"
        awk '!seen[$0]++ {print "||" $0 "^"}' "$CACHE/sni.list"
        awk '!seen[$0]++ {print "@@||" $0 "^$important"}' "$CACHE/allow.list"
    } | awk '!seen[$0]++' > "$CACHE/dns.list"
    rm -f "$t"
    [ "$(md5sum "$CACHE/dns.list" | cut -d' ' -f1)" != "$old" ]
}

# ---------------- 弹窗规则（开屏跳过用）----------------
# 和域名规则完全分开处理。注意：awk 正则里不能出现中文，有的 awk（安卓自带的、busybox 的）
# 遇到非 ASCII 正则会整个脚本报错；所以这里只用 index() 和字符串比较认中文
POPUP_AWK='
function trim(x) { gsub(/^[ \t]+|[ \t]+$/, "", x); return x }
function repl(x, from, to,   k) { while ((k = index(x, from)) > 0) x = substr(x, 1, k - 1) to substr(x, k + length(from)); return x }
function parse(line) {                     # 认得出返回 1，并设置 P_pkg / P_neg / P_key / P_words
    l = trim(line); P_pkg = "*"; P_neg = ""
    if (l == "" || substr(l, 1, 1) == "#") return 0
    if (substr(l, 1, 1) == "@") {
        k = index(l, " "); t = index(l, "\t"); if (k == 0 || (t > 0 && t < k)) k = t
        if (k == 0) return 0
        P_pkg = substr(l, 2, k - 2); l = trim(substr(l, k + 1))
        if (P_pkg !~ /^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$/) return 0
    }
    if (substr(l, 1, 1) == "-") { P_neg = "-"; l = substr(l, 2) }
    l = repl(l, "：", ":")
    k = index(l, ":"); if (k == 0) return 0
    P_key = trim(substr(l, 1, k - 1))
    if (!(P_key in KEY)) return 0
    P_words = repl(repl(substr(l, k + 1), "，", ","), "、", ",")
    return 1
}
BEGIN {
    KEY["跳过"] = "skip"; KEY["非广告"] = "notad"; KEY["拒绝"] = "any"; KEY["弹窗关闭"] = "float"
    KEY["通知拒绝"] = "notify"; KEY["通知提示"] = "hint"; KEY["不碰"] = "never"; KEY["图标"] = "id"
}
'

# 把一段文本拆成两份：弹窗规则行写到 $1，其余原样输出（交给 classify）
popup_split() {
    tr -d '\r' | awk -v out="$1" "$POPUP_AWK"'
        { if (parse($0)) print trim($0) > out; else print }'
}

# 内置 + 订阅 + 我的 → $CACHE/popup.rules（「包名或 *<TAB>类型<TAB>词」，Zygisk 库在应用启动时读取，改完立即生效）
popup_build() {
    mkdir -p "$CACHE"
    cat "$MODDIR/mod/popup_rules.txt" "$RULES/sub/popup.txt" "$RULES/popup.txt" 2>/dev/null | tr -d '\r' |
        awk "$POPUP_AWK"'
        parse($0) {
            n = split(P_words, a, ",")
            for (j = 1; j <= n; j++) {
                x = trim(a[j])
                if (x != "" && length(x) <= 64) print P_pkg "\t" P_neg KEY[P_key] "\t" x
            }
        }' > "$CACHE/.popup" && mv -f "$CACHE/.popup" "$CACHE/popup.rules"
    chmod 0644 "$CACHE/popup.rules" 2>/dev/null
    true
}

# 只重建 SNI / IP 两条子链（热更新用，毫秒级，不影响其他规则）
lists_apply() {
    for t in ipt ip6t; do $t -N "$SNI_CHAIN" 2>/dev/null; $t -F "$SNI_CHAIN"; done
    ipt -N "$IP_CHAIN" 2>/dev/null; ipt -F "$IP_CHAIN"
    n=0
    if [ "$BLOCK_SNI" = 1 ]; then
        while read -r d; do
            [ -n "$d" ] || continue
            for t in ipt ip6t; do
                $t -A "$SNI_CHAIN" -m string --string "$d" --algo bm -j REJECT --reject-with tcp-reset 2>/dev/null
            done && n=$((n + 1))
        done < "$CACHE/sni.list"
        [ -s "$CACHE/sni.list" ] && [ "$n" = 0 ] && log "ERROR: SNI 拦截未生效（内核可能不支持 string 匹配）"
    fi
    m=0
    while read -r ip; do
        [ -n "$ip" ] || continue
        ipt -A "$IP_CHAIN" -d "$ip" -j DROP && m=$((m + 1))
    done < "$CACHE/ip.list"
    log "规则已加载：拦截域名 $n 个，IP $m 个，DNS 规则 $(grep -vc '^!' "$CACHE/dns.list" 2>/dev/null) 条"
}

rules_apply() {
    rules_remove
    ipt -N "$CHAIN" || { log "ERROR: 无法创建 iptables 链"; return 1; }
    ip6t -N "$CHAIN"
    for pkg in $BLOCK_PKGS; do
        uid=$(pkg_uid "$pkg")
        if [ -z "$uid" ]; then
            log "SKIP: $pkg 未安装"
        elif [ "$uid" -lt 10000 ] 2>/dev/null; then
            log "SKIP: $pkg 使用共享系统 UID $uid，断网会波及整个系统，已跳过"
        else
            ipt  -A "$CHAIN" -m owner --uid-owner "$uid" -j REJECT
            ip6t -A "$CHAIN" -m owner --uid-owner "$uid" -j REJECT
            log "BLOCK: $pkg (uid=$uid) IPv4+IPv6"
        fi
    done
    if [ "$BLOCK_DNSPOD" = 1 ]; then
        ipt  -A "$CHAIN" -d 119.29.29.29 -j DROP
        ip6t -A "$CHAIN" -d 2402:4e00:: -j DROP
    fi
    if [ "$BLOCK_QUIC" = 1 ]; then
        ipt  -A "$CHAIN" -p udp --dport 443 -j REJECT
        ip6t -A "$CHAIN" -p udp --dport 443 -j REJECT
    fi
    rules_build >/dev/null
    lists_apply
    # 只检查每个连接的前几个包（TLS 握手 / HTTP 请求头），大流量上传不会被逐包扫描
    for t in ipt ip6t; do
        $t -A "$CHAIN" -p tcp -m multiport --dports 80,443 -m connbytes --connbytes 0:6 \
            --connbytes-dir original --connbytes-mode packets -j "$SNI_CHAIN" 2>/dev/null ||
        $t -A "$CHAIN" -p tcp -m multiport --dports 80,443 -j "$SNI_CHAIN"
    done
    ipt -A "$CHAIN" -j "$IP_CHAIN"
    ipt  -I OUTPUT 1 -j "$CHAIN"
    ip6t -I OUTPUT 1 -j "$CHAIN"
    log "网络拦截已应用: $(rule_count) 条 (IPv4)"
}

# 冻结或挂起后会弄坏系统功能的包，永远不碰（取自 android-ad-cleaner 的实测）
# appdetail：挂起后第三方安装会卡在「正在安装」；instant.platform：负一屏快递卡片详情页打不开
NEVER_PKGS="com.oplus.appdetail com.nearme.instant.platform com.heytap.market com.heytap.quicksearchbox com.coloros.assistantscreen com.android.systemui com.android.settings com.android.phone android"
is_never() { case " $NEVER_PKGS " in *" $1 "*) return 0 ;; esac; return 1; }

disable_pkgs() {
    # 从冻结名单里移除的包自动解冻
    if [ -f "$PERSIST/frozen.list" ]; then
        while read -r p; do
            [ -n "$p" ] || continue
            case " $DISABLE_PKGS " in *" $p "*) ;; *) pm enable "$p" >/dev/null 2>&1 && log "ENABLE: $p（已从冻结名单移除）" ;; esac
        done < "$PERSIST/frozen.list"
    fi
    : > "$PERSIST/frozen.list"
    for p in $DISABLE_PKGS; do
        if is_never "$p"; then log "SKIP: $p 冻结后会影响系统功能，不处理"; continue; fi
        echo "$p" >> "$PERSIST/frozen.list"
        if pm path "$p" >/dev/null 2>&1; then
            out=$(pm disable "$p" 2>&1) || out=$(pm disable-user --user 0 "$p" 2>&1)
            log "DISABLE: $p -> $out"
        else
            log "SKIP: $p 不存在"
        fi
    done
}

# ---------------- 挂起系统广告组件（pm suspend，可随时还原）----------------
QUICKAPP_PKGS="com.oppo.instant.local.service com.nearme.instant.card"
PICTORIAL_PKGS="com.heytap.pictorial"
suspend_want() {
    [ "$SUSPEND_QUICKAPP" = 1 ] && echo "$QUICKAPP_PKGS"
    [ "$SUSPEND_PICTORIAL" = 1 ] && echo "$PICTORIAL_PKGS"
    return 0
}
is_suspended() { dumpsys package "$1" 2>/dev/null | grep -q 'suspended=true'; }

suspend_pkgs() {
    want=" $(suspend_want | tr '\n' ' ') "
    # 关掉开关的：只还原本模块挂起过的
    if [ -f "$PERSIST/suspended.list" ]; then
        while read -r p; do
            [ -n "$p" ] || continue
            case "$want" in *" $p "*) ;; *) pm unsuspend --user 0 "$p" >/dev/null 2>&1 && log "UNSUSPEND: $p" ;; esac
        done < "$PERSIST/suspended.list"
    fi
    if [ -f "$MODDIR/disable" ]; then unsuspend_all; : > "$PERSIST/suspended.list"; return 0; fi
    : > "$PERSIST/suspended.list"
    for p in $want; do
        is_never "$p" && continue
        pm path "$p" >/dev/null 2>&1 || { log "SKIP: $p 不存在"; continue; }
        echo "$p" >> "$PERSIST/suspended.list"
        is_suspended "$p" && continue
        out=$(pm suspend --user 0 "$p" 2>&1)
        log "SUSPEND: $p -> $out"
    done
}

unsuspend_all() {
    [ -f "$PERSIST/suspended.list" ] || return 0
    while read -r p; do
        [ -n "$p" ] && pm unsuspend --user 0 "$p" >/dev/null 2>&1
    done < "$PERSIST/suspended.list"
}

# ---------------- 开屏广告自动跳过（Zygisk）----------------
# Zygisk 库在每个应用启动时读取 $SKIP_CONF，只对名单里的应用生效
SKIP_APPS=$PERSIST/skip_apps.list
SKIP_CONF=$PERSIST/skip.conf
skip_sync() {
    w=$SKIP_WINDOW
    case "$w" in ''|*[!0-9]*) w=8 ;; esac
    [ "$w" -lt 2 ] && w=2; [ "$w" -gt 30 ] && w=30
    {
        echo "# 自动生成，不要手动修改；应用名单在 skip_apps.list"
        echo "on=$([ "$ENABLE_SKIP" = 1 ] && echo 1 || echo 0)"
        echo "window=$w"
        echo "popup=$([ "$POPUP_DISMISS" = 1 ] && echo 1 || echo 0)"
        pw=$POPUP_WINDOW
        case "$pw" in ''|*[!0-9]*) pw=7 ;; esac
        [ "$pw" -lt 1 ] && pw=1; [ "$pw" -gt 60 ] && pw=60
        echo "popup_window=$pw"
        [ -f "$SKIP_APPS" ] && grep -E '^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$' "$SKIP_APPS" | sed 's/^/app=/'
        true    # 名单为空时 grep 返回 1，不能让它挡住写文件
    } > "$SKIP_CONF.tmp" && mv -f "$SKIP_CONF.tmp" "$SKIP_CONF"
    chmod 0644 "$SKIP_CONF"
}
# 0 = 正常；1 = 没装 Zygisk 库；2 = 没有可用的 Zygisk
skip_env() {
    ls "$MODDIR"/zygisk/*.so >/dev/null 2>&1 || { echo nolib; return; }
    for m in /data/adb/modules/zygisksu /data/adb/modules/zygisk_next /data/adb/modules/rezygisk /data/adb/modules/zygisk_noksu; do
        [ -d "$m" ] && [ ! -f "$m/disable" ] && [ ! -f "$m/remove" ] && { echo ok; return; }
    done
    echo nozygisk
}

# ---------------- AdGuard Home 配置 ----------------
# DNS 监听端口（从 yaml 的 dns: 段读取）
agh_port() { awk '/^dns:/{d=1;next} /^[^ #]/{d=0} d && /^  port:/{print $2; exit}' "$AGH_YAML" 2>/dev/null; }
agh_web()  { awk '/^http:/{h=1;next} /^[^ #]/{h=0} h && /^  address:/{print $2; exit}' "$AGH_YAML" 2>/dev/null; }

# 确保 yaml 里有「反诈屏蔽」本地过滤器，并允许读取 userfilters 目录（幂等）
agh_ensure_yaml() {
    [ -f "$AGH_YAML" ] || return 1
    mkdir -p "$AGH_DIR/userfilters"
    [ -s "$CACHE/dns.list" ] || rules_build >/dev/null
    agh_sync_filter
    pat="$AGH_DIR/userfilters/*"
    tmp="$AGH_YAML.afa_tmp"
    if ! grep -q "id: $AGH_FILTER_ID\$" "$AGH_YAML"; then
        awk -v url="$AGH_FILTER" -v id="$AGH_FILTER_ID" '
            function entry() { print "  - enabled: true"; print "    url: " url; print "    name: 反诈屏蔽（模块内置）"; print "    id: " id }
            /^filters: *\[\] *$/ { print "filters:"; entry(); next }
            /^filters: *$/       { print; entry(); next }
            { print }' "$AGH_YAML" > "$tmp" && mv -f "$tmp" "$AGH_YAML"
        log "AGH: 已添加反诈过滤器"
    fi
    if ! grep -qF -- "- $pat" "$AGH_YAML"; then
        if grep -q '^  safe_fs_patterns:' "$AGH_YAML"; then
            awk -v pat="$pat" '
                /^  safe_fs_patterns: *\[\] *$/ { print "  safe_fs_patterns:"; print "    - " pat; next }
                /^  safe_fs_patterns: *$/       { print; print "    - " pat; next }
                { print }' "$AGH_YAML" > "$tmp" && mv -f "$tmp" "$AGH_YAML"
        else
            awk -v pat="$pat" '
                /^filtering: *$/ { print; print "  safe_fs_patterns:"; print "    - " pat; next }
                { print }' "$AGH_YAML" > "$tmp" && mv -f "$tmp" "$AGH_YAML"
        fi
        log "AGH: 已添加 safe_fs_patterns"
    fi
    chmod 600 "$AGH_YAML"
}

# 把合并后的 DNS 规则写进 AdGuard 的本地过滤器
agh_sync_filter() {
    mkdir -p "$AGH_DIR/userfilters" "$AGH_DIR/data/filters"
    src="$CACHE/dns.list"; [ -s "$src" ] || src="$MODDIR/mod/antifraud_rules.txt"
    cp -f "$src" "$AGH_FILTER"
    cp -f "$src" "$AGH_DIR/data/filters/$AGH_FILTER_ID.txt"
}

# 是否存在另一个 AdGuard Home 模块（会抢 DNS 端口和重定向）
other_agh_module() {
    m=/data/adb/modules/AdGuardHome
    [ -d "$m" ] && [ ! -f "$m/disable" ] && [ ! -f "$m/remove" ]
}
