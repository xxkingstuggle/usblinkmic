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
import java.net.Inet4Address
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

object NsdHostSelector {
    fun selectBestIpv4Host(serviceInfo: NsdServiceInfo): String? {
        val hostList: List<java.net.InetAddress>? = if (Build.VERSION.SDK_INT >= 34) {
            try {
                val getHostAddresses = serviceInfo.javaClass.getMethod("getHostAddresses")
                @Suppress("UNCHECKED_CAST")
                getHostAddresses.invoke(serviceInfo) as? List<java.net.InetAddress>
            } catch (_: Throwable) {
                null
            }
        } else null
        return selectBestIpv4(serviceInfo.host, hostList)
    }

    fun selectBestIpv4(primaryHost: java.net.InetAddress?, allAddresses: List<java.net.InetAddress>? = null): String? {
        if (!allAddresses.isNullOrEmpty()) {
            val ipv4 = allAddresses.filterIsInstance<Inet4Address>().firstOrNull()?.hostAddress
            if (!ipv4.isNullOrBlank()) return ipv4
        }
        if (primaryHost is Inet4Address) {
            return primaryHost.hostAddress
        }
        if (primaryHost != null) {
            val addr = primaryHost.hostAddress ?: return null
            val clean = addr.split('%')[0].trim()
            if (clean.contains('.') && !clean.contains(':')) return clean
            return clean
        }
        return null
    }
}

class AndroidNsdDiscovery(private val context: Context) : WifiEndpointDiscovery {
    private var nsdManager: NsdManager? = null
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    private val serviceNameToMacId = ConcurrentHashMap<String, String>()
    private val activeFoundServices = ConcurrentHashMap.newKeySet<String>()
    private val discoveryGeneration = AtomicLong(0)

    override fun start(onDiscovered: (DiscoveredMac) -> Unit, onLost: (String) -> Unit) {
        stop()
        val manager = context.getSystemService(Context.NSD_SERVICE) as? NsdManager ?: return
        nsdManager = manager
        val myGen = discoveryGeneration.incrementAndGet()
        activeFoundServices.clear()
        serviceNameToMacId.clear()

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
                    val sName = service.serviceName.orEmpty()
                    if (sName.isNotEmpty()) {
                        activeFoundServices.add(sName)
                    }
                    try {
                        manager.resolveService(service, object : NsdManager.ResolveListener {
                            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                                Runtime.log("wifi", "nsdResolveFailed", "service=${serviceInfo.serviceName} errorCode=$errorCode")
                            }
                            override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                                if (myGen != discoveryGeneration.get()) return
                                val resolvedName = serviceInfo.serviceName.orEmpty()
                                if (resolvedName.isNotEmpty() && !activeFoundServices.contains(resolvedName)) {
                                    Runtime.log("wifi", "nsdResolveDropped", "service=$resolvedName was already lost")
                                    return
                                }
                                val host = NsdHostSelector.selectBestIpv4Host(serviceInfo) ?: return
                                val port = serviceInfo.port
                                if (port <= 0 || host.isBlank()) return
                                val attributes = serviceInfo.attributes ?: emptyMap()
                                val id = attributes["id"]?.let { String(it, Charsets.UTF_8) }.orEmpty()
                                val name = attributes["name"]?.let { String(it, Charsets.UTF_8) }.orEmpty().ifBlank { serviceInfo.serviceName ?: "Mac" }
                                if (id.isNotEmpty()) {
                                    if (resolvedName.isNotEmpty()) {
                                        serviceNameToMacId[resolvedName] = id
                                    }
                                    onDiscovered(DiscoveredMac(id = id, name = name, host = host, controlPort = port, isTrusted = false, serviceName = resolvedName))
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
                activeFoundServices.remove(sName)
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
        discoveryGeneration.incrementAndGet()
        activeFoundServices.clear()
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

    private fun postDelayed(delayMs: Long, action: () -> Unit) {
        when {
            delayedDispatcher != null -> delayedDispatcher.invoke(delayMs, action)
            mainHandler != null -> mainHandler.postDelayed(action, delayMs)
            else -> {
                thread(isDaemon = true) {
                    try { Thread.sleep(delayMs) } catch (_: InterruptedException) { return@thread }
                    postOnMain(action)
                }
            }
        }
    }

    val discoveredMap = ConcurrentHashMap<String, DiscoveredMac>()
    val running = AtomicBoolean(false)
    @Volatile var isUiVisible = false
    @Volatile var pausedByUser = false

    data class ActiveSession(
        val generation: Long,
        val target: DiscoveredMac,
        @Volatile var sessionID: String,
        val key: ByteArray,
        val clientNonce: String,
        val serverNonce: String,
        val socket: Socket,
        val reader: BufferedReader,
        val writer: OutputStreamWriter,
        @Volatile var nextClientSeq: Int = 1,
        @Volatile var expectedServerSeq: Int = 1,
        @Volatile var lastSentStatusSeq: Int = -1,
        @Volatile var lastValidResponseTimeMs: Long = 0L,
        @Volatile var isStreaming: Boolean = false,
        @Volatile var closed: Boolean = false,
        @Volatile var pendingPrepareSeq: Int = -1,
        @Volatile var audioEpoch: Long = 0L
    )

    private val sessionGeneration = AtomicLong(0)
    private val sessionLock = Any()
    @Volatile private var currentSession: ActiveSession? = null
    private val connectingAttempt = AtomicLong(0L)
    @Volatile private var pairingThread: Thread? = null
    private val pairingGeneration = AtomicLong(0)

    private val reconnectBackoffMs = AtomicLong(1000L)
    private val maxBackoffMs = 15000L

    var heartbeatIntervalMs: Long = 5000L
    var responseTimeoutBudgetMs: Long = 20000L
    var monotonicClock: () -> Long = {
        try {
            android.os.SystemClock.elapsedRealtime()
        } catch (_: Throwable) {
            System.nanoTime() / 1_000_000L
        }
    }

    val phoneDisplayName: String
        get() = "${Build.MANUFACTURER} ${Build.MODEL}".trim()

    val activeSessionID: String?
        get() = synchronized(sessionLock) { currentSession?.sessionID }

    val isSessionAlive: Boolean
        get() = synchronized(sessionLock) {
            currentSession?.let { !it.closed && it.socket.isConnected && !it.socket.isClosed } == true
        }

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
                    } else {
                        val hasActive = synchronized(sessionLock) { currentSession != null }
                        if (!hasActive) {
                            checkAutoConnect()
                        }
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
        closeCurrentSessionExplicitly("stoppedByUser")
        discoveredMap.clear()
        postOnMain { refreshSnapshot() }
    }

    fun stopAudioService(expectedSessionID: String? = null, reason: String = "stop") {
        val req = Runtime.audioRequest ?: return
        if (req.mode != "wifi") return
        if (expectedSessionID != null && expectedSessionID.isNotBlank() && req.session != expectedSessionID) return
        req.cancelled = true
        if (context != null) {
            Runtime.stop(context, req, source = reason)
        } else {
            MicrophoneService.stopCapture(req)
            if (Runtime.audioRequest === req) {
                Runtime.audioRequest = null
                Runtime.update {
                    it.copy(
                        microphone = ModuleStatus(),
                        level = 0.0,
                        waveform = emptyList(),
                        controlledByMac = false
                    )
                }
            }
        }
    }

    fun onUserStartedExplicitly() {
        pausedByUser = false
        reconnectBackoffMs.set(1000L)
        var active: ActiveSession? = null
        synchronized(sessionLock) {
            active = currentSession
            if (active != null && !active!!.closed) {
                active!!.audioEpoch++
                active!!.pendingPrepareSeq = -1
            }
        }
        if (active != null && !active!!.closed) {
            thread(name = "linkmic-start", isDaemon = true) {
                sendAuthenticatedPrepare(active!!, userInitiated = true)
            }
            postOnMain { refreshSnapshot() }
        } else {
            refreshSnapshot()
            checkAutoConnect(userInitiated = true)
        }
    }

    fun onUserStoppedExplicitly() {
        pausedByUser = true
        var sessionToStop: ActiveSession? = null
        var sessionIDToStop = ""
        synchronized(sessionLock) {
            sessionToStop = currentSession
            if (sessionToStop != null) {
                sessionToStop!!.audioEpoch++
                sessionToStop!!.pendingPrepareSeq = -1
                sessionIDToStop = sessionToStop!!.sessionID
                sessionToStop!!.sessionID = ""
                sessionToStop!!.isStreaming = false
            }
        }
        if (sessionToStop != null && !sessionToStop!!.closed) {
            thread(name = "linkmic-stop", isDaemon = true) {
                sendAuthenticatedStop(sessionToStop!!, reason = "userStopped", sessionIDOverride = sessionIDToStop)
            }
        }
        stopAudioService(expectedSessionID = sessionIDToStop, reason = "userStopped")
        postOnMain { refreshSnapshot() }
    }

    fun onMicrophoneServiceStopped(session: String?, error: String = "") {
        if (session.isNullOrBlank()) return
        var active: ActiveSession? = null
        synchronized(sessionLock) {
            val curr = currentSession
            if (curr != null && !curr.closed && curr.sessionID == session) {
                active = curr
                curr.audioEpoch++
                curr.pendingPrepareSeq = -1
                curr.isStreaming = false
                curr.sessionID = ""
            }
        }
        if (active != null) {
            thread(name = "linkmic-srv-stop", isDaemon = true) {
                sendAuthenticatedStop(active!!, reason = if (error.isNotBlank()) "audioError" else "phoneStop", sessionIDOverride = session)
            }
            postOnMain { refreshSnapshot() }
        }
    }

    fun forgetMac(macId: String) {
        trustStore.remove(macId)
        val existing = discoveredMap[macId]
        if (existing != null) {
            discoveredMap[macId] = existing.copy(isTrusted = false)
        }
        var activeToClose: ActiveSession? = null
        synchronized(sessionLock) {
            if (currentSession?.target?.id == macId) {
                activeToClose = currentSession
                currentSession = null
            }
        }
        if (activeToClose != null) {
            sessionGeneration.incrementAndGet()
            closeSessionIfOwner(activeToClose!!, "macForgotten", allowReconnect = false)
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
        synchronized(sessionLock) {
            if (currentSession != null && !currentSession!!.closed) return
        }
        if (Runtime.audioRequest != null && Runtime.audioRequest?.cancelled == false) return
        val currentSettings = Runtime.state.value.settings
        if (!currentSettings.wifiAutoConnect) return

        val trustedList = trustStore.loadTrustedMacs()
        if (trustedList.isEmpty()) return

        val target = discoveredMap.values.firstOrNull { mac -> trustedList.any { it.id == mac.id } } ?: return
        val trusted = trustStore.getMac(target.id) ?: return

        // Background safety: do not start microphone if UI is backgrounded unless user explicitly initiated
        if (!isUiVisible && !userInitiated) return

        if (!userInitiated && connectingAttempt.get() != 0L) {
            return
        }

        val myGen = sessionGeneration.incrementAndGet()
        if (!userInitiated) {
            if (!connectingAttempt.compareAndSet(0L, myGen)) {
                return
            }
        } else {
            connectingAttempt.set(myGen)
        }

        thread(name = "linkmic-connect-$myGen", isDaemon = true) {
            try {
                connectAndPrepare(myGen, target, trusted, userInitiated)
            } finally {
                connectingAttempt.compareAndSet(myGen, 0L)
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

            val active = ActiveSession(
                generation = myGen,
                target = target,
                sessionID = "",
                key = key,
                clientNonce = clientNonce,
                serverNonce = serverNonce,
                socket = s,
                reader = reader,
                writer = writer,
                nextClientSeq = 1,
                expectedServerSeq = 1,
                lastSentStatusSeq = -1,
                lastValidResponseTimeMs = monotonicClock(),
                isStreaming = false,
                closed = false
            )

            var installed = false
            synchronized(sessionLock) {
                if (myGen == sessionGeneration.get() && running.get()) {
                    val prev = currentSession
                    currentSession = active
                    if (prev != null && prev !== active) {
                        prev.closed = true
                        try { prev.socket.close() } catch (_: Throwable) {}
                    }
                    reconnectBackoffMs.set(1000L)
                    installed = true
                }
            }

            if (!installed) {
                active.closed = true
                try { s.close() } catch (_: Exception) {}
                return
            }

            postOnMain {
                refreshSnapshot()
            }

            if (!pausedByUser) {
                sendAuthenticatedPrepare(active, userInitiated = userInitiated)
            }

            // Run session loop (heartbeat and event listener)
            runSessionLoop(active)

        } catch (e: Exception) {
            Runtime.log("wifi", "autoConnectFailed", e.message ?: e.javaClass.simpleName)
            if (socket != null && currentSession?.socket !== socket) {
                try { socket.close() } catch (_: Exception) {}
            }
            if (myGen == sessionGeneration.get()) {
                closeCurrentSessionExplicitly("connectFailed: ${e.message}")
                postOnMain {
                    refreshSnapshot()
                    if (running.get()) {
                        scheduleReconnect()
                    }
                }
            }
        }
    }

    fun sendAuthenticatedPrepare(session: ActiveSession, userInitiated: Boolean) {
        if (session.closed) return
        if (pausedByUser && !userInitiated) return
        try {
            val audio = Runtime.state.value.settings.audio
            val formatStr = if (audio.format == PCMFormat.I16) "i16" else "f32"
            val sourceStr = when (audio.source) {
                RecordingSource.MICROPHONE -> "microphone"
                RecordingSource.UNPROCESSED -> "unprocessed"
                RecordingSource.VOICE_RECOGNITION -> "voiceRecognition"
            }
            val userInitiatedInt = if (userInitiated) 1 else 0
            synchronized(session.writer) {
                session.audioEpoch++
                val seq = session.nextClientSeq++
                session.pendingPrepareSeq = seq
                val fields = "${audio.sampleRate}|${audio.channels}|$formatStr|$sourceStr|$userInitiatedInt"
                val mac = WifiCrypto.messageMAC(session.key, direction = "c", clientNonce = session.clientNonce, serverNonce = session.serverNonce, sequence = seq, command = "prepare", fields = fields)
                val prepReq = JSONObject()
                    .put("cmd", "prepare")
                    .put("seq", seq)
                    .put("sampleRate", audio.sampleRate)
                    .put("channels", audio.channels)
                    .put("format", formatStr)
                    .put("source", sourceStr)
                    .put("userInitiated", userInitiatedInt)
                    .put("mac", mac)
                session.writer.write(prepReq.toString() + "\n")
                session.writer.flush()
            }
            postOnMain {
                Runtime.update {
                    it.copy(
                        wifiAuto = it.wifiAuto.copy(
                            phase = WifiAutoPhase.PREPARING,
                            message = "已连接 ${session.target.name}，正在准备音频…",
                            connectedMacName = session.target.name
                        )
                    )
                }
            }
        } catch (e: Exception) {
            Runtime.log("wifi", "sendPrepareFailed", e.message ?: e.javaClass.simpleName)
            closeSessionIfOwner(session, "sendPrepareFailed: ${e.message}", allowReconnect = true)
        }
    }

    private fun runSessionLoop(session: ActiveSession) {
        session.socket.soTimeout = minOf(heartbeatIntervalMs.toInt(), 2000).coerceAtLeast(100)

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
                        session.lastSentStatusSeq = seq
                        val mac = WifiCrypto.messageMAC(session.key, direction = "c", clientNonce = session.clientNonce, serverNonce = session.serverNonce, sequence = seq, command = "status", fields = "")
                        val req = JSONObject().put("cmd", "status").put("seq", seq).put("mac", mac)
                        session.writer.write(req.toString() + "\n")
                        session.writer.flush()
                    }
                } catch (e: Exception) {
                    Runtime.log("wifi", "heartbeatFailed", e.message ?: e.javaClass.simpleName)
                    closeSessionIfOwner(session, "heartbeatFailed", allowReconnect = true)
                    break
                }
            }
        }

        try {
            while (!session.closed && session.generation == sessionGeneration.get()) {
                if (monotonicClock() - session.lastValidResponseTimeMs > responseTimeoutBudgetMs) {
                    Runtime.log("wifi", "responseTimeout", "Response timeout expired: >${responseTimeoutBudgetMs}ms")
                    break
                }

                val line: String?
                try {
                    line = session.reader.readLine()
                } catch (e: SocketTimeoutException) {
                    if (monotonicClock() - session.lastValidResponseTimeMs > responseTimeoutBudgetMs) {
                        Runtime.log("wifi", "responseTimeout", "Response timeout expired: >${responseTimeoutBudgetMs}ms")
                        break
                    }
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
                        if (ack != session.lastSentStatusSeq && ack != 1) {
                            Runtime.log("wifi", "badAck", "cmd=state expected=${session.lastSentStatusSeq} got=$ack")
                            break
                        }
                        session.lastValidResponseTimeMs = monotonicClock()
                        session.expectedServerSeq++
                        if (state == "streaming") {
                            session.isStreaming = true
                            postOnMain { refreshSnapshot() }
                        } else if (state == "ended") {
                            if (session.isStreaming || session.sessionID.isNotBlank()) {
                                session.audioEpoch++
                                session.pendingPrepareSeq = -1
                                val targetToStop = session.sessionID
                                session.isStreaming = false
                                session.sessionID = ""
                                stopAudioService(expectedSessionID = targetToStop, reason = "stateEnded")
                                postOnMain { refreshSnapshot() }
                            }
                        }
                    }
                    "prepared" -> {
                        val sessionID = msg.optString("session")
                        val audioPort = msg.optInt("audioPort")
                        val prepRate = msg.optInt("sampleRate")
                        val prepChannels = msg.optInt("channels")
                        val prepFormat = msg.optString("format")
                        val prepSource = msg.optString("source")
                        val prepMacFields = "$sessionID|$audioPort|$prepRate|$prepChannels|$prepFormat|$prepSource"
                        val expectedPrepMac = WifiCrypto.messageMAC(session.key, direction = "s", clientNonce = session.clientNonce, serverNonce = session.serverNonce, sequence = seq, command = "prepared", fields = prepMacFields)
                        if (!WifiCrypto.equal(msgMac, expectedPrepMac)) {
                            Runtime.log("wifi", "invalidMac", "cmd=prepared")
                            break
                        }
                        if (ack != session.pendingPrepareSeq || session.pendingPrepareSeq == -1) {
                            Runtime.log("wifi", "badAck", "cmd=prepared ack=$ack expected=${session.pendingPrepareSeq}")
                            break
                        }
                        session.pendingPrepareSeq = -1
                        session.lastValidResponseTimeMs = monotonicClock()
                        session.expectedServerSeq++

                        if (audioPort !in 1..65535 || sessionID.isBlank()) {
                            Runtime.log("wifi", "malformedPrepared", "port=$audioPort session=$sessionID")
                            break
                        }

                        // Check if user stopped while prepare was in flight
                        if (pausedByUser) {
                            Runtime.log("wifi", "preparedIgnoredPaused", "session=$sessionID user paused")
                            thread(name = "linkmic-cancel-grant", isDaemon = true) {
                                sendAuthenticatedStop(session, reason = "cancelledPaused", sessionIDOverride = sessionID)
                            }
                            session.sessionID = ""
                            session.isStreaming = false
                            postOnMain { refreshSnapshot() }
                            continue
                        }

                        // Validate audio parameters against requested
                        val currentAudio = Runtime.state.value.settings.audio
                        val reqFormatStr = if (currentAudio.format == PCMFormat.I16) "i16" else "f32"
                        val reqSourceStr = when (currentAudio.source) {
                            RecordingSource.MICROPHONE -> "microphone"
                            RecordingSource.UNPROCESSED -> "unprocessed"
                            RecordingSource.VOICE_RECOGNITION -> "voiceRecognition"
                        }
                        if (prepRate != currentAudio.sampleRate || prepChannels != currentAudio.channels || prepFormat != reqFormatStr || prepSource != reqSourceStr) {
                            Runtime.log("wifi", "preparedParamMismatch", "got $prepRate/$prepChannels/$prepFormat/$prepSource expected ${currentAudio.sampleRate}/${currentAudio.channels}/$reqFormatStr/$reqSourceStr")
                            thread(name = "linkmic-cancel-param", isDaemon = true) {
                                sendAuthenticatedStop(session, reason = "unsupportedParams", sessionIDOverride = sessionID)
                            }
                            session.sessionID = ""
                            session.isStreaming = false
                            postOnMain { refreshSnapshot() }
                            continue
                        }

                        session.sessionID = sessionID
                        session.isStreaming = false
                        val audioToken = WifiCrypto.audioToken(session.key, sessionID, session.clientNonce, session.serverNonce)
                        val audioParams = AudioParameters(
                            sampleRate = prepRate,
                            channels = prepChannels,
                            format = if (prepFormat == "f32") PCMFormat.F32 else PCMFormat.I16,
                            source = when (prepSource) {
                                "unprocessed" -> RecordingSource.UNPROCESSED
                                "voiceRecognition" -> RecordingSource.VOICE_RECOGNITION
                                else -> RecordingSource.MICROPHONE
                            }
                        )
                        val capturedEpoch = session.audioEpoch
                        postOnMain {
                            if (currentSession === session && !session.closed && !pausedByUser && session.audioEpoch == capturedEpoch) {
                                Runtime.update {
                                    it.copy(
                                        wifiAuto = it.wifiAuto.copy(
                                            phase = WifiAutoPhase.PREPARING,
                                            message = "已连接 ${session.target.name}，正在准备音频…",
                                            connectedMacName = session.target.name
                                        )
                                    )
                                }
                                onSessionReady?.invoke(sessionID, audioToken, session.target.host, audioPort, audioParams)
                            } else {
                                thread(name = "linkmic-cancel-stale-ready", isDaemon = true) {
                                    sendAuthenticatedStop(session, reason = "cancelledStale", sessionIDOverride = sessionID)
                                }
                            }
                        }
                    }
                    "event-start" -> {
                        val expectedMac = WifiCrypto.messageMAC(session.key, direction = "s", clientNonce = session.clientNonce, serverNonce = session.serverNonce, sequence = seq, command = "event-start", fields = "")
                        if (!WifiCrypto.equal(msgMac, expectedMac)) {
                            Runtime.log("wifi", "invalidMac", "cmd=event-start")
                            break
                        }
                        if (ack != 0) {
                            Runtime.log("wifi", "badAck", "cmd=event-start ack=$ack")
                            break
                        }
                        session.lastValidResponseTimeMs = monotonicClock()
                        session.expectedServerSeq++
                        pausedByUser = false
                        session.audioEpoch++
                        session.pendingPrepareSeq = -1
                        Runtime.log("wifi", "serverEventStart", "Mac 端发起了开始拾音")
                        thread(name = "linkmic-prepare-start", isDaemon = true) {
                            sendAuthenticatedPrepare(session, userInitiated = true)
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
                        if (stopSession != session.sessionID && session.sessionID.isNotBlank()) {
                            Runtime.log("wifi", "wrongSession", "cmd=event-stop expected=${session.sessionID} got=$stopSession")
                            break
                        }
                        if (ack != 0) {
                            Runtime.log("wifi", "badAck", "cmd=event-stop ack=$ack")
                            break
                        }
                        session.lastValidResponseTimeMs = monotonicClock()
                        session.expectedServerSeq++
                        if (reason == "macUser" || reason == "macStopped") {
                            pausedByUser = true
                        }
                        session.audioEpoch++
                        session.pendingPrepareSeq = -1
                        val stoppedSession = session.sessionID
                        session.isStreaming = false
                        session.sessionID = ""
                        Runtime.log("wifi", "serverEventStop", "reason=$reason")
                        stopAudioService(expectedSessionID = stoppedSession, reason = "serverEventStop: $reason")
                        postOnMain { refreshSnapshot() }
                    }
                    "stopped" -> {
                        val stoppedSession = msg.optString("session")
                        val expectedMac = WifiCrypto.messageMAC(session.key, direction = "s", clientNonce = session.clientNonce, serverNonce = session.serverNonce, sequence = seq, command = "stopped", fields = stoppedSession)
                        if (!WifiCrypto.equal(msgMac, expectedMac)) {
                            Runtime.log("wifi", "invalidMac", "cmd=stopped")
                            break
                        }
                        session.lastValidResponseTimeMs = monotonicClock()
                        session.expectedServerSeq++
                        session.audioEpoch++
                        session.pendingPrepareSeq = -1
                        val targetToStop = if (session.sessionID.isNotBlank()) session.sessionID else stoppedSession
                        session.isStreaming = false
                        session.sessionID = ""
                        stopAudioService(expectedSessionID = targetToStop, reason = "stoppedAck")
                        postOnMain { refreshSnapshot() }
                    }
                    "error" -> {
                        val code = msg.optString("code")
                        val expectedMac = WifiCrypto.messageMAC(session.key, direction = "s", clientNonce = session.clientNonce, serverNonce = session.serverNonce, sequence = seq, command = "error", fields = code)
                        if (!WifiCrypto.equal(msgMac, expectedMac)) {
                            Runtime.log("wifi", "invalidMac", "cmd=error")
                            break
                        }
                        session.expectedServerSeq++
                        session.lastValidResponseTimeMs = monotonicClock()
                        if (code == "PAUSED_BY_USER") {
                            pausedByUser = true
                            session.audioEpoch++
                            session.pendingPrepareSeq = -1
                            val targetToStop = session.sessionID
                            session.isStreaming = false
                            session.sessionID = ""
                            stopAudioService(expectedSessionID = targetToStop, reason = "pausedByUser")
                            postOnMain { refreshSnapshot() }
                        } else if (code == "STALE_SESSION") {
                            Runtime.log("wifi", "staleSessionIgnored", code)
                        } else {
                            Runtime.log("wifi", "serverError", code)
                            break
                        }
                    }
                    else -> {
                        Runtime.log("wifi", "unrecognizedCommand", cmd)
                        break
                    }
                }
            }
        } catch (e: Exception) {
            Runtime.log("wifi", "sessionLoopError", e.message ?: e.javaClass.simpleName)
        } finally {
            heartbeatThread.interrupt()
            closeSessionIfOwner(session, "loopEnded", allowReconnect = true)
        }
    }

    private fun sendAuthenticatedStop(session: ActiveSession, reason: String, sessionIDOverride: String? = null) {
        val targetSession = if (!sessionIDOverride.isNullOrBlank()) sessionIDOverride else session.sessionID
        if (targetSession.isBlank()) return
        try {
            synchronized(session.writer) {
                val seq = session.nextClientSeq++
                val fields = "$targetSession|$reason"
                val mac = WifiCrypto.messageMAC(session.key, direction = "c", clientNonce = session.clientNonce, serverNonce = session.serverNonce, sequence = seq, command = "stop", fields = fields)
                val req = JSONObject().put("cmd", "stop").put("seq", seq).put("session", targetSession).put("reason", reason).put("mac", mac)
                session.writer.write(req.toString() + "\n")
                session.writer.flush()
            }
        } catch (_: Exception) {}
    }

    private fun closeSessionIfOwner(session: ActiveSession, reason: String, allowReconnect: Boolean = true): Boolean {
        session.closed = true
        try { session.socket.close() } catch (_: Throwable) {}

        var wasOwner = false
        val capturedSessionID = session.sessionID
        synchronized(sessionLock) {
            if (currentSession === session) {
                currentSession = null
                wasOwner = true
            }
        }

        if (wasOwner) {
            stopAudioService(expectedSessionID = capturedSessionID, reason = "sessionClosed: $reason")
            postOnMain {
                refreshSnapshot()
                if (allowReconnect && running.get()) {
                    scheduleReconnect()
                }
            }
        }
        return wasOwner
    }

    private fun closeCurrentSessionExplicitly(reason: String) {
        var toClose: ActiveSession? = null
        var toCloseID = ""
        synchronized(sessionLock) {
            toClose = currentSession
            toCloseID = toClose?.sessionID ?: ""
            currentSession = null
        }
        if (toClose != null) {
            toClose!!.closed = true
            try { toClose!!.socket.close() } catch (_: Throwable) {}
            stopAudioService(expectedSessionID = toCloseID, reason = "sessionExplicitlyClosed: $reason")
        }
        postOnMain { refreshSnapshot() }
    }

    private fun scheduleReconnect() {
        val delay = reconnectBackoffMs.get()
        val next = (delay * 2).coerceAtMost(maxBackoffMs)
        reconnectBackoffMs.set(next)
        Runtime.log("wifi", "scheduleReconnect", "in ${delay}ms")
        postDelayed(delay) {
            checkAutoConnect(userInitiated = false)
        }
    }

    private fun runPairing(gen: Long, target: DiscoveredMac) {
        if (gen != pairingGeneration.get() || !running.get()) return
        var socket: Socket? = null
        try {
            postOnMain {
                Runtime.update {
                    it.copy(
                        wifiAuto = it.wifiAuto.copy(
                            phase = WifiAutoPhase.PAIRING,
                            message = "正在连接 ${target.name} 进行配对…",
                            pendingPairCode = null,
                            pendingPairMacName = target.name
                        )
                    )
                }
            }

            val s = socketFactory?.invoke(target.host, target.controlPort) ?: Socket()
            socket = s
            s.tcpNoDelay = true
            s.soTimeout = 10000
            s.connect(InetSocketAddress(target.host, target.controlPort), 5000)

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

            // Generate ECDH P-256 ephemeral keys
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
            ) ?: throw IllegalStateException("KEY_AGREEMENT_FAILED")

            val verificationCode = WifiCrypto.verificationCode(pairingKey)
            postOnMain {
                if (gen == pairingGeneration.get()) {
                    Runtime.update {
                        it.copy(
                            wifiAuto = it.wifiAuto.copy(
                                phase = WifiAutoPhase.PAIRING,
                                message = "请在 Mac 上核对验证码并确认配对",
                                pendingPairCode = verificationCode,
                                pendingPairMacName = target.name
                            )
                        )
                    }
                }
            }

            // Poll for approval (10 attempts, 1s interval)
            var approved = false
            for (i in 0 until 30) {
                if (gen != pairingGeneration.get() || !running.get()) break
                Thread.sleep(1000)
                if (gen != pairingGeneration.get() || !running.get()) break

                val pollReq = JSONObject().put("cmd", "pairStatus").put("requestID", requestID)
                synchronized(writer) {
                    writer.write(pollReq.toString() + "\n")
                    writer.flush()
                }

                val pollRespLine = reader.readLine() ?: break
                val pollResp = JSONObject(pollRespLine)
                if (pollResp.optBoolean("ok") && pollResp.optString("status") == "approved") {
                    val proof = pollResp.optString("proof")
                    val expectedProof = WifiCrypto.pairApprovedProof(pairingKey, requestID, target.id, trustStore.phoneId)
                    if (WifiCrypto.equal(proof, expectedProof)) {
                        approved = true
                        break
                    }
                } else if (pollResp.optString("status") == "rejected") {
                    break
                }
            }

            try { s.close() } catch (_: Exception) {}

            if (gen == pairingGeneration.get()) {
                if (approved) {
                    val trusted = TrustedMac(id = target.id, name = target.name, keyHex = WifiCrypto.hex(pairingKey), pairedAt = System.currentTimeMillis())
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
        val session = synchronized(sessionLock) { currentSession }
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
            WifiAutoPhase.PREPARING -> if (session != null) "已连接 ${session.target.name}，正在等待音频…" else "已连接 Mac，正在等待音频…"
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
                    connectedMacName = if (phase == WifiAutoPhase.STREAMING || phase == WifiAutoPhase.PREPARING || (session != null && !session.closed)) (session?.target?.name ?: it.wifiAuto.connectedMacName) else null
                )
            )
        }
    }
}
