#!/usr/bin/env bash
# 编译开屏跳过的 Zygisk 库（arm64-v8a + armeabi-v7a），并打包成完整模块 zip
# 需要：Android SDK（含 build-tools、platforms）、NDK、JDK 17。GitHub Actions 的 ubuntu-latest 自带
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

SDK=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}
[ -n "$SDK" ] && [ -d "$SDK" ] || { echo "找不到 Android SDK"; exit 1; }
NDK=${ANDROID_NDK_LATEST_HOME:-${ANDROID_NDK_HOME:-}}
if [ -z "$NDK" ] || [ ! -d "$NDK" ]; then NDK=$( (ls -d "$SDK"/ndk/* 2>/dev/null || true) | sort -V | tail -1); fi
[ -d "$NDK" ] || { echo "找不到 NDK"; exit 1; }
PLAT=$(ls -d "$SDK"/platforms/android-* | sort -V | tail -1)
BT=$(ls -d "$SDK"/build-tools/* | sort -V | tail -1)
TC=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin
echo "SDK=$SDK"; echo "NDK=$NDK"; echo "platform=$PLAT"; echo "build-tools=$BT"

B=$ROOT/build
rm -rf "$B" && mkdir -p "$B/classes" "$B/dex" "$B/gen" "$B/zygisk"

# 1. Zygisk API 头文件（官方示例仓库）
curl -fsSL --retry 3 -o "$B/gen/zygisk.hpp" \
    https://raw.githubusercontent.com/topjohnwu/zygisk-module-sample/master/module/jni/zygisk.hpp
grep -q "DLCLOSE_MODULE_LIBRARY" "$B/gen/zygisk.hpp"

# 2. Java → dex
javac --release 8 -Xlint:-options -encoding UTF-8 -cp "$PLAT/android.jar" -d "$B/classes" \
    $(find zygisk/java -name '*.java')
"$BT/d8" --release --min-api 26 --lib "$PLAT/android.jar" --output "$B/dex" $(find "$B/classes" -name '*.class')
test -s "$B/dex/classes.dex"

# 3. dex 嵌进 .so
python3 - "$B/dex/classes.dex" "$B/gen/skip_dex.h" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read()
with open(sys.argv[2], 'w') as f:
    f.write('#pragma once\nalignas(16) static const unsigned char skip_dex[] = {\n')
    for i in range(0, len(data), 16):
        f.write(','.join(str(b) for b in data[i:i + 16]) + ',\n')
    f.write('};\nstatic const unsigned int skip_dex_len = %d;\n' % len(data))
PY

# 4. 编译 .so
build_so() {
    abi=$1; target=$2
    "$TC/clang++" --target="$target" -std=c++17 -shared -fPIC -O2 -fno-exceptions -fno-rtti \
        -I"$B/gen" -o "$B/zygisk/$abi.so" zygisk/src/main.cpp \
        -llog -static-libstdc++ -Wl,--strip-all -Wl,-z,max-page-size=16384
    syms=$("$TC/llvm-nm" -D --defined-only "$B/zygisk/$abi.so")
    case "$syms" in *zygisk_module_entry*) ;; *) echo "缺少 zygisk_module_entry"; exit 1 ;; esac
    case "$syms" in *zygisk_companion_entry*) ;; *) echo "缺少 zygisk_companion_entry"; exit 1 ;; esac
    echo "$abi.so: $(stat -c %s "$B/zygisk/$abi.so") 字节"
}
build_so arm64-v8a aarch64-linux-android26
build_so armeabi-v7a armv7a-linux-androideabi26

# 5. 打包模块
OUT=$ROOT/out
rm -rf "$OUT" && mkdir -p "$OUT/module"
cp -a module/. "$OUT/module/"
mkdir -p "$OUT/module/zygisk"
cp "$B/zygisk/"*.so "$OUT/module/zygisk/"
VER=$(grep -m1 '^version=' module/module.prop | cut -d= -f2)
(cd "$OUT/module" && zip -r -9 -X "$OUT/anti_fraud_ads_${VER}.zip" . >/dev/null)
unzip -l "$OUT/anti_fraud_ads_${VER}.zip" | grep -E "zygisk/|module.prop" || true
echo "完成：$OUT/anti_fraud_ads_${VER}.zip"
