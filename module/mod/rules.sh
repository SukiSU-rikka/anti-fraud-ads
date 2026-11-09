#!/system/bin/sh
# 规则热更新：reload | import <文件> | sub_update | sub_auto | watch <事件> <目录> <文件>
MODDIR=/data/adb/modules/anti_fraud_ads
[ -n "$AFA_MODDIR" ] && MODDIR=$AFA_MODDIR
. "$MODDIR/mod/common.sh"
SUBS=$RULES/subs.txt        # 订阅地址，一行一个
SUB_STATE=$RULES/sub/state  # 上次更新时间与结果

reload() {
    [ -f "$MODDIR/disable" ] && { echo "模块已禁用，规则会在启用时加载"; return 0; }
    if rules_build; then dns_changed=1; else dns_changed=0; fi
    if rules_active; then lists_apply; else rules_apply; fi
    agh_sync_filter
    # DNS 规则变了才重启 AdGuard（约 2 秒；重启期间 DNS 直连，不会断网）
    if [ "$dns_changed" = 1 ] && [ -f "$AGH_DIR/agh.pid" ]; then
        sh "$MODDIR/mod/agh.sh" stop >/dev/null 2>&1
        sh "$MODDIR/mod/agh.sh" start >/dev/null 2>&1
        log "规则热更新：DNS 规则有变化，AdGuard 已重载"
    fi
    echo "拦截域名 $(wc -l < "$CACHE/sni.list") 个，IP $(wc -l < "$CACHE/ip.list") 个，DNS 规则 $(grep -vc '^!' "$CACHE/dns.list") 条"
}

# 把一段规则文本归类后追加到「我的规则」，返回各类新增条数
import_file() {
    mkdir -p "$RULES" "$CACHE"
    : > "$CACHE/.imp_popup"
    popup_split "$CACHE/.imp_popup" < "$1" | classify > "$CACHE/.imp"
    sed 's/^/popup\t/' "$CACHE/.imp_popup" >> "$CACHE/.imp"
    rm -f "$CACHE/.imp_popup"
    out=""
    for k in sni dns ip allow popup; do
        touch "$RULES/$k.txt"
        before=$(grep -c . "$RULES/$k.txt")
        awk -F'\t' -v k="$k" '$1==k {print $2}' "$CACHE/.imp" >> "$RULES/$k.txt"
        awk 'NF && !seen[$0]++' "$RULES/$k.txt" > "$RULES/.$k" && mv -f "$RULES/.$k" "$RULES/$k.txt"
        add=$(( $(grep -c . "$RULES/$k.txt") - before ))
        [ "$add" -gt 0 ] && out="$out $k+$add"
    done
    rm -f "$CACHE/.imp"
    echo "${out:- 没有新规则}"
}

fetch() {   # fetch URL 输出文件
    rm -f "$2"
    curl -fsSL --max-time 30 -o "$2" "$1" 2>/dev/null && [ -s "$2" ] && return 0
    busybox wget -q -T 30 -O "$2" "$1" 2>/dev/null && [ -s "$2" ] && return 0
    wget -q -T 30 -O "$2" "$1" 2>/dev/null && [ -s "$2" ] && return 0
    rm -f "$2"; return 1
}

sub_update() {
    mkdir -p "$RULES/sub"
    [ -s "$SUBS" ] || { echo "没有订阅地址"; rm -f "$RULES/sub/"*.txt; echo "$(date +%s)|没有订阅" > "$SUB_STATE"; return 0; }
    tmp=$RULES/sub/.new; : > "$tmp"
    ok=0; fail=0; i=0
    while read -r url; do
        case "$url" in http://*|https://*) ;; *) continue ;; esac
        i=$((i + 1))
        if fetch "$url" "$RULES/sub/.dl" && [ "$(wc -c < "$RULES/sub/.dl")" -lt 4194304 ]; then
            cat "$RULES/sub/.dl" >> "$tmp"; echo >> "$tmp"; ok=$((ok + 1))
        else
            fail=$((fail + 1)); log "订阅下载失败: $url"
        fi
    done < "$SUBS"
    rm -f "$RULES/sub/.dl"
    if [ "$ok" -gt 0 ]; then
        : > "$RULES/sub/.pop"
        popup_split "$RULES/sub/.pop" < "$tmp" | classify > "$RULES/sub/.cls"
        sed 's/^/popup\t/' "$RULES/sub/.pop" >> "$RULES/sub/.cls"
        rm -f "$RULES/sub/.pop"
        for k in sni dns ip allow popup; do awk -F'\t' -v k="$k" '$1==k && !seen[$2]++ {print $2}' "$RULES/sub/.cls" > "$RULES/sub/$k.txt"; done
        rm -f "$RULES/sub/.cls"
    fi
    rm -f "$tmp"
    msg="成功 $ok 个，失败 $fail 个"
    echo "$(date +%s)|$msg" > "$SUB_STATE"
    log "订阅更新：$msg"
    echo "$msg"
    [ "$ok" -gt 0 ] && reload >/dev/null
}

# inotifyd 直接调用时参数是「事件 目录 文件」
case "$1" in w|y|d) set -- watch "$@" ;; esac

case "$1" in
reload) reload ;;
import) r=$(import_file "$2"); echo "$r"; reload >/dev/null ;;
sub_update) sub_update ;;
sub_auto)
    [ "$SUB_AUTO" = 1 ] && [ -s "$SUBS" ] || exit 0
    last=$(cut -d'|' -f1 "$SUB_STATE" 2>/dev/null); [ -z "$last" ] && last=0
    [ $(( $(date +%s) - last )) -ge $(( ${SUB_INTERVAL:-24} * 3600 )) ] && sub_update >/dev/null
    exit 0
    ;;
watch)   # inotifyd 回调：规则文件被保存后 3 秒自动热更新（合并多次保存）
    case "$4" in *.txt) ;; *) exit 0 ;; esac
    touch "$CACHE/.dirty" 2>/dev/null
    mkdir "$CACHE/.lock" 2>/dev/null || exit 0
    while [ -f "$CACHE/.dirty" ]; do rm -f "$CACHE/.dirty"; sleep 3; reload >/dev/null; done
    rmdir "$CACHE/.lock"
    ;;
esac
