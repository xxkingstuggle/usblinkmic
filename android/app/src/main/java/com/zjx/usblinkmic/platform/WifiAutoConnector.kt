package com.zjx.usblinkmic.platform

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.zjx.usblinkmic.contracts.*
import com.zjx.usblinkmic.support.TrustedMac
import com.zjx.usblinkmic.support.WifiCrypto
import com.zjx.usblinkmic.support.WifiTrustStore
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlin.concurrent.thread

interface WifiEndpointDiscovery {
    fun start(onDiscovered: (DiscoveredMac) -> Unit, onLost: (String) -> Unit)
    fun stop()
}

class AndroidNsdDiscovery(private val context: Context) : WifiEndpointDiscovery {
    private var nsdManager: NsdManager? = null
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    private val serviceNameToMacId = ConcurrentHashMap<String, String>()

    override fun start(onDiscovered: (DiscoveredMac) -> Unit, onLost: (String) -> Unit) {
        stop()
        val manager = context.getSystemService(Context.NSD_SERVICE) as? NsdManager ?: return
        nsdManager = manager

        discoveryListener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(regType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Runtime.log("wifi", "nsdDiscoveryFailed", "startFailed errorCode=$errorCode")
                stop()
            }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                Runtime.log("wifi", "nsdDiscoveryFailed", "stopFailed errorCode=$errorCode")
                stop()
            }

            override fun onServiceFound(service: NsdServiceInfo) {
                val serviceType = service.serviceType?.trimEnd('.').orEmpty()
                val targetType = Capabilities.BONJOUR_SERVICE_TYPE.trimEnd('.')
                if (serviceType.contains("usblinkmic") || serviceType == targetType) {
                    try {
                        manager.resolveService(service, object : NsdManager.ResolveListener {
                            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                                Runtime.log("wifi", "nsdResolveFailed", "service=${serviceInfo.serviceName} errorCode=$errorCode")
                            }
                            override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                                val host = serviceInfo.host?.hostAddress ?: return
                                val port = serviceInfo.port
                                if (port <= 0 || host.isBlank()) return
                                val attributes = serviceInfo.attributes ?: emptyMap()
                                val id = attributes["id"]?.let { String(it, Charsets.UTF_8) }.orEmpty()
                                val name = attributes["name"]?.let { String(it, Charsets.UTF_8) }.orEmpty().ifBlank { serviceInfo.serviceName ?: "Mac" }
                                val sName = serviceInfo.serviceName ?: ""
                                if (id.isNotEmpty()) {
                                    if (sName.isNotEmpty()) {
                                        serviceNameToMacId[sName] = id
                                    }
                                    onDiscovered(DiscoveredMac(id = id, name = name, host = host, controlPort = port, isTrusted = false, serviceName = sName))
                                }
                            }
                        })
                    } catch (e: Exception) {
                        Runtime.log("wifi", "nsdResolveException", e.message ?: e.javaClass.simpleName)
                    }
                }
            }

            override fun onServiceLost(service: NsdServiceInfo) {
                val sName = service.serviceName ?: return
                val macId = serviceNameToMacId.remove(sName) ?: sName
                onLost(macId)
            }
        }

        try {
            manager.discoverServices(Capabilities.BONJOUR_SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discoveryListener)
        } catch (e: Exception) {
            Runtime.log("wifi", "nsdStartException", e.message ?: e.javaClass.simpleName)
        }
    }

    override fun stop() {
        val listener = discoveryListener
        discoveryListener = null
        if (listener != null) {
            try { nsdManager?.stopServiceDiscovery(listener) } catch (_: Exception) {}
        }
        serviceNameToMacId.clear()
        nsdManager = null
    }
}

class WifiAutoConnector(
    private val context: Context? = null,
    private val trustStore: WifiTrustStore,
    private val discovery: WifiEndpointDiscovery = context?.let { AndroidNsdDiscovery(it) } ?: object : WifiEndpointDiscovery {
        override fun start(onDiscovered: (DiscoveredMac) -> Unit, onLost: (String) -> Unit) {}
        override fun stop() {}
    },
    var onSessionReady: ((sessionID: String, token: String, host: String, port: Int, audio: AudioParameters) -> Unit)? = null,
    private val mainDispatcher: ((() -> Unit) -> Unit)? = null,
    private val delayedDispatcher: ((Long, () -> Unit) -> Unit)? = null,
    private val socketFactory: ((String, Int) -> Socket)? = null
) {
    private val mainHandler: Handler? = try { Handler(Looper.getMainLooper()) } catch (_: Throwable) { null }

    private fun postOnMain(action: () -> Unit) {
        when {
            mainDispatcher != null -> mainDispatcher.invoke(action)
            mainHandler != null -> mainHandler.post(action)
            else -> action()
        }
    }

    private fun postDelayedOnMain(delayMs: Long, action: () -> Unit) {
        when {
            delayedDispatcher != null -> delayedDispatcher.invoke(delayMs, action)
            mainHandler != null -> mainHandler.postDelayed(action, delayMs)
            else -> thread(isDaemon = true) {
                try { Thread.sleep(delayMs) } catch (_: InterruptedException) { return@thread }
                action()
            }
        }
    }

    private val discoveredMap = ConcurrentHashMap<String, DiscoveredMac>()
    val running = AtomicBoolean(false)
    @Volatile var isUiVisible = false
    @Volatile var pausedByUser = false

    private class ActiveSession(
        val generation: Long,
        val target: DiscoveredMac,
        val sessionID: String,
        val key: ByteArray,
        val clientNonce: String,
        val serverNonce: String,
        val socket: Socket,
        val reader: BufferedReader,
        val writer: OutputStreamWriter,
        var nextClientSeq: Int = 2,
        var expectedServerSeq: Int = 1,
        @Volatile var isStreaming: Boolean = false,
        @Volatile var closed: Boolean = false
    )

    private val sessionGeneration = AtomicLong(0)
    @Volatile private var currentSession: ActiveSession? = null
    @Volatile private var pairingThread: Thread? = null
    private val pairingGeneration = AtomicLong(0)

    private val reconnectBackoffMs = AtomicLong(1000L)
    private val maxBackoffMs = 15000L
    private val isConnecting = AtomicBoolean(false)
    var heartbeatIntervalMs: Long = 5000L

    val phoneDisplayName: String
        get() = "${Build.MANUFACTURER} ${Build.MODEL}".trim()

    val activeSessionID: String?
        get() = currentSession?.sessionID

    fun onUiStart() {
        isUiVisible = true
        running.set(true)
        refreshSnapshot()
        discovery.start(
            onDiscovered = { mac ->
                val isTrusted = trustStore.getMac(mac.id) != null
                val previous = discoveredMap[mac.id]
                discoveredMap[mac.id] = mac.copy(isTrusted = isTrusted)
                postOnMain {
                    refreshSnapshot()
                    if (previous == null || previous.host != mac.host || previous.controlPort != mac.controlPort) {
                        checkAutoConnect()
                    } else if (currentSession == null) {
                        checkAutoConnect()
                    }
                }
            },
            onLost = { key ->
                val toRemove = discoveredMap.values.filter {
                    it.id == key || it.serviceName == key || (key.startsWith("USBLinkMic-") && it.id.startsWith(key.removePrefix("USBLinkMic-")))
                }.map { it.id }
                toRemove.forEach { discoveredMap.remove(it) }
                postOnMain { refreshSnapshot() }
            }
        )
        checkAutoConnect()
    }

    fun onUiStop() {
        isUiVisible = false
        discovery.stop()
        refreshSnapshot()
    }

    fun start() {
        running.set(true)
        onUiStart()
    }

    fun stop() {
        running.set(false)
        sessionGeneration.incrementAndGet()
        discovery.stop()
        cancelPairing()
        closeCurrentSession("stoppedByUser")
        discoveredMap.clear()
        refreshSnapshot()
    }

    fun onUserStartedExplicitly() {
        pausedByUser = false
        reconnectBackoffMs.set(1000L)
        refreshSnapshot()
        checkAutoConnect(userInitiated = true)
    }

    fun onUserStoppedExplicitly() {
        pausedByUser = true
        val session = currentSession
        if (session != null) {
            thread(name = "linkmic-stop", isDaemon = true) {
                sendAuthenticatedStop(session, reason = "userStopped")
                sessionGeneration.incrementAndGet()
                closeCurrentSession("userStoppedExplicitly")
            }
        } else {
            sessionGeneration.incrementAndGet()
        }
        refreshSnapshot()
    }

    fun onMicrophoneServiceStopped(session: String?, error: String = "") {
        val active = currentSession
        if (active != null && (session == null || active.sessionID == session)) {
            thread(name = "linkmic-srv-stop", isDaemon = true) {
                sendAuthenticatedStop(active, reason = if (error.isNotBlank()) "audioError" else "phoneStop")
                closeCurrentSession("serviceStopped: $error")
                if (!pausedByUser && running.get() && error.isNotBlank()) {
                    scheduleReconnect()
                }
            }
        }
    }

    fun forgetMac(macId: String) {
        trustStore.remove(macId)
        val existing = discoveredMap[macId]
        if (existing != null) {
            discoveredMap[macId] = existing.copy(isTrusted = false)
        }
        val active = currentSession
        if (active != null && active.target.id == macId) {
            sessionGeneration.incrementAndGet()
            closeCurrentSession("macForgotten")
        }
        refreshSnapshot()
    }

    fun startPairing(macId: String) {
        val target = discoveredMap[macId] ?: return
        cancelPairing()
        val gen = pairingGeneration.incrementAndGet()
        pairingThread = thread(name = "linkmic-pair-$gen", isDaemon = true) {
            runPairing(gen, target)
        }
    }

    fun cancelPairing() {
        pairingGeneration.incrementAndGet()
        pairingThread?.interrupt()
        pairingThread = null
        Runtime.update {
            it.copy(
                wifiAuto = it.wifiAuto.copy(
                    phase = if (pausedByUser) WifiAutoPhase.PAUSED else WifiAutoPhase.SEARCHING,
                    pendingPairCode = null,
                    pendingPairMacName = null
                )
            )
        }
    }

    fun checkAutoConnect(userInitiated: Boolean = false) {
        if (!running.get()) return
        if (pausedByUser && !userInitiated) return
        if (currentSession != null && !currentSession!!.closed) return
        if (Runtime.audioRequest != null && Runtime.audioRequest?.cancelled == false) return
        val currentSettings = Runtime.state.value.settings
        if (!currentSettings.wifiAutoConnect) return

        val trustedList = trustStore.loadTrustedMacs()
        if (trustedList.isEmpty()) return

        val target = discoveredMap.values.firstOrNull { mac -> trustedList.any { it.id == mac.id } } ?: return
        val trusted = trustStore.getMac(target.id) ?: return

        // Background safety: do not start microphone if UI is backgrounded unless user explicitly initiated
        if (!isUiVisible && !userInitiated) return

        if (!userInitiated && !isConnecting.compareAndSet(false, true)) {
            return
        } else if (userInitiated) {
            isConnecting.set(true)
        }

        val myGen = sessionGeneration.incrementAndGet()
        thread(name = "linkmic-connect-$myGen", isDaemon = true) {
            try {
                connectAndPrepare(myGen, target, trusted, userInitiated)
            } finally {
                isConnecting.set(false)
            }
        }
    }

    private fun connectAndPrepare(myGen: Long, target: DiscoveredMac, trusted: TrustedMac, userInitiated: Boolean) {
        if (myGen != sessionGeneration.get() || !running.get()) return
        var socket: Socket? = null
        try {
            postOnMain {
                if (myGen == sessionGeneration.get()) {
                    Runtime.update {
                        it.copy(
                            wifiAuto = it.wifiAuto.copy(
                                phase = WifiAutoPhase.CONNECTING,
                                message = "正在连接 ${target.name}…"
                            )
                        )
                    }
                }
            }

            val key = WifiCrypto.bytes(trusted.keyHex) ?: throw IllegalStateException("CORRUPT_KEY")
            val s = socketFactory?.invoke(target.host, target.controlPort) ?: Socket()
            socket = s
            s.tcpNoDelay = true
            s.soTimeout = 8000
            if (!s.isConnected) {
                s.connect(InetSocketAddress(target.host, target.controlPort), 5000)
            }

            if (myGen != sessionGeneration.get()) {
                try { s.close() } catch (_: Exception) {}
                return
            }

            val reader = BufferedReader(InputStreamReader(s.getInputStream(), Charsets.UTF_8))
            val writer = OutputStreamWriter(s.getOutputStream(), Charsets.UTF_8)

            val clientNonce = WifiCrypto.randomHex(16)
            val helloReq = JSONObject()
                .put("cmd", "hello")
                .put("protocol", Capabilities.PROTOCOL_VERSION)
                .put("wifi", Capabilities.WIFI_REVISION)
                .put("runtimeRevision", Capabilities.RUNTIME_REVISION)
                .put("phoneID", trustStore.phoneId)
                .put("phoneName", phoneDisplayName)
                .put("nonce", clientNonce)
                .put("macID", target.id)
            synchronized(writer) {
                writer.write(helloReq.toString() + "\n")
                writer.flush()
            }

            val helloRespLine = reader.readLine() ?: throw IllegalStateException("CLOSED_EARLY")
            val helloResp = JSONObject(helloRespLine)
            if (!helloResp.optBoolean("ok")) throw IllegalStateException(helloResp.optString("error", "HELLO_REJECTED"))
            val serverNonce = helloResp.getString("nonce")
            val serverMacID = helloResp.getString("macID")
            if (serverMacID != target.id) throw IllegalStateException("MAC_ID_MISMATCH")

            // Auth
            val proof = WifiCrypto.authProof(key, fromServer = false, macID = target.id, phoneID = trustStore.phoneId, clientNonce = clientNonce, serverNonce = serverNonce)
            val authReq = JSONObject().put("cmd", "auth").put("proof", proof)
            synchronized(writer) {
                writer.write(authReq.toString() + "\n")
                writer.flush()
            }

            val authRespLine = reader.readLine() ?: throw IllegalStateException("CLOSED_EARLY")
            val authResp = JSONObject(authRespLine)
            if (!authResp.optBoolean("ok")) throw IllegalStateException(authResp.optString("error", "AUTH_FAILED"))
            val serverProof = authResp.getString("proof")
            val expectedServerProof = WifiCrypto.authProof(key, fromServer = true, macID = target.id, phoneID = trustStore.phoneId, clientNonce = clientNonce, serverNonce = serverNonce)
            if (!WifiCrypto.equal(serverProof, expectedServerProof)) throw IllegalStateException("SERVER_PROOF_INVALID")

            // Prepare session
            val audio = Runtime.state.value.settings.audio
            val formatStr = if (audio.format == PCMFormat.I16) "i16" else "f32"
            val sourceStr = when (audio.source) {
                RecordingSource.MICROPHONE -> "microphone"
                RecordingSource.UNPROCESSED -> "unprocessed"
                RecordingSource.VOICE_RECOGNITION -> "voiceRecognition"
            }
            val fields = "${audio.sampleRate}|${audio.channels}|$formatStr|$sourceStr|${if (userInitiated) 1 else 0}"
            val mac = WifiCrypto.messageMAC(key, direction = "c", clientNonce = clientNonce, serverNonce = serverNonce, sequence = 1, command = "prepare", fields = fields)

            val prepReq = JSONObject()
                .put("cmd", "prepare")
                .put("seq", 1)
                .put("sampleRate", audio.sampleRate)
                .put("channels", audio.channels)
                .put("format", formatStr)
                .put("source", sourceStr)
                .put("userInitiated", userInitiated)
                .put("mac", mac)
            synchronized(writer) {
                writer.write(prepReq.toString() + "\n")
                writer.flush()
            }

            val prepRespLine = reader.readLine() ?: throw IllegalStateException("CLOSED_EARLY")
            val prepResp = JSONObject(prepRespLine)
            val serverSeq = prepResp.optInt("seq", -1)
            val ack = prepResp.optInt("ack", -1)
            val respMac = prepResp.optString("mac", "")

            if (!prepResp.optBoolean("ok")) {
                val errCode = prepResp.optString("code", "PREPARE_REJECTED")
                val expectedErrMac = WifiCrypto.messageMAC(key, direction = "s", clientNonce = clientNonce, serverNonce = serverNonce, sequence = serverSeq, command = "error", fields = errCode)
                if (!WifiCrypto.equal(respMac, expectedErrMac)) throw IllegalStateException("INVALID_ERROR_MAC")
                if (errCode == "PAUSED_BY_USER") {
                    pausedByUser = true
                }
                throw IllegalStateException(errCode)
            }

            if (serverSeq != 1 || ack != 1) throw IllegalStateException("INVALID_SEQUENCE_OR_ACK")
            val sessionID = prepResp.getString("session")
            val audioPort = prepResp.getInt("audioPort")
            val prepRate = prepResp.getInt("sampleRate")
            val prepChannels = prepResp.getInt("channels")
            val prepFormat = prepResp.getString("format")
            val prepSource = prepResp.getString("source")

            if (audioPort !in 1..65535 || sessionID.isBlank()) throw IllegalStateException("MALFORMED_PREPARE_RESPONSE")
            val prepMacFields = "$sessionID|$audioPort|$prepRate|$prepChannels|$prepFormat|$prepSource"
            val expectedPrepMac = WifiCrypto.messageMAC(key, direction = "s", clientNonce = clientNonce, serverNonce = serverNonce, sequence = 1, command = "prepared", fields = prepMacFields)
            if (!WifiCrypto.equal(respMac, expectedPrepMac)) throw IllegalStateException("INVALID_PREPARED_MAC")

            val audioToken = WifiCrypto.audioToken(key, sessionID, clientNonce, serverNonce)

            if (myGen != sessionGeneration.get() || !running.get() || pausedByUser) {
                try { s.close() } catch (_: Exception) {}
                return
            }

            val active = ActiveSession(
                generation = myGen,
                target = target,
                sessionID = sessionID,
                key = key,
                clientNonce = clientNonce,
                serverNonce = serverNonce,
                socket = s,
                reader = reader,
                writer = writer,
                nextClientSeq = 2,
                expectedServerSeq = 2,
                isStreaming = false
            )
            currentSession = active
            reconnectBackoffMs.set(1000L)

            postOnMain {
                if (myGen == sessionGeneration.get() && running.get() && !pausedByUser) {
                    Runtime.update {
                        it.copy(
                            wifiAuto = it.wifiAuto.copy(
                                phase = WifiAutoPhase.PREPARING,
                                message = "已连接 ${target.name}，正在准备音频…",
                                connectedMacName = target.name
                            )
                        )
                    }
                    onSessionReady?.invoke(sessionID, audioToken, target.host, audioPort, audio)
                }
            }

            // Run session loop (heartbeat and event listener)
            runSessionLoop(active)

        } catch (e: Exception) {
            Runtime.log("wifi", "autoConnectFailed", e.message ?: e.javaClass.simpleName)
            if (socket != null && currentSession?.socket !== socket) {
                try { socket.close() } catch (_: Exception) {}
            }
            if (myGen == sessionGeneration.get()) {
                closeCurrentSession("connectFailed: ${e.message}")
                postOnMain {
                    refreshSnapshot()
                    if (!pausedByUser && running.get()) {
                        scheduleReconnect()
                    }
                }
            }
        }
    }

    private fun runSessionLoop(session: ActiveSession) {
        // Start keepalive heartbeat sender
        val heartbeatThread = thread(name = "linkmic-heartbeat-${session.generation}", isDaemon = true) {
            while (!session.closed && session.generation == sessionGeneration.get()) {
                try {
                    Thread.sleep(heartbeatIntervalMs)
                } catch (_: InterruptedException) {
                    break
                }
                if (session.closed || session.generation != sessionGeneration.get()) break
                try {
                    synchronized(session.writer) {
                        val seq = session.nextClientSeq++
                        val mac = WifiCrypto.messageMAC(session.key, direction = "c", clientNonce = session.clientNonce, serverNonce = session.serverNonce, sequence = seq, command = "status", fields = "")
                        val req = JSONObject().put("cmd", "status").put("seq", seq).put("mac", mac)
                        session.writer.write(req.toString() + "\n")
                        session.writer.flush()
                    }
                } catch (e: Exception) {
                    Runtime.log("wifi", "heartbeatFailed", e.message ?: e.javaClass.simpleName)
                    closeCurrentSession("heartbeatFailed")
                    break
                }
            }
        }

        try {
            while (!session.closed && session.generation == sessionGeneration.get()) {
                val line: String?
                try {
                    line = session.reader.readLine()
                } catch (e: SocketTimeoutException) {
                    // Socket read timeout: normal when idle, continue reading
                    continue
                }

                if (line == null) {
                    Runtime.log("wifi", "controlEOF", "Mac 关闭了控制连接")
                    break
                }

                val msg = JSONObject(line)
                val cmd = msg.optString("cmd")
                val seq = msg.optInt("seq", -1)
                val ack = msg.optInt("ack", -1)
                val msgMac = msg.optString("mac")

                if (seq != session.expectedServerSeq) {
                    Runtime.log("wifi", "badSequence", "expected=${session.expectedServerSeq} got=$seq")
                    break
                }
                session.expectedServerSeq++

                when (cmd) {
                    "state" -> {
                        val stateSession = msg.optString("session")
                        val state = msg.optString("state")
                        val fields = "$stateSession|$state"
                        val expectedMac = WifiCrypto.messageMAC(session.key, direction = "s", clientNonce = session.clientNonce, serverNonce = session.serverNonce, sequence = seq, command = "state", fields = fields)
                        if (!WifiCrypto.equal(msgMac, expectedMac)) {
                            Runtime.log("wifi", "invalidMac", "cmd=state")
                            break
                        }
                        if (state == "streaming") {
                            session.isStreaming = true
                            postOnMain { refreshSnapshot() }
                        } else if (state == "ended") {
                            Runtime.log("wifi", "sessionEndedByHost", "Mac 端会话已结束")
                            break
                        }
                    }
                    "event-stop" -> {
                        val stopSession = msg.optString("session")
                        val reason = msg.optString("reason")
                        val fields = "$stopSession|$reason"
                        val expectedMac = WifiCrypto.messageMAC(session.key, direction = "s", clientNonce = session.clientNonce, serverNonce = session.serverNonce, sequence = seq, command = "event-stop", fields = fields)
                        if (!WifiCrypto.equal(msgMac, expectedMac)) {
                            Runtime.log("wifi", "invalidMac", "cmd=event-stop")
                            break
                        }
                        if (stopSession == session.sessionID) {
                            if (reason == "macUser" || reason == "macStopped") {
                                pausedByUser = true
                            }
                            Runtime.log("wifi", "serverEventStop", "reason=$reason")
                            val currentReq = Runtime.audioRequest
                            if (currentReq != null && currentReq.session == session.sessionID) {
                                currentReq.cancelled = true
                                MicrophoneService.stopCapture(currentReq)
                            }
                            break
                        }
                    }
                    "stopped" -> {
                        val stoppedSession = msg.optString("session")
                        val expectedMac = WifiCrypto.messageMAC(session.key, direction = "s", clientNonce = session.clientNonce, serverNonce = session.serverNonce, sequence = seq, command = "stopped", fields = stoppedSession)
                        if (!WifiCrypto.equal(msgMac, expectedMac)) {
                            Runtime.log("wifi", "invalidMac", "cmd=stopped")
                            break
                        }
                        break
                    }
                    "error" -> {
                        val code = msg.optString("code")
                        val expectedMac = WifiCrypto.messageMAC(session.key, direction = "s", clientNonce = session.clientNonce, serverNonce = session.serverNonce, sequence = seq, command = "error", fields = code)
                        if (!WifiCrypto.equal(msgMac, expectedMac)) {
                            Runtime.log("wifi", "invalidMac", "cmd=error")
                            break
                        }
                        if (code == "PAUSED_BY_USER") {
                            pausedByUser = true
                        }
                        break
                    }
                }
            }
        } catch (e: Exception) {
            Runtime.log("wifi", "sessionLoopError", e.message ?: e.javaClass.simpleName)
        } finally {
            heartbeatThread.interrupt()
            val currentReq = Runtime.audioRequest
            if (currentReq != null && currentReq.session == session.sessionID) {
                currentReq.cancelled = true
                MicrophoneService.stopCapture(currentReq)
            }
            closeCurrentSession("loopEnded")
            postOnMain {
                refreshSnapshot()
                if (!pausedByUser && running.get()) {
                    scheduleReconnect()
                }
            }
        }
    }

    private fun sendAuthenticatedStop(session: ActiveSession, reason: String) {
        try {
            synchronized(session.writer) {
                val seq = session.nextClientSeq++
                val fields = "${session.sessionID}|$reason"
                val mac = WifiCrypto.messageMAC(session.key, direction = "c", clientNonce = session.clientNonce, serverNonce = session.serverNonce, sequence = seq, command = "stop", fields = fields)
                val req = JSONObject().put("cmd", "stop").put("seq", seq).put("session", session.sessionID).put("reason", reason).put("mac", mac)
                session.writer.write(req.toString() + "\n")
                session.writer.flush()
            }
        } catch (_: Exception) {}
    }

    private fun closeCurrentSession(reason: String = "") {
        val session = currentSession
        currentSession = null
        if (session != null) {
            session.closed = true
            try { session.socket.close() } catch (_: Exception) {}
        }
    }

    private fun scheduleReconnect() {
        if (pausedByUser || !running.get()) return
        val delayMs = reconnectBackoffMs.get()
        reconnectBackoffMs.set((delayMs * 2).coerceAtMost(maxBackoffMs))
        postDelayedOnMain(delayMs) {
            if (!pausedByUser && running.get()) {
                checkAutoConnect(userInitiated = false)
            }
        }
    }

    private fun runPairing(gen: Long, target: DiscoveredMac) {
        if (gen != pairingGeneration.get()) return
        var socket: Socket? = null
        try {
            postOnMain {
                if (gen == pairingGeneration.get()) {
                    Runtime.update {
                        it.copy(
                            wifiAuto = it.wifiAuto.copy(
                                phase = WifiAutoPhase.PAIRING,
                                message = "正在连接 ${target.name} 申请绑定…"
                            )
                        )
                    }
                }
            }
            val s = socketFactory?.invoke(target.host, target.controlPort) ?: Socket()
            socket = s
            s.tcpNoDelay = true
            s.soTimeout = 10000
            if (!s.isConnected) {
                s.connect(InetSocketAddress(target.host, target.controlPort), 5000)
            }

            if (gen != pairingGeneration.get()) {
                try { s.close() } catch (_: Exception) {}
                return
            }

            val reader = BufferedReader(InputStreamReader(s.getInputStream(), Charsets.UTF_8))
            val writer = OutputStreamWriter(s.getOutputStream(), Charsets.UTF_8)

            val clientNonce = WifiCrypto.randomHex(16)
            val helloReq = JSONObject()
                .put("cmd", "hello")
                .put("protocol", Capabilities.PROTOCOL_VERSION)
                .put("wifi", Capabilities.WIFI_REVISION)
                .put("runtimeRevision", Capabilities.RUNTIME_REVISION)
                .put("phoneID", trustStore.phoneId)
                .put("phoneName", phoneDisplayName)
                .put("nonce", clientNonce)
                .put("macID", target.id)
            synchronized(writer) {
                writer.write(helloReq.toString() + "\n")
                writer.flush()
            }

            val helloRespLine = reader.readLine() ?: throw IllegalStateException("CLOSED_EARLY")
            val helloResp = JSONObject(helloRespLine)
            if (!helloResp.optBoolean("ok")) throw IllegalStateException(helloResp.optString("error", "HELLO_REJECTED"))
            val serverNonce = helloResp.getString("nonce")

            val phoneKeys = WifiCrypto.PairingKeys()
            val pairReq = JSONObject().put("cmd", "pair").put("pub", phoneKeys.publicBase64)
            synchronized(writer) {
                writer.write(pairReq.toString() + "\n")
                writer.flush()
            }

            val pairRespLine = reader.readLine() ?: throw IllegalStateException("CLOSED_EARLY")
            val pairResp = JSONObject(pairRespLine)
            if (!pairResp.optBoolean("ok")) throw IllegalStateException(pairResp.optString("error", "PAIR_REJECTED"))

            val macPub = pairResp.getString("macPub")
            val requestID = pairResp.getString("requestID")
            val pairingKey = WifiCrypto.pairingKey(
                privateKey = phoneKeys.keyPair.private,
                peerPublicBase64 = macPub,
                macID = target.id,
                phoneID = trustStore.phoneId,
                clientNonce = clientNonce,
                serverNonce = serverNonce,
                phonePublicBase64 = phoneKeys.publicBase64,
                macPublicBase64 = macPub
            ) ?: throw IllegalStateException("ECDH_FAILED")

            val verificationCode = WifiCrypto.verificationCode(pairingKey)
            postOnMain {
                if (gen == pairingGeneration.get()) {
                    Runtime.update {
                        it.copy(
                            wifiAuto = it.wifiAuto.copy(
                                phase = WifiAutoPhase.PAIRING,
                                message = "等待在 Mac 上确认",
                                pendingPairCode = verificationCode,
                                pendingPairMacName = target.name
                            )
                        )
                    }
                }
            }

            // Poll pairStatus
            var approved = false
            for (i in 0 until 120) {
                Thread.sleep(1000)
                if (Thread.interrupted() || gen != pairingGeneration.get()) throw InterruptedException()
                val statusReq = JSONObject().put("cmd", "pairStatus")
                synchronized(writer) {
                    writer.write(statusReq.toString() + "\n")
                    writer.flush()
                }

                val statusLine = reader.readLine() ?: break
                val statusResp = JSONObject(statusLine)
                val status = statusResp.optString("status")
                if (status == "approved") {
                    val proof = statusResp.optString("proof")
                    val expectedProof = WifiCrypto.pairApprovedProof(pairingKey, requestID, target.id, trustStore.phoneId)
                    if (WifiCrypto.equal(proof, expectedProof)) {
                        approved = true
                        break
                    }
                } else if (status == "rejected" || status == "expired") {
                    break
                }
            }

            try { s.close() } catch (_: Exception) {}

            if (gen == pairingGeneration.get()) {
                if (approved) {
                    val trusted = TrustedMac(
                        id = target.id,
                        name = target.name,
                        keyHex = WifiCrypto.hex(pairingKey),
                        pairedAt = System.currentTimeMillis()
                    )
                    trustStore.upsert(trusted)
                    discoveredMap[target.id] = target.copy(isTrusted = true)
                    postOnMain {
                        pausedByUser = false
                        Runtime.update {
                            it.copy(
                                wifiAuto = it.wifiAuto.copy(
                                    phase = WifiAutoPhase.SEARCHING,
                                    message = "已完成配对绑定",
                                    pendingPairCode = null,
                                    pendingPairMacName = null
                                )
                            )
                        }
                        refreshSnapshot()
                        checkAutoConnect(userInitiated = true)
                    }
                } else {
                    postOnMain {
                        Runtime.update {
                            it.copy(
                                wifiAuto = it.wifiAuto.copy(
                                    phase = WifiAutoPhase.SEARCHING,
                                    message = "配对未完成或已取消",
                                    pendingPairCode = null,
                                    pendingPairMacName = null
                                )
                            )
                        }
                    }
                }
            }
        } catch (_: InterruptedException) {
            try { socket?.close() } catch (_: Exception) {}
        } catch (e: Exception) {
            try { socket?.close() } catch (_: Exception) {}
            Runtime.log("wifi", "pairingFailed", e.message ?: e.javaClass.simpleName)
            if (gen == pairingGeneration.get()) {
                postOnMain {
                    Runtime.update {
                        it.copy(
                            wifiAuto = it.wifiAuto.copy(
                                phase = WifiAutoPhase.FAILED,
                                message = "配对失败：${e.message}",
                                pendingPairCode = null,
                                pendingPairMacName = null
                            )
                        )
                    }
                }
            }
        }
    }

    fun refreshSnapshot() {
        val trusted = trustStore.loadTrustedMacs().map {
            TrustedMacInfo(id = it.id, name = it.name, pairedAt = it.pairedAt)
        }
        val isEnabled = Runtime.state.value.settings.wifiAutoConnect
        val session = currentSession
        val isRecordingNow = Runtime.audioRequest?.let { MicrophoneService.isRecording(it) } == true
        val phase = when {
            !isEnabled -> WifiAutoPhase.OFF
            pausedByUser -> WifiAutoPhase.PAUSED
            session != null && (session.isStreaming || isRecordingNow) -> WifiAutoPhase.STREAMING
            session != null -> WifiAutoPhase.PREPARING
            Runtime.state.value.wifiAuto.phase == WifiAutoPhase.PAIRING -> WifiAutoPhase.PAIRING
            Runtime.state.value.wifiAuto.phase == WifiAutoPhase.CONNECTING -> WifiAutoPhase.CONNECTING
            else -> WifiAutoPhase.SEARCHING
        }
        val message = when (phase) {
            WifiAutoPhase.OFF -> "Wi-Fi 自动连接已关闭"
            WifiAutoPhase.PAUSED -> "已手动停止；点「开始拾音」或重新打开应用恢复"
            WifiAutoPhase.STREAMING -> "已连接 Mac Wi-Fi"
            WifiAutoPhase.PREPARING -> "已连接 Mac，正在等待音频…"
            WifiAutoPhase.SEARCHING -> if (trusted.isEmpty()) "正在发现局域网 Mac（请在下方点击配对）" else "正在等待已绑定 Mac…"
            else -> Runtime.state.value.wifiAuto.message
        }
        Runtime.update {
            it.copy(
                wifiAuto = it.wifiAuto.copy(
                    phase = phase,
                    message = if (it.wifiAuto.message.startsWith("正在连接") || it.wifiAuto.message.startsWith("等待在 Mac")) it.wifiAuto.message else message,
                    discovered = discoveredMap.values.toList(),
                    trusted = trusted,
                    pausedByUser = pausedByUser,
                    connectedMacName = if (phase == WifiAutoPhase.STREAMING || phase == WifiAutoPhase.PREPARING) (session?.target?.name ?: it.wifiAuto.connectedMacName) else null
                )
            )
        }
    }
}
