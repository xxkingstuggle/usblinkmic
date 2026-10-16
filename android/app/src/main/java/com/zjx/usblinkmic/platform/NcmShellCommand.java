package com.zjx.usblinkmic.platform;

import android.annotation.SuppressLint;
import android.content.Context;
import android.content.ContextWrapper;
import android.net.TetheringManager;
import android.os.Build;
import android.os.Looper;
import android.os.Process;
import org.json.JSONObject;
import java.lang.reflect.Method;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicBoolean;

/** An ADB shell entry point, never callable as an app permission escalation. */
@SuppressLint({"NewApi", "BlockedPrivateApi", "WrongConstant"})
public final class NcmShellCommand {
    private static final int ETHERNET = 5;
    private NcmShellCommand() {}

    public static void main(String[] args) {
        JSONObject result = new JSONObject();
        boolean ok = false;
        AtomicBoolean reported = new AtomicBoolean(false);
        // Bound the entire helper, including a blocked ROM service lookup. No
        // shell timeout tool or permanently running service is required.
        Thread deadline = new Thread(() -> {
            try { Thread.sleep(30000); } catch (InterruptedException done) { return; }
            if (reported.compareAndSet(false, true)) {
                JSONObject timeout = new JSONObject();
                try {
                    timeout.put("ok", false).put("error", "NCM_PROCESS_TIMEOUT");
                    if (args.length == 2) timeout.put("action", args[0]).put("session", args[1]);
                    System.out.println(timeout); System.out.flush();
                } catch (org.json.JSONException impossible) { System.err.println("NCM_RESULT_ENCODING_FAILED"); }
                System.exit(1);
            }
        }, "linkmic-ncm-deadline");
        deadline.setDaemon(true); deadline.start();
        try {
            if (Process.myUid() != 2000) throw new SecurityException("ADB_SHELL_REQUIRED");
            if (args.length != 2 || !(args[0].equals("start") || args[0].equals("stop"))
                    || !args[1].matches("[A-Fa-f0-9-]{36}")) throw new IllegalArgumentException("INVALID_COMMAND");
            result.put("action", args[0]).put("session", args[1]);
            if (Build.VERSION.SDK_INT < 30) throw new UnsupportedOperationException("NCM_SHELL_REQUIRES_API30");
            if (Looper.myLooper() == null) Looper.prepareMainLooper();
            Class<?> activityThread = Class.forName("android.app.ActivityThread");
            Object thread = activityThread.getDeclaredMethod("systemMain").invoke(null);
            Context system = (Context) activityThread.getDeclaredMethod("getSystemContext").invoke(thread);
            Context shell = new ContextWrapper(system.createPackageContext("com.android.shell", Context.CONTEXT_IGNORE_SECURITY)) {
                @Override public String getPackageName() { return "com.android.shell"; }
                @Override public String getOpPackageName() { return "com.android.shell"; }
                @Override public String getAttributionTag() { return null; }
            };
            TetheringManager manager = shell.getSystemService(TetheringManager.class);
            if (manager == null) throw new UnsupportedOperationException("TETHERING_SERVICE_UNAVAILABLE");
            // Some Android releases obtain this service through the base context.
            try {
                java.lang.reflect.Field context = TetheringManager.class.getDeclaredField("mContext");
                context.setAccessible(true);
                context.set(manager, shell);
            } catch (NoSuchFieldException ignored) { /* Service already obtained from shell context. */ }
            TetheringManager.TetheringRequest.Builder builder = new TetheringManager.TetheringRequest.Builder(ETHERNET);
            Method entitlement = builder.getClass().getDeclaredMethod("setShouldShowEntitlementUi", boolean.class);
            entitlement.setAccessible(true);
            entitlement.invoke(builder, false);
            TetheringManager.TetheringRequest request = builder.build();
            Executor executor = Runnable::run;
            CountDownLatch completed = new CountDownLatch(1);
            AtomicInteger code = new AtomicInteger(-1);
            boolean legacyStop = false;
            if (args[0].equals("start")) {
                manager.startTethering(request, executor, new TetheringManager.StartTetheringCallback() {
                    @Override public void onTetheringStarted() { code.set(0); completed.countDown(); }
                    @Override public void onTetheringFailed(int error) { code.set(error); completed.countDown(); }
                });
            } else if (Build.VERSION.SDK_INT >= 36) {
                manager.stopTethering(request, executor, new TetheringManager.StopTetheringCallback() {
                    @Override public void onStopTetheringSucceeded() { code.set(0); completed.countDown(); }
                    @Override public void onStopTetheringFailed(int error) { code.set(error); completed.countDown(); }
                });
            } else {
                // Pre-36 platform implementation has the hidden stop-by-type entry point.
                manager.getClass().getMethod("stopTethering", int.class).invoke(manager, ETHERNET);
                legacyStop = true;
                code.set(0); completed.countDown();
            }
            if (!completed.await(25, TimeUnit.SECONDS)) throw new IllegalStateException("TETHERING_CALLBACK_TIMEOUT");
            result.put("errorCode", code.get());
            ok = code.get() == 0;
            result.put("callback", ok ? (args[0].equals("start") ? "started" : (legacyStop ? "stopSubmitted" : "stopped")) : "failed");
        } catch (Throwable failure) {
            Throwable cause = failure;
            while (cause.getCause() != null && cause.getCause() != cause) cause = cause.getCause();
            try { result.put("error", cause.getClass().getSimpleName() + ": " + cause.getMessage()); }
            catch (org.json.JSONException impossible) { System.err.println("NCM_RESULT_ENCODING_FAILED"); }
        }
        deadline.interrupt();
        if (!reported.compareAndSet(false, true)) System.exit(1);
        try { result.put("ok", ok); System.out.println(result); System.out.flush(); }
        catch (org.json.JSONException impossible) { System.err.println("NCM_RESULT_ENCODING_FAILED"); }
        System.exit(ok ? 0 : 1);
    }
}
