#!/system/bin/sh
# 「执行」按钮：检查状态（DNS 没接管会自动修复），然后打开 AdGuard 后台
# 想暂停全部功能：在管理器里关闭本模块开关即可，立即生效，打开开关立即恢复
MODDIR=${0%/*}
. "$MODDIR/mod/common.sh"

echo "检查状态..."
sh "$MODDIR/mod/agh.sh" start >/dev/null 2>&1
rules_active || rules_apply
sh "$MODDIR/mod/agh.sh" status
echo "反诈规则: $(rule_count) 条"
WEB=$(agh_web); [ -z "$WEB" ] && WEB=127.0.0.1:3000
echo ""
echo "正在打开 AdGuard 后台 http://$WEB （账号密码默认 root / root）"
echo "暂停全部功能：在管理器里关闭本模块开关（立即生效）"
sleep 1
am start -a android.intent.action.VIEW -d "http://$WEB" >/dev/null 2>&1
