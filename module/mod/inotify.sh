#!/system/bin/sh
# 管理器里禁用/启用模块时立即生效，无需重启
MODDIR=/data/adb/modules/anti_fraud_ads
. "$MODDIR/mod/common.sh"
[ "$3" = disable ] || exit 0
case "$1" in
    n) log "模块被禁用：停止全部功能"; sh "$MODDIR/mod/agh.sh" stop; rules_remove; unsuspend_all ;;
    d) log "模块被启用：恢复全部功能"; rules_apply; suspend_pkgs; sh "$MODDIR/mod/agh.sh" start ;;
esac
