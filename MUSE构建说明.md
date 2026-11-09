# 给 Muse 的构建说明：anti_fraud_ads v7.8（含开屏跳过）

## 你的任务
把本目录编译成**一个可直接刷入的 KernelSU 模块 zip**：`anti_fraud_ads_v7.8.zip`。
需要编译的只有「开屏广告自动跳过」的 Zygisk 部分，其余文件（`module/` 里的脚本、设置页、AdGuard Home）**原样打包，不要修改**。

## 环境要求
- JDK 17（`javac` 要支持 `--release 8`）
- Android SDK：任意 `platforms/android-XX`（≥ 26，有 `android.jar` 即可）、`build-tools`（要用里面的 `d8`）
- Android NDK（r25 及以上均可）
- `python3`、`zip`、`unzip`、`curl`

脚本按以下顺序找 SDK / NDK，找不到就报错退出：
- SDK：`$ANDROID_HOME` → `$ANDROID_SDK_ROOT`
- NDK：`$ANDROID_NDK_LATEST_HOME` → `$ANDROID_NDK_HOME` → `$SDK/ndk/` 下版本最新的那个

## 一条命令构建
```bash
bash zygisk/build.sh
```
产物：`out/anti_fraud_ads_v7.8.zip`。也可以直接把仓库推到 GitHub，`.github/workflows/build.yml` 会跑同样的脚本。

## build.sh 做了什么（出错时对照排查）
1. 下载 Zygisk API 头文件到 `build/gen/zygisk.hpp`
   来源：`https://raw.githubusercontent.com/topjohnwu/zygisk-module-sample/master/module/jni/zygisk.hpp`
   **没网时**：从 topjohnwu/zygisk-module-sample 仓库的 `module/jni/zygisk.hpp` 手动拷进 `build/gen/`，并注释掉脚本里的 curl 那一行。
2. `javac --release 8 -cp android.jar` 编译 `zygisk/java/afa/skip/Main.java`，再用 `d8 --min-api 26` 转成 `classes.dex`
3. 用 python 把 dex 转成 C 数组头文件 `build/gen/skip_dex.h`（`skip_dex[]` / `skip_dex_len`）
4. 用 NDK clang++ 编译 `zygisk/src/main.cpp`，分别输出 `arm64-v8a.so` 和 `armeabi-v7a.so`
   参数：`-std=c++17 -shared -fPIC -O2 -fno-exceptions -fno-rtti -llog -static-libstdc++`，目标 API 26
5. 把 `module/` 整个复制到 `out/module/`，把两个 .so 放进 `out/module/zygisk/`，再在 `out/module/` **里面**打成 zip（zip 根目录必须直接是 `module.prop`，不能多套一层文件夹）

## 验收（全部通过才算完成）
```bash
Z=out/anti_fraud_ads_v7.8.zip
unzip -l $Z | grep -E "^.* (module.prop|customize.sh|zygisk/arm64-v8a.so|zygisk/armeabi-v7a.so|agh/AdGuardHome|webroot/index.html)$"
# 上面应该列出 6 行；module.prop 必须在根目录
unzip -p $Z module.prop | grep -E "^(id=anti_fraud_ads|version=v7.8)$"     # 应输出 2 行
# 两个 .so 必须导出这两个符号（用 NDK 的 llvm-nm）
$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-nm -D --defined-only build/zygisk/arm64-v8a.so | grep -E "zygisk_(module|companion)_entry"
# dex 里必须有入口类
$BUILD_TOOLS/dexdump build/dex/classes.dex | grep "Class descriptor.*Lafa/skip/Main;"
```
另外确认 zip 大小约 11 MB（主要是 AdGuard Home 二进制），明显偏小说明 `agh/` 漏了。

## 必须遵守
- **不要改 `module/` 里的任何文件**，不要改模块 id（`anti_fraud_ads`）和版本号。用户是覆盖安装，id 一变就会变成两个模块。
- **不要改这些约定**，它们和模块脚本、设置页是对应的：
  - companion 读取的名单：`/data/adb/afa/skip.conf`（格式：`on=1`、`window=8`、`popup=1`、`popup_window=7`、`app=包名`，由模块脚本生成）
  - 模块目录：`/data/adb/modules/anti_fraud_ads`（存在 `disable` 或 `remove` 文件时一律不生效）
  - Java 入口：类 `afa.skip.Main`，静态方法 `start(String pkg, int windowMs, int flags, int popupMs, byte[] rules)`（flags 第 1 位 = 关闭启动弹窗）
  - companion 回复结构：5 个 int32（on、window_ms、flags、popup_ms、rules_len），后面紧跟 rules_len 字节的规则文本；`main.cpp` 两端已对齐，不要单独改一边
  - 弹窗规则文件：`/data/adb/afa/cache/popup.rules`（「包名或 *<TAB>类型<TAB>词」，由模块脚本生成，companion 每次应用启动时读取）
  - 日志 tag：`AFA-Skip`（设置页「最近跳过记录」靠它读 logcat）
- 编译报错时只做**最小修改**让它通过，不要重写逻辑。最可能出问题的是 `zygisk.hpp` 版本差异：如果头文件里 `AppSpecializeArgs` 的 `uid` / `nice_name`、`Api::connectCompanion` / `setOption`、`Option::DLCLOSE_MODULE_LIBRARY`、`REGISTER_ZYGISK_MODULE` / `REGISTER_ZYGISK_COMPANION` 的名字不一样，按头文件的实际名字改 `main.cpp`。
- 改了什么，最后列成清单（文件、改动、原因）交给用户。

## 交付
- `out/anti_fraud_ads_v7.8.zip`（直接给用户刷入）
- 改动清单（没改就写「无改动」）
- 验收命令的输出

## 用户刷入后怎么确认生效
1. 管理器里 Zygisk Next 处于启用状态，刷入后重启
2. 打开本模块设置页 →「开屏」：顶部显示「Zygisk 已就绪」
3. 选一个有开屏广告的应用，在最近任务里划掉再打开
4. 回到「开屏」→「最近跳过记录」点刷新，应能看到「已启用」和「跳过「…」」两类记录；或终端执行 `logcat -s AFA-Skip`
