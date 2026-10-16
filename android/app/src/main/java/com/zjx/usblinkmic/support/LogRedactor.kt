package com.zjx.usblinkmic.support

import java.net.Inet6Address
import java.net.InetAddress

object LogRedactor {
    private val assignments = Regex(
        "(?i)(\\b(?:serial|token|pairingCode)\\s*=\\s*)(?:\"[^\"\\r\\n]*\"|'[^'\\r\\n]*'|[^\\s,;})\\]]+)"
    )
    private val homePaths = Regex("(?<![\\w])(/Users/[^/\\s]+(?:/[^\\s\"'<>]*)?|~/[^\\s\"'<>]*)")
    private val ipv4Candidates = Regex("(?<![A-Za-z0-9_.])(?:[0-9]{1,3}\\.){3}[0-9]{1,3}(?![A-Za-z0-9_.])")
    private val ipv6Candidates = Regex("(?<![A-Fa-f0-9:.])[A-Fa-f0-9:.]+(?:%[A-Za-z0-9_.-]+)?(?![A-Fa-f0-9:.])")

    fun redact(text: String): String {
        var result = assignments.replace(text) { match -> "${match.groups[1]?.value}[REDACTED]" }
        result = homePaths.replace(result, "[HOME]")
        result = ipv4Candidates.replace(result) { match ->
            if (isIPv4Address(match.value)) "[IP]" else match.value
        }
        result = ipv6Candidates.replace(result) { match ->
            if (isIPv6Address(match.value)) "[IP]" else match.value
        }
        return result
    }

    private fun isIPv6Address(value: String): Boolean {
        if (!value.contains(':')) return false
        val address = value.substringBefore('%')
        return try {
            InetAddress.getByName(address) is Inet6Address
        } catch (_: Exception) {
            false
        }
    }
}
