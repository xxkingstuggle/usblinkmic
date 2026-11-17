package com.zjx.usblinkmic.support

import java.math.BigInteger
import java.security.*
import java.security.interfaces.ECPrivateKey
import java.security.interfaces.ECPublicKey
import java.security.spec.*
import java.util.Base64
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

object WifiCrypto {
    fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }

    fun bytes(fromHex: String): ByteArray? {
        val trimmed = fromHex.trim()
        if (trimmed.length % 2 != 0 || trimmed.isEmpty()) return null
        return try {
            ByteArray(trimmed.length / 2) { i ->
                trimmed.substring(i * 2, i * 2 + 2).toInt(16).toByte()
            }
        } catch (_: Exception) {
            null
        }
    }

    fun randomHex(byteCount: Int = 16): String {
        val bytes = ByteArray(byteCount)
        SecureRandom().nextBytes(bytes)
        return hex(bytes)
    }

    fun hmacHex(key: ByteArray, message: String): String {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return hex(mac.doFinal(message.toByteArray(Charsets.UTF_8)))
    }

    fun equal(a: String, b: String): Boolean {
        return MessageDigest.isEqual(a.toByteArray(Charsets.UTF_8), b.toByteArray(Charsets.UTF_8))
    }

    class PairingKeys {
        val keyPair: KeyPair
        val publicBase64: String

        init {
            val kpg = KeyPairGenerator.getInstance("EC")
            kpg.initialize(ECGenParameterSpec("secp256r1"))
            keyPair = kpg.generateKeyPair()
            val pub = keyPair.public as ECPublicKey
            publicBase64 = Base64.getEncoder().encodeToString(x963Representation(pub))
        }
    }

    private fun x963Representation(pub: ECPublicKey): ByteArray {
        val point = pub.w
        val xBytes = toFixedByteArray(point.affineX, 32)
        val yBytes = toFixedByteArray(point.affineY, 32)
        val result = ByteArray(65)
        result[0] = 0x04
        System.arraycopy(xBytes, 0, result, 1, 32)
        System.arraycopy(yBytes, 0, result, 33, 32)
        return result
    }

    private fun toFixedByteArray(bi: BigInteger, length: Int): ByteArray {
        val raw = bi.toByteArray()
        val result = ByteArray(length)
        if (raw.size >= length) {
            System.arraycopy(raw, raw.size - length, result, 0, length)
        } else {
            System.arraycopy(raw, 0, result, length - raw.size, raw.size)
        }
        return result
    }

    private fun publicKeyFromX963(raw: ByteArray): PublicKey {
        require(raw.size == 65 && raw[0] == 0x04.toByte()) { "Invalid X9.63 public key" }
        val x = BigInteger(1, raw.copyOfRange(1, 33))
        val y = BigInteger(1, raw.copyOfRange(33, 65))
        val point = ECPoint(x, y)

        val kpg = KeyPairGenerator.getInstance("EC")
        kpg.initialize(ECGenParameterSpec("secp256r1"))
        val dummy = kpg.generateKeyPair().public as ECPublicKey
        val spec = ECPublicKeySpec(point, dummy.params)
        return KeyFactory.getInstance("EC").generatePublic(spec)
    }

    fun pairingKey(
        privateKey: PrivateKey,
        peerPublicBase64: String,
        macID: String,
        phoneID: String,
        clientNonce: String,
        serverNonce: String,
        phonePublicBase64: String,
        macPublicBase64: String
    ): ByteArray? {
        return try {
            val peerRaw = Base64.getDecoder().decode(peerPublicBase64)
            val peerKey = publicKeyFromX963(peerRaw)
            val agreement = KeyAgreement.getInstance("ECDH")
            agreement.init(privateKey)
            agreement.doPhase(peerKey, true)
            val secret = agreement.generateSecret()

            val transcript = "usblinkmic-wifi-pair-v1|$macID|$phoneID|$clientNonce|$serverNonce|$phonePublicBase64|$macPublicBase64"
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(secret, "HmacSHA256"))
            mac.doFinal(transcript.toByteArray(Charsets.UTF_8))
        } catch (_: Exception) {
            null
        }
    }

    fun verificationCode(pairingKey: ByteArray): String {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(pairingKey, "HmacSHA256"))
        val digest = mac.doFinal("sas".toByteArray(Charsets.UTF_8))
        var value = 0L
        for (i in 0 until 4) {
            value = (value shl 8) or ((digest[i].toInt() and 0xFF).toLong())
        }
        val code = (value % 1_000_000L).toInt()
        return "%06d".format(code)
    }

    fun pairApprovedProof(pairingKey: ByteArray, requestID: String, macID: String, phoneID: String): String {
        return hmacHex(pairingKey, "pair-approved|$requestID|$macID|$phoneID")
    }

    fun authProof(key: ByteArray, fromServer: Boolean, macID: String, phoneID: String, clientNonce: String, serverNonce: String): String {
        return hmacHex(key, "${if (fromServer) "auth-s" else "auth-c"}|$macID|$phoneID|$clientNonce|$serverNonce")
    }

    fun messageMAC(key: ByteArray, direction: String, clientNonce: String, serverNonce: String, sequence: Int, command: String, fields: String): String {
        return hmacHex(key, "msg|$direction|$clientNonce|$serverNonce|$sequence|$command|$fields")
    }

    fun audioToken(key: ByteArray, sessionID: String, clientNonce: String, serverNonce: String): String {
        return hmacHex(key, "audio|$sessionID|$clientNonce|$serverNonce")
    }
}
