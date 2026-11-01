package com.zjx.usblinkmic.support

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import com.zjx.usblinkmic.contracts.AppSnapshot
import com.zjx.usblinkmic.contracts.AudioParameters
import com.zjx.usblinkmic.contracts.Settings
import com.zjx.usblinkmic.platform.CapabilityProvider
import com.zjx.usblinkmic.platform.NcmShellCommand
import com.zjx.usblinkmic.platform.Runtime
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.Closeable
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

class SupportTests {
    @Test
    fun defaultSettingsPassValidation() {
        assertTrue(SettingsValidator.errors(Settings()).isEmpty())
    }

    @Test
    fun wifiStartValidatorAllowsOptionalEmptyPairingCodeAndRequiresWifiHost() {
        val withoutHost = Settings(wifiHost = "", pairingCode = "")
        assertTrue(SettingsValidator.wifiStartErrors(withoutHost).any { it.startsWith("wifiHost") })

        val validWithoutPairingCode = Settings(wifiHost = "192.168.1.10", pairingCode = "")
        assertTrue(SettingsValidator.wifiStartErrors(validWithoutPairingCode).isEmpty())

        val validWithPairingCode = Settings(wifiHost = "192.168.1.10", pairingCode = "0123456789abcdef0123456789abcdef")
        assertTrue(SettingsValidator.wifiStartErrors(validWithPairingCode).isEmpty())

        val invalidPairingCode = Settings(wifiHost = "192.168.1.10", pairingCode = "short")
        assertTrue(SettingsValidator.wifiStartErrors(invalidPairingCode).any { it.startsWith("pairingCode") })
    }

    @Test
    fun validatorRejectsUnsupportedSchemaAndInvalidValues() {
        assertEquals(listOf("Unsupported schemaVersion: 9"), SettingsValidator.errors(Settings(schemaVersion = 9)))

        val settings = Settings(
            audio = AudioParameters(sampleRate = 12345, channels = 3),
            wifiHost = "bad host",
            audioPort = 1023,
            controlPort = 1023,
            pairingCode = "xyz",
            dns = "256.1.1.1",
            routes = "10.0.0.0/33"
        )
        val errors = SettingsValidator.errors(settings)
        assertTrue(errors.any { it.startsWith("audio.sampleRate") })
        assertTrue(errors.any { it.startsWith("audio.channels") })
        assertTrue(errors.any { it.startsWith("audioPort") })
        assertTrue(errors.any { it.startsWith("controlPort") })
        assertTrue(errors.any { it.contains("distinct") })
        assertTrue(errors.any { it.startsWith("wifiHost") })
        assertTrue(errors.any { it.startsWith("pairingCode") })
        assertTrue(errors.any { it.startsWith("dns") })
        assertTrue(errors.any { it.startsWith("routes") })
    }

    @Test
    fun storeRoundTripsAndRejectsUnknownSchema() {
        val preferences = MemoryPreferences()
        val store = SettingsStore(preferences)
        val saved = Settings(
            audio = AudioParameters(sampleRate = 48000, channels = 2),
            wifiHost = "mic.example.local",
            audioPort = 48126,
            controlPort = 48127,
            pairingCode = "00112233445566778899aabbccddeeff",
            dns = "8.8.8.8",
            routes = "0.0.0.0/0,192.168.0.0/16"
        )
        store.save(saved)
        assertEquals(saved, store.load())

        val commitCount = preferences.commitCount
        try {
            store.save(saved.copy(audioPort = 48127))
            throw AssertionError("Expected invalid settings to be rejected")
        } catch (_: IllegalArgumentException) {
            // Invalid settings must be rejected before SharedPreferences is edited.
        }
        assertEquals(commitCount, preferences.commitCount)
        assertEquals(saved, store.load())

        preferences.edit().putString(SettingsStore.SETTINGS_KEY, "{\"schemaVersion\":77}").commit()
        try {
            store.load()
            throw AssertionError("Expected an unknown schema version to be rejected")
        } catch (error: IllegalArgumentException) {
            assertTrue(error.message.orEmpty().contains("Unsupported schemaVersion: 77"))
        }
    }

    @Test
    fun logRedactorMasksStructuredSecretsIPsAndHomePaths() {
        val input = "serial=ABC123 token=secret pairingCode=001122 ip=192.168.1.5 v6=2001:db8::1 file=/Users/alice/private.log ~/Documents/secret"
        val output = LogRedactor.redact(input)

        assertFalse(output.contains("ABC123"))
        assertFalse(output.contains("secret"))
        assertFalse(output.contains("192.168.1.5"))
        assertFalse(output.contains("2001:db8::1"))
        assertFalse(output.contains("/Users/alice"))
        assertFalse(output.contains("~/Documents"))
        assertTrue(output.contains("serial=[REDACTED]"))
        assertTrue(output.contains("[IP]"))
        assertTrue(output.contains("[HOME]"))
    }

    @Test
    fun socketWriteWatchdogUnblocksStalledLocalLoopbackWriteInBoundedTime() {
        ServerSocket().use { server ->
            server.reuseAddress = true
            server.receiveBufferSize = 4096
            server.bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0), 1)
            var acceptedPeer: Socket? = null
            val acceptThread = Thread({
                try {
                    acceptedPeer = server.accept().apply { receiveBufferSize = 4096 }
                } catch (_: Throwable) {
                }
            }, "stalled-peer-accept").apply {
                isDaemon = true
                start()
            }

            Socket().use { sender ->
                sender.sendBufferSize = 4096
                sender.connect(InetSocketAddress(InetAddress.getByName("127.0.0.1"), server.localPort), 1000)
                sender.soTimeout = 200
                SocketWriteWatchdog(
                    target = sender,
                    defaultTimeoutMs = 200L,
                    checkIntervalMs = 25L
                ).use { watchdog ->
                    val chunk = ByteArray(65536)
                    val startNs = System.nanoTime()
                    var caught: Throwable? = null
                    try {
                        val out = sender.getOutputStream()
                        for (i in 0 until 256) {
                            watchdog.withWriteTimeout {
                                out.write(chunk)
                                out.flush()
                            }
                        }
                    } catch (error: Throwable) {
                        caught = error
                    }
                    val elapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startNs)
                    assertTrue("Expected stalled socket write to throw, got null", caught is SocketTimeoutException)
                    assertTrue("Expected watchdog to mark timeout", watchdog.didTimeOut())
                    assertTrue("Expected stalled socket to be closed by watchdog", sender.isClosed)
                    assertTrue("Expected stalled write to unblock in <1200ms, took ${elapsedMs}ms", elapsedMs < 1200L)
                }
            }
            acceptThread.join(500L)
            try { acceptedPeer?.close() } catch (_: Throwable) { }
        }
    }

    @Test
    fun socketWriteWatchdogDoesNotSpuriouslyCloseCompletedOrRepeatedWrites() {
        val targetClosed = AtomicBoolean(false)
        val target = Closeable { targetClosed.set(true) }
        SocketWriteWatchdog(
            target = target,
            defaultTimeoutMs = 120L,
            checkIntervalMs = 20L
        ).use { watchdog ->
            repeat(5) {
                watchdog.withWriteTimeout {
                    Thread.sleep(15L)
                }
            }
            Thread.sleep(220L)
            assertFalse("Completed writes must not trigger watchdog timeout during idle", watchdog.didTimeOut())
            assertFalse("Target must remain open when all writes finish within deadline", targetClosed.get())
        }
    }

    @Test
    fun socketWriteWatchdogCloseCancelsPendingDeadlineAndIsolatesOldCaptureFromNewCapture() {
        val oldSocketClosedByWatchdog = AtomicBoolean(false)
        val newSocketClosedByWatchdog = AtomicBoolean(false)
        val oldWatchdog = SocketWriteWatchdog(
            target = Closeable { oldSocketClosedByWatchdog.set(true) },
            defaultTimeoutMs = 100L,
            checkIntervalMs = 20L
        )
        val newWatchdog = SocketWriteWatchdog(
            target = Closeable { newSocketClosedByWatchdog.set(true) },
            defaultTimeoutMs = 500L,
            checkIntervalMs = 20L
        )
        try {
            oldWatchdog.beginWrite(100L)
            oldWatchdog.close()
            newWatchdog.withWriteTimeout {
                Thread.sleep(20L)
            }
            Thread.sleep(200L)
            assertFalse("Closed old watchdog must not fire after cancellation", oldWatchdog.didTimeOut())
            assertFalse("Closed old watchdog must not close target after close()", oldSocketClosedByWatchdog.get())
            assertFalse("Old watchdog must never affect new capture's watchdog or socket", newWatchdog.didTimeOut())
            assertFalse("New capture socket must remain open", newSocketClosedByWatchdog.get())
        } finally {
            oldWatchdog.close()
            newWatchdog.close()
        }
    }

    @Test
    fun socketWriteWatchdogStaleCheckCannotCloseReplacementWriteOrClosedWatchdog() {
        val entered = CountDownLatch(1)
        val resume = CountDownLatch(1)
        val calls = AtomicInteger()
        val closes = AtomicInteger()
        val timeouts = AtomicInteger()
        val scheduler = ScheduledThreadPoolExecutor(1)
        val guard = SocketWriteWatchdog(
            target = Closeable { closes.incrementAndGet() },
            defaultTimeoutMs = 1L,
            checkIntervalMs = 60_000L,
            clockNs = {
                when (calls.incrementAndGet()) {
                    1 -> 1L
                    2 -> {
                        entered.countDown()
                        check(resume.await(2, TimeUnit.SECONDS)) { "fixture timeout" }
                        2_000_001L
                    }
                    3 -> 3_000_001L
                    else -> 5_000_001L
                }
            },
            scheduler = scheduler,
            onTimeout = { timeouts.incrementAndGet() }
        )
        try {
            guard.beginWrite(1L)
            val checker = Thread { guard.checkDeadline() }
            checker.start()
            assertTrue("Expected checker to enter clockNs", entered.await(1, TimeUnit.SECONDS))
            guard.endWrite()
            guard.beginWrite(1L)
            resume.countDown()
            checker.join(1_000L)

            assertEquals("Stale deadline observation must not close replacement write", 0, closes.get())
            assertEquals("Stale deadline observation must not invoke onTimeout", 0, timeouts.get())
            assertFalse("Watchdog must not mark timedOut on stale check", guard.didTimeOut())
            assertFalse("Watchdog must remain open for active replacement write", guard.isClosed())

            // When the replacement write genuinely expires, checkDeadline trips once.
            guard.checkDeadline()
            guard.checkDeadline()
            assertEquals(1, closes.get())
            assertEquals(1, timeouts.get())
            assertTrue(guard.didTimeOut())
            assertTrue(guard.isClosed())
        } finally {
            guard.close()
            scheduler.shutdownNow()
        }

        // Racing explicit close() while checkDeadline is in-flight must also prevent target close.
        val enteredClose = CountDownLatch(1)
        val resumeClose = CountDownLatch(1)
        val closeCalls = AtomicInteger()
        val closeTargetCount = AtomicInteger()
        val closeTimeoutCount = AtomicInteger()
        val scheduler2 = ScheduledThreadPoolExecutor(1)
        val guard2 = SocketWriteWatchdog(
            target = Closeable { closeTargetCount.incrementAndGet() },
            defaultTimeoutMs = 1L,
            checkIntervalMs = 60_000L,
            clockNs = {
                if (closeCalls.incrementAndGet() == 1) {
                    1L
                } else {
                    enteredClose.countDown()
                    check(resumeClose.await(2, TimeUnit.SECONDS)) { "fixture timeout" }
                    2_000_001L
                }
            },
            scheduler = scheduler2,
            onTimeout = { closeTimeoutCount.incrementAndGet() }
        )
        try {
            guard2.beginWrite(1L)
            val checker2 = Thread { guard2.checkDeadline() }
            checker2.start()
            assertTrue(enteredClose.await(1, TimeUnit.SECONDS))
            guard2.close()
            resumeClose.countDown()
            checker2.join(1_000L)
            assertEquals("Explicit close() must prevent in-flight checkDeadline from closing target", 0, closeTargetCount.get())
            assertEquals("Explicit close() must prevent in-flight checkDeadline from invoking onTimeout", 0, closeTimeoutCount.get())
            assertFalse(guard2.didTimeOut())
            assertTrue(guard2.isClosed())
        } finally {
            guard2.close()
            scheduler2.shutdownNow()
        }
    }

    @Test
    fun capabilityProviderAllowsRootShellSystemAndSelfButDeniesOtherApps() {
        val appUid = 10234
        assertTrue(CapabilityProvider.isAllowedCallerUid(0, appUid))
        assertTrue(CapabilityProvider.isAllowedCallerUid(2000, appUid))
        assertTrue(CapabilityProvider.isAllowedCallerUid(1000, appUid))
        assertTrue(CapabilityProvider.isAllowedCallerUid(appUid, appUid))
        assertFalse(CapabilityProvider.isAllowedCallerUid(10235, appUid))
        assertFalse(CapabilityProvider.isAllowedCallerUid(9999, appUid))
        assertFalse(CapabilityProvider.isAllowedCallerUid(-1, appUid))
    }

    @Test
    fun ncmShellCommandDropsRootToShellAndRejectsOrdinaryApps() {
        val callOrder = mutableListOf<String>()
        var currentUid = 0
        var currentGid = 0
        val rootOps = object : NcmShellCommand.IdentityOps {
            override fun myUid(): Int = currentUid
            override fun getuid(): Int = currentUid
            override fun geteuid(): Int = currentUid
            override fun getgid(): Int = currentGid
            override fun getegid(): Int = currentGid
            override fun setgid(gid: Int) {
                check(currentUid == 0) { "setgid requires root before setuid drop" }
                callOrder.add("setgid:$gid")
                currentGid = gid
            }
            override fun setuid(uid: Int) {
                callOrder.add("setuid:$uid")
                currentUid = uid
            }
        }
        NcmShellCommand.ensureShellProcessIdentity(rootOps)
        assertEquals(listOf("setgid:2000", "setuid:2000"), callOrder)
        assertEquals(2000, currentUid)
        assertEquals(2000, currentGid)

        // Already shell (2000) succeeds without setgid/setuid calls.
        val shellCalls = mutableListOf<String>()
        val shellOps = object : NcmShellCommand.IdentityOps {
            override fun myUid(): Int = 2000
            override fun getuid(): Int = 2000
            override fun geteuid(): Int = 2000
            override fun getgid(): Int = 2000
            override fun getegid(): Int = 2000
            override fun setgid(gid: Int) { shellCalls.add("setgid:$gid") }
            override fun setuid(uid: Int) { shellCalls.add("setuid:$uid") }
        }
        NcmShellCommand.ensureShellProcessIdentity(shellOps)
        assertTrue(shellCalls.isEmpty())

        // Ordinary app caller (e.g. 10234) is rejected without attempting setgid/setuid.
        val appCalls = mutableListOf<String>()
        val appOps = object : NcmShellCommand.IdentityOps {
            override fun myUid(): Int = 10234
            override fun getuid(): Int = 10234
            override fun geteuid(): Int = 10234
            override fun getgid(): Int = 10234
            override fun getegid(): Int = 10234
            override fun setgid(gid: Int) { appCalls.add("setgid:$gid") }
            override fun setuid(uid: Int) { appCalls.add("setuid:$uid") }
        }
        var appRejected = false
        try {
            NcmShellCommand.ensureShellProcessIdentity(appOps)
        } catch (error: SecurityException) {
            appRejected = error.message == "ADB_SHELL_REQUIRED"
        }
        assertTrue("Expected ordinary app UID to be rejected with ADB_SHELL_REQUIRED", appRejected)
        assertTrue(appCalls.isEmpty())
    }

    @Test
    fun wifiHostSyncPreservesUserLanTargetAndRejectsLoopbackOrVpnAddresses() {
        for (invalid in listOf(
            "127.0.0.1",
            "localhost",
            "localhost.",
            "LOCALHOST.",
            "router.localhost",
            "router.localhost.",
            "sub.router.localhost.",
            "0.0.0.0",
            "255.255.255.255",
            "169.254.1.2",
            "10.0.0.2",
            "224.0.0.1"
        )) {
            assertFalse("Invalid Wi-Fi target $invalid must be rejected", SettingsValidator.isUsableWifiTargetHost(invalid))
            assertTrue(SettingsValidator.errors(Settings(wifiHost = invalid)).any { it.startsWith("wifiHost") })
        }
        for (valid in listOf("192.168.1.10", "10.0.1.5", "172.16.0.2", "macbook.local", "macbook.local.")) {
            assertTrue("Valid Wi-Fi target $valid must be accepted", SettingsValidator.isUsableWifiTargetHost(valid))
        }

        // Auto-detected USB sync IP must NOT overwrite user's existing valid LAN wifiHost when incomingExplicit is false
        assertEquals(
            "192.168.1.99",
            SettingsValidator.resolveSyncedWifiHost(
                existingHost = "192.168.1.99",
                incomingHost = "172.16.42.1",
                incomingExplicit = false
            )
        )
        // Explicit user-configured wifiHost from Mac updates the synced target
        assertEquals(
            "192.168.1.88",
            SettingsValidator.resolveSyncedWifiHost(
                existingHost = "192.168.1.99",
                incomingHost = "192.168.1.88",
                incomingExplicit = true
            )
        )
        // Invalid incoming host (e.g. VPN 10.0.0.2 or loopback) never overwrites existing valid target
        assertEquals(
            "192.168.1.99",
            SettingsValidator.resolveSyncedWifiHost(
                existingHost = "192.168.1.99",
                incomingHost = "10.0.0.2",
                incomingExplicit = true
            )
        )
    }

    @Test
    fun affectsAudioAndApplySettingsSaveHandleUsbIsolationAndSaveErrorRetry() {
        val base = Settings()
        val wifiEdited = base.copy(
            wifiHost = "192.168.1.77",
            pairingCode = "00112233445566778899aabbccddeeff"
        )
        assertFalse(
            "Wi-Fi-only edits must not affect active USB audio",
            SettingsValidator.affectsAudio(base, wifiEdited, activeMode = "audio")
        )
        assertTrue(
            "Wi-Fi edits must affect active Wi-Fi audio",
            SettingsValidator.affectsAudio(base, wifiEdited, activeMode = "wifi")
        )
        assertTrue(
            "Sample rate changes must affect active USB audio",
            SettingsValidator.affectsAudio(
                base,
                base.copy(audio = AudioParameters(sampleRate = 48000)),
                activeMode = "audio"
            )
        )

        // 1. Persistence failure surfaces settingsError, keeps baseline settings, and does not increment revision
        val initialSnapshot = AppSnapshot(settings = base)
        var audioStoppedCount = 0
        val failedSnapshot = SettingsValidator.applySettingsSave(
            current = initialSnapshot,
            newSettings = wifiEdited,
            activeAudioMode = "audio",
            persist = { throw IllegalStateException("Unable to persist settings") },
            onStopAudio = { audioStoppedCount += 1 }
        )
        assertFalse(failedSnapshot.isSavingSettings)
        assertEquals("Unable to persist settings", failedSnapshot.settingsError)
        assertEquals(base, failedSnapshot.settings)
        assertEquals(0L, failedSnapshot.settingsSavedRevision)
        assertEquals(0, audioStoppedCount)

        // 2. Retrying save with working persistence clears settingsError, updates settings, and does not stop USB audio for Wi-Fi-only edits
        val retriedSnapshot = SettingsValidator.applySettingsSave(
            current = failedSnapshot,
            newSettings = wifiEdited,
            activeAudioMode = "audio",
            persist = { },
            onStopAudio = { audioStoppedCount += 1 }
        )
        assertFalse(retriedSnapshot.isSavingSettings)
        assertEquals(null, retriedSnapshot.settingsError)
        assertEquals(wifiEdited, retriedSnapshot.settings)
        assertEquals(1L, retriedSnapshot.settingsSavedRevision)
        assertEquals("USB audio must not be stopped by Wi-Fi-only edits", 0, audioStoppedCount)
    }

    @Test
    fun compactDiagnosticsLogLinesBoundsSizeAndPreservesCriticalEntries() {
        val rows = mutableListOf<String>()
        rows += JSONObject().put("timestamp", 1000L).put("module", "audio").put("stage", "macStart").put("message", "session=s1 started").toString()
        rows += JSONObject().put("timestamp", 1001L).put("module", "audio").put("stage", "failed").put("message", "HANDSHAKE_REJECTED").toString()
        for (i in 0 until 60) {
            rows += JSONObject().put("timestamp", 2000L + i).put("module", "audio").put("stage", "healthSummary").put("message", "periodic frame telemetry $i padding-text").toString()
        }
        val compacted = Runtime.compactDiagnosticsLogLines(rows, maxBytes = 2000, targetBytes = 1500)
        val totalBytes = compacted.joinToString("\n", postfix = "\n").toByteArray(Charsets.UTF_8).size
        assertTrue("Compacted log must stay within budget, got $totalBytes", totalBytes <= 2000)
        assertTrue("Critical start/failed entries must be preserved across compaction", compacted.any { it.contains("macStart") || it.contains("HANDSHAKE_REJECTED") })
        assertTrue("Newest tail entry must be retained", compacted.last().contains("telemetry 59"))
    }
}

private class MemoryPreferences : SharedPreferences {
    private val values = linkedMapOf<String, Any?>()
    var commitCount: Int = 0
        private set

    override fun getAll(): MutableMap<String, *> = values.toMutableMap()
    override fun getString(key: String, defValue: String?): String? = values[key] as? String ?: defValue
    @Suppress("UNCHECKED_CAST")
    override fun getStringSet(key: String, defValues: MutableSet<String>?): MutableSet<String>? =
        (values[key] as? Set<String>)?.toMutableSet() ?: defValues
    override fun getInt(key: String, defValue: Int): Int = values[key] as? Int ?: defValue
    override fun getLong(key: String, defValue: Long): Long = values[key] as? Long ?: defValue
    override fun getFloat(key: String, defValue: Float): Float = values[key] as? Float ?: defValue
    override fun getBoolean(key: String, defValue: Boolean): Boolean = values[key] as? Boolean ?: defValue
    override fun contains(key: String): Boolean = values.containsKey(key)
    override fun edit(): SharedPreferences.Editor = MemoryEditor()
    override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit
    override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit

    private inner class MemoryEditor : SharedPreferences.Editor {
        private val updates = linkedMapOf<String, Any?>()
        private var clearFirst = false

        override fun putString(key: String, value: String?): SharedPreferences.Editor = update(key, value)
        override fun putStringSet(key: String, values: MutableSet<String>?): SharedPreferences.Editor = update(key, values?.toSet())
        override fun putInt(key: String, value: Int): SharedPreferences.Editor = update(key, value)
        override fun putLong(key: String, value: Long): SharedPreferences.Editor = update(key, value)
        override fun putFloat(key: String, value: Float): SharedPreferences.Editor = update(key, value)
        override fun putBoolean(key: String, value: Boolean): SharedPreferences.Editor = update(key, value)
        override fun remove(key: String): SharedPreferences.Editor = update(key, Removed)
        override fun clear(): SharedPreferences.Editor = apply { clearFirst = true }
        override fun commit(): Boolean {
            commitCount += 1
            if (clearFirst) values.clear()
            updates.forEach { (key, value) -> if (value === Removed) values.remove(key) else values[key] = value }
            return true
        }
        override fun apply() { commit() }

        private fun update(key: String, value: Any?): SharedPreferences.Editor = apply { updates[key] = value }
    }

    private data object Removed
}
