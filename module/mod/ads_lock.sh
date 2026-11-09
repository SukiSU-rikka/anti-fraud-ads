#!/system/bin/sh
# 广告缓存锁定 + SQLite 空壳替换（改版）
# 改动：只处理已存在的路径（不再给没装的应用凭空建目录/数据库）；
#       去掉 ads / applog / crashsdk / AMPS / app_ad 这类过于通用的目录名；
#       修复原版跳过主用户 0 的 bug；锁定过的路径记入 locked.list，卸载时自动解锁还原。
MODDIR=${1:-/data/adb/modules/anti_fraud_ads}
. "$MODDIR/mod/common.sh"
LOCKLIST="$PERSIST/locked.list"
locked=0; shells=0
log "ads_lock: start"

record() { echo "$1" >> "$LOCKLIST"; }
perm_of() { stat -c %a "$1" 2>/dev/null; }

lock_dir() {
    [ -d "$1" ] || return 0
    [ "$(perm_of "$1")" = "0" ] && return 0          # 已锁过
    chattr -i "$1" 2>/dev/null
    rm -rf "$1" 2>/dev/null && mkdir "$1" 2>/dev/null || return 0
    chmod 000 "$1"; chattr +i "$1" 2>/dev/null
    record "$1"; locked=$((locked + 1))
}

lock_file() {
    [ -e "$1" ] || return 0
    [ -f "$1" ] && [ ! -s "$1" ] && [ "$(perm_of "$1")" = "0" ] && return 0
    chattr -i "$1" 2>/dev/null
    rm -rf "$1" 2>/dev/null && touch "$1" 2>/dev/null || return 0
    chmod 000 "$1"; chattr +i "$1" 2>/dev/null
    record "$1"; locked=$((locked + 1))
}

empty_sqlite() {
    [ -f "$1" ] || return 0
    [ "$(wc -c < "$1")" = 16 ] && [ "$(perm_of "$1")" = "444" ] && return 0
    chattr -i "$1" 2>/dev/null
    rm -f "$1" && printf 'SQLite format 3\000' > "$1" || return 0
    chmod 0444 "$1"; chattr +i "$1" 2>/dev/null
    record "$1"; shells=$((shells + 1))
}

# ===== 第一部分：按广告 SDK 专用目录名扫描 =====
set -f
AD_DIR_NAMES="splashCache SplashPreload splash_image SplashData TMEAds qad_cache
splash_ad_cache GDTDOWNLOAD app_adnet tad_cache TTCache cachett_ad tt_tmpl_pkg
com_qq_e_download pangle_com.byted.pangle ksadsdk kwad_ex BeiZi app_baidu_sdk_remote
app_e_qq_com_* ks_union noah_ads anythink_internal_video_resource
anythink_internal_resource xm_ad_img_cache douban_ad"
set --
for n in $AD_DIR_NAMES; do
    [ $# -gt 0 ] && set -- "$@" -o
    set -- "$@" -iname "$n"
done
set +f

TMP="$PERSIST/.dirs_$$"
find /data/data /data/user /data/media/*/Android/data -type d \( "$@" \) -prune -print 2>/dev/null > "$TMP"
while read -r d; do lock_dir "$d"; done < "$TMP"
rm -f "$TMP"
log "ads_lock: part1 done (locked=$locked)"

# ===== 第二部分：各应用专属广告路径（含主用户 0 和应用分身 999）=====
for user_dir in /data/user/*; do
    u=$(basename "$user_dir")
    m="/data/media/$u"
    for d in "$m"/Android/data/com.handsgo.jiakao.android/cache/reward_video_cache_*; do lock_dir "$d"; done
    for f in \
        "$user_dir/com.douban.frodo/cache/douban_ad" \
        "$user_dir/com.handsgo.jiakao.android/cache/GDTDOWNLOAD" \
        "$m/Android/data/com.handsgo.jiakao.android/cache/splash_ad_cache" \
        "$user_dir/com.baidu.BaiduMap/files/AdvertData" \
        "$m/Android/data/com.ss.android.ugc.aweme/awemeSplashCache" \
        "$m/Android/data/com.ss.android.ugc.aweme/liveSplashCache" \
        "$m/Android/data/com.ss.android.ugc.aweme/splashCache" \
        "$user_dir/com.tencent.mtt/files/tad_cache" \
        "$user_dir/com.tencent.qqmusic/app_adnet" \
        "$user_dir/com.tencent.qqmusic/files/tad_cache" \
        "$m/qqmusic/splash" \
        "$m/Android/data/com.coolapk.market/cachett_ad" \
        "$m/Android/data/com.coolapk.market/cache/splash_image" \
        "$m/Android/data/com.coolapk.market/cache/com_qq_e_download" \
        "$m/Android/data/com.coolapk.market/cache/pangle_com.byted.pangle" \
        "$m/Android/data/com.coolapk.market/cache/tt_tmpl_pkg" \
        "$m/Android/data/com.coolapk.market/files/TTCache" \
        "$m/Android/data/com.gotokeep.keep/files/keep/ads" \
        "$m/Android/data/com.netease.cloudmusic/cache/Ad" \
        "$m/netease/adcache" \
        "$m/netease/cloudmusic/Ad" \
        "$m/Android/data/com.ss.android.article.news/splashCache" \
        "$m/Tencent/MobileQQ/splahAD" \
        "$m/Android/data/com.tencent.mobileqq/MobileQQ/splahAD" \
        "$m/Android/data/com.tencent.mobileqq/Tencent/MobileQQ/vasSplashAD" \
        "$m/autonavi/afpSplash" \
        "$m/autonavi/splash" \
        "$user_dir/com.autonavi.minimap/files/splash" \
        "$m/kugou/.splash" \
        "$m/Android/data/com.kugou.android/files/kugou/.splash" \
        "$m/sina/weibo/.weibo_ad_universal_cache" \
        "$m/sina/weibo/.weibo_refreshad_cache" \
        "$m/sina/weibo/.weiboadcache" \
        "$m/sina/weibo/storage/biz_keep/.weibo_ad_universal_cache" \
        "$m/sina/weibo/storage/biz_keep/.weibo_refreshad_cache" \
        "$m/Android/data/com.taobao.taobao/files/acds" \
        "$user_dir/com.taobao.taobao/files/bootimageresources" \
        "$m/Android/data/com.youdao.dict/files/yd_sdk_path" \
        "$user_dir/com.netease.mail/cache/adcache1" \
        "$user_dir/com.netease.mail/cache/adcache" \
        "$user_dir/com.sankuai.meituan/files/cips/common/mtplatform_group/assets/startup" \
        "$user_dir/me.ele/cache/splash" \
        "$user_dir/me.ele/files/o2o_ad" \
        "$user_dir/com.baidu.netdisk/files/default_ad_caches" \
        "$user_dir/com.baidu.netdisk/files/splash_res_caches" \
        "$user_dir/com.baidu.netdisk/files/video_front_ad_caches" \
        "$user_dir/com.baidu.netdisk/files/splash" \
        "$m/Android/data/com.chinamobile.mcloud/files/boot_logo" \
        "$user_dir/com.taobao.trip/files/fliggy_splash" \
        "$m/Android/data/ctrip.android.view/cache/CTADCache" \
        "$m/com.luna.music/cache/image_commercial_cache" \
        "$m/com.luna.music/cache/pangle_com.byted.pangle" \
        "$m/com.luna.music/files/splashCache"
    do
        lock_file "$f"
    done
done
log "ads_lock: part2 done (locked=$locked)"

# ===== 第三、四部分：广告 SDK 数据库替换成空壳（只处理已存在的）=====
for user_dir in /data/user/*; do
    for f in "$user_dir"/com.mfcloudcalculate.networkdisk/files/gdt_database/*.db \
             "$user_dir"/com.mfcloudcalculate.networkdisk/databases/amps_ad.db \
             "$user_dir"/com.mfcloudcalculate.networkdisk/databases/ksadrep.db \
             "$user_dir"/com.mfcloudcalculate.networkdisk/databases/ksadcache.db \
             "$user_dir"/com.youdao.dict/databases/ad_sdk_database* \
             "$user_dir"/com.netease.mail/databases/ad_sdk_database* \
             "$user_dir"/com.tencent.map/databases/splash.db
    do
        empty_sqlite "$f"
    done
    for db_dir in "$user_dir"/*/databases; do
        [ -d "$db_dir" ] || continue
        for db in beizi_ad pangle_com.byted.pangle_npth_log pangle_com.byted.pangle_ttopensdk \
                  pangle_com.byted.pangle_ttopensdk2 tt_mediation_open_sdk \
                  pangle_com.byted.pangle_tt_mediation_open_sdk; do
            empty_sqlite "$db_dir/$db.db"
        done
    done
done

[ -f "$LOCKLIST" ] && sort -u "$LOCKLIST" -o "$LOCKLIST"
log "ads_lock: finished (新锁定=$locked, 数据库空壳=$shells, 累计=$(wc -l < "$LOCKLIST" 2>/dev/null || echo 0))"
