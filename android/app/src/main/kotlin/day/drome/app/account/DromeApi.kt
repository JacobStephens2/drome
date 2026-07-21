package day.drome.app.account

import day.drome.core.ActiveChallengeConflict
import day.drome.core.SyncNetworkRequest
import day.drome.core.SyncNetworkResponse
import day.drome.core.SyncTransport
import day.drome.core.WireEvent
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.longOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

class DromeApi(
    private val baseUrl: String,
    private val client: OkHttpClient = OkHttpClient(),
) : SyncTransport {
    private val json = Json { ignoreUnknownKeys = true }
    private val mediaType = "application/json".toMediaType()

    suspend fun requestEmailCode(email: String) {
        post("v1/auth/email/request", buildJsonObject { put("email", JsonPrimitive(email)) })
    }

    suspend fun verifyEmailCode(email: String, code: String): SessionTokens = auth(
        "v1/auth/email/verify",
        buildJsonObject { put("email", JsonPrimitive(email)); put("code", JsonPrimitive(code)) },
    )

    suspend fun attachEmail(linkCode: String, email: String, code: String): SessionTokens = auth(
        "v1/account/link",
        buildJsonObject {
            put("link_code", JsonPrimitive(linkCode.trim().uppercase()))
            put("email", JsonPrimitive(email))
            put("code", JsonPrimitive(code))
        },
    )

    suspend fun issueLinkCode(accessToken: String): String =
        post("v1/account/link/code", JsonObject(emptyMap()), accessToken)
            .jsonObject.getValue("link_code").jsonPrimitive.content

    suspend fun refresh(refreshToken: String): SessionTokens = auth(
        "v1/auth/refresh",
        buildJsonObject { put("refresh_token", JsonPrimitive(refreshToken)) },
    )

    override suspend fun exchange(request: SyncNetworkRequest, accessToken: String): SyncNetworkResponse {
        val body = buildJsonObject {
            put("device_id", JsonPrimitive(request.deviceId))
            put("last_server_seq", JsonPrimitive(request.lastServerSeq))
            put("events", buildJsonArray { request.events.forEach { add(it.toJson()) } })
            put("config", json.parseToJsonElement(request.configJson))
        }
        val response = post("v1/sync", body, accessToken).jsonObject
        val conflict = response["active_challenge_conflict"]?.let { raw ->
            if (raw is JsonObject) ActiveChallengeConflict(
                raw.getValue("archived_challenge_id").jsonPrimitive.content,
                raw.getValue("winner_challenge_id").jsonPrimitive.content,
            ) else null
        }
        return SyncNetworkResponse(
            ackedUuids = response.getValue("acked_uuids").jsonArray.map { it.jsonPrimitive.content },
            events = response.getValue("events").jsonArray.map { it.jsonObject.toWireEvent() },
            newLastServerSeq = response.getValue("new_last_server_seq").jsonPrimitive.long,
            more = response["more"]?.jsonPrimitive?.booleanOrNull ?: false,
            configJson = response.getValue("config").toString(),
            conflict = conflict,
        )
    }

    suspend fun get(path: String, accessToken: String): JsonObject = execute(
        Request.Builder().url(url(path)).header("Authorization", "Bearer $accessToken").get().build(),
    ).jsonObject

    suspend fun authedPost(path: String, body: JsonObject, accessToken: String): JsonObject =
        post(path, body, accessToken).jsonObject

    private suspend fun auth(path: String, body: JsonObject): SessionTokens {
        val response = post(path, body).jsonObject
        return SessionTokens(
            accountId = response.getValue("account_id").jsonPrimitive.long,
            accessToken = response.getValue("access_token").jsonPrimitive.content,
            refreshToken = response.getValue("refresh_token").jsonPrimitive.content,
            expiresAtEpoch = response.getValue("expires_at_epoch").jsonPrimitive.long,
        )
    }

    private suspend fun post(path: String, body: JsonObject, token: String? = null) = execute(
        Request.Builder().url(url(path)).apply { if (token != null) header("Authorization", "Bearer $token") }
            .post(body.toString().toRequestBody(mediaType)).build(),
    )

    private suspend fun execute(request: Request) = withContext(Dispatchers.IO) {
        client.newCall(request).execute().use { response ->
            val text = response.body?.string().orEmpty()
            if (!response.isSuccessful) {
                val message = runCatching { json.parseToJsonElement(text).jsonObject["message"]?.jsonPrimitive?.content }.getOrNull()
                error(message ?: "Drome server returned ${response.code}")
            }
            if (text.isBlank()) JsonObject(emptyMap()) else json.parseToJsonElement(text)
        }
    }

    private fun url(path: String) = "${baseUrl.trimEnd('/')}/${path.trimStart('/')}"
}

private fun WireEvent.toJson() = buildJsonObject {
    put("uuid", JsonPrimitive(uuid))
    put("challenge_id", JsonPrimitive(challengeId))
    put("logged_at_epoch", JsonPrimitive(loggedAtEpoch))
    put("tz_offset_secs", JsonPrimitive(tzOffsetSecs))
    effectiveDate?.let { put("effective_date", JsonPrimitive(it)) }
    put("kind", JsonPrimitive(kind))
    put("payload_json", JsonPrimitive(payloadJson))
    put("schema_version", JsonPrimitive(schemaVersion))
}

private fun JsonObject.toWireEvent() = WireEvent(
    uuid = getValue("uuid").jsonPrimitive.content,
    challengeId = getValue("challenge_id").jsonPrimitive.content,
    loggedAtEpoch = getValue("logged_at_epoch").jsonPrimitive.long,
    tzOffsetSecs = getValue("tz_offset_secs").jsonPrimitive.long.toInt(),
    effectiveDate = get("effective_date")?.jsonPrimitive?.contentOrNull,
    kind = getValue("kind").jsonPrimitive.content,
    payloadJson = getValue("payload_json").jsonPrimitive.content,
    schemaVersion = getValue("schema_version").jsonPrimitive.long,
)
