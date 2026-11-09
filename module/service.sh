#!/system/bin/sh
MODDIR=${0%/*}
. "$MODDIR/mod/common.sh"

[ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 204800 ] && : > "$LOG"

log "=== service.sh start ($(grep -m1 '^version=' "$MODDIR/module.prop" | cut -d= -f2)) ==="

until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 3; done
for i in $(seq 1 30); do [ -s /data/system/packages.list ] && break; sleep 2; done

# v7.2 的自定义域名迁移到「我的规则」
mkdir -p "$RULES" "$CACHE"
if [ -f "$PERSIST/sni_user.txt" ]; then
    cat "$PERSIST/sni_user.txt" >> "$RULES/sni.txt"; rm -f "$PERSIST/sni_user.txt"
fi
rm -rf "$CACHE/.lock" "$CACHE/.dirty"

rules_apply
disable_pkgs
suspend_pkgs
skip_sync
nohup sh "$MODDIR/mod/agh.sh" start >/dev/null 2>&1 &

# 禁用/启用模块即时生效
busybox pkill -f "inotifyd $MODDIR/mod/inotify.sh" 2>/dev/null
nohup inotifyd "$MODDIR/mod/inotify.sh" "$MODDIR:d,n" >/dev/null 2>&1 &

# 规则热更新：/data/adb/afa/rules/ 里的文件保存后自动生效
busybox pkill -f "inotifyd $MODDIR/mod/rules.sh" 2>/dev/null
nohup inotifyd "$MODDIR/mod/rules.sh" "$RULES:w,y,d" >/dev/null 2>&1 &

# 开屏跳过记录：系统日志几分钟就会被别的应用冲掉，开机后把本模块的记录单独存一份
SKIP_LOG=$PERSIST/skip.log
[ -f "$SKIP_LOG" ] && [ "$(wc -c < "$SKIP_LOG")" -gt 102400 ] && { tail -n 300 "$SKIP_LOG" > "$SKIP_LOG.tmp"; mv -f "$SKIP_LOG.tmp" "$SKIP_LOG"; }
[ -f "$PERSIST/.skiplog.pid" ] && kill "$(cat "$PERSIST/.skiplog.pid")" 2>/dev/null
nohup logcat -v time -s AFA-Skip:I >> "$SKIP_LOG" 2>/dev/null &
echo $! > "$PERSIST/.skiplog.pid"

# 订阅自动更新：开机 2 分钟后检查一次，之后每 30 分钟检查是否到期
nohup sh -c "sleep 120; while true; do sh '$MODDIR/mod/rules.sh' sub_auto; sleep 1800; done" >/dev/null 2>&1 &

if [ "$ADS_LOCK" = 1 ]; then
    nohup sh -c "
        until [ -d /data/media/0/Android/data ]; do sleep 10; done
        exec sh '$MODDIR/mod/ads_lock.sh' '$MODDIR'
    " >> "$LOG" 2>&1 &
fi
nohup sh -c "sleep 300; exec sh '$MODDIR/mod/self_check.sh' '$MODDIR'" >/dev/null 2>&1 &
log "service.sh done"
