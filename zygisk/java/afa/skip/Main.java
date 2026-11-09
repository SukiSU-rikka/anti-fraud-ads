package afa.skip;

import android.app.Activity;
import android.app.Application;
import android.graphics.Rect;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.DisplayMetrics;
import android.util.Log;
import android.view.InputDevice;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.ViewParent;
import android.view.Window;
import android.widget.TextView;

import java.lang.ref.WeakReference;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.List;
import java.util.WeakHashMap;

/**
 * 运行在被选中的应用进程里。应用打开第一个页面后：
 *   1. 前 windowMs 毫秒：找开屏广告的「跳过」并点掉；
 *   2. 再多 popupMs 毫秒（开关打开时）：关掉应用自己弹的通知权限、活动推广、更新提示等弹窗。
 * 用哪些字、哪些按钮由规则决定：模块把内置规则 + 用户规则 + 订阅合并后，在应用启动时传进来（热更新）；
 * 没收到规则时用下面写死的默认值。
 * 每 150ms 看一眼当前页面和应用自己的浮层窗口；时间一到就停止检查。
 * 应用从后台回到前台（热启动开屏）时会重新检查一轮。
 * 全部代码包在 try/catch 里，出任何问题都只写日志，不会影响应用本身。
 */
public final class Main implements Application.ActivityLifecycleCallbacks, Runnable {
    static final String TAG = "AFA-Skip";
    static final int FLAG_POPUP = 1;
    static final long TICK_MS = 150;
    static final long HOT_START_MS = 5000;      // 在后台待超过 5 秒再回来，算一次热启动
    static final int MAX_SKIPS = 3;
    static final int MAX_POPUPS = 3;
    static final int MAX_NODES = 4000;

    // ---------- 开屏「跳过」 ----------
    static final String[] SKIP_WORDS = {"跳过", "跳過", "skip"};
    // 视频、引导页里的正常「跳过」，不点
    static final String[] NOT_AD = {"片头", "片尾", "片頭", "片段", "引导", "引導", "教程", "本集", "intro", "recap", "此步", "这一步"};

    // ---------- 弹窗的「拒绝」按钮 ----------
    // 只要出现就可以点（本身就是拒绝 / 推迟的意思）
    static final String[] DISMISS_ANY = {
            "以后再说", "下次再说", "稍后再说", "稍后提醒", "下次吧", "以后吧", "暂不开启", "暂不打开", "暂不需要", "暂不更新",
            "暂不升级", "暂不领取", "暂不参与", "暂时不用", "暂时不要", "暂不", "不再提醒", "不再提示", "不再显示",
            "残忍拒绝", "狠心拒绝", "忍痛拒绝", "我再想想", "先不了", "先不用", "不用了", "不了谢谢", "不感兴趣",
            "放弃领取", "放弃福利", "我知道了", "知道了", "notnow", "later", "nothanks", "maybelater"};
    // 只在浮层窗口里点（页面里的「关闭」「取消」可能是正常功能）
    static final String[] DISMISS_FLOATING = {"关闭", "关闭弹窗", "×", "✕", "✖", "x", "close"};
    // 「取消」「拒绝」太泛，只有弹窗内容是在要通知权限时才点
    static final String[] DISMISS_NOTIFY_ONLY = {"取消", "拒绝", "不允许", "禁止"};
    static final String[] NOTIFY_HINT = {"通知", "推送", "消息提醒", "开启提醒", "提醒我", "notification"};
    // 弹窗里出现这些字就完全不碰：隐私协议点「不同意」会直接退出应用；涉及账号、钱、数据的也不碰
    static final String[] NEVER_TOUCH = {"隐私", "协议", "政策", "条款", "同意", "授权登录", "实名", "支付", "付款", "扣款", "订阅",
            "续费", "删除", "清空", "注销", "退出登录", "卸载", "格式化", "privacy", "terms", "agree"};

    final String pkg;
    final int windowMs;
    final int popupMs;
    final boolean popup;
    String[] skipWords = SKIP_WORDS, notAd = NOT_AD, dismissAny = DISMISS_ANY, dismissFloating = DISMISS_FLOATING,
            dismissNotify = DISMISS_NOTIFY_ONLY, notifyHint = NOTIFY_HINT, neverTouch = NEVER_TOUCH, closeIds = {"close"};
    volatile Application app;
    Handler handler;
    long skipUntil = 0, popupUntil = 0;     // 第一个页面出现时开始计时
    boolean ticking = false, finished = false;
    int skips = 0, popups = 0, nodes = 0;
    int started = 0;                    // 处于前台的页面数
    long backgroundAt = 0;              // 进入后台的时间
    Field viewsField;                   // WindowManagerGlobal.mViews：应用的全部窗口（含弹窗、浮层）
    Object wmGlobal;
    boolean windowsUnavailable = false;
    WeakReference<Activity> current = new WeakReference<Activity>(null);
    final WeakHashMap<View, Boolean> clicked = new WeakHashMap<View, Boolean>();

    private Main(String pkg, int windowMs, int flags, int popupMs) {
        this.pkg = pkg;
        this.windowMs = Math.max(2000, Math.min(windowMs, 30000));
        this.popupMs = Math.max(1000, Math.min(popupMs, 60000));
        this.popup = (flags & FLAG_POPUP) != 0;
    }

    /** 由 Zygisk 库在应用进程刚创建时调用（此时应用代码还没开始运行） */
    public static void start(String pkg, int windowMs, int flags, int popupMs, byte[] rules) {
        try {
            final Main m = new Main(pkg, windowMs, flags, popupMs);
            if (rules != null && rules.length > 0) m.loadRules(new String(rules, "UTF-8"));
            Thread t = new Thread(new Runnable() {
                @Override
                public void run() {
                    m.waitForApplication();
                }
            }, "afa-skip");
            t.setDaemon(true);
            t.start();
        } catch (Throwable e) {
            Log.w(TAG, "start", e);
        }
    }

    void waitForApplication() {
        try {
            Method current = Class.forName("android.app.ActivityThread").getMethod("currentApplication");
            for (int i = 0; i < 4000 && app == null; i++) {        // 最多等 20 秒
                Object a = current.invoke(null);
                if (a instanceof Application) {
                    app = (Application) a;
                    break;
                }
                Thread.sleep(5);
            }
            if (app == null) {
                Log.w(TAG, pkg + ": 等不到 Application，放弃");
                return;
            }
            handler = new Handler(Looper.getMainLooper());
            // 直接在这个线程注册（这个方法本身是线程安全的），赶在第一个页面创建之前
            app.registerActivityLifecycleCallbacks(this);
            initWindows();
            Log.i(TAG, pkg + ": 已启用，" + (windowMs / 1000) + " 秒内自动跳过开屏"
                    + (popup ? "，之后 " + (popupMs / 1000) + " 秒内关闭启动弹窗" : ""));
        } catch (Throwable e) {
            Log.w(TAG, pkg + ": 初始化失败", e);
        }
    }

    /** 规则：一行「类型<TAB>词」，类型前带 - 表示删掉前面加过的这个词 */
    void loadRules(String text) {
        java.util.Map<String, java.util.LinkedHashSet<String>> m = new java.util.HashMap<String, java.util.LinkedHashSet<String>>();
        String[] keys = {"skip", "notad", "any", "float", "notify", "hint", "never", "id"};
        for (String k : keys) m.put(k, new java.util.LinkedHashSet<String>());
        int n = 0;
        for (String line : text.split("\n")) {
            int t = line.indexOf('\t');
            if (t <= 0) continue;
            String type = line.substring(0, t).trim();
            String word = norm(line.substring(t + 1));
            boolean del = type.startsWith("-");
            if (del) type = type.substring(1);
            java.util.LinkedHashSet<String> set = m.get(type);
            if (set == null || word.length() == 0) continue;
            if (del) set.remove(word); else set.add(word);
            n++;
        }
        if (n == 0) return;
        skipWords = m.get("skip").toArray(new String[0]);
        notAd = m.get("notad").toArray(new String[0]);
        dismissAny = m.get("any").toArray(new String[0]);
        dismissFloating = m.get("float").toArray(new String[0]);
        dismissNotify = m.get("notify").toArray(new String[0]);
        notifyHint = m.get("hint").toArray(new String[0]);
        neverTouch = m.get("never").toArray(new String[0]);
        closeIds = m.get("id").toArray(new String[0]);
    }

    void arm() {
        long now = SystemClock.uptimeMillis();
        skipUntil = now + windowMs;
        popupUntil = popup ? skipUntil + popupMs : 0;
        skips = 0;
        popups = 0;
        finished = false;
    }

    // ---------------- 页面生命周期 ----------------
    @Override
    public void onActivityCreated(Activity a, Bundle b) {
        if (skipUntil == 0) arm();
    }

    @Override
    public void onActivityStarted(Activity a) {
        try {
            if (started++ == 0 && backgroundAt > 0 && SystemClock.uptimeMillis() - backgroundAt >= HOT_START_MS) {
                arm();      // 从后台回来：重新检查一轮，抓热启动开屏
            }
        } catch (Throwable e) {
            Log.w(TAG, "started", e);
        }
    }

    @Override
    public void onActivityResumed(Activity a) {
        try {
            if (skipUntil == 0) arm();
            current = new WeakReference<Activity>(a);
            if (!finished && !ticking) {
                ticking = true;
                handler.post(this);
            }
        } catch (Throwable e) {
            Log.w(TAG, "resumed", e);
        }
    }

    @Override
    public void onActivityPaused(Activity a) {
        if (current.get() == a) current = new WeakReference<Activity>(null);
    }

    @Override
    public void onActivityStopped(Activity a) {
        if (started > 0 && --started == 0) backgroundAt = SystemClock.uptimeMillis();
    }

    @Override public void onActivitySaveInstanceState(Activity a, Bundle b) { }
    @Override public void onActivityDestroyed(Activity a) { }

    // ---------------- 定时检查 ----------------
    @Override
    public void run() {
        try {
            if (finished) return;
            long now = SystemClock.uptimeMillis();
            boolean wantSkip = now <= skipUntil && skips < MAX_SKIPS;
            boolean wantPopup = popup && now <= popupUntil && popups < MAX_POPUPS;
            if (!wantSkip && !wantPopup) {
                finish();
                return;
            }
            Activity a = current.get();
            View main = null;
            if (a != null && !a.isFinishing()) {
                Window w = a.getWindow();
                main = w == null ? null : w.peekDecorView();
            }
            // 先看最上层的浮层窗口（广告和弹窗常盖在页面上），最后看页面本身
            List<View> roots = windowRoots();
            boolean done = false;
            for (int i = roots.size() - 1; i >= 0 && !done; i--) {
                View r = roots.get(i);
                if (r == null || r == main || !r.isShown()) continue;
                done = check(r, true, wantSkip, wantPopup);
            }
            if (!done && main != null && main.isShown()) check(main, false, wantSkip, wantPopup);
            handler.postDelayed(this, TICK_MS);
        } catch (Throwable e) {
            Log.w(TAG, "tick", e);
            finish();
        }
    }

    boolean check(View root, boolean floating, boolean wantSkip, boolean wantPopup) {
        if (wantSkip) {
            nodes = 0;
            View v = findSkip(root);
            if (v != null && click(v, root, "跳过")) {
                skips++;
                return true;
            }
        }
        if (wantPopup) {
            View v = findDismiss(root, floating);
            if (v != null && click(v, root, "关闭弹窗")) {
                popups++;
                return true;
            }
        }
        return false;
    }

    /** 停止检查（生命周期回调保留，只用来发现热启动，几乎没有开销） */
    void finish() {
        finished = true;
        ticking = false;
        try {
            handler.removeCallbacks(this);
        } catch (Throwable ignored) {
        }
    }

    // ---------------- 窗口 ----------------
    void initWindows() {
        try {
            Class<?> c = Class.forName("android.view.WindowManagerGlobal");
            wmGlobal = c.getMethod("getInstance").invoke(null);
            viewsField = c.getDeclaredField("mViews");
            viewsField.setAccessible(true);
        } catch (Throwable e) {
            windowsUnavailable = true;   // 系统不让读就只看页面本身，不影响基本功能
        }
    }

    @SuppressWarnings("unchecked")
    List<View> windowRoots() {
        List<View> out = new ArrayList<View>();
        if (windowsUnavailable || viewsField == null) return out;
        try {
            Object v = viewsField.get(wmGlobal);
            if (v instanceof List) {
                try {
                    out.addAll((List<View>) v);
                } catch (RuntimeException busy) {
                    out.clear();     // 正好在增删窗口，下一轮再看
                }
            }
        } catch (Throwable e) {
            windowsUnavailable = true;
        }
        return out;
    }

    // ---------------- 找「跳过」 ----------------
    View findSkip(View v) {
        if (++nodes > MAX_NODES || v.getVisibility() != View.VISIBLE) return null;
        if (isSkip(textOf(v)) || isSkip(v.getContentDescription())) {
            if (usable(v)) return v;
        }
        if (v instanceof ViewGroup) {
            ViewGroup g = (ViewGroup) v;
            for (int i = 0; i < g.getChildCount(); i++) {
                View c = g.getChildAt(i);
                if (c == null) continue;
                View r = findSkip(c);
                if (r != null) return r;
            }
        }
        return null;
    }

    boolean isSkip(CharSequence cs) {
        String s = norm(cs);
        if (s.length() == 0 || s.length() > 12) return false;
        if (!containsAny(s, skipWords)) return false;
        return !containsAny(s, notAd);
    }

    static boolean isSkipText(CharSequence cs) {      // 测试用：默认规则
        String s = norm(cs);
        if (s.length() == 0 || s.length() > 12) return false;
        return containsAny(s, SKIP_WORDS) && !containsAny(s, NOT_AD);
    }

    // ---------------- 找弹窗的「拒绝」按钮 ----------------
    View findDismiss(View root, boolean floating) {
        // 先把整个窗口的文字收集起来，判断能不能碰、是不是通知权限弹窗
        StringBuilder all = new StringBuilder();
        List<View> cands = new ArrayList<View>();
        nodes = 0;
        collect(root, all, cands);
        String text = all.toString();
        if (containsAny(text, neverTouch)) return null;
        boolean notify = containsAny(text, notifyHint);

        View best = null;
        int bestRank = 99;
        for (View v : cands) {
            int rank = dismissRank(v, floating, notify);
            if (rank < bestRank && usable(v)) {
                best = v;
                bestRank = rank;
            }
        }
        return best;
    }

    void collect(View v, StringBuilder all, List<View> cands) {
        if (++nodes > MAX_NODES || v.getVisibility() != View.VISIBLE) return;
        CharSequence t = textOf(v);
        CharSequence d = v.getContentDescription();
        if (t != null && t.length() > 0) all.append(norm(t)).append('|');
        if (d != null && d.length() > 0) all.append(norm(d)).append('|');
        if ((t != null && t.length() > 0) || (d != null && d.length() > 0) || v.getId() != View.NO_ID) cands.add(v);
        if (v instanceof ViewGroup) {
            ViewGroup g = (ViewGroup) v;
            for (int i = 0; i < g.getChildCount(); i++) {
                View c = g.getChildAt(i);
                if (c != null) collect(c, all, cands);
            }
        }
    }

    /** 数字越小越优先；99 = 不是拒绝按钮 */
    int dismissRank(View v, boolean floating, boolean notify) {
        String t = norm(textOf(v));
        String d = norm(v.getContentDescription());
        if (t.length() > 0 && t.length() <= 12) {
            if (equalsAny(t, dismissAny)) return 0;
            if (floating && equalsAny(t, dismissFloating)) return 1;
            if (notify && equalsAny(t, dismissNotify)) return 2;
        }
        if (d.length() > 0 && d.length() <= 12) {
            if (equalsAny(d, dismissAny)) return 0;
            if (floating && equalsAny(d, dismissFloating)) return 3;
        }
        // 没有文字的「×」图标：只在浮层窗口里，按资源名认（iv_close、btn_close、dialog_close…）
        if (floating && t.length() == 0) {
            String id = idName(v);
            if (id.length() > 0 && !id.contains("closed") && containsAny(id, closeIds)) return 4;
        }
        return 99;
    }

    static String idName(View v) {
        int id = v.getId();
        if (id == View.NO_ID || (id >>> 24) == 0) return "";
        try {
            return v.getResources().getResourceEntryName(id).toLowerCase();
        } catch (Throwable e) {
            return "";
        }
    }

    // ---------------- 通用 ----------------
    static CharSequence textOf(View v) {
        return (v instanceof TextView) ? ((TextView) v).getText() : null;
    }

    static String norm(CharSequence cs) {
        if (cs == null) return "";
        return cs.toString().replaceAll("[\\s\\u00a0]+", "").toLowerCase();
    }

    static boolean containsAny(String s, String[] words) {
        for (String w : words) if (s.contains(w)) return true;
        return false;
    }

    static boolean equalsAny(String s, String[] words) {
        for (String w : words) if (s.equals(w)) return true;
        return false;
    }

    /** 只点可见的小按钮：大面积的容器（整张广告图、整个弹窗）不点 */
    boolean usable(View v) {
        if (clicked.containsKey(v) || !v.isShown()) return false;
        return small(v, v.getResources().getDisplayMetrics());
    }

    static boolean small(View v, DisplayMetrics dm) {
        Rect r = new Rect();
        if (!v.getGlobalVisibleRect(r) || r.width() <= 0 || r.height() <= 0) return false;
        return r.width() <= dm.widthPixels * 0.6f && r.height() <= dm.heightPixels * 0.25f;
    }

    static String label(View v) {
        CharSequence t = textOf(v);
        if (t != null && t.length() > 0) return t.toString();
        CharSequence d = v.getContentDescription();
        if (d != null && d.length() > 0) return d.toString();
        String id = idName(v);
        return id.length() > 0 ? "#" + id : v.getClass().getSimpleName();
    }

    boolean click(View v, View root, String what) {
        DisplayMetrics dm = v.getResources().getDisplayMetrics();
        // 文字本身不可点时，往上找最近的可点击父控件（同样要求是小控件）
        View target = v;
        for (int i = 0; i < 4 && target != null && !target.isClickable(); i++) {
            ViewParent p = target.getParent();
            target = (p instanceof View) ? (View) p : null;
        }
        if (target == null || !target.isClickable() || (target != v && !small(target, dm))) target = v;

        clicked.put(v, Boolean.TRUE);
        Log.i(TAG, pkg + ": " + what + "「" + label(v) + "」");

        // 先模拟一次真实的触摸（有的广告 SDK 只认触摸事件）
        tap(root, v);
        // 350ms 后按钮还在，再直接触发点击
        final View src = v;
        final View tgt = target;
        handler.postDelayed(new Runnable() {
            @Override
            public void run() {
                try {
                    if (src.isShown() && tgt.isShown()) {
                        boolean ok = tgt.performClick();
                        Log.i(TAG, pkg + ": 触摸未生效，改用 performClick -> " + ok);
                    }
                } catch (Throwable e) {
                    Log.w(TAG, "performClick", e);
                }
            }
        }, 350);
        return true;
    }

    static void tap(View root, View v) {
        try {
            int[] rl = new int[2];
            int[] vl = new int[2];
            root.getLocationInWindow(rl);
            v.getLocationInWindow(vl);
            float x = vl[0] - rl[0] + v.getWidth() / 2f;
            float y = vl[1] - rl[1] + v.getHeight() / 2f;
            long t = SystemClock.uptimeMillis();
            MotionEvent down = MotionEvent.obtain(t, t, MotionEvent.ACTION_DOWN, x, y, 0);
            down.setSource(InputDevice.SOURCE_TOUCHSCREEN);
            root.dispatchTouchEvent(down);
            down.recycle();
            MotionEvent up = MotionEvent.obtain(t, t + 50, MotionEvent.ACTION_UP, x, y, 0);
            up.setSource(InputDevice.SOURCE_TOUCHSCREEN);
            root.dispatchTouchEvent(up);
            up.recycle();
        } catch (Throwable e) {
            Log.w(TAG, "tap", e);
        }
    }
}
