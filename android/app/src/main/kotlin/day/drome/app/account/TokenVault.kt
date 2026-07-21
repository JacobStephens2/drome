package day.drome.app.account

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

data class SessionTokens(
    val accountId: Long,
    val accessToken: String,
    val refreshToken: String,
    val expiresAtEpoch: Long,
)

/** Direct Keystore + AES/GCM storage; no deprecated security-crypto wrapper. */
class TokenVault(context: Context) {
    private val file = File(context.noBackupFilesDir, "session.v1")
    private val gate = Mutex()
    private val alias = "day.drome.app.session.v1"

    suspend fun read(): SessionTokens? = gate.withLock { readUnlocked() }

    suspend fun replace(tokens: SessionTokens) = gate.withLock {
        val json = JSONObject()
            .put("account_id", tokens.accountId)
            .put("access_token", tokens.accessToken)
            .put("refresh_token", tokens.refreshToken)
            .put("expires_at_epoch", tokens.expiresAtEpoch)
            .toString()
            .toByteArray()
        try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key())
            val sealed = cipher.iv + cipher.doFinal(json)
            val temp = File(file.parentFile, "${file.name}.tmp")
            temp.writeBytes(sealed)
            if (!temp.renameTo(file)) {
                file.delete()
                check(temp.renameTo(file)) { "could not atomically replace session" }
            }
        } catch (error: Exception) {
            cleanSignOutUnlocked()
            throw error
        }
    }

    suspend fun clear() = gate.withLock { cleanSignOutUnlocked() }

    private fun readUnlocked(): SessionTokens? {
        if (!file.exists()) return null
        return try {
            val sealed = file.readBytes()
            if (sealed.size <= 12) error("invalid session envelope")
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, sealed.copyOfRange(0, 12)))
            val json = JSONObject(String(cipher.doFinal(sealed.copyOfRange(12, sealed.size))))
            SessionTokens(
                accountId = json.getLong("account_id"),
                accessToken = json.getString("access_token"),
                refreshToken = json.getString("refresh_token"),
                expiresAtEpoch = json.getLong("expires_at_epoch"),
            )
        } catch (_: Exception) {
            // Device transfer, biometric/key invalidation, or a damaged envelope is a sign-out only.
            cleanSignOutUnlocked()
            null
        }
    }

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(
                KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setRandomizedEncryptionRequired(true)
                    .build(),
            )
            generateKey()
        }
    }

    private fun cleanSignOutUnlocked() {
        file.delete()
    }
}
