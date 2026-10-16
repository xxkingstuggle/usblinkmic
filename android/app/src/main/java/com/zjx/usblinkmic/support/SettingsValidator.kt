package com.zjx.usblinkmic.support

import com.zjx.usblinkmic.contracts.Capabilities
import com.zjx.usblinkmic.contracts.Settings

object SettingsValidator {
    fun errors(settings: Settings): List<String> {
        if (settings.schemaVersion != 1) {
            return listOf("Unsupported schemaVersion: ${settings.schemaVersion}")
        }

        val issues = mutableListOf<String>()
        if (settings.audio.sampleRate !in Capabilities.SAMPLE_RATES) {
            issues += "audio.sampleRate must be one of ${Capabilities.SAMPLE_RATES}"
        }
        if (settings.audio.channels !in Capabilities.CHANNELS) {
            issues += "audio.channels must be one of ${Capabilities.CHANNELS}"
        }
        if (settings.audioPort !in 1024..65535) {
            issues += "audioPort must be between 1024 and 65535"
        }
        if (settings.controlPort !in 1024..65535) {
            issues += "controlPort must be between 1024 and 65535"
        }
        if (settings.audioPort == settings.controlPort) {
            issues += "audioPort and controlPort must be distinct"
        }
        if (settings.wifiHost.isNotEmpty() && !isIPv4Address(settings.wifiHost) && !isHostname(settings.wifiHost)) {
            issues += "wifiHost must be empty or a valid hostname or IPv4 address"
        }
        if (settings.pairingCode.isNotEmpty() && !isHexString(settings.pairingCode, 32)) {
            issues += "pairingCode must be empty or 32 hexadecimal characters"
        }
        if (!isIPv4Address(settings.dns)) {
            issues += "dns must be a valid IPv4 address"
        }
        if (!isIPv4CidrList(settings.routes)) {
            issues += "routes must contain one or more IPv4 CIDR routes"
        }
        return issues
    }
}

internal fun isIPv4Address(value: String): Boolean {
    val octets = value.split('.', ignoreCase = false, limit = 0)
    if (octets.size != 4) return false
    return octets.all { octet ->
        if (octet.isEmpty() || octet.length > 1 && octet[0] == '0' || !octet.all { it in '0'..'9' }) {
            false
        } else {
            octet.toIntOrNull()?.let { it in 0..255 } ?: false
        }
    }
}

private fun isIPv4CidrList(value: String): Boolean {
    val routes = value.split(',', ignoreCase = false, limit = 0)
    if (routes.isEmpty()) return false
    return routes.all { route ->
        val parts = route.split('/', ignoreCase = false, limit = 0)
        if (parts.size != 2) return@all false
        val address = parts[0].trim()
        val prefixText = parts[1]
        isIPv4Address(address) && prefixText.isNotEmpty() && prefixText.all { it in '0'..'9' } &&
            (prefixText.toIntOrNull()?.let { it in 0..32 } ?: false)
    }
}

private fun isHostname(value: String): Boolean {
    if (value.isEmpty() || value.toByteArray(Charsets.US_ASCII).size != value.length || value.length > 254) return false
    if (!value.all { it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || it == '-' || it == '.' }) return false
    if (value.all { it in '0'..'9' || it == '.' }) return false

    val hostname = value.removeSuffix(".")
    if (hostname.isEmpty()) return false
    return hostname.split('.', ignoreCase = false, limit = 0).all { label ->
        label.isNotEmpty() && label.length <= 63 && label.first() != '-' && label.last() != '-'
    }
}

private fun isHexString(value: String, length: Int): Boolean =
    value.length == length && value.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }
