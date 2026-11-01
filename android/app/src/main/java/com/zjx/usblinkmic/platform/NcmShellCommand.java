package com.zjx.usblinkmic.platform;

import android.annotation.SuppressLint;
import android.content.Context;
import android.content.ContextWrapper;
import android.net.TetheringManager;
import android.net.Network;
import android.os.Build;
import android.os.Looper;
import android.os.Process;
import org.json.JSONObject;
import org.json.JSONArray;
import java.util.List;
import java.util.Set;
import java.util.ArrayList;
import java.util.concurrent.atomic.AtomicReference;
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
    public static final int ROOT_UID = 0;
    public static final int SHELL_UID = 2000;
    private NcmShellCommand() {}

    public interface IdentityOps {
        int myUid();
        int getuid();
        int geteuid();
        int getgid();
        int getegid();
        void setgid(int gid) throws Exception;
        void setuid(int uid) throws Exception;
    }

    private static final IdentityOps SYSTEM_IDENTITY_OPS = new IdentityOps() {
        @Override public int myUid() { return Process.myUid(); }
        @Override public int getuid() { return android.system.Os.getuid(); }
        @Override public int geteuid() { return android.system.Os.geteuid(); }
        @Override public int getgid() { return android.system.Os.getgid(); }
        @Override public int getegid() { return android.system.Os.getegid(); }
        @Override public void setgid(int gid) throws Exception { android.system.Os.setgid(gid); }
        @Override public void setuid(int uid) throws Exception { android.system.Os.setuid(uid); }
    };

    public static void ensureShellProcessIdentity(IdentityOps ops) throws Exception {
        int initialUid = ops.myUid();
        if (initialUid == ROOT_UID) {
            ops.setgid(SHELL_UID);
            ops.setuid(SHELL_UID);
            if (ops.myUid() != SHELL_UID || ops.getuid() != SHELL_UID || ops.geteuid() != SHELL_UID
                    || ops.getgid() != SHELL_UID || ops.getegid() != SHELL_UID) {
                throw new SecurityException("ADB_SHELL_UID_DROP_INCOMPLETE");
            }
        }
        if (ops.myUid() != SHELL_UID) {
            throw new SecurityException("ADB_SHELL_REQUIRED");
        }
    }

    public static void main(String[] args) {
        JSONObject result = new JSONObject();
        boolean ok = false;
        AtomicBoolean reported = new AtomicBoolean(false);
        Throwable identityFailure = null;
        try {
            ensureShellProcessIdentity(SYSTEM_IDENTITY_OPS);
        } catch (Throwable failure) {
            identityFailure = failure;
        }
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
            if (identityFailure != null) throw identityFailure;
            if (Process.myUid() != SHELL_UID) throw new SecurityException("ADB_SHELL_REQUIRED");
            if (args.length != 2 || !(args[0].equals("start") || args[0].equals("stop") || args[0].equals("status"))
                    || !args[1].matches("[A-Fa-f0-9-]{36}")) throw new IllegalArgumentException("INVALID_COMMAND");
            result.put("action", args[0]).put("session", args[1]).put("sdk", Build.VERSION.SDK_INT);
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
            if (args[0].equals("status")) {
                // Registering delivers the real interface list immediately. Both callback
                // signatures are needed: Android 11–13 use List, newer modules use Set.
                CountDownLatch changed = new CountDownLatch(1);
                AtomicReference<List<String>> tethered = new AtomicReference<>();
                AtomicReference<Throwable> readError = new AtomicReference<>();
                AtomicReference<Boolean> upstream = new AtomicReference<>();
                TetheringManager.TetheringEventCallback callback = new TetheringManager.TetheringEventCallback() {
                    // Hidden in the public SDK; an optional diagnostic callback on the platform.
                    public void onUpstreamChanged(Network network) { upstream.set(network != null); }
                    public void onTetheredInterfacesChanged(List<String> interfaces) {
                        tethered.set(new ArrayList<>(interfaces)); changed.countDown();
                    }
                    @Override @SuppressWarnings("rawtypes")
                    public void onTetheredInterfacesChanged(Set interfaces) {
                        try {
                            List<String> names = new ArrayList<>();
                            for (Object iface : interfaces) {
                                names.add((String) iface.getClass().getMethod("getInterface").invoke(iface));
                            }
                            tethered.set(names);
                        } catch (Throwable failure) { readError.set(failure); }
                        changed.countDown();
                    }
                };
                boolean registered = false;
                try {
                    manager.registerTetheringEventCallback(Runnable::run, callback);
                    registered = true;
                    if (!changed.await(8, TimeUnit.SECONDS)) throw new IllegalStateException("TETHERING_STATUS_TIMEOUT");
                    if (readError.get() != null) throw new IllegalStateException("TETHERING_STATUS_DECODE", readError.get());
                    result.put("tethered", new JSONArray(tethered.get()));
                    result.put("upstreamPresent", upstream.get() == null ? JSONObject.NULL : upstream.get());
                    result.put("callback", "interfaces").put("errorCode", 0);
                    ok = true;
                } finally { if (registered) manager.unregisterTetheringEventCallback(callback); }
            } else {
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
            }
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
