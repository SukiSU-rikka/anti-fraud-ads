// 开屏广告自动跳过：Zygisk 部分
// 每个应用启动时问一次 companion（root 进程）这个包在不在名单里：
//   不在 → 立即卸载本库，什么都不留下；
//   在   → 把内嵌的 dex 载入应用进程，由 afa.skip.Main 负责找「跳过」并点击。
#include <jni.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <stdint.h>
#include <errno.h>
#include <android/log.h>

#include "zygisk.hpp"
#include "skip_dex.h"   // 构建时生成：skip_dex[] / skip_dex_len

#define TAG "AFA-Skip"
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, TAG, __VA_ARGS__)

#ifndef MOD_DIR
#define MOD_DIR   "/data/adb/modules/anti_fraud_ads"
#endif
#ifndef SKIP_CONF
#define SKIP_CONF "/data/adb/afa/skip.conf"
#endif
#ifndef POPUP_RULES
#define POPUP_RULES "/data/adb/afa/cache/popup.rules"
#endif
#define MAX_RULES (128 * 1024)

struct Reply {
    int32_t on;
    int32_t window_ms;
    int32_t flags;      // 1 = 同时关闭启动弹窗
    int32_t popup_ms;   // 关弹窗再多检查多久
    int32_t rules_len;  // 后面紧跟这么多字节的规则文本（「类型<TAB>词」一行一条）
};

// 从 popup.rules 里挑出全局规则和这个应用自己的规则，去掉包名列
static int load_rules(const char *pkg, char *out, int cap) {
    FILE *f = fopen(POPUP_RULES, "re");
    if (!f) return 0;
    int n = 0;
    char line[512];
    size_t plen = strlen(pkg);
    while (fgets(line, sizeof(line), f)) {
        char *tab = strchr(line, '\t');
        if (!tab) continue;
        size_t klen = (size_t) (tab - line);
        bool mine = (klen == 1 && line[0] == '*') || (klen == plen && strncmp(line, pkg, plen) == 0);
        if (!mine) continue;
        const char *rest = tab + 1;
        size_t rlen = strlen(rest);
        if (rlen == 0) continue;
        if (n + (int) rlen + 1 > cap) break;
        memcpy(out + n, rest, rlen);
        n += (int) rlen;
        if (out[n - 1] != '\n') out[n++] = '\n';
    }
    fclose(f);
    return n;
}

static bool read_full(int fd, void *buf, size_t n) {
    char *p = static_cast<char *>(buf);
    while (n > 0) {
        ssize_t r = read(fd, p, n);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) return false;
        p += r; n -= (size_t) r;
    }
    return true;
}

static bool write_full(int fd, const void *buf, size_t n) {
    const char *p = static_cast<const char *>(buf);
    while (n > 0) {
        ssize_t r = write(fd, p, n);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) return false;
        p += r; n -= (size_t) r;
    }
    return true;
}

static void trim(char *s) {
    size_t n = strlen(s);
    while (n > 0 && (s[n - 1] == '\n' || s[n - 1] == '\r' || s[n - 1] == ' ' || s[n - 1] == '\t')) s[--n] = 0;
}

// ---------------- companion：root 权限，读名单 ----------------
static void companion(int fd) {
    Reply r = {0, 8000, 0, 7000, 0};
    uint32_t len = 0;
    char pkg[256];
    if (!read_full(fd, &len, sizeof(len)) || len == 0 || len >= sizeof(pkg) || !read_full(fd, pkg, len)) {
        write_full(fd, &r, sizeof(r));
        return;
    }
    pkg[len] = 0;
    if (access(MOD_DIR "/disable", F_OK) == 0 || access(MOD_DIR "/remove", F_OK) == 0) {
        write_full(fd, &r, sizeof(r));
        return;
    }
    FILE *f = fopen(SKIP_CONF, "re");
    if (f) {
        char line[512];
        bool on = false, hit = false, popup = false;
        int win = 8, pwin = 7;
        while (fgets(line, sizeof(line), f)) {
            trim(line);
            if (strncmp(line, "on=", 3) == 0) on = line[3] == '1';
            else if (strncmp(line, "window=", 7) == 0) win = atoi(line + 7);
            else if (strncmp(line, "popup=", 6) == 0) popup = line[6] == '1';
            else if (strncmp(line, "popup_window=", 13) == 0) pwin = atoi(line + 13);
            else if (strncmp(line, "app=", 4) == 0 && strcmp(line + 4, pkg) == 0) hit = true;
        }
        fclose(f);
        if (win < 2) win = 2;
        if (win > 30) win = 30;
        r.on = (on && hit) ? 1 : 0;
        r.window_ms = win * 1000;
        r.flags = popup ? 1 : 0;
        if (pwin < 1) pwin = 1;
        if (pwin > 60) pwin = 60;
        r.popup_ms = pwin * 1000;
    }
    char *rules = nullptr;
    if (r.on == 1) {
        rules = (char *) malloc(MAX_RULES);
        if (rules) r.rules_len = load_rules(pkg, rules, MAX_RULES);
    }
    if (write_full(fd, &r, sizeof(r)) && r.rules_len > 0) write_full(fd, rules, (size_t) r.rules_len);
    free(rules);
}

// ---------------- 模块本体：运行在每个新应用进程里 ----------------
class SkipModule : public zygisk::ModuleBase {
public:
    void onLoad(zygisk::Api *a, JNIEnv *e) override {
        api = a;
        env = e;
    }

    void preAppSpecialize(zygisk::AppSpecializeArgs *args) override {
        enabled = false;
        int appid = args->uid % 100000;
        // 只管普通应用（10000~19999），系统进程、隔离进程一律跳过
        if (appid < 10000 || appid > 19999 || args->nice_name == nullptr) { unload(); return; }
        const char *name = env->GetStringUTFChars(args->nice_name, nullptr);
        if (name == nullptr) { env->ExceptionClear(); unload(); return; }
        snprintf(pkg, sizeof(pkg), "%s", name);
        env->ReleaseStringUTFChars(args->nice_name, name);
        // 只管主进程（推送、小程序等 :xxx 子进程不管）
        if (pkg[0] == 0 || strchr(pkg, ':') != nullptr || strchr(pkg, '.') == nullptr) { unload(); return; }

        int fd = api->connectCompanion();
        if (fd < 0) { unload(); return; }
        uint32_t len = (uint32_t) strlen(pkg);
        Reply r = {0, 0, 0, 0, 0};
        bool ok = write_full(fd, &len, sizeof(len)) && write_full(fd, pkg, len) && read_full(fd, &r, sizeof(r));
        if (ok && r.on == 1 && r.rules_len > 0 && r.rules_len <= MAX_RULES) {
            rules = (char *) malloc((size_t) r.rules_len);
            if (rules == nullptr || !read_full(fd, rules, (size_t) r.rules_len)) {
                free(rules);
                rules = nullptr;
                rules_len = 0;
            } else {
                rules_len = r.rules_len;
            }
        }
        close(fd);
        if (!ok || r.on != 1) { unload(); return; }
        window_ms = r.window_ms;
        flags = r.flags;
        popup_ms = r.popup_ms;
        enabled = true;
    }

    void postAppSpecialize(const zygisk::AppSpecializeArgs *) override {
        if (enabled) inject();
    }

    void preServerSpecialize(zygisk::ServerSpecializeArgs *) override {
        unload();
    }

private:
    zygisk::Api *api = nullptr;
    JNIEnv *env = nullptr;
    bool enabled = false;
    int window_ms = 8000;
    int flags = 0;
    int popup_ms = 7000;
    char *rules = nullptr;
    int rules_len = 0;
    char pkg[256] = {0};

    void unload() {
        api->setOption(zygisk::Option::DLCLOSE_MODULE_LIBRARY);
    }

    bool failed(const char *step) {
        if (env->ExceptionCheck()) {
            env->ExceptionDescribe();
            env->ExceptionClear();
            LOGW("%s: %s 失败", pkg, step);
            return true;
        }
        return false;
    }

    void inject() {
        JNIEnv *e = env;
        jclass clCls = e->FindClass("java/lang/ClassLoader");
        if (clCls == nullptr || failed("ClassLoader")) return;
        jmethodID getSys = e->GetStaticMethodID(clCls, "getSystemClassLoader", "()Ljava/lang/ClassLoader;");
        if (getSys == nullptr || failed("getSystemClassLoader")) return;
        jobject parent = e->CallStaticObjectMethod(clCls, getSys);
        if (failed("parent")) return;

        jobject buf = e->NewDirectByteBuffer((void *) skip_dex, (jlong) skip_dex_len);
        if (buf == nullptr || failed("ByteBuffer")) return;
        jclass imCls = e->FindClass("dalvik/system/InMemoryDexClassLoader");
        if (imCls == nullptr || failed("InMemoryDexClassLoader")) return;
        jmethodID ctor = e->GetMethodID(imCls, "<init>", "(Ljava/nio/ByteBuffer;Ljava/lang/ClassLoader;)V");
        if (ctor == nullptr || failed("ctor")) return;
        jobject loader = e->NewObject(imCls, ctor, buf, parent);
        if (loader == nullptr || failed("new loader")) return;

        jmethodID loadClass = e->GetMethodID(clCls, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;");
        if (loadClass == nullptr || failed("loadClass")) return;
        jstring cname = e->NewStringUTF("afa.skip.Main");
        jclass main = (jclass) e->CallObjectMethod(loader, loadClass, cname);
        if (main == nullptr || failed("load Main")) return;
        jmethodID start = e->GetStaticMethodID(main, "start", "(Ljava/lang/String;III[B)V");
        if (start == nullptr || failed("start")) return;
        jstring jpkg = e->NewStringUTF(pkg);
        // 规则是 UTF-8 字节，交给 Java 解码（NewStringUTF 对 emoji 等字符不安全）
        jbyteArray jrules = e->NewByteArray(rules_len);
        if (jrules == nullptr || failed("rules")) return;
        if (rules_len > 0) e->SetByteArrayRegion(jrules, 0, rules_len, (const jbyte *) rules);
        free(rules);
        rules = nullptr;
        e->CallStaticVoidMethod(main, start, jpkg, (jint) window_ms, (jint) flags, (jint) popup_ms, jrules);
        failed("run");

        e->DeleteLocalRef(jrules);
        e->DeleteLocalRef(jpkg);
        e->DeleteLocalRef(cname);
        e->DeleteLocalRef(main);
        e->DeleteLocalRef(loader);
        e->DeleteLocalRef(imCls);
        e->DeleteLocalRef(buf);
        if (parent) e->DeleteLocalRef(parent);
        e->DeleteLocalRef(clCls);
    }
};

REGISTER_ZYGISK_MODULE(SkipModule)
REGISTER_ZYGISK_COMPANION(companion)
