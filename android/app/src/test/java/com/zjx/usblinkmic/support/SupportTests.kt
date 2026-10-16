package com.zjx.usblinkmic.support

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import com.zjx.usblinkmic.contracts.AudioParameters
import com.zjx.usblinkmic.contracts.Settings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SupportTests {
    @Test
    fun defaultSettingsPassValidation() {
        assertTrue(SettingsValidator.errors(Settings()).isEmpty())
    }

    @Test
    fun validatorRejectsUnsupportedSchemaAndInvalidValues() {
        assertEquals(listOf("Unsupported schemaVersion: 9"), SettingsValidator.errors(Settings(schemaVersion = 9)))

        val settings = Settings(
            audio = AudioParameters(sampleRate = 12345, channels = 3),
            wifiHost = "bad host",
            audioPort = 1023,
            controlPort = 1023,
            pairingCode = "xyz",
            dns = "256.1.1.1",
            routes = "10.0.0.0/33"
        )
        val errors = SettingsValidator.errors(settings)
        assertTrue(errors.any { it.startsWith("audio.sampleRate") })
        assertTrue(errors.any { it.startsWith("audio.channels") })
        assertTrue(errors.any { it.startsWith("audioPort") })
        assertTrue(errors.any { it.startsWith("controlPort") })
        assertTrue(errors.any { it.contains("distinct") })
        assertTrue(errors.any { it.startsWith("wifiHost") })
        assertTrue(errors.any { it.startsWith("pairingCode") })
        assertTrue(errors.any { it.startsWith("dns") })
        assertTrue(errors.any { it.startsWith("routes") })
    }

    @Test
    fun storeRoundTripsAndRejectsUnknownSchema() {
        val preferences = MemoryPreferences()
        val store = SettingsStore(preferences)
        val saved = Settings(
            audio = AudioParameters(sampleRate = 48000, channels = 2),
            wifiHost = "mic.example.local",
            audioPort = 48126,
            controlPort = 48127,
            pairingCode = "00112233445566778899aabbccddeeff",
            dns = "8.8.8.8",
            routes = "0.0.0.0/0,192.168.0.0/16"
        )
        store.save(saved)
        assertEquals(saved, store.load())

        val commitCount = preferences.commitCount
        try {
            store.save(saved.copy(audioPort = 48127))
            throw AssertionError("Expected invalid settings to be rejected")
        } catch (_: IllegalArgumentException) {
            // Invalid settings must be rejected before SharedPreferences is edited.
        }
        assertEquals(commitCount, preferences.commitCount)
        assertEquals(saved, store.load())

        preferences.edit().putString(SettingsStore.SETTINGS_KEY, "{\"schemaVersion\":77}").commit()
        try {
            store.load()
            throw AssertionError("Expected an unknown schema version to be rejected")
        } catch (error: IllegalArgumentException) {
            assertTrue(error.message.orEmpty().contains("Unsupported schemaVersion: 77"))
        }
    }

    @Test
    fun logRedactorMasksStructuredSecretsIPsAndHomePaths() {
        val input = "serial=ABC123 token=secret pairingCode=001122 ip=192.168.1.5 v6=2001:db8::1 file=/Users/alice/private.log ~/Documents/secret"
        val output = LogRedactor.redact(input)

        assertFalse(output.contains("ABC123"))
        assertFalse(output.contains("secret"))
        assertFalse(output.contains("192.168.1.5"))
        assertFalse(output.contains("2001:db8::1"))
        assertFalse(output.contains("/Users/alice"))
        assertFalse(output.contains("~/Documents"))
        assertTrue(output.contains("serial=[REDACTED]"))
        assertTrue(output.contains("[IP]"))
        assertTrue(output.contains("[HOME]"))
    }
}

private class MemoryPreferences : SharedPreferences {
    private val values = linkedMapOf<String, Any?>()
    var commitCount: Int = 0
        private set

    override fun getAll(): MutableMap<String, *> = values.toMutableMap()
    override fun getString(key: String, defValue: String?): String? = values[key] as? String ?: defValue
    @Suppress("UNCHECKED_CAST")
    override fun getStringSet(key: String, defValues: MutableSet<String>?): MutableSet<String>? =
        (values[key] as? Set<String>)?.toMutableSet() ?: defValues
    override fun getInt(key: String, defValue: Int): Int = values[key] as? Int ?: defValue
    override fun getLong(key: String, defValue: Long): Long = values[key] as? Long ?: defValue
    override fun getFloat(key: String, defValue: Float): Float = values[key] as? Float ?: defValue
    override fun getBoolean(key: String, defValue: Boolean): Boolean = values[key] as? Boolean ?: defValue
    override fun contains(key: String): Boolean = values.containsKey(key)
    override fun edit(): SharedPreferences.Editor = MemoryEditor()
    override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit
    override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit

    private inner class MemoryEditor : SharedPreferences.Editor {
        private val updates = linkedMapOf<String, Any?>()
        private var clearFirst = false

        override fun putString(key: String, value: String?): SharedPreferences.Editor = update(key, value)
        override fun putStringSet(key: String, values: MutableSet<String>?): SharedPreferences.Editor = update(key, values?.toSet())
        override fun putInt(key: String, value: Int): SharedPreferences.Editor = update(key, value)
        override fun putLong(key: String, value: Long): SharedPreferences.Editor = update(key, value)
        override fun putFloat(key: String, value: Float): SharedPreferences.Editor = update(key, value)
        override fun putBoolean(key: String, value: Boolean): SharedPreferences.Editor = update(key, value)
        override fun remove(key: String): SharedPreferences.Editor = update(key, Removed)
        override fun clear(): SharedPreferences.Editor = apply { clearFirst = true }
        override fun commit(): Boolean {
            commitCount += 1
            if (clearFirst) values.clear()
            updates.forEach { (key, value) -> if (value === Removed) values.remove(key) else values[key] = value }
            return true
        }
        override fun apply() { commit() }

        private fun update(key: String, value: Any?): SharedPreferences.Editor = apply { updates[key] = value }
    }

    private data object Removed
}
