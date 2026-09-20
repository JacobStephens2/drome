package day.drome.app.account

import day.drome.core.AccessTokenProvider
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.time.Instant

class AccountRepository(
    private val api: DromeApi,
    private val vault: SessionStore,
) : AccessTokenProvider {
    private val refreshGate = Mutex()

    suspend fun current(): SessionTokens? = vault.read()

    suspend fun requestCode(email: String) = api.requestEmailCode(email.trim())

    suspend fun verify(email: String, code: String): SessionTokens {
        val session = api.verifyEmailCode(email.trim(), code.trim())
        vault.replace(session)
        return session
    }

    suspend fun attach(linkCode: String, email: String, code: String): SessionTokens {
        val session = api.attachEmail(linkCode, email.trim(), code.trim())
        vault.replace(session)
        return session
    }

    suspend fun issueLinkCode(): String =
        api.issueLinkCode(checkNotNull(validAccessToken()) { "Sign in before issuing a link code" })

    override suspend fun validAccessToken(): String? = refreshGate.withLock {
        val current = vault.read() ?: return@withLock null
        if (current.expiresAtEpoch > Instant.now().epochSecond + 60) return@withLock current.accessToken
        try {
            val rotated = api.refresh(current.refreshToken)
            vault.replace(rotated)
            rotated.accessToken
        } catch (error: CancellationException) {
            throw error
        } catch (error: DromeApiException.Unauthorized) {
            vault.clear()
            null
        } catch (_: Exception) {
            null
        }
    }

    suspend fun signOut() = vault.clear()
}
