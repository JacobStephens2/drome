package day.drome.app.account

import kotlinx.coroutines.test.runTest
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

class AccountRepositoryTest {
    private val server = MockWebServer()
    private val expired = SessionTokens(1L, "old-access", "old-refresh", 0L)

    @Before fun startServer() = server.start()
    @After fun stopServer() = server.shutdown()

    @Test fun transientRefreshFailureDoesNotSignOut() = runTest {
        server.enqueue(
            MockResponse()
                .setResponseCode(500)
                .setBody("""{"error":"internal","message":"internal server error"}"""),
        )
        val store = MemoryStore(expired)
        val token = repo(store).validAccessToken()

        assertNull(token)
        assertEquals(expired, store.session)
    }

    @Test fun rejectedRefreshSignsOutLocally() = runTest {
        server.enqueue(
            MockResponse()
                .setResponseCode(401)
                .setBody("""{"error":"bad_refresh","message":"unknown or expired refresh token"}"""),
        )
        val store = MemoryStore(expired)
        val token = repo(store).validAccessToken()

        assertNull(token)
        assertNull(store.session)
    }

    @Test fun invalidGrantRefreshSignsOutLocally() = runTest {
        server.enqueue(
            MockResponse()
                .setResponseCode(400)
                .setBody("""{"error":"invalid_grant","message":"refresh token rejected"}"""),
        )
        val store = MemoryStore(expired)
        val token = repo(store).validAccessToken()

        assertNull(token)
        assertNull(store.session)
    }

    @Test fun offlineRefreshLeavesTheSession() = runTest {
        server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AT_START))
        val store = MemoryStore(expired)
        val token = repo(store).validAccessToken()

        assertNull(token)
        assertEquals(expired, store.session)
    }

    @Test fun rateLimitedRefreshLeavesTheSession() = runTest {
        server.enqueue(
            MockResponse()
                .setResponseCode(429)
                .setBody("""{"error":"rate_limited","message":"too many requests"}"""),
        )
        val store = MemoryStore(expired)
        val token = repo(store).validAccessToken()

        assertNull(token)
        assertEquals(expired, store.session)
    }

    @Test fun successfulRefreshReplacesTheSession() = runTest {
        server.enqueue(
            MockResponse().setBody(
                """{"account_id":1,"access_token":"new-access","refresh_token":"new-refresh","expires_at_epoch":4102444800}""",
            ),
        )
        val store = MemoryStore(expired)
        val token = repo(store).validAccessToken()

        assertEquals("new-access", token)
        assertEquals(SessionTokens(1L, "new-access", "new-refresh", 4102444800L), store.session)
    }

    @Test fun unexpiredAccessTokenSkipsRefresh() = runTest {
        val live = SessionTokens(1L, "live-access", "live-refresh", Long.MAX_VALUE / 2)
        val store = MemoryStore(live)

        assertEquals("live-access", repo(store).validAccessToken())
        assertEquals(0, server.requestCount)
        assertEquals(live, store.session)
    }

    private fun repo(store: MemoryStore) = AccountRepository(DromeApi(server.url("/").toString()), store)
}

private class MemoryStore(var session: SessionTokens? = null) : SessionStore {
    override suspend fun read() = session
    override suspend fun replace(tokens: SessionTokens) {
        session = tokens
    }
    override suspend fun clear() {
        session = null
    }
}
