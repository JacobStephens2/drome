package day.drome.app.account

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

data class GroupSummary(
    val id: String,
    val name: String,
    val inviteCode: String,
    val myDisplayName: String?,
    val memberCount: Int,
)

data class GroupMember(
    val handle: String,
    val displayName: String,
    val isSelf: Boolean,
    val isActive: Boolean,
    val dayIndex: Int?,
    val currentRun: Int?,
    val tasksDone: Int,
)

data class GroupDetail(val id: String, val name: String, val inviteCode: String, val members: List<GroupMember>)
data class PendingNudge(val fromDisplayName: String, val groupName: String)

class GroupsRepository(
    private val api: DromeApi,
    private val account: AccountRepository,
) {
    suspend fun list(): List<GroupSummary> {
        val token = checkNotNull(account.validAccessToken()) { "Sign in to view groups" }
        return api.get("v1/groups", token).getValue("groups").jsonArray.map { raw ->
            val group = raw.jsonObject
            GroupSummary(
                id = group.getValue("id").jsonPrimitive.content,
                name = group.getValue("name").jsonPrimitive.content,
                inviteCode = group.getValue("invite_code").jsonPrimitive.content,
                myDisplayName = group["my_display_name"]?.jsonPrimitive?.contentOrNull,
                memberCount = group.getValue("member_count").jsonPrimitive.int,
            )
        }
    }

    suspend fun create(name: String, displayName: String) {
        val token = checkNotNull(account.validAccessToken()) { "Sign in to create a group" }
        api.authedPost("v1/groups", buildJsonObject {
            put("name", JsonPrimitive(name.trim()))
            put("display_name", JsonPrimitive(displayName.trim()))
        }, token)
    }

    suspend fun join(code: String, displayName: String) {
        val token = checkNotNull(account.validAccessToken()) { "Sign in to join a group" }
        api.authedPost("v1/groups/join", buildJsonObject {
            put("invite_code", JsonPrimitive(code.trim().uppercase()))
            put("display_name", JsonPrimitive(displayName.trim()))
        }, token)
    }

    suspend fun detail(id: String): GroupDetail {
        val token = checkNotNull(account.validAccessToken()) { "Sign in to view a group" }
        val group = api.get("v1/groups/$id", token)
        return GroupDetail(
            id = group.getValue("id").jsonPrimitive.content,
            name = group.getValue("name").jsonPrimitive.content,
            inviteCode = group.getValue("invite_code").jsonPrimitive.content,
            members = group.getValue("members").jsonArray.map { raw ->
                val member = raw.jsonObject
                val tasks = member["tasks"] as? JsonObject
                GroupMember(
                    handle = member.getValue("member_handle").jsonPrimitive.content,
                    displayName = member.getValue("display_name").jsonPrimitive.content,
                    isSelf = member.getValue("is_self").jsonPrimitive.content.toBoolean(),
                    isActive = member.getValue("is_active").jsonPrimitive.content.toBoolean(),
                    dayIndex = member["day_index"]?.jsonPrimitive?.contentOrNull?.toIntOrNull(),
                    currentRun = member["current_run"]?.jsonPrimitive?.contentOrNull?.toIntOrNull(),
                    tasksDone = tasks?.values?.count { it.jsonPrimitive.content.toBoolean() } ?: 0,
                )
            },
        )
    }

    suspend fun nudge(groupId: String, memberHandle: String) {
        val token = checkNotNull(account.validAccessToken()) { "Sign in to nudge" }
        api.authedPost("v1/groups/$groupId/nudge", buildJsonObject {
            put("to_member_handle", JsonPrimitive(memberHandle))
        }, token)
    }

    suspend fun pendingNudges(): List<PendingNudge> {
        val token = checkNotNull(account.validAccessToken()) { "Sign in to view nudges" }
        return api.get("v1/nudges", token).getValue("nudges").jsonArray.map { raw ->
            val nudge = raw.jsonObject
            PendingNudge(
                nudge.getValue("from_display_name").jsonPrimitive.content,
                nudge.getValue("group_name").jsonPrimitive.content,
            )
        }
    }

    suspend fun leave(id: String) {
        val token = checkNotNull(account.validAccessToken()) { "Sign in to leave" }
        api.authedPost("v1/groups/$id/leave", JsonObject(emptyMap()), token)
    }
}
