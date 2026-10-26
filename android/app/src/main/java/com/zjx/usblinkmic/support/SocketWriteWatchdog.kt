package com.zjx.usblinkmic.support

import java.io.Closeable
import java.io.IOException
import java.net.SocketTimeoutException
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit

class SocketWriteWatchdog(
    private val target: Closeable,
    val defaultTimeoutMs: Long = DEFAULT_WRITE_TIMEOUT_MS,
    checkIntervalMs: Long = DEFAULT_CHECK_INTERVAL_MS,
    private val clockNs: () -> Long = System::nanoTime,
    scheduler: ScheduledExecutorService = sharedScheduler,
    private val onTimeout: (() -> Unit)? = null
) : Closeable {
    companion object {
        const val DEFAULT_WRITE_TIMEOUT_MS = 3_000L
        const val DEFAULT_CHECK_INTERVAL_MS = 250L
        private const val NO_ACTIVE_WRITE = 0L
        private const val NO_DEADLINE = 0L

        private val sharedScheduler: ScheduledExecutorService =
            ScheduledThreadPoolExecutor(1) { runnable ->
                Thread(runnable, "linkmic-write-watchdog").apply { isDaemon = true }
            }.apply {
                removeOnCancelPolicy = true
            }
    }

    private val stateLock = Any()
    private var writeGeneration = 0L
    private var activeWriteGeneration = NO_ACTIVE_WRITE
    private var activeDeadlineNs = NO_DEADLINE
    @Volatile private var closed = false
    @Volatile private var timedOut = false
    private val checkTask: ScheduledFuture<*> = scheduler.scheduleWithFixedDelay(
        ::checkDeadline,
        checkIntervalMs.coerceAtLeast(10L),
        checkIntervalMs.coerceAtLeast(10L),
        TimeUnit.MILLISECONDS
    )

    fun beginWrite(timeoutMs: Long = defaultTimeoutMs) {
        if (closed) return
        val timeoutNs = TimeUnit.MILLISECONDS.toNanos(timeoutMs.coerceAtLeast(1L))
        val deadline = clockNs() + timeoutNs
        val effectiveDeadline = if (deadline == NO_DEADLINE) 1L else deadline
        synchronized(stateLock) {
            if (closed) return
            val generation = ++writeGeneration
            activeWriteGeneration = generation
            activeDeadlineNs = effectiveDeadline
        }
    }

    fun endWrite() {
        synchronized(stateLock) {
            activeWriteGeneration = NO_ACTIVE_WRITE
            activeDeadlineNs = NO_DEADLINE
        }
    }

    inline fun <T> withWriteTimeout(timeoutMs: Long = defaultTimeoutMs, block: () -> T): T {
        beginWrite(timeoutMs)
        return try {
            block()
        } catch (error: IOException) {
            if (didTimeOut() && error !is SocketTimeoutException) {
                throw SocketTimeoutException("SOCKET_WRITE_TIMEOUT").apply { initCause(error) }
            }
            throw error
        } finally {
            endWrite()
        }
    }

    fun didTimeOut(): Boolean = timedOut

    fun isClosed(): Boolean = closed

    internal fun checkDeadline() {
        val observedGeneration: Long
        val observedDeadlineNs: Long
        synchronized(stateLock) {
            if (closed || activeWriteGeneration == NO_ACTIVE_WRITE) return
            observedGeneration = activeWriteGeneration
            observedDeadlineNs = activeDeadlineNs
        }
        if (clockNs() - observedDeadlineNs < 0L) return
        val shouldTrip = synchronized(stateLock) {
            if (closed || activeWriteGeneration != observedGeneration) {
                false
            } else {
                closed = true
                timedOut = true
                activeWriteGeneration = NO_ACTIVE_WRITE
                activeDeadlineNs = NO_DEADLINE
                true
            }
        }
        if (!shouldTrip) return
        checkTask.cancel(false)
        try {
            target.close()
        } catch (_: Throwable) {
        }
        try {
            onTimeout?.invoke()
        } catch (_: Throwable) {
        }
    }

    override fun close() {
        val shouldCancel = synchronized(stateLock) {
            if (closed) {
                false
            } else {
                closed = true
                activeWriteGeneration = NO_ACTIVE_WRITE
                activeDeadlineNs = NO_DEADLINE
                true
            }
        }
        if (shouldCancel) {
            checkTask.cancel(false)
        }
    }
}
