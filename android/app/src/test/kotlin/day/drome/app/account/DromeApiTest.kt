package day.drome.app.account

import kotlinx.coroutines.test.runTest
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class DromeApiTest {
    private val server = MockWebServer()

    @Before fun startServer() = server.start()
    @After fun stopServer() = server.shutdown()

    @Test fun refresh401IsUnauthorized() = runTest {
        server.enqueue(
            MockResponse()
                .setResponseCode(401)
                .setBody("""{"error":"bad_refresh","message":"unknown or expired refresh token"}"""),
        )
        val error = runCatching { api().refresh("tok") }.exceptionOrNull()
        val unauthorized = error as DromeApiException.Unauthorized
        assertEquals("bad_refresh", unauthorized.code)
        assertEquals("unknown or expired refresh token", unauthorized.message)
    }

    @Test fun refresh500IsServer() = runTest {
        server.enqueue(
            MockResponse()
                .setResponseCode(500)
                .setBody("""{"error":"internal","message":"internal server error"}"""),
        )
        val error = runCatching { api().refresh("tok") }.exceptionOrNull()
        assertTrue(error is DromeApiException.Server)
        assertEquals(500, (error as DromeApiException.Server).status)
    }

    @Test fun refreshDisconnectIsOffline() = runTest {
        server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AT_START))
        val error = runCatching { api().refresh("tok") }.exceptionOrNull()
        assertTrue(error is DromeApiException.Offline)
    }

    private fun api() = DromeApi(server.url("/").toString())
}
