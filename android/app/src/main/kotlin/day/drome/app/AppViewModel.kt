package day.drome.app

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import day.drome.core.Challenge
import day.drome.core.ChallengeDraft
import day.drome.core.ChallengeSummary
import day.drome.core.ChugCheck
import day.drome.core.ContainerPreset
import day.drome.core.DayBrief
import day.drome.core.BackfilledDay
import day.drome.core.RevocableTask
import day.drome.core.DromeCoreClient
import day.drome.core.LogResult
import day.drome.core.ShareCardData
import day.drome.core.TodayState
import day.drome.app.account.AccountRepository
import day.drome.app.account.DromeApi
import day.drome.app.account.GroupSummary
import day.drome.app.account.GroupsRepository
import day.drome.app.account.GroupDetail
import day.drome.app.account.PendingNudge
import day.drome.app.account.TokenVault
import day.drome.core.SyncEngine
import day.drome.app.reminders.ReminderScheduler
import day.drome.app.widget.DromeWidget
import androidx.glance.appwidget.updateAll
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

data class AppUiState(
    val loading: Boolean = true,
    val challenge: Challenge? = null,
    val today: TodayState? = null,
    val summary: ChallengeSummary? = null,
    val presets: List<ContainerPreset> = emptyList(),
    val history: List<DayBrief> = emptyList(),
    val accountId: Long? = null,
    val codeRequestedFor: String? = null,
    val groups: List<GroupSummary> = emptyList(),
    val accountLinkCode: String? = null,
    val selectedGroup: GroupDetail? = null,
    val nudges: List<PendingNudge> = emptyList(),
    val error: String? = null,
)

sealed interface AppEvent {
    data class DayCompleted(val date: String) : AppEvent
    data class ChugWarning(val check: ChugCheck) : AppEvent
    data class Message(val text: String) : AppEvent
}

/** UI command surface kept independent from Android lifecycle state for previews and snapshots. */
interface DromeActions {
    fun createChallenge(draft: ChallengeDraft): Any? = null
    fun logWater(ml: Long, confirmChug: Boolean = false): Any? = null
    fun correctWater(ml: Long): Any? = null
    fun logWorkout(minutes: Int, outdoor: Boolean, note: String?): Any? = null
    fun logReading(book: String, pages: Int): Any? = null
    fun logDiet(): Any? = null
    fun logNoJunk(): Any? = null
    fun logPhoto(ref: String?): Any? = null
    fun logExtra(id: String): Any? = null
    fun revokeTask(task: RevocableTask): Any? = null
    fun backfill(day: BackfilledDay): Any? = null
    fun requestEmailCode(email: String): Any? = null
    fun verifyEmailCode(email: String, code: String, linkCode: String? = null): Any? = null
    fun refreshGroups(): Any? = null
    fun createGroup(name: String, displayName: String): Any? = null
    fun joinGroup(code: String, displayName: String): Any? = null
    fun openGroup(id: String): Any? = null
    fun issueAccountLinkCode(): Any? = null
    fun nudge(groupId: String, memberHandle: String): Any? = null
    fun leaveGroup(id: String): Any? = null
    fun signOut(): Any? = null
    suspend fun exportJson(): String = error("Export is unavailable")
    suspend fun shareCard(): ShareCardData = error("Share card is unavailable")
    fun importJson(snapshot: String): Any? = null
    fun resetAllData(): Any? = null
}

class AppViewModel(
    application: Application,
    private val core: DromeCoreClient = DromeCoreProvider.get(application),
) : AndroidViewModel(application), DromeActions {
    private val api = DromeApi("https://drome.day")
    private val account = AccountRepository(api, TokenVault(application))
    private val groups = GroupsRepository(api, account)
    private val sync = SyncEngine(core, api, account)
    private val mutationQueue = Mutex()
    private val _state = MutableStateFlow(AppUiState())
    val state = _state.asStateFlow()
    private val _events = MutableSharedFlow<AppEvent>(extraBufferCapacity = 8)
    val events = _events.asSharedFlow()

    private val errors = CoroutineExceptionHandler { _, throwable ->
        _state.value = _state.value.copy(loading = false, error = throwable.message ?: "Something went wrong")
    }

    init { refresh() }

    fun refresh() = viewModelScope.launch(errors) {
        mutationQueue.withLock { reload() }
    }

    override fun createChallenge(draft: ChallengeDraft) = mutate {
        core.createChallenge(draft)
        _events.emit(AppEvent.Message("Your challenge is ready."))
    }

    override fun logWater(ml: Long, confirmChug: Boolean) = mutate {
        val check = core.checkChug(ml)
        if (check.warn && !confirmChug) {
            _events.emit(AppEvent.ChugWarning(check))
            return@mutate
        }
        publish(core.logWater(ml), suppressChug = confirmChug)
    }

    override fun correctWater(ml: Long) = mutate { publish(core.adjustWater(-ml.coerceAtLeast(1))) }
    override fun logWorkout(minutes: Int, outdoor: Boolean, note: String?) = mutate {
        publish(core.logWorkout(minutes, outdoor, note))
    }
    override fun logReading(book: String, pages: Int) = mutate { publish(core.logReading(book, pages)) }
    override fun logDiet() = mutate { publish(core.logDiet()) }
    override fun logNoJunk() = mutate { publish(core.logNoJunk()) }
    override fun logPhoto(ref: String?) = mutate { publish(core.logPhoto(ref)) }
    override fun logExtra(id: String) = mutate { publish(core.logExtra(id)) }
    override fun revokeTask(task: RevocableTask) = mutate {
        val result = core.revokeTask(checkNotNull(core.today().date), task)
        publish(result)
    }
    override fun backfill(day: BackfilledDay) = mutate { core.backfill(listOf(day)) }
    fun updateWaterGoal(ml: Long) = mutate { core.setWaterGoal(ml) }
    fun updateBook(book: String) = mutate { core.setCurrentBook(book) }
    fun updateDiet(description: String) = mutate { core.setDietDescription(description) }

    override fun requestEmailCode(email: String) = viewModelScope.launch(errors) {
        account.requestCode(email)
        _state.value = _state.value.copy(codeRequestedFor = email.trim())
        _events.emit(AppEvent.Message("Check your email for a six-digit code."))
    }

    override fun verifyEmailCode(email: String, code: String, linkCode: String?) = viewModelScope.launch(errors) {
        val session = if (linkCode.isNullOrBlank()) account.verify(email, code) else account.attach(linkCode, email, code)
        _state.value = _state.value.copy(accountId = session.accountId, codeRequestedFor = null)
        sync.syncNow("account:${session.accountId}")
        refreshGroups()
        mutationQueue.withLock { reload() }
    }

    override fun issueAccountLinkCode() = viewModelScope.launch(errors) {
        _state.value = _state.value.copy(accountLinkCode = account.issueLinkCode())
    }

    override fun signOut() = viewModelScope.launch(errors) {
        account.signOut()
        _state.value = _state.value.copy(accountId = null, groups = emptyList(), codeRequestedFor = null)
    }

    override fun refreshGroups() = viewModelScope.launch(errors) {
        if (account.current() == null) return@launch
        _state.value = _state.value.copy(groups = groups.list(), nudges = groups.pendingNudges())
    }

    override fun createGroup(name: String, displayName: String) = viewModelScope.launch(errors) {
        groups.create(name, displayName)
        _state.value = _state.value.copy(groups = groups.list())
    }

    override fun joinGroup(code: String, displayName: String) = viewModelScope.launch(errors) {
        groups.join(code, displayName)
        _state.value = _state.value.copy(groups = groups.list())
    }

    override fun openGroup(id: String) = viewModelScope.launch(errors) {
        _state.value = _state.value.copy(selectedGroup = groups.detail(id))
    }

    override fun nudge(groupId: String, memberHandle: String) = viewModelScope.launch(errors) {
        groups.nudge(groupId, memberHandle)
        _events.emit(AppEvent.Message("Supportive nudge sent."))
    }

    override fun leaveGroup(id: String) = viewModelScope.launch(errors) {
        groups.leave(id)
        _state.value = _state.value.copy(groups = groups.list(), selectedGroup = null)
    }

    override suspend fun exportJson(): String = mutationQueue.withLock { core.exportJson() }
    suspend fun exportCsv(): String = mutationQueue.withLock { core.exportCsv() }
    override suspend fun shareCard() = mutationQueue.withLock {
        val date = core.today().date
        core.shareCard(date)
    }
    override fun importJson(snapshot: String) = mutate {
        core.importJson(snapshot)
        _events.emit(AppEvent.Message("Backup restored."))
    }
    override fun resetAllData() = mutate {
        core.resetAllData()
        _events.emit(AppEvent.Message("Local data reset."))
    }

    private fun mutate(block: suspend () -> Unit) = viewModelScope.launch(errors) {
        mutationQueue.withLock {
            block()
            reload()
        }
        ReminderScheduler.reschedule(getApplication())
        DromeWidget().updateAll(getApplication())
        account.current()?.let { session -> runCatching { sync.syncNow("account:${session.accountId}") } }
    }

    private suspend fun publish(result: LogResult, suppressChug: Boolean = false) {
        result.revokedPhotoRefs.forEach { ref -> runCatching { java.io.File(ref).delete() } }
        if (!suppressChug) result.chugWarning?.let { _events.emit(AppEvent.ChugWarning(it)) }
        if (result.dayBecameComplete) _events.emit(AppEvent.DayCompleted(result.dayState.date))
    }

    private suspend fun reload() {
        val session = account.current()
        val existing = _state.value
        _state.value = _state.value.copy(loading = true, error = null)
        val challenge = core.activeChallenge()
        _state.value = if (challenge == null) {
            AppUiState(loading = false, accountId = session?.accountId, codeRequestedFor = existing.codeRequestedFor, groups = existing.groups, accountLinkCode = existing.accountLinkCode, selectedGroup = existing.selectedGroup, nudges = existing.nudges)
        } else {
            AppUiState(
                loading = false,
                challenge = challenge,
                today = core.today(),
                summary = core.summary(),
                presets = core.containerPresets(),
                history = core.calendar(
                    challenge.startDate,
                    java.time.LocalDate.parse(challenge.startDate).plusDays(challenge.lengthDays.toLong() - 1).toString(),
                ),
                accountId = session?.accountId,
                codeRequestedFor = existing.codeRequestedFor,
                groups = existing.groups,
                accountLinkCode = existing.accountLinkCode,
                selectedGroup = existing.selectedGroup,
                nudges = existing.nudges,
            )
        }
    }
}
