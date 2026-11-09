# 安装脚本（默认解压到 $MODPATH，再把 AdGuard 本体移到持久目录 /data/adb/afa）
PERSIST=/data/adb/afa
AGH_DIR=$PERSIST/agh
OLD_MOD=/data/adb/modules/anti_fraud_ads
OLD_AGH_MOD=/data/adb/modules/AdGuardHome
OLD_AGH_DIR=/data/adb/agh

ui_print "*********************************************"
ui_print "  反诈屏蔽 + AdGuard 去广告  v7.9"
ui_print "  一加 Ace 6 / ColorOS 17"
ui_print "*********************************************"
[ "$ARCH" = arm64 ] || abort "! 内置 AdGuard 只有 arm64 版本，当前架构 $ARCH 不支持"
rom=$(getprop ro.build.version.oplusrom)
ui_print "- 机型: $(getprop ro.product.model)  ColorOS: ${rom:-未检测到}"

# 音量键选择：上 = 是，下 = 否，超时返回 $1
vol_key() {
    t0=$(date +%s)
    while true; do
        [ $(( $(date +%s) - t0 )) -ge 20 ] && return "$1"
        ev=$(timeout 1 getevent -lqc 1 2>/dev/null)
        case "$ev" in
            *KEY_VOLUMEUP*DOWN*) return 0 ;;
            *KEY_VOLUMEDOWN*DOWN*) return 1 ;;
        esac
    done
}

# 0. 更新时先停掉正在运行的旧版 AdGuard，并撤掉 DNS 劫持，避免重启前断网
for p in /proc/[0-9]*; do
    [ "$(readlink "$p/exe" 2>/dev/null)" = "$AGH_DIR/AdGuardHome" ] && kill "${p#/proc/}" 2>/dev/null
done
iptables -w 5 -t nat -D OUTPUT -j AFA_DNS 2>/dev/null
iptables -w 5 -t nat -F AFA_DNS 2>/dev/null; iptables -w 5 -t nat -X AFA_DNS 2>/dev/null
sleep 1

# 1. 持久目录
mkdir -p "$AGH_DIR/userfilters" "$AGH_DIR/data/filters"
mv -f "$MODPATH/agh/AdGuardHome" "$AGH_DIR/AdGuardHome" || abort "! 无法写入 $AGH_DIR"
chown 0:3004 "$AGH_DIR/AdGuardHome"; chmod 0755 "$AGH_DIR/AdGuardHome"

# 2. AdGuard 配置：更新保留 → 迁移 AdGuardHomeForRoot → 全新默认
if [ -f "$AGH_DIR/AdGuardHome.yaml" ]; then
    ui_print "- 保留现有 AdGuard 配置（密码、订阅、自定义规则不变）"
elif [ -f "$OLD_AGH_DIR/bin/AdGuardHome.yaml" ] && grep -q '^author=twoone3' "$OLD_AGH_MOD/module.prop" 2>/dev/null; then
    cp -f "$OLD_AGH_DIR/bin/AdGuardHome.yaml" "$AGH_DIR/AdGuardHome.yaml"
    cp -rf "$OLD_AGH_DIR/bin/data/filters/." "$AGH_DIR/data/filters/" 2>/dev/null
    ui_print "- 已迁移 AdGuardHomeForRoot 的配置（密码、订阅、自定义规则）"
else
    cp -f "$MODPATH/mod/agh_default.yaml" "$AGH_DIR/AdGuardHome.yaml"
    ui_print "- 使用默认 AdGuard 配置（秋风规则 + 反诈规则）"
fi
[ -f "$AGH_DIR/data/filters/1732747955.txt" ] || cp -f "$MODPATH/agh/awavenue_seed.txt" "$AGH_DIR/data/filters/1732747955.txt"
cp -f "$MODPATH/mod/antifraud_rules.txt" "$AGH_DIR/userfilters/antifraud.txt"
chmod 600 "$AGH_DIR/AdGuardHome.yaml"
rm -rf "$MODPATH/agh"

# 3. 用户配置（更新时保留）
[ -f "$PERSIST/user.conf" ] || cp -f "$MODPATH/mod/user.conf.template" "$PERSIST/user.conf"

# 4. 从 v6.x 迁移已锁定的缓存列表
for l in "$OLD_MOD/locked.list" /data/adb/afa_unlock.list; do
    [ -f "$l" ] && cat "$l" >> "$PERSIST/locked.list"
done
[ -f "$PERSIST/locked.list" ] && sort -u "$PERSIST/locked.list" -o "$PERSIST/locked.list"
rm -f /data/adb/afa_unlock.list /data/adb/service.d/afa_cleanup.sh

# 5. 旧的 AdGuardHome 模块（两个去广模块的 id 都是 AdGuardHome）
if [ -d "$OLD_AGH_MOD" ] && [ ! -f "$OLD_AGH_MOD/remove" ]; then
    ui_print " "
    ui_print "! 检测到旧的 AdGuard 模块：$(grep -m1 '^name=' "$OLD_AGH_MOD/module.prop" | cut -d= -f2)"
    ui_print "  两个同时运行会冲突，是否在重启时移除它？"
    ui_print "  音量上 = 移除（推荐）  音量下 = 保留（本模块的 AdGuard 不启动）"
    ui_print "  20 秒无操作 = 移除"
    if vol_key 0; then
        touch "$OLD_AGH_MOD/remove"
        ui_print "- 已标记移除，重启后生效"
    else
        ui_print "- 已保留旧模块；以后在管理器里删除它，本模块的 AdGuard 就会启动"
    fi
fi

# 6. 开屏跳过（Zygisk）
touch "$PERSIST/skip_apps.list"
if ls "$MODPATH"/zygisk/*.so >/dev/null 2>&1; then
    if [ -d /data/adb/modules/zygisksu ] && [ ! -f /data/adb/modules/zygisksu/disable ]; then
        ui_print "- 开屏跳过：已检测到 Zygisk Next，到设置页「开屏」里选择应用"
    else
        ui_print "! 开屏跳过需要 Zygisk Next，没装时其他功能照常工作"
    fi
else
    rm -rf "$MODPATH/zygisk"
    ui_print "- 本安装包不含 Zygisk 库，开屏跳过不可用（其他功能不受影响）"
fi

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm_recursive "$MODPATH/mod" 0 0 0755 0755
for f in service.sh action.sh uninstall.sh; do set_perm "$MODPATH/$f" 0 0 0755; done

ui_print " "
ui_print "- 管理器里点「打开」进入设置页，「执行」直达 AdGuard 后台"
ui_print "- AdGuard 后台账号/密码: root / root（可在设置页修改密码）"
ui_print "- 自定义设置: $PERSIST/user.conf；我的规则: $PERSIST/rules/"
ui_print "- 日志: $PERSIST/module.log、self_check.log"
ui_print "- 安装完成，请重启"
