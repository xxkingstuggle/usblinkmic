package com.zjx.usblinkmic.platform

import android.Manifest
import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import com.zjx.usblinkmic.contracts.*
import com.zjx.usblinkmic.support.SocketWriteWatchdog
import org.json.JSONObject
import java.io.DataOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.sqrt

class MicrophoneService : Service() {
    private class Capture(val request: Request) {
        interface RecordingCallbackRegistration {
            fun register()
            fun initialState(): String
            fun close()
        }

        private data class Resources(
            val recorder: AudioRecord?,
            val socket: Socket?,
            val writeWatchdog: SocketWriteWatchdog?,
            val callbackRegistration: RecordingCallbackRegistration?
        )

        @Volatile var recorder: AudioRecord? = null
        @Volatile var socket: Socket? = null
        @Volatile var writeWatchdog: SocketWriteWatchdog? = null
        @Volatile var recording = false
        @Volatile var silenced = "unknown"
        @Volatile var startedAtElapsedMs = 0L
        @Volatile private var endedAtElapsedMs = 0L
        @Volatile private var callbackRegistration: RecordingCallbackRegistration? = null
        val framesSent = AtomicLong()
        val pcmBytesSent = AtomicLong()
        val readFailures = AtomicLong()
        val transportFailures = AtomicLong()
        val captureFailures = AtomicLong()
        val silenceChanges = AtomicLong()
        val readCalls = AtomicLong()
        val readDurationTotalUs = AtomicLong()
        val readDurationMaxUs = AtomicLong()
        val readGapCount = AtomicLong()
        val readGapTotalUs = AtomicLong()
        val readGapMaxUs = AtomicLong()
        val socketWriteCalls = AtomicLong()
        val socketWriteTotalUs = AtomicLong()
        val socketWriteMaxUs = AtomicLong()
        val socketWriteSlowCount = AtomicLong()
        val audioThreadPriorityApplied = AtomicLong()
        @Volatile var audioRecordLostFramesApiAvailable = false
        private val silenceLock = Any()
        private var silencedSinceElapsedMs = 0L
        private var totalSilencedMs = 0L
        @Volatile private var closed = false
        private val resourcesCloseComplete = CountDownLatch(1)

        @Synchronized fun attachRecorder(audio: AudioRecord): Boolean {
            if (closed) return false
            recorder = audio
            return true
        }

        @Synchronized fun attachSocket(connection: Socket, watchdog: SocketWriteWatchdog): Boolean {
            if (closed) return false
            socket = connection
            writeWatchdog = watchdog
            return true
        }

        @Synchronized fun installRecordingCallback(
            registration: RecordingCallbackRegistration
        ): Boolean {
            if (closed) return false
            registration.register()
            callbackRegistration = registration
            return true
        }

        fun clearRecordingCallback(registration: RecordingCallbackRegistration) {
            val owned = synchronized(this) {
                if (callbackRegistration !== registration) false
                else {
                    callbackRegistration = null
                    true
                }
            }
            if (owned) try { registration.close() } catch (_: Exception) { }
        }

        @Synchronized fun markWorkerStarted(): Boolean {
            if (closed) return false
            workerStarted = true
            return true
        }

        @Synchronized fun markWorkerNotStarted() {
            workerStarted = false
        }

        @Volatile var workerStarted = false
            private set

        fun isClosed(): Boolean = closed

        @Synchronized fun hasWorkerStarted(): Boolean = workerStarted

        fun setSilenced(value: String, nowElapsedMs: Long): Boolean = synchronized(silenceLock) {
            if (closed) return@synchronized false
            if (silenced == value) return@synchronized false
            if (silenced == "silenced" && silencedSinceElapsedMs > 0L) {
                totalSilencedMs += (nowElapsedMs - silencedSinceElapsedMs).coerceAtLeast(0L)
                silencedSinceElapsedMs = 0L
            }
            if (value == "silenced") silencedSinceElapsedMs = nowElapsedMs
            silenced = value
            silenceChanges.incrementAndGet()
            true
        }

        fun diagnostics(nowElapsedMs: Long): JSONObject = synchronized(silenceLock) {
            val silencedMs = totalSilencedMs + if (silenced == "silenced" && silencedSinceElapsedMs > 0L) {
                (nowElapsedMs - silencedSinceElapsedMs).coerceAtLeast(0L)
            } else 0L
            JSONObject()
                .put("framesSent", framesSent.get())
                .put("pcmBytesSent", pcmBytesSent.get())
                .put("readFailures", readFailures.get())
                .put("transportFailures", transportFailures.get())
                .put("captureFailures", captureFailures.get())
                .put("silenceChanges", silenceChanges.get())
                .put("silencedMs", silencedMs)
                .put("readCalls", readCalls.get())
                .put("readDurationTotalUs", readDurationTotalUs.get())
                .put("readDurationMaxUs", readDurationMaxUs.get())
                .put("readGapCount", readGapCount.get())
                .put("readGapTotalUs", readGapTotalUs.get())
                .put("readGapMaxUs", readGapMaxUs.get())
                .put("socketWriteCalls", socketWriteCalls.get())
                .put("socketWriteTotalUs", socketWriteTotalUs.get())
                .put("socketWriteMaxUs", socketWriteMaxUs.get())
                .put("socketWriteSlowCount", socketWriteSlowCount.get())
                .put("audioRecordLostFrames", -1L)
                .put("audioRecordLostFramesApiAvailable", if (audioRecordLostFramesApiAvailable) 1 else 0)
                .put("audioThreadPriorityApplied", audioThreadPriorityApplied.get())
                .put("uptimeMs", if (startedAtElapsedMs > 0L) ((if (endedAtElapsedMs > 0L) endedAtElapsedMs else nowElapsedMs) - startedAtElapsedMs).coerceAtLeast(0L) else 0L)
        }

        fun recordReadDuration(durationNs: Long) {
            readCalls.incrementAndGet()
            accumulateMicros(readDurationTotalUs, readDurationMaxUs, durationNs)
        }

        fun recordReadGap(durationNs: Long) {
            readGapCount.incrementAndGet()
            accumulateMicros(readGapTotalUs, readGapMaxUs, durationNs)
        }

        fun recordSocketWrite(durationNs: Long, slowThresholdNs: Long) {
            socketWriteCalls.incrementAndGet()
            accumulateMicros(socketWriteTotalUs, socketWriteMaxUs, durationNs)
            if (durationNs >= slowThresholdNs) socketWriteSlowCount.incrementAndGet()
        }

        private fun accumulateMicros(total: AtomicLong, maximum: AtomicLong, durationNs: Long) {
            val micros = durationNs.coerceAtLeast(0L) / 1_000L
            total.addAndGet(micros)
            while (true) {
                val previous = maximum.get()
                if (micros <= previous || maximum.compareAndSet(previous, micros)) return
            }
        }

        fun closeResources() {
            val resources = synchronized(this) {
                if (closed) null else {
                    closed = true
                    recording = false
                    endedAtElapsedMs = android.os.SystemClock.elapsedRealtime()
                    Resources(recorder, socket, writeWatchdog, callbackRegistration).also {
                        recorder = null
                        socket = null
                        writeWatchdog = null
                        callbackRegistration = null
                    }
                }
            }
            if (resources == null) {
                awaitResourcesClose()
                return
            }
            val audio = resources.recorder
            try {
                finishSilenced(android.os.SystemClock.elapsedRealtime())
                try { resources.writeWatchdog?.close() } catch (_: Exception) { }
                try { resources.socket?.close() } catch (_: Exception) { }
                try { resources.callbackRegistration?.close() } catch (_: Exception) { }
                try { audio?.stop() } catch (_: Exception) { }
            } finally {
                resourcesCloseComplete.countDown()
            }
        }

        private fun awaitResourcesClose() {
            var interrupted = false
            while (true) {
                try {
                    resourcesCloseComplete.await()
                    break
                } catch (_: InterruptedException) {
                    interrupted = true
                }
            }
            if (interrupted) Thread.currentThread().interrupt()
        }

        private fun finishSilenced(nowElapsedMs: Long) = synchronized(silenceLock) {
            if (silenced == "silenced" && silencedSinceElapsedMs > 0L) {
                totalSilencedMs += (nowElapsedMs - silencedSinceElapsedMs).coerceAtLeast(0L)
                silencedSinceElapsedMs = 0L
            }
        }
    }

    @Suppress("NewApi")
    private class Api29RecordingCallbackRegistration(
        private val capture: Capture,
        private val audio: AudioRecord
    ) : Capture.RecordingCallbackRegistration {
        private val callbackThread = HandlerThread("linkmic-audio-state")
        private val audioSessionId = audio.audioSessionId
        private val callback = object : android.media.AudioManager.AudioRecordingCallback() {
            override fun onRecordingConfigChanged(configs: MutableList<android.media.AudioRecordingConfiguration>) {
                if (!MicrophoneService.isCurrent(capture)) return
                MicrophoneService.updateSilencing(capture, silenceState(configs))
            }
        }
        private var registered = false
        private var threadStarted = false

        override fun register() {
            try {
                callbackThread.start()
                threadStarted = true
                val callbackHandler = Handler(callbackThread.looper)
                val callbackExecutor = Executor { command -> callbackHandler.post(command) }
                registered = true
                audio.registerAudioRecordingCallback(callbackExecutor, callback)
            } catch (error: Exception) {
                close()
                throw error
            }
        }

        override fun initialState(): String {
            val initial = audio.activeRecordingConfiguration
            return if (initial != null && initial.clientAudioSessionId == audioSessionId) {
                if (initial.isClientSilenced) "silenced" else "active"
            } else "unknown"
        }

        override fun close() {
            if (registered) {
                try { audio.unregisterAudioRecordingCallback(callback) } catch (_: Exception) { }
                registered = false
            }
            if (threadStarted) {
                try { callbackThread.quitSafely() } catch (_: Exception) { }
                threadStarted = false
            }
        }

        private fun silenceState(configurations: List<android.media.AudioRecordingConfiguration>): String {
            val ownConfiguration = configurations.firstOrNull { it.clientAudioSessionId == audioSessionId }
                ?: return "unknown"
            return if (ownConfiguration.isClientSilenced) "silenced" else "active"
        }
    }

    companion object {
        @Volatile var recording = false
            private set
        @Volatile private var activeCapture: Capture? = null
        @Volatile private var lastCapture: Capture? = null

        @Synchronized
        private fun claim(request: Request): Capture? {
            if (lastCapture?.request === request) return null
            val previous = activeCapture
            if (previous != null) {
                if (previous.request === request || previous.hasWorkerStarted()) return null
                if (!previous.request.cancelled && Runtime.audioRequest === previous.request) return null
                previous.closeResources()
                if (activeCapture === previous) {
                    lastCapture = previous
                    activeCapture = null
                    recording = false
                }
            }
            lastCapture = null
            return Capture(request).also {
                activeCapture = it
                recording = false
            }
        }

        @Synchronized
        fun stopCapture(request: Request? = null) {
            val capture = activeCapture ?: return
            if (request != null && capture.request !== request) return
            capture.closeResources()
            recording = false
            if (activeCapture === capture && !capture.hasWorkerStarted()) {
                lastCapture = capture
                activeCapture = null
            }
        }

        fun hasCapture(request: Request): Boolean = activeCapture?.request === request

        fun hasCompletedCapture(request: Request): Boolean = lastCapture?.request === request

        fun isRecording(request: Request): Boolean = activeCapture?.let {
            it.request === request && it.recording
        } == true

        @Synchronized
        private fun markRecording(capture: Capture): Boolean {
            if (activeCapture !== capture || capture.isClosed() || Runtime.audioRequest !== capture.request || capture.request.cancelled) return false
            capture.recording = true
            recording = true
            return true
        }

        @Synchronized
        private fun releaseCapture(capture: Capture): Boolean {
            if (activeCapture !== capture) return false
            lastCapture = capture
            recording = false
            activeCapture = null
            return true
        }

        fun addStatusFields(reply: JSONObject, request: Request) {
            val capture = activeCapture?.takeIf { it.request === request } ?: lastCapture?.takeIf { it.request === request }
            reply.put("silenced", when (capture?.silenced) { "silenced" -> true; "active" -> false; else -> JSONObject.NULL })
            reply.put("audioDiagnostics", capture?.diagnostics(android.os.SystemClock.elapsedRealtime()) ?: JSONObject.NULL)
        }

        private fun isCurrent(capture: Capture): Boolean =
            activeCapture === capture && !capture.isClosed() && Runtime.audioRequest === capture.request && !capture.request.cancelled

        private fun updateSilencing(capture: Capture, value: String) {
            val changed = capture.setSilenced(value, android.os.SystemClock.elapsedRealtime())
            if (changed && isCurrent(capture)) Runtime.log("audio", "systemSilenced", "state=$value")
        }
    }

    private var request: Request? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "STOP") {
            val activeRequest = Runtime.audioRequest
            if (activeRequest != null && intent.getStringExtra("session") == activeRequest.session) {
                activeRequest.cancelled = true
                stopCapture(activeRequest)
                stopSelf(startId)
            }
            return START_NOT_STICKY
        }
        val currentRequest = Runtime.audioRequest
        if (currentRequest == null || currentRequest.cancelled || !currentRequest.accepted ||
            intent?.getStringExtra("session") != currentRequest.session
        ) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        if (hasCapture(currentRequest) || hasCompletedCapture(currentRequest)) return START_NOT_STICKY
        val capture = claim(currentRequest)
        if (capture == null) {
            if (!currentRequest.cancelled && Runtime.audioRequest === currentRequest) {
                Runtime.fail(currentRequest, "AUDIO_BUSY: 旧录音会话仍在释放")
            }
            stopSelf(startId)
            return START_NOT_STICKY
        }
        request = currentRequest
        if (currentRequest.cancelled || Runtime.audioRequest !== currentRequest) {
            stopCapture(currentRequest)
            stopSelf(startId)
            return START_NOT_STICKY
        }
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            if (!currentRequest.cancelled && Runtime.audioRequest === currentRequest) Runtime.fail(currentRequest, "MICROPHONE_DENIED")
            stopCapture(currentRequest)
            stopSelf(startId)
            return START_NOT_STICKY
        }
        val stopIntent = Intent(this, MicrophoneService::class.java).setAction("STOP").putExtra("session", currentRequest.session)
        var captureThread: Thread? = null
        try {
            startForeground(10, Notifications.create(
                this,
                "USB LinkMic · 正在采音",
                stopIntent,
                subtitle = "麦克风正向 Mac 传输音频 · 点按查看状态或停止",
                stopLabel = "停止采音",
            ))
            captureThread = Thread({ capture(capture, startId) }, "linkmic-capture").apply { isDaemon = true }
            check(capture.markWorkerStarted()) { "CAPTURE_STOPPED_BEFORE_START" }
            captureThread.start()
        } catch (e: Exception) {
            if (captureThread == null || captureThread.state == Thread.State.NEW) capture.markWorkerNotStarted()
            if (!currentRequest.cancelled && Runtime.audioRequest === currentRequest) {
                Runtime.fail(currentRequest, e.message ?: e.javaClass.simpleName)
            }
            stopCapture(currentRequest)
            stopSelf(startId)
        }
        return START_NOT_STICKY
    }

    private fun capture(capture: Capture, startId: Int) {
        val r = capture.request
        var ownedAudio: AudioRecord? = null
        try {
            try {
                android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_AUDIO)
                capture.audioThreadPriorityApplied.set(1L)
            } catch (_: SecurityException) {
                capture.audioThreadPriorityApplied.set(0L)
            } catch (_: IllegalArgumentException) {
                capture.audioThreadPriorityApplied.set(0L)
            }
            val p = r.settings.audio
            require(Runtime.parametersSupported(p)) { "UNSUPPORTED_AUDIO" }
            val encoding = if (p.format == PCMFormat.I16) AudioFormat.ENCODING_PCM_16BIT else AudioFormat.ENCODING_PCM_FLOAT
            val mask = if (p.channels == 1) AudioFormat.CHANNEL_IN_MONO else AudioFormat.CHANNEL_IN_STEREO
            val min = AudioRecord.getMinBufferSize(p.sampleRate, mask, encoding)
            if (p.source == RecordingSource.UNPROCESSED) {
                val manager = getSystemService(android.media.AudioManager::class.java)
                require(manager.getProperty(android.media.AudioManager.PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED) == "true") { "UNSUPPORTED_SOURCE" }
            }
            if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) throw SecurityException("MICROPHONE_DENIED")

            val audio = AudioRecord.Builder()
                .setAudioSource(Runtime.source(p))
                .setAudioFormat(AudioFormat.Builder().setEncoding(encoding).setSampleRate(p.sampleRate).setChannelMask(mask).build())
                .setBufferSizeInBytes(maxOf(min * 2, 8192))
                .build()
            ownedAudio = audio
            if (!capture.attachRecorder(audio)) return
            check(audio.state == AudioRecord.STATE_INITIALIZED && audio.sampleRate == p.sampleRate &&
                audio.channelCount == p.channels && audio.audioFormat == encoding
            ) { "AUDIO_HARDWARE_UNAVAILABLE_OR_FORMAT_CHANGED" }

            val connectStartMs = android.os.SystemClock.elapsedRealtime()
            val connection = Socket()
            val writeWatchdog = SocketWriteWatchdog(connection)
            if (!capture.attachSocket(connection, writeWatchdog)) {
                writeWatchdog.close()
                connection.close()
                return
            }
            connection.tcpNoDelay = true
            connection.connect(InetSocketAddress(if (r.mode == "wifi") r.settings.wifiHost else "127.0.0.1", r.settings.audioPort), 10000)
            connection.soTimeout = 10000
            val socketOutput = connection.getOutputStream()
            val out = DataOutputStream(socketOutput)
            val header = JSONObject()
                .put("protocol", 4).put("session", r.session).put("token", r.token)
                .put("sampleRate", p.sampleRate).put("channels", p.channels)
                .put("format", if (p.format == PCMFormat.I16) "i16" else "f32")
                .put("source", when (p.source) {
                    RecordingSource.MICROPHONE -> "microphone"
                    RecordingSource.UNPROCESSED -> "unprocessed"
                    else -> "voiceRecognition"
                })
            writeWatchdog.withWriteTimeout {
                out.write((header.toString() + "\n").toByteArray())
                out.flush()
            }
            val reply = connection.getInputStream().bufferedReader().readLine()
            check(reply != null && JSONObject(reply).optBoolean("accepted")) { "HANDSHAKE_REJECTED" }
            val handshakeElapsedMs = (android.os.SystemClock.elapsedRealtime() - connectStartMs).coerceAtLeast(0L)
            Runtime.log(
                r.mode,
                "handshakeAccepted",
                "音频握手成功 mode=${r.mode} rate=${p.sampleRate} ch=${p.channels} fmt=${p.format} src=${p.source}",
                session = r.session,
                elapsedMs = handshakeElapsedMs
            )
            if (!isCurrent(capture)) return

            audio.startRecording()
            check(audio.recordingState == AudioRecord.RECORDSTATE_RECORDING) { "AUDIO_HARDWARE_BUSY" }
            capture.startedAtElapsedMs = android.os.SystemClock.elapsedRealtime()
            if (!markRecording(capture)) return
            registerSilencingCallback(capture, audio)
            Runtime.log(
                r.mode,
                "recordingStarted",
                "AudioRecord 采音已启动 mode=${r.mode} rate=${p.sampleRate} ch=${p.channels}",
                session = r.session
            )
            Runtime.updateAudio(r) {
                it.copy(
                    microphone = ModuleStatus(TaskPhase.RUNNING, "正在采音", "系统静音状态通过 Android 录音状态回报"),
                    effectiveAudio = p,
                    controlledByMac = r.mode == "audio",
                    frames = 0,
                    level = 0.0,
                    waveform = emptyList()
                )
            }

            val count = 1024 * p.channels
            val sampleBytes = if (p.format == PCMFormat.I16) 2 else 4
            val samples = if (p.format == PCMFormat.I16) ShortArray(count) else null
            val floatSamples = if (p.format == PCMFormat.F32) FloatArray(count) else null
            val frame = ByteBuffer.allocate(4 + count * sampleBytes).order(ByteOrder.BIG_ENDIAN)
            frame.position(4)
            val shortFrame = samples?.let { frame.slice().order(ByteOrder.LITTLE_ENDIAN).asShortBuffer() }
            val floatFrame = floatSamples?.let { frame.slice().order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer() }
            val trend = DoubleArray(64)
            val updateStride = maxOf(1, count / trend.size)
            var trendCount = 0
            var lastUiUpdateMs = android.os.SystemClock.elapsedRealtime()
            var lastHealthLogMs = lastUiUpdateMs
            var previousReadEndNs = 0L
            while (isCurrent(capture) && capture.recording) {
                val readStartNs = android.os.SystemClock.elapsedRealtimeNanos()
                if (previousReadEndNs > 0L) capture.recordReadGap(readStartNs - previousReadEndNs)
                val n = if (samples != null) {
                    audio.read(samples, 0, count, AudioRecord.READ_BLOCKING)
                } else {
                    audio.read(floatSamples!!, 0, count, AudioRecord.READ_BLOCKING)
                }
                val readEndNs = android.os.SystemClock.elapsedRealtimeNanos()
                capture.recordReadDuration(readEndNs - readStartNs)
                previousReadEndNs = readEndNs
                if (n <= 0) {
                    capture.readFailures.incrementAndGet()
                    throw IllegalStateException("AUDIO_READ_FAILED:$n")
                }
                check(n % p.channels == 0) { "BAD_FRAME_ALIGNMENT" }

                val nowMs = android.os.SystemClock.elapsedRealtime()
                val updateUi = Runtime.isAudioUiVisible() && nowMs - lastUiUpdateMs >= 200L
                frame.clear()
                frame.putInt(n * sampleBytes)
                var energy = 0.0
                trendCount = 0
                if (samples != null) {
                    shortFrame!!.clear()
                    shortFrame.put(samples, 0, n)
                    if (updateUi) {
                        for (i in 0 until n) {
                            val sample = samples[i]
                            val value = sample.toDouble() / 32768.0
                            energy += value * value
                            if (i % updateStride == 0 && trendCount < trend.size) trend[trendCount++] = value
                        }
                    }
                } else {
                    floatFrame!!.clear()
                    floatFrame.put(floatSamples!!, 0, n)
                    for (i in 0 until n) {
                        val sample = floatSamples[i]
                        check(sample.isFinite()) { "BAD_SAMPLE" }
                        if (updateUi) {
                            val value = sample.toDouble()
                            energy += value * value
                            if (i % updateStride == 0 && trendCount < trend.size) trend[trendCount++] = value
                        }
                    }
                }
                val wireBytes = 4 + n * sampleBytes
                val writeStartNs = android.os.SystemClock.elapsedRealtimeNanos()
                try {
                    writeWatchdog.withWriteTimeout {
                        socketOutput.write(frame.array(), 0, wireBytes)
                    }
                } catch (e: Exception) {
                    capture.transportFailures.incrementAndGet()
                    throw e
                } finally {
                    val writeDurationNs = android.os.SystemClock.elapsedRealtimeNanos() - writeStartNs
                    val packetDurationNs = (n / p.channels).toLong() * 1_000_000_000L / p.sampleRate
                    capture.recordSocketWrite(writeDurationNs, packetDurationNs)
                }
                val totalFrames = capture.framesSent.incrementAndGet()
                val totalBytes = capture.pcmBytesSent.addAndGet((wireBytes - 4).toLong())
                if (totalFrames == 1L) {
                    val firstFrameMs = (nowMs - connectStartMs).coerceAtLeast(0L)
                    Runtime.log(r.mode, "firstFrameSent", "首帧音频已发送 bytes=${wireBytes - 4}", session = r.session, elapsedMs = firstFrameMs)
                }
                if (nowMs - lastHealthLogMs >= 45_000L) {
                    lastHealthLogMs = nowMs
                    val upMs = (nowMs - capture.startedAtElapsedMs).coerceAtLeast(0L)
                    Runtime.log(
                        r.mode,
                        "healthSummary",
                        "framesSent=$totalFrames pcmBytes=$totalBytes readMaxUs=${capture.readDurationMaxUs.get()} writeMaxUs=${capture.socketWriteMaxUs.get()} writeSlow=${capture.socketWriteSlowCount.get()} silenced=${capture.silenced}",
                        session = r.session,
                        elapsedMs = upMs
                    )
                }
                if (updateUi) {
                    val level = sqrt(energy / n)
                    val waveform = ArrayList<Double>(trendCount)
                    for (i in 0 until trendCount) waveform.add(trend[i])
                    Runtime.updateAudioMeter(r) {
                        it.copy(level = level, waveform = waveform, frames = totalFrames)
                    }
                    lastUiUpdateMs = nowMs
                }
            }
        } catch (e: Exception) {
            if (isCurrent(capture) && !r.cancelled) {
                capture.captureFailures.incrementAndGet()
                Runtime.fail(r, e.message ?: e.javaClass.simpleName, source = "capture")
            }
        } finally {
            val endMs = android.os.SystemClock.elapsedRealtime()
            val runMs = if (capture.startedAtElapsedMs > 0L) (endMs - capture.startedAtElapsedMs).coerceAtLeast(0L) else 0L
            Runtime.log(
                r.mode,
                "sessionEnd",
                "采音会话结束 framesSent=${capture.framesSent.get()} pcmBytes=${capture.pcmBytesSent.get()} cancelled=${r.cancelled} error=${r.error.ifBlank { "none" }}",
                session = r.session,
                elapsedMs = runMs
            )
            capture.closeResources()
            try { ownedAudio?.release() } catch (_: Exception) { }
            val stopThisStart = releaseCapture(capture)
            if (stopThisStart) stopSelf(startId)
        }
    }

    @Suppress("NewApi")
    private fun registerSilencingCallback(capture: Capture, audio: AudioRecord) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            Runtime.log("audio", "systemSilencedUnavailable", "androidApi=${Build.VERSION.SDK_INT}")
            return
        }
        val registration = Api29RecordingCallbackRegistration(capture, audio)
        try {
            if (!capture.installRecordingCallback(registration)) {
                registration.close()
                return
            }
            updateSilencing(capture, registration.initialState())
        } catch (e: Exception) {
            capture.clearRecordingCallback(registration)
            Runtime.log("audio", "systemSilencedUnavailable", "reason=${e.javaClass.simpleName}")
        }
    }

    override fun onDestroy() {
        val currentRequest = request
        if (currentRequest != null) {
            if (!currentRequest.cancelled && currentRequest.accepted && currentRequest.error.isBlank()) {
                currentRequest.error = "SERVICE_DESTROYED"
                Runtime.log("audio", "serviceDestroyed", "服务结束时本次会话未收到明确停止")
            }
            stopCapture(currentRequest)
            if (Runtime.audioRequest === currentRequest) {
                Runtime.audioRequest = null
                val snapshot = Runtime.state.value
                if (!currentRequest.cancelled && currentRequest.accepted && currentRequest.error.isNotBlank()) {
                    Runtime.state.value = if (snapshot.microphone.phase == TaskPhase.FAILED) {
                        snapshot.copy(level = 0.0, waveform = emptyList())
                    } else {
                        snapshot.copy(
                            microphone = ModuleStatus(TaskPhase.FAILED, "采音服务意外结束", currentRequest.error, "AUDIO_FAILED"),
                            level = 0.0,
                            waveform = emptyList()
                        )
                    }
                } else if (snapshot.microphone.phase == TaskPhase.FAILED) {
                    Runtime.state.value = snapshot.copy(level = 0.0, waveform = emptyList())
                } else {
                    Runtime.state.value = snapshot.copy(microphone = ModuleStatus(), level = 0.0, waveform = emptyList())
                }
            }
        }
        super.onDestroy()
    }
}
