#!/system/bin/sh
# 开机 5 分钟后自检；规则丢失且未手动暂停时自动补回
MODDIR=${1:-/data/adb/modules/anti_fraud_ads}
. "$MODDIR/mod/common.sh"
OUT="$PERSIST/self_check.log"
{
echo "=================================================="
echo "[$(date '+%F %T')] 自检  版本: $(grep -m1 '^version=' "$MODDIR/module.prop" | cut -d= -f2)"
echo "[环境] $(getprop ro.product.model) / ColorOS $(getprop ro.build.version.oplusrom) / $(getprop ro.build.display.id)"

if [ -f "$MODDIR/disable" ]; then
    echo "[INFO] 模块已在管理器中禁用，跳过检查"
else
    # ---- AdGuard ----
    if [ "$ENABLE_AGH" = 1 ]; then
        if other_agh_module; then
            echo "[WARN] 另一个 AdGuardHome 模块仍在启用，本模块的 AdGuard 未启动。请在管理器里删除它"
        else
            sh "$MODDIR/mod/agh.sh" start >/dev/null 2>&1   # 运行中但没接管 DNS 会自动补上
            st=$(sh "$MODDIR/mod/agh.sh" status)
            case "$st" in
                *运行中*) echo "[PASS] $(echo "$st" | head -1)"
                          echo "$st" | grep -q "未接管" && echo "[WARN] DNS 未接管，见 module.log" || echo "[PASS] DNS 已接管" ;;
                *) echo "[WARN] AdGuard 未运行，尝试重新启动..."
                   sh "$MODDIR/mod/agh.sh" start
                   sh "$MODDIR/mod/agh.sh" status | sed 's/^/       /' ;;
            esac
            pd=$(settings get global private_dns_mode 2>/dev/null)
            [ "$pd" = hostname ] && echo "[WARN] 私人DNS 设置为指定服务器，会绕过 AdGuard，建议改为「关闭」"
        fi
    else
        echo "[INFO] AdGuard 已在配置中关闭"
    fi

    # ---- 反诈 ----
    if rules_active; then
        echo "[PASS] 反诈拦截链生效：$(rule_count) 条 IPv4 规则"
    else
        echo "[WARN] 反诈拦截链丢失，正在重新应用..."
        rules_apply
        rules_active && echo "[PASS] 已恢复：$(rule_count) 条" || echo "[FAIL] 恢复失败，见 module.log"
    fi
    for p in $BLOCK_PKGS; do
        uid=$(pkg_uid "$p")
        if [ -z "$uid" ]; then echo "[INFO] $p 未安装"
        elif [ "$uid" -lt 10000 ]; then echo "[WARN] $p uid=$uid（共享系统UID，未断网）"
        else ipt -S "$CHAIN" 2>/dev/null | grep -q "uid-owner $uid " && echo "[PASS] $p uid=$uid 已断网" || echo "[WARN] $p uid=$uid 未拦截"
        fi
    done
fi

disabled=$(pm list packages -d 2>/dev/null)
for p in $DISABLE_PKGS; do
    if ! pm path "$p" >/dev/null 2>&1; then echo "[INFO] $p 不存在"
    elif echo "$disabled" | grep -qx "package:$p"; then echo "[PASS] $p 已冻结"
    else echo "[WARN] $p 未冻结"
    fi
done
for p in $(suspend_want); do
    if ! pm path "$p" >/dev/null 2>&1; then echo "[INFO] $p 不存在"
    elif is_suspended "$p"; then echo "[PASS] $p 已挂起"
    else echo "[WARN] $p 未挂起，正在补上"; suspend_pkgs; fi
done
if [ "$ENABLE_SKIP" = 1 ]; then
    case "$(skip_env)" in
        ok)       echo "[PASS] 开屏跳过：Zygisk 正常，已选 $(cat "$SKIP_APPS" 2>/dev/null | grep -c .) 个应用" ;;
        nolib)    echo "[INFO] 开屏跳过：本模块不含 Zygisk 库（需要 GitHub 编译版），此功能未生效" ;;
        nozygisk) echo "[WARN] 开屏跳过：没有检测到启用中的 Zygisk Next" ;;
    esac
    [ -f "$SKIP_CONF" ] || skip_sync
fi
echo "[INFO] 已锁定广告缓存路径: $(cat "$PERSIST/locked.list" 2>/dev/null | wc -l) 个"

ERR=$(grep -E 'ERROR|FAIL' "$LOG" 2>/dev/null | tail -3)
[ -n "$ERR" ] && { echo "[WARN] module.log 近期错误:"; echo "$ERR" | sed 's/^/   /'; }
echo "=================================================="
} >> "$OUT" 2>&1
