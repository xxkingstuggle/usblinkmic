package com.zjx.usblinkmic.support

import com.zjx.usblinkmic.contracts.*
import com.zjx.usblinkmic.platform.WifiAutoConnector
import com.zjx.usblinkmic.platform.WifiEndpointDiscovery
import com.zjx.usblinkmic.platform.NsdHostSelector
import com.zjx.usblinkmic.platform.Runtime
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
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

        val server = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
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

        val server = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
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

        val server = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
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

        val server = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
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

        val server = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
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

        val server = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
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
                            .put("ack", statusSeq)
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

        val server = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
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

        val server = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
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

    @Test
    fun blackholeSilentServerTriggersResponseTimeoutAndReconnect() {
        val prefs = MemoryPreferences()
        val store = WifiTrustStore(prefs)
        val key = ByteArray(32) { 0x5a.toByte() }
        store.upsert(TrustedMac("mac-trusted", "My Trusted Mac", WifiCrypto.hex(key), 1000L))

        val server = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
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
        // Short heartbeat and fast response timeout budget for testing
        connector.heartbeatIntervalMs = 50L
        connector.responseTimeoutBudgetMs = 300L

        val heartbeatsRead = AtomicInteger(0)
        val serverDone = CountDownLatch(1)

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

            val sessionID = "session-blackhole-1"
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

            // Server acts as a black hole: reads incoming heartbeats but NEVER replies!
            while (true) {
                val line = reader.readLine() ?: break
                heartbeatsRead.incrementAndGet()
            }
            serverDone.countDown()
        }

        connector.start()
        assertTrue(sessionReadyLatch.await(5, TimeUnit.SECONDS))

        // Without timeout budget handling, client will hang forever.
        // With timeout budget, client will detect lack of response, close socket, and exit!
        assertTrue("Client must close connection when Mac reads heartbeats but never responds", serverDone.await(2, TimeUnit.SECONDS))
        assertTrue("Server should have read at least 1 heartbeat before timeout", heartbeatsRead.get() >= 1)

        connector.stop()
        server.close()
    }

    @Test
    fun wrongAckOrWrongSessionInStateResponseDoesNotRefreshLiveness() {
        val prefs = MemoryPreferences()
        val store = WifiTrustStore(prefs)
        val key = ByteArray(32) { 0x5a.toByte() }
        store.upsert(TrustedMac("mac-trusted", "My Trusted Mac", WifiCrypto.hex(key), 1000L))

        val server = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
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
        connector.heartbeatIntervalMs = 50L
        connector.responseTimeoutBudgetMs = 300L

        val serverDone = CountDownLatch(1)

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

            val sessionID = "session-wrong-ack-1"
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

            // When status arrives, send a state response with WRONG ACK (ack=9999 instead of client seq)
            val line = reader.readLine()
            if (line != null) {
                val stateFields = "$sessionID|streaming"
                val stateMac = WifiCrypto.messageMAC(key, "s", clientNonce, serverNonce, 2, "state", stateFields)
                val badState = JSONObject()
                    .put("cmd", "state")
                    .put("seq", 2)
                    .put("ack", 9999) // Wrong ACK!
                    .put("session", sessionID)
                    .put("state", "streaming")
                    .put("mac", stateMac)
                writer.write(badState.toString() + "\n")
                writer.flush()
            }

            // Client should reject bad ack, NOT refresh deadline, and close connection
            while (reader.readLine() != null) {}
            serverDone.countDown()
        }

        connector.start()
        assertTrue(sessionReadyLatch.await(5, TimeUnit.SECONDS))
        assertTrue("Client must reject bad ack state response and time out", serverDone.await(2, TimeUnit.SECONDS))

        connector.stop()
        server.close()
    }

    @Test
    fun continuousLegalHeartbeatsMaintainSessionOverWindow() {
        val prefs = MemoryPreferences()
        val store = WifiTrustStore(prefs)
        val key = ByteArray(32) { 0x5a.toByte() }
        store.upsert(TrustedMac("mac-trusted", "My Trusted Mac", WifiCrypto.hex(key), 1000L))

        val server = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
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
        // Heartbeat every 40ms, timeout budget 150ms -> 5 heartbeats cover 200ms (> 1 budget window)
        connector.heartbeatIntervalMs = 40L
        connector.responseTimeoutBudgetMs = 150L

        val heartbeatsAnswered = AtomicInteger(0)
        val roundTarget = 5
        val testFinished = CountDownLatch(1)

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

            val sessionID = "session-continuous-1"
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

            var serverSeq = 2
            for (i in 1..roundTarget) {
                val line = reader.readLine() ?: break
                val msg = JSONObject(line)
                if (msg.optString("cmd") == "status") {
                    val clientSeq = msg.getInt("seq")
                    val stateFields = "$sessionID|streaming"
                    val stateMac = WifiCrypto.messageMAC(key, "s", clientNonce, serverNonce, serverSeq, "state", stateFields)
                    val stateResp = JSONObject()
                        .put("cmd", "state")
                        .put("seq", serverSeq)
                        .put("ack", clientSeq)
                        .put("session", sessionID)
                        .put("state", "streaming")
                        .put("mac", stateMac)
                    writer.write(stateResp.toString() + "\n")
                    writer.flush()
                    serverSeq++
                    heartbeatsAnswered.incrementAndGet()
                }
            }
            testFinished.countDown()
        }

        connector.start()
        assertTrue(sessionReadyLatch.await(5, TimeUnit.SECONDS))
        assertTrue("Server should answer multiple rounds of heartbeats across budget window", testFinished.await(3, TimeUnit.SECONDS))
        assertEquals(roundTarget, heartbeatsAnswered.get())
        assertTrue("Session should remain alive and streaming across valid heartbeats", connector.isSessionAlive)

        connector.stop()
        server.close()
    }

    @Test
    fun oldSessionCleanupFinallyDoesNotCloseNewActiveSession() {
        val prefs = MemoryPreferences()
        val store = WifiTrustStore(prefs)
        val key = ByteArray(32) { 0x5a.toByte() }
        store.upsert(TrustedMac("mac-trusted", "My Trusted Mac", WifiCrypto.hex(key), 1000L))

        val server1 = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
        val port1 = server1.localPort

        val server2 = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
        val port2 = server2.localPort

        var discoveryCallback: ((DiscoveredMac) -> Unit)? = null
        val mockDiscovery = object : WifiEndpointDiscovery {
            override fun start(onDiscovered: (DiscoveredMac) -> Unit, onLost: (String) -> Unit) {
                discoveryCallback = onDiscovered
                onDiscovered(DiscoveredMac("mac-trusted", "My Trusted Mac", "127.0.0.1", port1, isTrusted = true))
            }
            override fun stop() {}
        }

        val session1Ready = CountDownLatch(1)
        val session2Ready = CountDownLatch(1)

        val connector = WifiAutoConnector(
            context = null,
            trustStore = store,
            discovery = mockDiscovery,
            onSessionReady = { sessionID, _, _, _, _ ->
                if (sessionID == "session-1") session1Ready.countDown()
                if (sessionID == "session-2") session2Ready.countDown()
            },
            mainDispatcher = { it() }
        )
        connector.heartbeatIntervalMs = 50L
        connector.responseTimeoutBudgetMs = 200L

        val session1ClientSocket = AtomicReference<Socket>()
        val session2ClientSocket = AtomicReference<Socket>()

        // Server 1
        thread(isDaemon = true) {
            val client = server1.accept()
            session1ClientSocket.set(client)
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

            val prepMacFields = "session-1|48124|$sampleRate|$channels|$format|$source"
            val prepMac = WifiCrypto.messageMAC(key, "s", clientNonce, serverNonce, 1, "prepared", prepMacFields)
            val prepResp = JSONObject()
                .put("ok", true)
                .put("cmd", "prepared")
                .put("seq", 1)
                .put("ack", 1)
                .put("session", "session-1")
                .put("audioPort", 48124)
                .put("sampleRate", sampleRate)
                .put("channels", channels)
                .put("format", format)
                .put("source", source)
                .put("mac", prepMac)
            writer.write(prepResp.toString() + "\n")
            writer.flush()

            // Keep Server 1 open until Server 2 starts
            reader.readLine()
        }

        // Server 2
        thread(isDaemon = true) {
            val client = server2.accept()
            session2ClientSocket.set(client)
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

            val prepMacFields = "session-2|48124|$sampleRate|$channels|$format|$source"
            val prepMac = WifiCrypto.messageMAC(key, "s", clientNonce, serverNonce, 1, "prepared", prepMacFields)
            val prepResp = JSONObject()
                .put("ok", true)
                .put("cmd", "prepared")
                .put("seq", 1)
                .put("ack", 1)
                .put("session", "session-2")
                .put("audioPort", 48124)
                .put("sampleRate", sampleRate)
                .put("channels", channels)
                .put("format", format)
                .put("source", source)
                .put("mac", prepMac)
            writer.write(prepResp.toString() + "\n")
            writer.flush()

            // Keep answering heartbeats for Session 2
            var serverSeq = 2
            while (true) {
                val line = reader.readLine() ?: break
                val msg = JSONObject(line)
                if (msg.optString("cmd") == "status") {
                    val clientSeq = msg.getInt("seq")
                    val stateFields = "session-2|streaming"
                    val stateMac = WifiCrypto.messageMAC(key, "s", clientNonce, serverNonce, serverSeq, "state", stateFields)
                    val stateResp = JSONObject()
                        .put("cmd", "state")
                        .put("seq", serverSeq)
                        .put("ack", clientSeq)
                        .put("session", "session-2")
                        .put("state", "streaming")
                        .put("mac", stateMac)
                    writer.write(stateResp.toString() + "\n")
                    writer.flush()
                    serverSeq++
                }
            }
        }

        connector.start()
        assertTrue(session1Ready.await(5, TimeUnit.SECONDS))
        assertEquals("session-1", connector.activeSessionID)

        // Now initiate connection to Server 2
        discoveryCallback?.invoke(DiscoveredMac("mac-trusted", "My Trusted Mac", "127.0.0.1", port2, isTrusted = true))
        connector.onUserStartedExplicitly()

        assertTrue(session2Ready.await(5, TimeUnit.SECONDS))
        assertEquals("session-2", connector.activeSessionID)

        // Session 1 will now exit its loop / finally.
        // Assert: Session 1's exit must NOT destroy or disconnect Session 2!
        Thread.sleep(500)
        assertEquals("session-2", connector.activeSessionID)
        assertTrue("Session 2 must remain alive after Session 1's cleanup", connector.isSessionAlive)

        connector.stop()
        server1.close()
        server2.close()
    }

    @Test
    fun duplicateDiscoveryDuringPendingPrepareSpawnsOnlyOneConnection() {
        val prefs = MemoryPreferences()
        val store = WifiTrustStore(prefs)
        val key = ByteArray(32) { 0x5a.toByte() }
        store.upsert(TrustedMac("mac-trusted", "My Trusted Mac", WifiCrypto.hex(key), 1000L))

        val server = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
        val port = server.localPort

        var discoveryCallback: ((DiscoveredMac) -> Unit)? = null
        val mockDiscovery = object : WifiEndpointDiscovery {
            override fun start(onDiscovered: (DiscoveredMac) -> Unit, onLost: (String) -> Unit) {
                discoveryCallback = onDiscovered
            }
            override fun stop() {}
        }

        val sessionReadyCount = AtomicInteger(0)
        val connector = WifiAutoConnector(
            context = null,
            trustStore = store,
            discovery = mockDiscovery,
            onSessionReady = { _, _, _, _, _ -> sessionReadyCount.incrementAndGet() },
            mainDispatcher = { it() }
        )

        val connectionCount = AtomicInteger(0)
        val prepareReceived = CountDownLatch(1)

        thread(isDaemon = true) {
            val client = server.accept()
            connectionCount.incrementAndGet()
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

            // Delay prepare response slightly so duplicate discovery can fire while prepare is pending
            prepareReceived.countDown()
            Thread.sleep(300)

            val sessionID = "session-single-1"
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
        val endpoint = DiscoveredMac("mac-trusted", "My Trusted Mac", "127.0.0.1", port, isTrusted = true)
        discoveryCallback?.invoke(endpoint)

        assertTrue(prepareReceived.await(5, TimeUnit.SECONDS))
        // Fire duplicate discovery while prepare is still pending!
        discoveryCallback?.invoke(endpoint)
        discoveryCallback?.invoke(endpoint)

        Thread.sleep(600)
        assertEquals("Exactly one TCP connection must be established", 1, connectionCount.get())
        assertEquals("onSessionReady must be invoked exactly once", 1, sessionReadyCount.get())

        connector.stop()
        server.close()
    }

    @Test
    fun nsdHostSelectorPrefersIpv4AndStripsScope() {
        val ipv4 = InetAddress.getByName("192.168.1.100")
        val selected = NsdHostSelector.selectBestIpv4(ipv4)
        assertEquals("192.168.1.100", selected)

        val rawIpv6 = ByteArray(16) { 0 }
        rawIpv6[0] = 0xfe.toByte()
        rawIpv6[1] = 0x80.toByte()
        rawIpv6[15] = 1.toByte()
        val ipv6WithScope = java.net.Inet6Address.getByAddress("fe80::1", rawIpv6, 3)
        assertTrue(ipv6WithScope.hostAddress?.contains("%") == true)

        val selectedIpv4OverIpv6 = NsdHostSelector.selectBestIpv4(ipv6WithScope, listOf(ipv6WithScope, ipv4))
        assertEquals("192.168.1.100", selectedIpv4OverIpv6)

        val strippedScope = NsdHostSelector.selectBestIpv4(ipv6WithScope, null)
        assertNotNull(strippedScope)
        assertFalse(strippedScope!!.contains("%"))
    }

    @Test
    fun queuedReadyCallbackAfterUserStopDoesNotTriggerAudio() {
        val prefs = MemoryPreferences()
        val store = WifiTrustStore(prefs)
        val key = ByteArray(32) { 0x5a.toByte() }
        store.upsert(TrustedMac("mac-trusted", "My Trusted Mac", WifiCrypto.hex(key), 1000L))

        val server = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
        val port = server.localPort

        val mockDiscovery = object : WifiEndpointDiscovery {
            override fun start(onDiscovered: (DiscoveredMac) -> Unit, onLost: (String) -> Unit) {
                onDiscovered(DiscoveredMac("mac-trusted", "My Trusted Mac", "127.0.0.1", port, isTrusted = true))
            }
            override fun stop() {}
        }

        val queuedTasks = java.util.concurrent.ConcurrentLinkedQueue<() -> Unit>()
        val sessionReadyCount = AtomicInteger(0)

        val connector = WifiAutoConnector(
            context = null,
            trustStore = store,
            discovery = mockDiscovery,
            onSessionReady = { _, _, _, _, _ -> sessionReadyCount.incrementAndGet() },
            mainDispatcher = { task -> queuedTasks.add(task) }
        )

        val prepareHandshakeDone = CountDownLatch(1)

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

            val sessionID = "session-queued-1"
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
            prepareHandshakeDone.countDown()
        }

        connector.start()
        assertTrue(prepareHandshakeDone.await(5, TimeUnit.SECONDS))

        // Wait until postOnMain enqueues the ready callback
        var attempts = 0
        while (queuedTasks.isEmpty() && attempts++ < 30) {
            Thread.sleep(50)
        }
        assertFalse("Ready callback should be queued in mainDispatcher", queuedTasks.isEmpty())

        // Now user stops explicitly BEFORE queued callback executes
        connector.onUserStoppedExplicitly()
        assertTrue(connector.pausedByUser)

        // Now drain all queued UI tasks
        while (queuedTasks.isNotEmpty()) {
            queuedTasks.poll()?.invoke()
        }

        // Verify onSessionReady was NEVER fired because pausedByUser was true
        assertEquals("Queued ready callback must not fire onSessionReady after user stop", 0, sessionReadyCount.get())

        connector.stop()
        server.close()
    }
}
