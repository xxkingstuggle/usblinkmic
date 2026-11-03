package com.zjx.usblinkmic.support

import com.zjx.usblinkmic.contracts.*
import com.zjx.usblinkmic.platform.WifiAutoConnector
import com.zjx.usblinkmic.platform.WifiEndpointDiscovery
import com.zjx.usblinkmic.platform.Runtime
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.ServerSocket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

class WifiAutoConnectTests {

    @Before
    fun setUp() {
        Runtime.audioRequest = null
        Runtime.update { AppSnapshot() }
    }

    @Test
    fun crossPlatformVectorsMatchMacSwiftVerbatim() {
        val key = ByteArray(32) { it.toByte() }
        assertEquals("f0133729c4163dede81e21cd47839256da58171238c8a0d874397c73b14e1e47", WifiCrypto.hmacHex(key, "abc"))
        assertEquals("0fb1371464bf3aa28008ff9965cf272585c967f1aa957854a3bf3f189493239c", WifiCrypto.authProof(key, false, "mac1", "phone1", "cn", "sn"))
        assertEquals("480533b34be185e0bc788e38d09f378af81fe1ea51dd9c5a49176017d8ba8ab9", WifiCrypto.authProof(key, true, "mac1", "phone1", "cn", "sn"))
        assertEquals("47b2f2299d45e9dc3f27254bed6da93483261cbbc4239f76b41831c7c46774c1", WifiCrypto.messageMAC(key, "c", "cn", "sn", 3, "prepare", "48000|1|i16|microphone|0"))
        assertEquals("d39779a86a5b8f2dc1791c6e803e5817bba9b8b83d8ac276bc57ebbb0bfaff90", WifiCrypto.audioToken(key, "sid", "cn", "sn"))
        assertEquals("795361", WifiCrypto.verificationCode(key))
        assertEquals("fd41055d8ac7d6f1c0c52644cf743c3f146b4076f66432c9410826fe89c09c42", WifiCrypto.pairApprovedProof(key, "req", "mac1", "phone1"))
    }

    @Test
    fun trustStorePersistsAndRemovesMac() {
        val prefs = MemoryPreferences()
        val store = WifiTrustStore(prefs)
        val phoneId = store.phoneId
        assertEquals(32, phoneId.length)
        assertEquals(phoneId, store.phoneId)

        store.upsert(TrustedMac("mac-1", "MacBook", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", 1000L))
        val loaded = store.getMac("mac-1")
        assertNotNull(loaded)
        assertEquals("MacBook", loaded?.name)

        store.remove("mac-1")
        assertNull(store.getMac("mac-1"))
    }

    @Test
    fun loopbackPairingFlowAllowsApprovalAndDerivesMatchingSecret() {
        val prefs = MemoryPreferences()
        val store = WifiTrustStore(prefs)

        val server = ServerSocket(0)
        val port = server.localPort

        val mockDiscovery = object : WifiEndpointDiscovery {
            override fun start(onDiscovered: (DiscoveredMac) -> Unit, onLost: (String) -> Unit) {
                onDiscovered(DiscoveredMac("mock-mac", "Mock Mac", "127.0.0.1", port, isTrusted = false))
            }
            override fun stop() {}
        }

        val connector = WifiAutoConnector(
            context = null,
            trustStore = store,
            discovery = mockDiscovery,
            onSessionReady = { _, _, _, _, _ -> },
            mainDispatcher = { it() }
        )
        val pairDone = CountDownLatch(1)
        val macServerKeys = WifiCrypto.PairingKeys()

        thread(isDaemon = true) {
            val client = server.accept()
            val reader = BufferedReader(InputStreamReader(client.getInputStream(), Charsets.UTF_8))
            val writer = OutputStreamWriter(client.getOutputStream(), Charsets.UTF_8)

            // Hello
            val helloLine = reader.readLine()
            val hello = JSONObject(helloLine)
            val clientNonce = hello.getString("nonce")
            val phoneId = hello.getString("phoneID")
            val serverNonce = WifiCrypto.randomHex(16)
            writer.write(JSONObject().put("ok", true).put("nonce", serverNonce).put("macID", "mock-mac").toString() + "\n")
            writer.flush()

            // Pair
            val pairLine = reader.readLine()
            val pair = JSONObject(pairLine)
            val phonePub = pair.getString("pub")
            val reqId = "req-1"
            writer.write(JSONObject().put("ok", true).put("macPub", macServerKeys.publicBase64).put("requestID", reqId).toString() + "\n")
            writer.flush()

            val macPairingKey = WifiCrypto.pairingKey(
                privateKey = macServerKeys.keyPair.private,
                peerPublicBase64 = phonePub,
                macID = "mock-mac",
                phoneID = phoneId,
                clientNonce = clientNonce,
                serverNonce = serverNonce,
                phonePublicBase64 = phonePub,
                macPublicBase64 = macServerKeys.publicBase64
            )!!

            // PairStatus poll
            val pollLine = reader.readLine()
            val poll = JSONObject(pollLine)
            assertEquals("pairStatus", poll.getString("cmd"))
            val proof = WifiCrypto.pairApprovedProof(macPairingKey, reqId, "mock-mac", phoneId)
            writer.write(JSONObject().put("ok", true).put("status", "approved").put("proof", proof).toString() + "\n")
            writer.flush()
            client.close()
            server.close()
            pairDone.countDown()
        }

        connector.start()
        connector.startPairing("mock-mac")

        assertTrue(pairDone.await(5, TimeUnit.SECONDS))
        Thread.sleep(500)

        val trusted = store.getMac("mock-mac")
        assertNotNull(trusted)
        assertEquals("Mock Mac", trusted?.name)
        connector.stop()
    }

    @Test
    fun autoConnectPreparesSessionForTrustedMacOverLoopback() {
        val prefs = MemoryPreferences()
        val store = WifiTrustStore(prefs)
        val key = ByteArray(32) { 0x5a.toByte() }
        store.upsert(TrustedMac("mac-trusted", "My Trusted Mac", WifiCrypto.hex(key), 1000L))

        val server = ServerSocket(0)
        val port = server.localPort

        val mockDiscovery = object : WifiEndpointDiscovery {
            override fun start(onDiscovered: (DiscoveredMac) -> Unit, onLost: (String) -> Unit) {
                onDiscovered(DiscoveredMac("mac-trusted", "My Trusted Mac", "127.0.0.1", port, isTrusted = true))
            }
            override fun stop() {}
        }

        val sessionReadyLatch = CountDownLatch(1)
        val readySessionID = AtomicReference<String>()

        val connector = WifiAutoConnector(
            context = null,
            trustStore = store,
            discovery = mockDiscovery,
            onSessionReady = { sessionID, token, host, audioPort, audio ->
                readySessionID.set(sessionID)
                sessionReadyLatch.countDown()
            },
            mainDispatcher = { it() }
        )

        thread(isDaemon = true) {
            val client = server.accept()
            val reader = BufferedReader(InputStreamReader(client.getInputStream(), Charsets.UTF_8))
            val writer = OutputStreamWriter(client.getOutputStream(), Charsets.UTF_8)

            // Hello
            val hello = JSONObject(reader.readLine())
            val clientNonce = hello.getString("nonce")
            val phoneId = hello.getString("phoneID")
            val serverNonce = WifiCrypto.randomHex(16)
            writer.write(JSONObject().put("ok", true).put("nonce", serverNonce).put("macID", "mac-trusted").toString() + "\n")
            writer.flush()

            // Auth
            val auth = JSONObject(reader.readLine())
            val proof = auth.getString("proof")
            val expectedClientProof = WifiCrypto.authProof(key, false, "mac-trusted", phoneId, clientNonce, serverNonce)
            assertEquals(expectedClientProof, proof)
            val serverProof = WifiCrypto.authProof(key, true, "mac-trusted", phoneId, clientNonce, serverNonce)
            writer.write(JSONObject().put("ok", true).put("proof", serverProof).toString() + "\n")
            writer.flush()

            // Prepare
            val prepare = JSONObject(reader.readLine())
            assertEquals("prepare", prepare.getString("cmd"))
            assertEquals(1, prepare.getInt("seq"))
            val sampleRate = prepare.getInt("sampleRate")
            val channels = prepare.getInt("channels")
            val format = prepare.getString("format")
            val source = prepare.getString("source")
            val userInit = prepare.getBoolean("userInitiated")
            val reqFields = "$sampleRate|$channels|$format|$source|${if (userInit) 1 else 0}"
            val expectedPrepareMac = WifiCrypto.messageMAC(key, "c", clientNonce, serverNonce, 1, "prepare", reqFields)
            assertEquals(expectedPrepareMac, prepare.getString("mac"))

            // Send prepared with valid MAC
            val sessionID = "session-auto-1"
            val audioPort = 48124
            val prepMacFields = "$sessionID|$audioPort|$sampleRate|$channels|$format|$source"
            val prepMac = WifiCrypto.messageMAC(key, "s", clientNonce, serverNonce, 1, "prepared", prepMacFields)
            val prepResp = JSONObject()
                .put("ok", true)
                .put("cmd", "prepared")
                .put("seq", 1)
                .put("ack", 1)
                .put("session", sessionID)
                .put("audioPort", audioPort)
                .put("sampleRate", sampleRate)
                .put("channels", channels)
                .put("format", format)
                .put("source", source)
                .put("mac", prepMac)
            writer.write(prepResp.toString() + "\n")
            writer.flush()
        }

        connector.start()
        assertTrue(sessionReadyLatch.await(5, TimeUnit.SECONDS))
        assertEquals("session-auto-1", readySessionID.get())

        connector.stop()
        server.close()
    }

    @Test
    fun autoConnectRejectsPreparedPacketWithInvalidMac() {
        val prefs = MemoryPreferences()
        val store = WifiTrustStore(prefs)
        val key = ByteArray(32) { 0x5a.toByte() }
        store.upsert(TrustedMac("mac-trusted", "My Trusted Mac", WifiCrypto.hex(key), 1000L))

        val server = ServerSocket(0)
        val port = server.localPort

        val mockDiscovery = object : WifiEndpointDiscovery {
            override fun start(onDiscovered: (DiscoveredMac) -> Unit, onLost: (String) -> Unit) {
                onDiscovered(DiscoveredMac("mac-trusted", "My Trusted Mac", "127.0.0.1", port, isTrusted = true))
            }
            override fun stop() {}
        }

        val sessionReadyLatch = CountDownLatch(1)
        val connector = WifiAutoConnector(
            context = null,
            trustStore = store,
            discovery = mockDiscovery,
            onSessionReady = { _, _, _, _, _ -> sessionReadyLatch.countDown() },
            mainDispatcher = { it() }
        )
        connector.heartbeatIntervalMs = 100L

        thread(isDaemon = true) {
            val client = server.accept()
            val reader = BufferedReader(InputStreamReader(client.getInputStream(), Charsets.UTF_8))
            val writer = OutputStreamWriter(client.getOutputStream(), Charsets.UTF_8)

            // Hello
            val hello = JSONObject(reader.readLine())
            val clientNonce = hello.getString("nonce")
            val phoneId = hello.getString("phoneID")
            val serverNonce = WifiCrypto.randomHex(16)
            writer.write(JSONObject().put("ok", true).put("nonce", serverNonce).put("macID", "mac-trusted").toString() + "\n")
            writer.flush()

            // Auth
            reader.readLine()
            val serverProof = WifiCrypto.authProof(key, true, "mac-trusted", phoneId, clientNonce, serverNonce)
            writer.write(JSONObject().put("ok", true).put("proof", serverProof).toString() + "\n")
            writer.flush()

            // Prepare
            val prepare = JSONObject(reader.readLine())
            val sampleRate = prepare.getInt("sampleRate")
            val channels = prepare.getInt("channels")
            val format = prepare.getString("format")
            val source = prepare.getString("source")

            // Send prepared with TAMPERED MAC
            val prepResp = JSONObject()
                .put("ok", true)
                .put("cmd", "prepared")
                .put("seq", 1)
                .put("ack", 1)
                .put("session", "session-auto-1")
                .put("audioPort", 48124)
                .put("sampleRate", sampleRate)
                .put("channels", channels)
                .put("format", format)
                .put("source", source)
                .put("mac", "tampered_mac_value_here")
            writer.write(prepResp.toString() + "\n")
            writer.flush()
        }

        connector.start()
        assertFalse("Session should NOT be ready when MAC is invalid", sessionReadyLatch.await(1500, TimeUnit.MILLISECONDS))

        connector.stop()
        server.close()
    }

    @Test
    fun autoConnectRejectsPreparedPacketWithWrongSequenceOrAck() {
        val prefs = MemoryPreferences()
        val store = WifiTrustStore(prefs)
        val key = ByteArray(32) { 0x5a.toByte() }
        store.upsert(TrustedMac("mac-trusted", "My Trusted Mac", WifiCrypto.hex(key), 1000L))

        val server = ServerSocket(0)
        val port = server.localPort

        val mockDiscovery = object : WifiEndpointDiscovery {
            override fun start(onDiscovered: (DiscoveredMac) -> Unit, onLost: (String) -> Unit) {
                onDiscovered(DiscoveredMac("mac-trusted", "My Trusted Mac", "127.0.0.1", port, isTrusted = true))
            }
            override fun stop() {}
        }

        val sessionReadyLatch = CountDownLatch(1)
        val connector = WifiAutoConnector(
            context = null,
            trustStore = store,
            discovery = mockDiscovery,
            onSessionReady = { _, _, _, _, _ -> sessionReadyLatch.countDown() },
            mainDispatcher = { it() }
        )
        connector.heartbeatIntervalMs = 100L

        thread(isDaemon = true) {
            val client = server.accept()
            val reader = BufferedReader(InputStreamReader(client.getInputStream(), Charsets.UTF_8))
            val writer = OutputStreamWriter(client.getOutputStream(), Charsets.UTF_8)

            val hello = JSONObject(reader.readLine())
            val clientNonce = hello.getString("nonce")
            val phoneId = hello.getString("phoneID")
            val serverNonce = WifiCrypto.randomHex(16)
            writer.write(JSONObject().put("ok", true).put("nonce", serverNonce).put("macID", "mac-trusted").toString() + "\n")
            writer.flush()

            reader.readLine()
            val serverProof = WifiCrypto.authProof(key, true, "mac-trusted", phoneId, clientNonce, serverNonce)
            writer.write(JSONObject().put("ok", true).put("proof", serverProof).toString() + "\n")
            writer.flush()

            val prepare = JSONObject(reader.readLine())
            val sampleRate = prepare.getInt("sampleRate")
            val channels = prepare.getInt("channels")
            val format = prepare.getString("format")
            val source = prepare.getString("source")

            // Send prepared with wrong ack (e.g. ack=999 instead of 1)
            val sessionID = "session-auto-1"
            val audioPort = 48124
            val prepMacFields = "$sessionID|$audioPort|$sampleRate|$channels|$format|$source"
            val prepMac = WifiCrypto.messageMAC(key, "s", clientNonce, serverNonce, 1, "prepared", prepMacFields)
            val prepResp = JSONObject()
                .put("ok", true)
                .put("cmd", "prepared")
                .put("seq", 1)
                .put("ack", 999) // Wrong ACK!
                .put("session", sessionID)
                .put("audioPort", audioPort)
                .put("sampleRate", sampleRate)
                .put("channels", channels)
                .put("format", format)
                .put("source", source)
                .put("mac", prepMac)
            writer.write(prepResp.toString() + "\n")
            writer.flush()
        }

        connector.start()
        assertFalse("Session should NOT be ready when ack is wrong", sessionReadyLatch.await(1500, TimeUnit.MILLISECONDS))

        connector.stop()
        server.close()
    }

    @Test
    fun autoConnectRejectsServerErrorWithTamperedMac() {
        val prefs = MemoryPreferences()
        val store = WifiTrustStore(prefs)
        val key = ByteArray(32) { 0x5a.toByte() }
        store.upsert(TrustedMac("mac-trusted", "My Trusted Mac", WifiCrypto.hex(key), 1000L))

        val server = ServerSocket(0)
        val port = server.localPort

        val mockDiscovery = object : WifiEndpointDiscovery {
            override fun start(onDiscovered: (DiscoveredMac) -> Unit, onLost: (String) -> Unit) {
                onDiscovered(DiscoveredMac("mac-trusted", "My Trusted Mac", "127.0.0.1", port, isTrusted = true))
            }
            override fun stop() {}
        }

        val sessionReadyLatch = CountDownLatch(1)
        val connector = WifiAutoConnector(
            context = null,
            trustStore = store,
            discovery = mockDiscovery,
            onSessionReady = { _, _, _, _, _ -> sessionReadyLatch.countDown() },
            mainDispatcher = { it() }
        )
        connector.heartbeatIntervalMs = 100L

        thread(isDaemon = true) {
            val client = server.accept()
            val reader = BufferedReader(InputStreamReader(client.getInputStream(), Charsets.UTF_8))
            val writer = OutputStreamWriter(client.getOutputStream(), Charsets.UTF_8)

            val hello = JSONObject(reader.readLine())
            val clientNonce = hello.getString("nonce")
            val phoneId = hello.getString("phoneID")
            val serverNonce = WifiCrypto.randomHex(16)
            writer.write(JSONObject().put("ok", true).put("nonce", serverNonce).put("macID", "mac-trusted").toString() + "\n")
            writer.flush()

            reader.readLine()
            val serverProof = WifiCrypto.authProof(key, true, "mac-trusted", phoneId, clientNonce, serverNonce)
            writer.write(JSONObject().put("ok", true).put("proof", serverProof).toString() + "\n")
            writer.flush()

            reader.readLine() // prepare

            // Error response with fake/tampered MAC
            val errResp = JSONObject()
                .put("ok", false)
                .put("seq", 1)
                .put("code", "DENIED")
                .put("mac", "tampered_mac")
            writer.write(errResp.toString() + "\n")
            writer.flush()
        }

        connector.start()
        assertFalse(sessionReadyLatch.await(1500, TimeUnit.MILLISECONDS))

        connector.stop()
        server.close()
    }

    @Test
    fun heartbeatLoopMaintainsControlConnectionAndTransitionsToStreamingOnStateAck() {
        val prefs = MemoryPreferences()
        val store = WifiTrustStore(prefs)
        val key = ByteArray(32) { 0x5a.toByte() }
        store.upsert(TrustedMac("mac-trusted", "My Trusted Mac", WifiCrypto.hex(key), 1000L))

        val server = ServerSocket(0)
        val port = server.localPort

        val mockDiscovery = object : WifiEndpointDiscovery {
            override fun start(onDiscovered: (DiscoveredMac) -> Unit, onLost: (String) -> Unit) {
                onDiscovered(DiscoveredMac("mac-trusted", "My Trusted Mac", "127.0.0.1", port, isTrusted = true))
            }
            override fun stop() {}
        }

        val sessionReadyLatch = CountDownLatch(1)
        val heartbeatReceived = CountDownLatch(1)

        val connector = WifiAutoConnector(
            context = null,
            trustStore = store,
            discovery = mockDiscovery,
            onSessionReady = { _, _, _, _, _ -> sessionReadyLatch.countDown() },
            mainDispatcher = { it() }
        )
        connector.heartbeatIntervalMs = 100L

        thread(isDaemon = true) {
            val client = server.accept()
            val reader = BufferedReader(InputStreamReader(client.getInputStream(), Charsets.UTF_8))
            val writer = OutputStreamWriter(client.getOutputStream(), Charsets.UTF_8)

            // Hello
            val hello = JSONObject(reader.readLine())
            val clientNonce = hello.getString("nonce")
            val phoneId = hello.getString("phoneID")
            val serverNonce = WifiCrypto.randomHex(16)
            writer.write(JSONObject().put("ok", true).put("nonce", serverNonce).put("macID", "mac-trusted").toString() + "\n")
            writer.flush()

            // Auth
            reader.readLine()
            val serverProof = WifiCrypto.authProof(key, true, "mac-trusted", phoneId, clientNonce, serverNonce)
            writer.write(JSONObject().put("ok", true).put("proof", serverProof).toString() + "\n")
            writer.flush()

            // Prepare
            val prepare = JSONObject(reader.readLine())
            val sampleRate = prepare.getInt("sampleRate")
            val channels = prepare.getInt("channels")
            val format = prepare.getString("format")
            val source = prepare.getString("source")

            val sessionID = "session-heartbeat-1"
            val audioPort = 48124
            val prepMacFields = "$sessionID|$audioPort|$sampleRate|$channels|$format|$source"
            val prepMac = WifiCrypto.messageMAC(key, "s", clientNonce, serverNonce, 1, "prepared", prepMacFields)
            val prepResp = JSONObject()
                .put("ok", true)
                .put("cmd", "prepared")
                .put("seq", 1)
                .put("ack", 1)
                .put("session", sessionID)
                .put("audioPort", audioPort)
                .put("sampleRate", sampleRate)
                .put("channels", channels)
                .put("format", format)
                .put("source", source)
                .put("mac", prepMac)
            writer.write(prepResp.toString() + "\n")
            writer.flush()

            // Now client enters keepalive / status loop. Wait for heartbeat status message
            val statusMsgLine = reader.readLine()
            if (statusMsgLine != null) {
                val statusMsg = JSONObject(statusMsgLine)
                if (statusMsg.optString("cmd") == "status") {
                    val statusSeq = statusMsg.getInt("seq")
                    val expectedStatusMac = WifiCrypto.messageMAC(key, "c", clientNonce, serverNonce, statusSeq, "status", "")
                    if (statusMsg.getString("mac") == expectedStatusMac) {
                        heartbeatReceived.countDown()

                        // Reply with state: streaming
                        val stateFields = "$sessionID|streaming"
                        val stateMac = WifiCrypto.messageMAC(key, "s", clientNonce, serverNonce, 2, "state", stateFields)
                        val stateResp = JSONObject()
                            .put("cmd", "state")
                            .put("seq", 2)
                            .put("session", sessionID)
                            .put("state", "streaming")
                            .put("mac", stateMac)
                        writer.write(stateResp.toString() + "\n")
                        writer.flush()
                    }
                }
            }
        }

        connector.start()
        assertTrue(sessionReadyLatch.await(5, TimeUnit.SECONDS))
        assertTrue("Client should send signed heartbeat status", heartbeatReceived.await(7, TimeUnit.SECONDS))

        // Check phase transitions to STREAMING
        var reachedStreaming = false
        for (i in 0 until 20) {
            if (Runtime.state.value.wifiAuto.phase == WifiAutoPhase.STREAMING) {
                reachedStreaming = true
                break
            }
            Thread.sleep(100)
        }
        assertTrue("Phase should transition to STREAMING upon receiving state=streaming", reachedStreaming)

        connector.stop()
        server.close()
    }

    @Test
    fun userStopSendsSignedStopAndTearsDownSession() {
        val prefs = MemoryPreferences()
        val store = WifiTrustStore(prefs)
        val key = ByteArray(32) { 0x5a.toByte() }
        store.upsert(TrustedMac("mac-trusted", "My Trusted Mac", WifiCrypto.hex(key), 1000L))

        val server = ServerSocket(0)
        val port = server.localPort

        val mockDiscovery = object : WifiEndpointDiscovery {
            override fun start(onDiscovered: (DiscoveredMac) -> Unit, onLost: (String) -> Unit) {
                onDiscovered(DiscoveredMac("mac-trusted", "My Trusted Mac", "127.0.0.1", port, isTrusted = true))
            }
            override fun stop() {}
        }

        val sessionReadyLatch = CountDownLatch(1)
        val stopReceived = CountDownLatch(1)

        val connector = WifiAutoConnector(
            context = null,
            trustStore = store,
            discovery = mockDiscovery,
            onSessionReady = { _, _, _, _, _ -> sessionReadyLatch.countDown() },
            mainDispatcher = { it() }
        )
        connector.heartbeatIntervalMs = 100L

        thread(isDaemon = true) {
            val client = server.accept()
            val reader = BufferedReader(InputStreamReader(client.getInputStream(), Charsets.UTF_8))
            val writer = OutputStreamWriter(client.getOutputStream(), Charsets.UTF_8)

            val hello = JSONObject(reader.readLine())
            val clientNonce = hello.getString("nonce")
            val phoneId = hello.getString("phoneID")
            val serverNonce = WifiCrypto.randomHex(16)
            writer.write(JSONObject().put("ok", true).put("nonce", serverNonce).put("macID", "mac-trusted").toString() + "\n")
            writer.flush()

            reader.readLine()
            val serverProof = WifiCrypto.authProof(key, true, "mac-trusted", phoneId, clientNonce, serverNonce)
            writer.write(JSONObject().put("ok", true).put("proof", serverProof).toString() + "\n")
            writer.flush()

            val prepare = JSONObject(reader.readLine())
            val sampleRate = prepare.getInt("sampleRate")
            val channels = prepare.getInt("channels")
            val format = prepare.getString("format")
            val source = prepare.getString("source")

            val sessionID = "session-stop-1"
            val audioPort = 48124
            val prepMacFields = "$sessionID|$audioPort|$sampleRate|$channels|$format|$source"
            val prepMac = WifiCrypto.messageMAC(key, "s", clientNonce, serverNonce, 1, "prepared", prepMacFields)
            val prepResp = JSONObject()
                .put("ok", true)
                .put("cmd", "prepared")
                .put("seq", 1)
                .put("ack", 1)
                .put("session", sessionID)
                .put("audioPort", audioPort)
                .put("sampleRate", sampleRate)
                .put("channels", channels)
                .put("format", format)
                .put("source", source)
                .put("mac", prepMac)
            writer.write(prepResp.toString() + "\n")
            writer.flush()

            // Wait for stop command from client
            while (true) {
                val line = reader.readLine() ?: break
                val msg = JSONObject(line)
                if (msg.optString("cmd") == "stop") {
                    val stopSeq = msg.getInt("seq")
                    val expectedStopMac = WifiCrypto.messageMAC(key, "c", clientNonce, serverNonce, stopSeq, "stop", "$sessionID|userStopped")
                    if (msg.getString("mac") == expectedStopMac) {
                        stopReceived.countDown()

                        // Acknowledge stopped
                        val stoppedMac = WifiCrypto.messageMAC(key, "s", clientNonce, serverNonce, 2, "stopped", sessionID)
                        val stoppedResp = JSONObject()
                            .put("cmd", "stopped")
                            .put("seq", 2)
                            .put("session", sessionID)
                            .put("mac", stoppedMac)
                        writer.write(stoppedResp.toString() + "\n")
                        writer.flush()
                        break
                    }
                }
            }
        }

        connector.start()
        assertTrue(sessionReadyLatch.await(5, TimeUnit.SECONDS))

        // Trigger explicit user stop
        connector.onUserStoppedExplicitly()
        assertTrue("Server should receive valid signed stop command", stopReceived.await(5, TimeUnit.SECONDS))
        assertTrue(connector.pausedByUser)

        connector.stop()
        server.close()
    }

    @Test
    fun duplicateDiscoveryDoesNotDisruptActiveControlSession() {
        val prefs = MemoryPreferences()
        val store = WifiTrustStore(prefs)
        val key = ByteArray(32) { 0x5a.toByte() }
        store.upsert(TrustedMac("mac-trusted", "My Trusted Mac", WifiCrypto.hex(key), 1000L))

        val server = ServerSocket(0)
        val port = server.localPort

        var discoveryCallback: ((DiscoveredMac) -> Unit)? = null
        val mockDiscovery = object : WifiEndpointDiscovery {
            override fun start(onDiscovered: (DiscoveredMac) -> Unit, onLost: (String) -> Unit) {
                discoveryCallback = onDiscovered
                onDiscovered(DiscoveredMac("mac-trusted", "My Trusted Mac", "127.0.0.1", port, isTrusted = true))
            }
            override fun stop() {}
        }

        val sessionReadyLatch = CountDownLatch(1)
        val sessionReadyCount = AtomicInteger(0)
        val connector = WifiAutoConnector(
            context = null,
            trustStore = store,
            discovery = mockDiscovery,
            onSessionReady = { _, _, _, _, _ ->
                sessionReadyCount.incrementAndGet()
                sessionReadyLatch.countDown()
            },
            mainDispatcher = { it() }
        )

        thread(isDaemon = true) {
            val client = server.accept()
            val reader = BufferedReader(InputStreamReader(client.getInputStream(), Charsets.UTF_8))
            val writer = OutputStreamWriter(client.getOutputStream(), Charsets.UTF_8)

            val hello = JSONObject(reader.readLine())
            val clientNonce = hello.getString("nonce")
            val phoneId = hello.getString("phoneID")
            val serverNonce = WifiCrypto.randomHex(16)
            writer.write(JSONObject().put("ok", true).put("nonce", serverNonce).put("macID", "mac-trusted").toString() + "\n")
            writer.flush()

            reader.readLine()
            val serverProof = WifiCrypto.authProof(key, true, "mac-trusted", phoneId, clientNonce, serverNonce)
            writer.write(JSONObject().put("ok", true).put("proof", serverProof).toString() + "\n")
            writer.flush()

            val prepare = JSONObject(reader.readLine())
            val sampleRate = prepare.getInt("sampleRate")
            val channels = prepare.getInt("channels")
            val format = prepare.getString("format")
            val source = prepare.getString("source")

            val sessionID = "session-duplicate-1"
            val audioPort = 48124
            val prepMacFields = "$sessionID|$audioPort|$sampleRate|$channels|$format|$source"
            val prepMac = WifiCrypto.messageMAC(key, "s", clientNonce, serverNonce, 1, "prepared", prepMacFields)
            val prepResp = JSONObject()
                .put("ok", true)
                .put("cmd", "prepared")
                .put("seq", 1)
                .put("ack", 1)
                .put("session", sessionID)
                .put("audioPort", audioPort)
                .put("sampleRate", sampleRate)
                .put("channels", channels)
                .put("format", format)
                .put("source", source)
                .put("mac", prepMac)
            writer.write(prepResp.toString() + "\n")
            writer.flush()
        }

        connector.start()
        assertTrue(sessionReadyLatch.await(5, TimeUnit.SECONDS))
        assertEquals(1, sessionReadyCount.get())

        // Fire duplicate discovery events
        discoveryCallback?.invoke(DiscoveredMac("mac-trusted", "My Trusted Mac", "127.0.0.1", port, isTrusted = true))
        discoveryCallback?.invoke(DiscoveredMac("mac-other", "Other Mac", "127.0.0.1", 55555, isTrusted = true))
        Thread.sleep(500)

        // Count should remain 1 because active session is protected by single ownership and generation
        assertEquals(1, sessionReadyCount.get())

        connector.stop()
        server.close()
    }

    @Test
    fun uiStopPausesDiscoveryWhilePreservingActiveSession() {
        val prefs = MemoryPreferences()
        val store = WifiTrustStore(prefs)
        val discoveryStopped = AtomicBoolean(false)
        val discoveryStarted = AtomicBoolean(false)

        val mockDiscovery = object : WifiEndpointDiscovery {
            override fun start(onDiscovered: (DiscoveredMac) -> Unit, onLost: (String) -> Unit) {
                discoveryStarted.set(true)
            }
            override fun stop() {
                discoveryStopped.set(true)
            }
        }

        val connector = WifiAutoConnector(
            context = null,
            trustStore = store,
            discovery = mockDiscovery,
            onSessionReady = { _, _, _, _, _ -> },
            mainDispatcher = { it() }
        )
        connector.start()
        assertTrue(discoveryStarted.get())

        // onUiStop pauses NSD discovery so background battery isn't drained
        connector.onUiStop()
        assertTrue(discoveryStopped.get())

        // onUiStart resumes discovery
        discoveryStarted.set(false)
        connector.onUiStart()
        assertTrue(discoveryStarted.get())

        connector.stop()
    }

    @Test
    fun userStopPausesAutoConnectUntilExplicitStart() {
        val prefs = MemoryPreferences()
        val store = WifiTrustStore(prefs)
        val mockDiscovery = object : WifiEndpointDiscovery {
            override fun start(onDiscovered: (DiscoveredMac) -> Unit, onLost: (String) -> Unit) {}
            override fun stop() {}
        }
        val connector = WifiAutoConnector(
            context = null,
            trustStore = store,
            discovery = mockDiscovery,
            onSessionReady = { _, _, _, _, _ -> },
            mainDispatcher = { it() }
        )
        connector.start()
        assertFalse(connector.pausedByUser)

        connector.onUserStoppedExplicitly()
        assertTrue(connector.pausedByUser)

        connector.onUserStartedExplicitly()
        assertFalse(connector.pausedByUser)

        connector.stop()
    }
}
