package com.zjx.usblinkmic.support

import com.zjx.usblinkmic.contracts.AppSnapshot
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
        if (settings.wifiHost.isNotEmpty()) {
            if (!isIPv4Address(settings.wifiHost) && !isHostname(settings.wifiHost)) {
                issues += "wifiHost must be empty or a valid hostname or IPv4 address"
            } else if (!isUsableWifiTargetHost(settings.wifiHost)) {
                issues += "wifiHost must not be loopback, link-local, unspecified, or internal VPN address"
            }
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

    fun wifiStartErrors(settings: Settings): List<String> {
        val issues = errors(settings).toMutableList()
        if (settings.wifiHost.isBlank()) {
            issues += "wifiHost must not be blank when starting Wi-Fi microphone"
        }
        return issues
    }

    fun normalizedWifiTargetHost(host: String): String =
        host.trim().trimEnd('.')

    fun isUsableWifiTargetHost(host: String): Boolean {
        val trimmed = host.trim()
        if (trimmed.isEmpty()) return false
        if (!isIPv4Address(trimmed) && !isHostname(trimmed)) return false
        val normalized = normalizedWifiTargetHost(trimmed).lowercase()
        if (normalized.isEmpty()) return false
        if (normalized == "localhost" ||
            normalized.endsWith(".localhost") ||
            normalized == "0.0.0.0" ||
            normalized == "255.255.255.255" ||
            normalized == "10.0.0.2"
        ) {
            return false
        }
        if (isIPv4Address(normalized)) {
            val octets = normalized.split('.').mapNotNull { it.toIntOrNull() }
            if (octets.size != 4) return false
            if (octets[0] == 0) return false
            if (octets[0] == 127) return false
            if (octets[0] == 169 && octets[1] == 254) return false
            if (octets[0] >= 224) return false
            if (octets == listOf(10, 0, 0, 2)) return false
            return true
        }
        return isHostname(trimmed)
    }

    fun resolveSyncedWifiHost(
        existingHost: String,
        incomingHost: String?,
        incomingExplicit: Boolean = false
    ): String {
        val cleanExisting = normalizedWifiTargetHost(existingHost)
        val cleanIncoming = normalizedWifiTargetHost(incomingHost.orEmpty())
        if (!isUsableWifiTargetHost(cleanIncoming)) {
            return if (isUsableWifiTargetHost(cleanExisting)) cleanExisting else ""
        }
        if (incomingExplicit) return cleanIncoming
        if (isUsableWifiTargetHost(cleanExisting)) return cleanExisting
        return cleanIncoming
    }

    fun changedKeys(from: Settings, to: Settings): List<String> {
        val keys = mutableListOf<String>()
        if (from.audio.sampleRate != to.audio.sampleRate) keys += "audio.sampleRate"
        if (from.audio.channels != to.audio.channels) keys += "audio.channels"
        if (from.audio.format != to.audio.format) keys += "audio.format"
        if (from.audio.source != to.audio.source) keys += "audio.source"
        if (from.wifiHost != to.wifiHost) keys += "wifiHost"
        if (from.audioPort != to.audioPort) keys += "audioPort"
        if (from.controlPort != to.controlPort) keys += "controlPort"
        if (from.pairingCode != to.pairingCode) keys += "pairingCode"
        if (from.dns != to.dns) keys += "dns"
        if (from.routes != to.routes) keys += "routes"
        return keys
    }

    fun affectsAudio(from: Settings, to: Settings, activeMode: String? = null): Boolean {
        if (from.audio != to.audio || from.audioPort != to.audioPort) return true
        if (activeMode == "audio") {
            return from.controlPort != to.controlPort
        }
        return normalizedWifiTargetHost(from.wifiHost) != normalizedWifiTargetHost(to.wifiHost) ||
            from.pairingCode != to.pairingCode
    }

    fun applySettingsSave(
        current: AppSnapshot,
        newSettings: Settings,
        activeAudioMode: String? = null,
        persist: (Settings) -> Unit,
        onStopAudio: () -> Unit = {},
    ): AppSnapshot {
        val validationErrors = errors(newSettings)
        if (validationErrors.isNotEmpty()) {
            val detail = validationErrors.joinToString("；")
            return current.copy(
                isSavingSettings = false,
                settingsError = detail,
                settingsMessage = "设置校验未通过",
            )
        }
        return try {
            persist(newSettings)
            if (affectsAudio(current.settings, newSettings, activeMode = activeAudioMode)) {
                onStopAudio()
            }
            current.copy(
                settings = newSettings,
                isSavingSettings = false,
                settingsError = null,
                settingsMessage = "设置已保存",
                settingsSavedRevision = current.settingsSavedRevision + 1L,
            )
        } catch (e: Exception) {
            current.copy(
                isSavingSettings = false,
                settingsError = e.message ?: "保存设置失败",
                settingsMessage = "保存设置失败",
            )
        }
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
