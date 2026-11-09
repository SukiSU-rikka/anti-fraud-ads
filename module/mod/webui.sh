#!/system/bin/sh
# WebUI 后端：所有带用户输入的参数都用 base64 传入，避免引号/注入问题
MODDIR=/data/adb/modules/anti_fraud_ads
[ -n "$AFA_MODDIR" ] && MODDIR=$AFA_MODDIR
. "$MODDIR/mod/common.sh"
b64d() { echo "$1" | base64 -d 2>/dev/null; }
KEYS="ENABLE_AGH AGH_BLOCK_IPV6_DNS AGH_BLOCK_DOT BLOCK_QUIC BLOCK_IP_LIST BLOCK_COLOROS_IP BLOCK_SNI BLOCK_DNSPOD ADS_LOCK SUB_AUTO SUSPEND_QUICKAPP SUSPEND_PICTORIAL ENABLE_SKIP POPUP_DISMISS"

case "$1" in
status)
    pid=$(cat "$AGH_DIR/agh.pid" 2>/dev/null)
    if [ -n "$pid" ] && [ "$(readlink "/proc/$pid/exe" 2>/dev/null)" = "$AGH_BIN" ]; then echo "agh=1"; echo "pid=$pid"; else echo "agh=0"; fi
    ipt -t nat -C OUTPUT -j "$DNS_CHAIN" 2>/dev/null && echo "dns=1" || echo "dns=0"
    rules_active && echo "rules=$(rule_count)" || echo "rules=0"
    echo "sni_hits=$(ipt -L "$SNI_CHAIN" -v -n -x 2>/dev/null | awk '/STRING/ {s+=$1} END {print s+0}')"
    echo "sni_rules=$(ipt -S "$SNI_CHAIN" 2>/dev/null | grep -c -- '--string')"
    echo "port=$(agh_port)"; echo "web=$(agh_web)"
    echo "version=$(grep -m1 '^version=' "$MODDIR/module.prop" | cut -d= -f2)"
    echo "agh_version=$("$AGH_BIN" --version 2>/dev/null | head -1 | sed 's/.*version //')"
    echo "disabled=$([ -f "$MODDIR/disable" ] && echo 1 || echo 0)"
    echo "locked=$(cat "$PERSIST/locked.list" 2>/dev/null | wc -l)"
    echo "private_dns=$(settings get global private_dns_mode 2>/dev/null)"
    for p in $BLOCK_PKGS; do
        uid=$(pkg_uid "$p")
        if [ -z "$uid" ]; then st=missing
        elif [ "$uid" -lt 10000 ]; then st=shared
        elif ipt -S "$CHAIN" 2>/dev/null | grep -q "uid-owner $uid "; then st=blocked
        else st=open; fi
        echo "pkg=$p|$uid|$st"
    done
    dis=$(pm list packages -d 2>/dev/null)
    for p in $DISABLE_PKGS; do
        if ! pm path "$p" >/dev/null 2>&1; then st=missing
        elif echo "$dis" | grep -qx "package:$p"; then st=frozen
        else st=active; fi
        echo "frz=$p|$st"
    done
    for p in $QUICKAPP_PKGS $PICTORIAL_PKGS; do
        if ! pm path "$p" >/dev/null 2>&1; then st=missing
        elif is_suspended "$p"; then st=suspended
        else st=active; fi
        echo "sus=$p|$st"
    done
    echo "skip_env=$(skip_env)"
    lg=$(logcat -d -s AFA-Skip:I 2>/dev/null)
    echo "skip_n=$(echo "$lg" | grep -cF '跳过「')"
    echo "popup_n=$(echo "$lg" | grep -cF '关闭弹窗「')"
    echo "skip_apps=$(cat "$SKIP_APPS" 2>/dev/null | grep -cE '^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$')"
    ;;
getconf)
    for k in $KEYS; do eval "echo $k=\$$k"; done
    echo "SKIP_WINDOW=$SKIP_WINDOW"
    echo "POPUP_WINDOW=$POPUP_WINDOW"
    echo "BLOCK_PKGS=$BLOCK_PKGS"
    echo "DISABLE_PKGS=$DISABLE_PKGS"
    ;;
save)   # $2 = base64(user.conf 全文)
    b64d "$2" > "$PERSIST/user.conf.new" && [ -s "$PERSIST/user.conf.new" ] && mv -f "$PERSIST/user.conf.new" "$PERSIST/user.conf"
    log "WebUI: 设置已保存"
    echo ok
    ;;
rules_get)   # $2 = sni|dns|ip|allow
    case "$2" in sni|dns|ip|allow|popup) cat "$RULES/$2.txt" 2>/dev/null ;; esac
    ;;
rules_save)  # $2 = 类型  $3 = base64(内容)
    case "$2" in sni|dns|ip|allow|popup) ;; *) echo "类型不对"; exit 0 ;; esac
    mkdir -p "$RULES"
    b64d "$3" | tr -d '\r' > "$RULES/.$2" && mv -f "$RULES/.$2" "$RULES/$2.txt"
    sh "$MODDIR/mod/rules.sh" reload
    ;;
import)      # $2 = base64(规则文本)
    mkdir -p "$CACHE"
    b64d "$2" > "$CACHE/.paste"
    sh "$MODDIR/mod/rules.sh" import "$CACHE/.paste"
    rm -f "$CACHE/.paste"
    ;;
stats)
    [ -s "$CACHE/sni.list" ] || rules_build >/dev/null
    cnt() { grep -v '^[#!]' "$1" 2>/dev/null | grep -c . ; }
    echo "builtin_sni=$(cnt "$MODDIR/mod/sni_block.txt")"
    echo "user_sni=$(cnt "$RULES/sni.txt")"; echo "user_dns=$(cnt "$RULES/dns.txt")"
    echo "user_ip=$(cnt "$RULES/ip.txt")"; echo "user_allow=$(cnt "$RULES/allow.txt")"
    echo "user_popup=$(cnt "$RULES/popup.txt")"
    sub=0; for k in sni dns ip allow popup; do sub=$((sub + $(cnt "$RULES/sub/$k.txt"))); done; echo "sub_total=$sub"
    echo "popup_total=$(grep -c . "$CACHE/popup.rules" 2>/dev/null)"
    echo "sni_total=$(grep -c . "$CACHE/sni.list" 2>/dev/null)"
    echo "ip_total=$(grep -c . "$CACHE/ip.list" 2>/dev/null)"
    echo "dns_total=$(grep -vc '^!' "$CACHE/dns.list" 2>/dev/null)"
    echo "builtin_list=$(grep -v '^#' "$MODDIR/mod/sni_block.txt" | grep . | tr '\n' ' ')"
    echo "allow_list=$(grep -v '^#' "$MODDIR/mod/allow.txt" | grep . | tr '\n' ' ')"
    ;;
sub_get)
    cat "$RULES/subs.txt" 2>/dev/null | sed 's/^/url=/'
    st=$(cat "$RULES/sub/state" 2>/dev/null)
    [ -n "$st" ] && echo "last=$(date -d "@${st%%|*}" '+%m-%d %H:%M' 2>/dev/null || echo "${st%%|*}")|${st#*|}"
    ;;
sub_save)    # $2 = base64(地址列表)
    mkdir -p "$RULES"
    b64d "$2" | tr -d '\r' | grep -E '^https?://[^[:space:]]+$' > "$RULES/subs.txt"
    echo ok
    ;;
sub_update)
    sh "$MODDIR/mod/rules.sh" sub_update
    ;;
apply)
    rules_apply
    disable_pkgs
    suspend_pkgs
    skip_sync
    sig="$ENABLE_AGH|$AGH_BLOCK_IPV6_DNS|$AGH_BLOCK_DOT"
    if [ "$(cat "$PERSIST/.agh_sig" 2>/dev/null)" != "$sig" ]; then
        sh "$MODDIR/mod/agh.sh" stop
        echo "$sig" > "$PERSIST/.agh_sig"
    fi
    sh "$MODDIR/mod/agh.sh" start
    sh "$MODDIR/mod/agh.sh" status
    ;;
pause)
    sh "$MODDIR/mod/agh.sh" stop
    rules_remove
    log "WebUI: 已暂停"
    echo ok
    ;;
resume)
    rules_apply
    sh "$MODDIR/mod/agh.sh" start
    sh "$MODDIR/mod/agh.sh" status
    ;;
test)   # $2 = base64(域名)
    d=$(b64d "$2" | tr -cd 'A-Za-z0-9.-')
    [ -n "$d" ] || { echo "域名无效"; exit 0; }
    r=$(ping -c 1 -W 2 "$d" 2>&1 | head -1)
    case "$r" in
        *"(0.0.0.0)"*|*"(::)"*) echo "blocked|DNS 已拦截：解析结果为 0.0.0.0" ;;
        *"unknown host"*|*"bad address"*) echo "blocked|DNS 已拦截：无法解析" ;;
        *"("*")"*) ip=$(echo "$r" | sed -n 's/.*(\([^)]*\)).*/\1/p'); echo "open|DNS 未拦截：解析到 $ip" ;;
        *) echo "unknown|$r" ;;
    esac
    ;;
log)
    case "$2" in
        module) tail -n 120 "$LOG" 2>/dev/null ;;
        check)  sh "$MODDIR/mod/self_check.sh" "$MODDIR"; tail -n 40 "$PERSIST/self_check.log" ;;
        agh)    tail -n 120 "$AGH_DIR/agh.log" 2>/dev/null ;;
    esac
    ;;
passwd) # $2 = base64(bcrypt 哈希)
    h=$(b64d "$2")
    case "$h" in '$2'[aby]'$'*) ;; *) echo "哈希格式不对"; exit 0 ;; esac
    cp -f "$AGH_YAML" "$AGH_YAML.bak"
    awk -v h="$h" '
        /^users:/ {u=1; print; next}
        /^[^ ]/ {u=0}
        u && !done && /^ +password:/ { sub(/password:.*/, "password: " h); done=1 }
        {print}' "$AGH_YAML" > "$AGH_YAML.tmp" && mv -f "$AGH_YAML.tmp" "$AGH_YAML"
    chmod 600 "$AGH_YAML"
    sh "$MODDIR/mod/agh.sh" stop; sh "$MODDIR/mod/agh.sh" start
    grep -qF "$h" "$AGH_YAML" && echo ok || echo "写入失败，已保留备份 AdGuardHome.yaml.bak"
    ;;
apps)        # 第三方应用包名，一行一个
    pm list packages -3 2>/dev/null | sed -n 's/^package://p' | sort
    ;;
skip_get)
    cat "$SKIP_APPS" 2>/dev/null
    ;;
skip_save)   # $2 = base64(包名列表)
    b64d "$2" | tr -d '\r' | grep -E '^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$' | sort -u > "$SKIP_APPS.new"
    mv -f "$SKIP_APPS.new" "$SKIP_APPS"
    skip_sync
    echo "ok $(grep -c . "$SKIP_APPS")"
    ;;
popup_builtin)
    cat "$MODDIR/mod/popup_rules.txt"
    ;;
skip_log)    # 最近的跳过记录（Zygisk 库写进 logcat）
    logcat -d -v time -s AFA-Skip:I AFA-Skip:W 2>/dev/null | grep 'AFA-Skip' | tail -n 40 |
        sed 's/^\([0-9-]* [0-9:]*\)\.[0-9]* \([IW]\)\/AFA-Skip( *[0-9]*): /\1 /'
    ;;
open)
    w=$(agh_web); [ -z "$w" ] && w=127.0.0.1:3000
    am start -a android.intent.action.VIEW -d "http://$w" >/dev/null 2>&1; echo ok
    ;;
esac
