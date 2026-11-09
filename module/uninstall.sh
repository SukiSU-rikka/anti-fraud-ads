#!/system/bin/sh
# 卸载：停止 AdGuard、删除自己的规则；解冻应用、解锁缓存要等开机解锁后才能做，
# 交给 /data/adb/service.d/ 里的一次性脚本，完成后连同 /data/adb/afa 一起删除。
MODDIR=${0%/*}
. "$MODDIR/mod/common.sh"
sh "$MODDIR/mod/agh.sh" stop 2>/dev/null
rules_remove
rm -rf "$AGH_DIR"

CLEAN=/data/adb/service.d/afa_cleanup.sh
mkdir -p /data/adb/service.d
cat > "$CLEAN" <<CLEANEOF
#!/system/bin/sh
until [ "\$(getprop sys.boot_completed)" = 1 ]; do sleep 5; done
until [ -d /data/media/0/Android/data ]; do sleep 10; done
for p in $DISABLE_PKGS; do pm enable "\$p" >/dev/null 2>&1; done
[ -f $PERSIST/suspended.list ] && while read -r p; do [ -n "\$p" ] && pm unsuspend --user 0 "\$p" >/dev/null 2>&1; done < $PERSIST/suspended.list
for LIST in $PERSIST/locked.list /data/adb/afa_unlock.list; do
    [ -f "\$LIST" ] || continue
    while read -r f; do
        [ -n "\$f" ] || continue
        chattr -i "\$f" 2>/dev/null
        rm -rf "\$f"
    done < "\$LIST"
done
rm -rf $PERSIST /data/adb/afa_unlock.list
rm -f "\$0"
CLEANEOF
chmod 0755 "$CLEAN"
