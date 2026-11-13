package com.hairu.idea;

import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ShortcutInfo;
import android.content.pm.ShortcutManager;
import android.graphics.Color;
import android.graphics.drawable.Icon;
import android.os.Build;
import android.os.Bundle;
import android.view.View;
import android.view.inputmethod.InputMethodManager;
import android.webkit.JavascriptInterface;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import java.io.ByteArrayOutputStream;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Collections;

/**
 * 海如便签：单 Activity + 本地 WebView。
 * 界面与逻辑全部在 assets/index.html，Java 只负责：
 *  1) 把 HTML 显示出来；2) 按页面请求弹/收软键盘；3) 提供本地文件读写 / 分享 / 剪贴板的桥；
 *  4) 同步自定义应用名到系统最近任务标题与桌面快捷方式。
 * 数据存在应用私有目录 notes.json，不联网、不申请任何权限。
 */
public class MainActivity extends Activity {

    private static final String DATA_FILE = "notes.json";
    private static final String PAGE_URL  = "file:///android_asset/index.html";
    private static final String META      = "app_meta";
    private static final String KEY_NAME  = "app_name";

    private WebView web;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        // 浅色状态栏 + 深色状态栏图标
        getWindow().setStatusBarColor(Color.parseColor("#F7F5FB"));
        getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR);

        web = new WebView(this);
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setAllowFileAccess(true);
        s.setAllowContentAccess(true);
        s.setDefaultTextEncodingName("UTF-8");
        s.setTextZoom(100);
        s.setCacheMode(WebSettings.LOAD_NO_CACHE);
        s.setMediaPlaybackRequiresUserGesture(true);

        web.setBackgroundColor(Color.parseColor("#F7F5FB"));
        web.setHorizontalScrollBarEnabled(false);
        web.setVerticalScrollBarEnabled(false);
        web.addJavascriptInterface(new Store(), "AndroidStore");
        web.setWebViewClient(new WebViewClient());
        setContentView(web);
        web.loadUrl(PAGE_URL);

        // 列表页不弹键盘；打开编辑页时由页面调用 AndroidStore.showKeyboard() 主动唤起。
        // 自定义名称保存后，冷启动时也要让「最近任务」标题保持新名字
        setTitle(getSavedName());
    }

    private String getSavedName() {
        String v = getSharedPreferences(META, MODE_PRIVATE).getString(KEY_NAME, null);
        return (v == null || v.trim().isEmpty()) ? getString(R.string.app_name) : v;
    }

    private String safeName(String raw) {
        if (raw == null) return getString(R.string.app_name);
        String v = raw.replaceAll("[\\r\\n\\t]", " ").trim();
        if (v.isEmpty()) return getString(R.string.app_name);
        return v.length() > 12 ? v.substring(0, 12) : v;
    }

    private Intent launchIntent() {
        Intent i = new Intent(MainActivity.this, MainActivity.class);
        i.setAction(Intent.ACTION_MAIN);
        i.setFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        return i;
    }

    /** 长按图标弹出的动态快捷方式也用自定义名称 */
    private void updateDynamicShortcut(String name) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N_MR1) return;
        try {
            ShortcutManager sm = (ShortcutManager) getSystemService(Context.SHORTCUT_SERVICE);
            if (sm == null) return;
            ShortcutInfo info = new ShortcutInfo.Builder(this, "app_main")
                    .setShortLabel(name)
                    .setLongLabel(name)
                    .setIcon(Icon.createWithResource(this, R.mipmap.ic_launcher))
                    .setIntent(launchIntent())
                    .build();
            sm.setDynamicShortcuts(Collections.singletonList(info));
        } catch (Exception ignored) { }
    }

    /**
     * 列表 / 编辑 / 关于三个视图由页面 JS 切换，WebView 里没有 history 记录。
     * 物理返回键先问页面能否回退（关弹层 → 关于页回列表 → 编辑页回列表），
     * 已经停在列表页时才真正退出应用。
     */
    @Override
    public void onBackPressed() {
        web.evaluateJavascript(
            "(function(){try{return (window.__nativeBack && window.__nativeBack()) ? '1' : '0';}catch(e){return '0';}})()",
            value -> {
                if (!"\"1\"".equals(value)) finish();
            });
    }

    /** 暴露给页面 JS 的本地存储桥，名字固定为 AndroidStore */
    private class Store {

        @JavascriptInterface
        public String load() {
            FileInputStream in = null;
            try {
                in = openFileInput(DATA_FILE);
                ByteArrayOutputStream out = new ByteArrayOutputStream();
                byte[] buf = new byte[4096];
                int n;
                while ((n = in.read(buf)) > 0) {
                    out.write(buf, 0, n);
                }
                return new String(out.toByteArray(), StandardCharsets.UTF_8);
            } catch (Exception e) {
                return "";
            } finally {
                if (in != null) {
                    try { in.close(); } catch (Exception ignored) { }
                }
            }
        }

        @JavascriptInterface
        public void save(String json) {
            FileOutputStream out = null;
            try {
                out = openFileOutput(DATA_FILE, MODE_PRIVATE);
                out.write(json.getBytes(StandardCharsets.UTF_8));
                out.flush();
            } catch (Exception ignored) {
                // 存储空间异常时静默失败，页面仍可继续使用
            } finally {
                if (out != null) {
                    try { out.close(); } catch (Exception ignored) { }
                }
            }
        }

        /** 导出：调起系统分享，可存到文件 / 发给自己的微信文件传输助手 */
        @JavascriptInterface
        public void share(final String text) {
            runOnUiThread(new Runnable() {
                @Override public void run() {
                    try {
                        Intent i = new Intent(Intent.ACTION_SEND);
                        i.setType("text/plain");
                        i.putExtra(Intent.EXTRA_TEXT, text);
                        startActivity(Intent.createChooser(i, "导出便签备份"));
                    } catch (Exception ignored) { }
                }
            });
        }

        /** 导入：读取剪贴板里的备份文本 */
        @JavascriptInterface
        public String paste() {
            try {
                ClipboardManager cm = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
                if (cm == null || !cm.hasPrimaryClip()) return "";
                ClipData d = cm.getPrimaryClip();
                if (d == null || d.getItemCount() == 0) return "";
                CharSequence c = d.getItemAt(0).getText();
                return c == null ? "" : c.toString();
            } catch (Exception e) {
                return "";
            }
        }

        /** 打开编辑页时唤起软键盘，保证「点开就能写」 */
        @JavascriptInterface
        public void showKeyboard() {
            runOnUiThread(new Runnable() {
                @Override public void run() {
                    web.requestFocus();
                    InputMethodManager imm = (InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE);
                    if (imm != null) imm.showSoftInput(web, InputMethodManager.SHOW_IMPLICIT);
                }
            });
        }

        /** 关闭编辑页时收起软键盘 */
        @JavascriptInterface
        public void hideKeyboard() {
            runOnUiThread(new Runnable() {
                @Override public void run() {
                    InputMethodManager imm = (InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE);
                    if (imm != null) imm.hideSoftInputFromWindow(web.getWindowToken(), 0);
                }
            });
        }

        /** 自定义应用名称：同步到最近任务标题、动态快捷方式，并持久化 */
        @JavascriptInterface
        public void setAppName(String raw) {
            final String name = safeName(raw);
            runOnUiThread(new Runnable() {
                @Override public void run() {
                    getSharedPreferences(META, MODE_PRIVATE)
                            .edit().putString(KEY_NAME, name).apply();
                    setTitle(name);
                    updateDynamicShortcut(name);
                }
            });
        }

        /**
         * 桌面上另建一个使用自定义名称的快捷方式。
         * Android 的启动器图标名写在 APK 资源表里，运行时无法直接改写，
         * 这是系统允许的标准替代方案；部分定制桌面会拒绝，返回 false 由页面提示。
         */
        @JavascriptInterface
        public boolean pinShortcut(String raw) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false;
            try {
                final String name = safeName(raw);
                ShortcutManager sm = (ShortcutManager) getSystemService(Context.SHORTCUT_SERVICE);
                if (sm == null || !sm.isRequestPinShortcutSupported()) return false;
                ShortcutInfo pin = new ShortcutInfo.Builder(
                        MainActivity.this, "pinned_" + System.currentTimeMillis())
                        .setShortLabel(name)
                        .setLongLabel(name)
                        .setIcon(Icon.createWithResource(MainActivity.this, R.mipmap.ic_launcher))
                        .setIntent(launchIntent())
                        .build();
                return sm.requestPinShortcut(pin, null);
            } catch (Exception e) {
                return false;
            }
        }
    }
}
