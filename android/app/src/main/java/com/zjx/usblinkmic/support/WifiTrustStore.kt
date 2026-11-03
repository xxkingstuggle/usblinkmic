package com.zjx.usblinkmic.support

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

data class TrustedMac(
    val id: String,
    val name: String,
    val keyHex: String,
    val pairedAt: Long
)

class WifiTrustStore internal constructor(private val preferences: SharedPreferences) {
    constructor(context: Context) : this(context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE))

    val phoneId: String
        get() {
            var existing = preferences.getString(KEY_PHONE_ID, null)
            if (existing.isNullOrBlank()) {
                existing = UUID.randomUUID().toString().replace("-", "").lowercase()
                preferences.edit().putString(KEY_PHONE_ID, existing).apply()
            }
            return existing
        }

    fun loadTrustedMacs(): List<TrustedMac> {
        val json = preferences.getString(KEY_TRUSTED_MACS, null) ?: return emptyList()
        return try {
            val array = JSONArray(json)
            val list = mutableListOf<TrustedMac>()
            for (i in 0 until array.length()) {
                val obj = array.getJSONObject(i)
                list.add(
                    TrustedMac(
                        id = obj.getString("id"),
                        name = obj.getString("name"),
                        keyHex = obj.getString("keyHex"),
                        pairedAt = obj.optLong("pairedAt", System.currentTimeMillis())
                    )
                )
            }
            list
        } catch (_: Exception) {
            emptyList()
        }
    }

    fun getMac(id: String): TrustedMac? = loadTrustedMacs().firstOrNull { it.id == id }

    @Synchronized
    fun upsert(mac: TrustedMac) {
        val list = loadTrustedMacs().filter { it.id != mac.id }.toMutableList()
        list.add(mac)
        saveList(list)
    }

    @Synchronized
    fun remove(id: String) {
        val list = loadTrustedMacs().filter { it.id != id }
        saveList(list)
    }

    private fun saveList(list: List<TrustedMac>) {
        val array = JSONArray()
        for (item in list) {
            val obj = JSONObject()
                .put("id", item.id)
                .put("name", item.name)
                .put("keyHex", item.keyHex)
                .put("pairedAt", item.pairedAt)
            array.put(obj)
        }
        preferences.edit().putString(KEY_TRUSTED_MACS, array.toString()).apply()
    }

    companion object {
        internal const val PREFERENCES_NAME = "usblinkmic_wifi_trust"
        private const val KEY_PHONE_ID = "phone_id"
        private const val KEY_TRUSTED_MACS = "trusted_macs"
    }
}
