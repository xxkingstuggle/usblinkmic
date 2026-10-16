package com.zjx.usblinkmic.support

import android.content.Context
import android.content.SharedPreferences
import com.zjx.usblinkmic.contracts.AudioParameters
import com.zjx.usblinkmic.contracts.PCMFormat
import com.zjx.usblinkmic.contracts.RecordingSource
import com.zjx.usblinkmic.contracts.Settings
import org.json.JSONObject

class SettingsStore internal constructor(private val preferences: SharedPreferences) {
    constructor(context: Context) : this(context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE))

    fun load(): Settings {
        val jsonText = preferences.getString(SETTINGS_KEY, null) ?: return Settings()
        val root = JSONObject(jsonText)
        val schemaVersion = root.getInt("schemaVersion")
        require(schemaVersion == 1) { "Unsupported schemaVersion: $schemaVersion" }

        val audio = root.getJSONObject("audio")
        val settings = Settings(
            schemaVersion = schemaVersion,
            audio = AudioParameters(
                sampleRate = audio.getInt("sampleRate"),
                channels = audio.getInt("channels"),
                format = enumValueOf<PCMFormat>(audio.getString("format")),
                source = enumValueOf<RecordingSource>(audio.getString("source"))
            ),
            wifiHost = root.getString("wifiHost"),
            audioPort = root.getInt("audioPort"),
            controlPort = root.getInt("controlPort"),
            pairingCode = root.getString("pairingCode"),
            dns = root.getString("dns"),
            routes = root.getString("routes")
        )
        val validationErrors = SettingsValidator.errors(settings)
        check(validationErrors.isEmpty()) {
            "Stored settings are invalid: ${validationErrors.joinToString("; ")}"
        }
        return settings
    }

    fun save(settings: Settings) {
        val validationErrors = SettingsValidator.errors(settings)
        require(validationErrors.isEmpty()) {
            "Invalid settings: ${validationErrors.joinToString("; ")}"
        }

        val audio = JSONObject()
            .put("sampleRate", settings.audio.sampleRate)
            .put("channels", settings.audio.channels)
            .put("format", settings.audio.format.name)
            .put("source", settings.audio.source.name)
        val json = JSONObject()
            .put("schemaVersion", settings.schemaVersion)
            .put("audio", audio)
            .put("wifiHost", settings.wifiHost)
            .put("audioPort", settings.audioPort)
            .put("controlPort", settings.controlPort)
            .put("pairingCode", settings.pairingCode)
            .put("dns", settings.dns)
            .put("routes", settings.routes)

        check(preferences.edit().putString(SETTINGS_KEY, json.toString()).commit()) {
            "Unable to persist settings"
        }
    }

    companion object {
        internal const val PREFERENCES_NAME = "usblinkmic_settings"
        internal const val SETTINGS_KEY = "settings_json"
    }
}
