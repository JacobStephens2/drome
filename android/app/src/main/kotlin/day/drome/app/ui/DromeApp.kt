package day.drome.app.ui

import android.content.Intent
import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.result.PickVisualMediaRequest
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import day.drome.app.AppEvent
import day.drome.app.AppUiState
import day.drome.app.AppViewModel
import day.drome.app.DromeActions
import day.drome.core.ChallengeDraft
import day.drome.core.BackfilledDay
import day.drome.core.CoreTasks
import day.drome.core.RulesetKind
import day.drome.core.WaterUnits
import day.drome.app.share.ShareCardRenderer
import day.drome.app.health.HealthConnectImporter
import day.drome.app.health.ImportedWorkout
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.PermissionController
import java.time.Instant
import java.time.temporal.ChronoUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.UUID

private enum class Tab(val label: String, val glyph: String) {
    TODAY("Today", "●"), HISTORY("History", "▦"), GROUPS("Groups", "◎"), SETTINGS("Settings", "⚙")
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DromeApp(model: AppViewModel) {
    val state by model.state.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    var selected by remember { mutableStateOf(Tab.TODAY) }
    var chugAmount by remember { mutableStateOf<Long?>(null) }

    LaunchedEffect(model) {
        model.events.collectLatest { event ->
            when (event) {
                is AppEvent.ChugWarning -> chugAmount = event.check.addMl
                is AppEvent.DayCompleted -> snackbar.showSnackbar("Day complete. Steady work, honestly logged.")
                is AppEvent.Message -> snackbar.showSnackbar(event.text)
            }
        }
    }

    if (chugAmount != null) {
        AlertDialog(
            onDismissRequest = { chugAmount = null },
            title = { Text("That’s a lot at once") },
            text = { Text("Large catch-up pours can be unsafe. Log only what you actually drank, and don’t force water late at night.") },
            confirmButton = {
                TextButton(onClick = {
                    val ml = chugAmount ?: return@TextButton
                    chugAmount = null
                    model.logWater(ml, confirmChug = true)
                }) { Text("Log it honestly") }
            },
            dismissButton = { TextButton(onClick = { chugAmount = null }) { Text("Cancel") } },
        )
    }

    Scaffold(
        topBar = { TopAppBar(title = { Text("DROME", fontWeight = FontWeight.Black) }) },
        snackbarHost = { SnackbarHost(snackbar) },
        bottomBar = {
            if (state.challenge != null) NavigationBar {
                Tab.entries.forEach { tab ->
                    NavigationBarItem(
                        selected = selected == tab,
                        onClick = { selected = tab },
                        icon = { Text(tab.glyph) },
                        label = { Text(tab.label) },
                    )
                }
            }
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            when {
                state.loading -> CircularProgressIndicator(Modifier.align(Alignment.Center))
                state.challenge == null -> OnboardingScreen(model)
                selected == Tab.TODAY -> TodayScreen(state, model)
                selected == Tab.HISTORY -> HistoryScreen(state, model)
                selected == Tab.GROUPS -> GroupsScreen(state, model)
                else -> SettingsScreen(state, model)
            }
            state.error?.let {
                Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.align(Alignment.BottomCenter).padding(16.dp))
            }
        }
    }
}

@Composable
internal fun OnboardingScreen(model: DromeActions) {
    var purist by remember { mutableStateOf(false) }
    var days by remember { mutableStateOf("75") }
    var waterOz by remember { mutableStateOf("128") }
    var book by remember { mutableStateOf("") }
    var diet by remember { mutableStateOf("") }
    var startDate by remember { mutableStateOf(java.time.LocalDate.now().toString()) }
    LazyColumn(contentPadding = PaddingValues(24.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        item {
            Text("Build the streak you can stand behind.", style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Black)
            Text("Everything works locally. An account is optional and only adds sync and groups.")
        }
        item {
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Checkbox(checked = purist, onCheckedChange = { purist = it })
                        Column {
                            Text("Purist rules", fontWeight = FontWeight.Bold)
                            Text("Opt in to rules-as-written. Flexible mode is the default.", style = MaterialTheme.typography.bodySmall)
                        }
                    }
                }
            }
        }
        item { OutlinedTextField(days, { days = it.filter(Char::isDigit) }, label = { Text("Challenge length (days)") }, modifier = Modifier.fillMaxWidth()) }
        item { OutlinedTextField(startDate, { startDate = it }, label = { Text("Start date (YYYY-MM-DD)") }, modifier = Modifier.fillMaxWidth()) }
        item { OutlinedTextField(waterOz, { waterOz = it.filter { c -> c.isDigit() || c == '.' } }, label = { Text("Daily water goal (fl oz)") }, modifier = Modifier.fillMaxWidth()) }
        item { OutlinedTextField(book, { book = it }, label = { Text("Current book") }, modifier = Modifier.fillMaxWidth()) }
        item { OutlinedTextField(diet, { diet = it }, label = { Text("Your diet commitment") }, modifier = Modifier.fillMaxWidth()) }
        item {
            Button(
                onClick = {
                    model.createChallenge(
                        ChallengeDraft(
                            ruleset = if (purist) RulesetKind.PURIST else RulesetKind.FLEXIBLE,
                            startDate = runCatching { java.time.LocalDate.parse(startDate).toString() }.getOrNull(),
                            lengthDays = days.toIntOrNull()?.coerceIn(1, 365) ?: 75,
                            initialWaterGoalMl = WaterUnits.millilitersFromOunces(waterOz.toDoubleOrNull() ?: 128.0),
                            dietDescription = diet,
                            currentBook = book,
                        ),
                    )
                },
                modifier = Modifier.fillMaxWidth().height(52.dp),
            ) { Text("Start challenge") }
        }
        item { Text("No analytics. Photos stay on this device. Export a backup whenever you like.", style = MaterialTheme.typography.bodySmall) }
    }
}

@Composable
internal fun TodayScreen(state: AppUiState, model: DromeActions, choosePhoto: (() -> Unit)? = null) {
    val today = state.today ?: return
    val day = today.day
    var workoutDialog by remember { mutableStateOf(false) }
    var readingDialog by remember { mutableStateOf(false) }
    var photoRef by remember { mutableStateOf<String?>(null) }
    val context = LocalContext.current
    val photoPicker = if (choosePhoto == null) {
        rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
            if (uri != null) {
                val dir = context.filesDir.resolve("photos").also { it.mkdirs() }
                val file = dir.resolve("${UUID.randomUUID()}.jpg")
                context.contentResolver.openInputStream(uri)?.use { input -> file.outputStream().use(input::copyTo) }
                photoRef = file.absolutePath
                model.logPhoto(file.absolutePath)
            }
        }
    } else null

    if (workoutDialog) WorkoutDialog(onDismiss = { workoutDialog = false }) { minutes, outdoor, note ->
        workoutDialog = false
        model.logWorkout(minutes, outdoor, note)
    }
    if (readingDialog) ReadingDialog(state.challenge?.currentBook.orEmpty(), onDismiss = { readingDialog = false }) { book, pages ->
        readingDialog = false
        model.logReading(book, pages)
    }

    LazyColumn(contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            Text("Day ${today.dayIndex} of ${state.challenge?.lengthDays}", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Black)
            if (today.outOfRange) Text("Outside the challenge window", color = MaterialTheme.colorScheme.error)
        }
        item {
            JeromeView(
                fill = if (day.waterGoalMl > 0) day.waterMl.toFloat() / day.waterGoalMl else 0f,
                celebrating = day.coreComplete,
                onPour = { model.logWater(state.presets.firstOrNull()?.ml ?: 473) },
                onCorrect = { model.correctWater(state.presets.firstOrNull()?.ml ?: 473) },
            )
            Text(
                "${WaterUnits.ouncesFromMilliliters(day.waterMl).toInt()} / ${WaterUnits.ouncesFromMilliliters(day.waterGoalMl).toInt()} fl oz",
                modifier = Modifier.fillMaxWidth(), textAlign = TextAlign.Center, fontWeight = FontWeight.Bold,
            )
            if (today.water.discourageCatchUp) Text("Don’t force a late catch-up. Continue safely tomorrow.", color = MaterialTheme.colorScheme.error)
        }
        item {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                state.presets.take(3).forEach { preset ->
                    FilledTonalButton(onClick = { model.logWater(preset.ml) }, modifier = Modifier.weight(1f)) { Text("+${WaterUnits.ouncesFromMilliliters(preset.ml).toInt()} oz") }
                }
            }
        }
        item { TaskCard("Outdoor workout", day.outdoorWorkoutDone, "${day.workouts.count { it.outdoor }} logged") { workoutDialog = true } }
        item { TaskCard("Second workout", day.secondWorkoutDone, "${day.workouts.size} total") { workoutDialog = true } }
        item { TaskCard("Reading", day.readingDone, "${day.readingPages} pages") { if (day.readingDone && day.revocable.reading) model.revokeTask(CoreTasks.Reading) else readingDialog = true } }
        item { TaskCard("Followed my diet", day.dietDone, state.challenge?.dietDescription ?: "Your commitment") { if (day.dietDone && day.revocable.diet) model.revokeTask(CoreTasks.Diet) else if (!day.dietDone) model.logDiet() } }
        item { TaskCard("No junk food or alcohol", day.noJunkDone, "Honest daily attestation") { if (day.noJunkDone && day.revocable.noJunk) model.revokeTask(CoreTasks.NoJunk) else if (!day.noJunkDone) model.logNoJunk() } }
        item {
            TaskCard("Progress photo", day.photoDone, if (photoRef != null) "Attached on-device" else "Never synced or shared") {
                if (day.photoDone && day.revocable.photo) model.revokeTask(CoreTasks.Photo)
                else if (choosePhoto != null) choosePhoto()
                else photoPicker?.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
            }
        }
        items(today.weekExtras) { extra ->
            TaskCard(extra.name, extra.done, if (extra.done) "Done this week" else "Weekly extra") {
                if (extra.done && day.revocable.extraIds.contains(extra.extraId)) model.revokeTask(CoreTasks.extra(extra.extraId))
                else if (!extra.done) model.logExtra(extra.extraId)
            }
        }
        item { Spacer(Modifier.height(12.dp)) }
    }
}

@Composable
private fun TaskCard(title: String, done: Boolean, detail: String, action: () -> Unit) {
    Card(onClick = action, modifier = Modifier.fillMaxWidth()) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(if (done) "✓" else "○", style = MaterialTheme.typography.headlineSmall, color = if (done) MaterialTheme.colorScheme.tertiary else MaterialTheme.colorScheme.onSurface)
            Column(Modifier.padding(start = 14.dp).weight(1f)) {
                Text(title, fontWeight = FontWeight.Bold)
                Text(detail, style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

@Composable
private fun WorkoutDialog(onDismiss: () -> Unit, onLog: (Int, Boolean, String?) -> Unit) {
    var minutes by remember { mutableStateOf("45") }
    var outdoor by remember { mutableStateOf(true) }
    var note by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Log workout") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(minutes, { minutes = it.filter(Char::isDigit) }, label = { Text("Minutes") })
                OutlinedTextField(note, { note = it }, label = { Text("Optional note") })
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(outdoor, { outdoor = it })
                    Text("Outdoors")
                }
            }
        },
        confirmButton = { Button(onClick = { onLog(minutes.toIntOrNull()?.coerceAtLeast(1) ?: 45, outdoor, note.ifBlank { null }) }) { Text("Log") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun ReadingDialog(initialBook: String, onDismiss: () -> Unit, onLog: (String, Int) -> Unit) {
    var book by remember { mutableStateOf(initialBook) }
    var pages by remember { mutableStateOf("10") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Log reading") },
        text = { Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(book, { book = it }, label = { Text("Book") })
            OutlinedTextField(pages, { pages = it.filter(Char::isDigit) }, label = { Text("Pages") })
        } },
        confirmButton = { Button(onClick = { onLog(book.ifBlank { "Untitled" }, pages.toIntOrNull()?.coerceAtLeast(1) ?: 10) }) { Text("Log") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
internal fun HistoryScreen(state: AppUiState, model: DromeActions) {
    val summary = state.summary ?: return
    var backfill by remember { mutableStateOf(false) }
    if (backfill) BackfillDialog(onDismiss = { backfill = false }) { day -> backfill = false; model.backfill(day) }
    LazyColumn(contentPadding = PaddingValues(24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item { Text("History", style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Black) }
        item { MetricCard("Days complete", "${summary.daysCompleteCount} / ${summary.lengthDays}") }
        item { MetricCard("Current run", "${summary.currentRun} days") }
        item { MetricCard("Workouts", "${summary.totalWorkouts} (${summary.totalOutdoorWorkouts} outdoors)") }
        item { MetricCard("Pages", summary.totalPages.toString()) }
        item { MetricCard("Water", "${WaterUnits.ouncesFromMilliliters(summary.totalWaterMl).toInt()} fl oz") }
        item { OutlinedButton(onClick = { backfill = true }, modifier = Modifier.fillMaxWidth()) { Text("Backfill an earlier day…") } }
        items(state.history) { day ->
            Card(Modifier.fillMaxWidth()) { Row(Modifier.padding(14.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                Text("Day ${day.dayIndex} • ${day.date}")
                Text(if (day.coreComplete) "✓" else if (day.isClosed) "miss" else "open", fontWeight = FontWeight.Bold)
            } }
        }
        item { Text("Every status above is a Rust projection; Android computes no streak or day-boundary logic.", style = MaterialTheme.typography.bodySmall) }
    }
}

@Composable
private fun BackfillDialog(onDismiss: () -> Unit, onSave: (BackfilledDay) -> Unit) {
    var date by remember { mutableStateOf(java.time.LocalDate.now().minusDays(1).toString()) }
    var water by remember { mutableStateOf(false) }
    var outdoor by remember { mutableStateOf(false) }
    var second by remember { mutableStateOf(false) }
    var reading by remember { mutableStateOf(false) }
    var diet by remember { mutableStateOf(false) }
    var noJunk by remember { mutableStateOf(false) }
    var photo by remember { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Backfill honestly") },
        text = { Column {
            OutlinedTextField(date, { date = it }, label = { Text("Date") })
            listOf(
                "Water" to water, "Outdoor workout" to outdoor, "Second workout" to second,
                "Reading" to reading, "Diet" to diet, "No junk or alcohol" to noJunk, "Photo" to photo,
            ).forEachIndexed { index, item -> Row(verticalAlignment = Alignment.CenterVertically) {
                Checkbox(item.second, { checked -> when (index) {
                    0 -> water = checked; 1 -> outdoor = checked; 2 -> second = checked; 3 -> reading = checked
                    4 -> diet = checked; 5 -> noJunk = checked; else -> photo = checked
                } })
                Text(item.first)
            } }
            Text("Backfilled days are labeled; they are never disguised as live logs.", style = MaterialTheme.typography.bodySmall)
        } },
        confirmButton = { Button(onClick = { onSave(BackfilledDay(date, water, outdoor, second, reading, diet, noJunk, photo, emptyList())) }) { Text("Save") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable private fun MetricCard(label: String, value: String) {
    Card(Modifier.fillMaxWidth()) { Row(Modifier.padding(18.dp), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label); Text(value, fontWeight = FontWeight.Black)
    } }
}

@Composable
internal fun GroupsScreen(state: AppUiState, model: DromeActions) {
    var email by remember { mutableStateOf("") }
    var code by remember { mutableStateOf("") }
    var groupName by remember { mutableStateOf("") }
    var displayName by remember { mutableStateOf("") }
    var inviteCode by remember { mutableStateOf("") }
    var accountLinkCode by remember { mutableStateOf("") }
    LaunchedEffect(state.accountId) { if (state.accountId != null) model.refreshGroups() }
    LazyColumn(contentPadding = PaddingValues(24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item { Text("Friend groups", style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Black) }
        if (state.accountId == null) {
            item { Text("Sign in with email to sync across devices, create or join groups, and send a supportive nudge.") }
            item { OutlinedTextField(email, { email = it }, label = { Text("Email") }, modifier = Modifier.fillMaxWidth()) }
            if (state.codeRequestedFor == null) {
                item { Button(onClick = { model.requestEmailCode(email) }, enabled = email.contains('@'), modifier = Modifier.fillMaxWidth()) { Text("Email me a code") } }
            } else {
                item { OutlinedTextField(code, { code = it.filter(Char::isDigit).take(6) }, label = { Text("Six-digit code") }, modifier = Modifier.fillMaxWidth()) }
                item { OutlinedTextField(accountLinkCode, { accountLinkCode = it.uppercase() }, label = { Text("Link code from iPhone (optional)") }, supportingText = { Text("Use this before creating a second account.") }, modifier = Modifier.fillMaxWidth()) }
                item { Button(onClick = { model.verifyEmailCode(state.codeRequestedFor, code, accountLinkCode.ifBlank { null }) }, enabled = code.length == 6, modifier = Modifier.fillMaxWidth()) { Text(if (accountLinkCode.isBlank()) "Verify and sync" else "Attach and sync") } }
                item { TextButton(onClick = { model.requestEmailCode(state.codeRequestedFor) }) { Text("Resend code") } }
            }
            item { Text("Drome remains fully functional without an account.", style = MaterialTheme.typography.bodySmall) }
        } else {
            item { Text("Signed in • sync is opportunistic after every log") }
            items(state.nudges) { nudge ->
                Card(Modifier.fillMaxWidth()) { Text("${nudge.fromDisplayName} sent support in ${nudge.groupName}", Modifier.padding(14.dp)) }
            }
            item { OutlinedButton(onClick = model::issueAccountLinkCode, modifier = Modifier.fillMaxWidth()) { Text("Link another device…") } }
            state.accountLinkCode?.let { link -> item {
                Card(Modifier.fillMaxWidth()) { Column(Modifier.padding(16.dp)) {
                    Text("Link code", fontWeight = FontWeight.Bold)
                    Text(link, style = MaterialTheme.typography.headlineSmall)
                    Text("Single-use; expires in five minutes.", style = MaterialTheme.typography.bodySmall)
                } }
            } }
            items(state.groups) { group ->
                Card(onClick = { model.openGroup(group.id) }, modifier = Modifier.fillMaxWidth()) { Column(Modifier.padding(16.dp)) {
                    Text(group.name, fontWeight = FontWeight.Bold)
                    Text("${group.memberCount} members • invite ${group.inviteCode}")
                    group.myDisplayName?.let { Text("You appear as $it", style = MaterialTheme.typography.bodySmall) }
                } }
            }
            state.selectedGroup?.let { group ->
                item {
                    Card(Modifier.fillMaxWidth()) { Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(group.name, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Black)
                        Text("Invite ${group.inviteCode}")
                        group.members.forEach { member ->
                            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                                Column(Modifier.weight(1f)) {
                                    Text(member.displayName + if (member.isSelf) " (you)" else "", fontWeight = FontWeight.Bold)
                                    Text(if (member.isActive) "Day ${member.dayIndex} • ${member.tasksDone}/7 tasks • ${member.currentRun}-day run" else "No active challenge", style = MaterialTheme.typography.bodySmall)
                                }
                                if (!member.isSelf) TextButton(onClick = { model.nudge(group.id, member.handle) }) { Text("Nudge") }
                            }
                        }
                        TextButton(onClick = { model.leaveGroup(group.id) }) { Text("Leave group", color = MaterialTheme.colorScheme.error) }
                    } }
                }
            }
            item { HorizontalDivider() }
            item { OutlinedTextField(displayName, { displayName = it }, label = { Text("Your group display name") }, modifier = Modifier.fillMaxWidth()) }
            item { OutlinedTextField(groupName, { groupName = it }, label = { Text("New group name") }, modifier = Modifier.fillMaxWidth()) }
            item { Button(onClick = { model.createGroup(groupName, displayName); groupName = "" }, enabled = groupName.isNotBlank() && displayName.isNotBlank(), modifier = Modifier.fillMaxWidth()) { Text("Create group") } }
            item { OutlinedTextField(inviteCode, { inviteCode = it.uppercase() }, label = { Text("Invite code") }, modifier = Modifier.fillMaxWidth()) }
            item { OutlinedButton(onClick = { model.joinGroup(inviteCode, displayName); inviteCode = "" }, enabled = inviteCode.isNotBlank() && displayName.isNotBlank(), modifier = Modifier.fillMaxWidth()) { Text("Join group") } }
            item { TextButton(onClick = model::signOut) { Text("Sign out") } }
        }
    }
}

@Composable
internal fun SettingsScreen(
    state: AppUiState,
    model: DromeActions,
    enableSystemLaunchers: Boolean = true,
    healthAvailableOverride: Boolean? = null,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var pendingExport by remember { mutableStateOf<String?>(null) }
    var confirmReset by remember { mutableStateOf(false) }
    val health = remember { HealthConnectImporter(context) }
    var healthCandidate by remember { mutableStateOf<ImportedWorkout?>(null) }
    val healthPermissions = if (enableSystemLaunchers) rememberLauncherForActivityResult(PermissionController.createRequestPermissionResultContract()) { } else null
    val notifications = if (enableSystemLaunchers) rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { } else null
    val createDocument = if (enableSystemLaunchers) rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { uri ->
        val text = pendingExport
        if (uri != null && text != null) context.contentResolver.openOutputStream(uri)?.bufferedWriter()?.use { it.write(text) }
        pendingExport = null
    } else null
    val openDocument = if (enableSystemLaunchers) rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) scope.launch {
            val text = withContext(Dispatchers.IO) { context.contentResolver.openInputStream(uri)?.bufferedReader()?.use { it.readText() } }
            if (text != null) model.importJson(text)
        }
    } else null
    if (confirmReset) AlertDialog(
        onDismissRequest = { confirmReset = false },
        title = { Text("Reset all local data?") },
        text = { Text("This permanently removes the active challenge and ${state.summary?.todayRawDayIndex ?: 0} days of local history. Export a backup first.") },
        confirmButton = { TextButton(onClick = { confirmReset = false; model.resetAllData() }) { Text("Reset", color = MaterialTheme.colorScheme.error) } },
        dismissButton = { TextButton(onClick = { confirmReset = false }) { Text("Cancel") } },
    )
    healthCandidate?.let { candidate ->
        var outdoor by remember(candidate.healthConnectId) { mutableStateOf(candidate.outdoorGuess) }
        AlertDialog(
            onDismissRequest = { healthCandidate = null },
            title = { Text("Import workout?") },
            text = { Column {
                Text("${candidate.title ?: "Health Connect workout"} • ${candidate.durationMinutes} minutes")
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(outdoor, { outdoor = it })
                    Text("Count as outdoors")
                }
                Text("Confirm this guess before it reaches your challenge.", style = MaterialTheme.typography.bodySmall)
            } },
            confirmButton = { Button(onClick = {
                model.logWorkout(candidate.durationMinutes, outdoor, "Imported from Health Connect")
                healthCandidate = null
            }) { Text("Import") } },
            dismissButton = { TextButton(onClick = { healthCandidate = null }) { Text("Cancel") } },
        )
    }
    LazyColumn(contentPadding = PaddingValues(24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item { Text("Settings", style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Black) }
        item { Text("Data safety", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold) }
        item { Button(onClick = { scope.launch { ShareCardRenderer.share(context, model.shareCard()) } }, modifier = Modifier.fillMaxWidth()) { Text("Share today’s card…") } }
        item { OutlinedButton(onClick = { scope.launch { pendingExport = model.exportJson(); createDocument?.launch("drome-backup.json") } }, modifier = Modifier.fillMaxWidth()) { Text("Export backup…") } }
        item { OutlinedButton(onClick = { openDocument?.launch(arrayOf("application/json", "text/json", "text/plain")) }, modifier = Modifier.fillMaxWidth()) { Text("Restore backup…") } }
        item { HorizontalDivider() }
        item { Text("Reminders & Health Connect", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold) }
        if (Build.VERSION.SDK_INT >= 33) item {
            OutlinedButton(onClick = { notifications?.launch(Manifest.permission.POST_NOTIFICATIONS) }, modifier = Modifier.fillMaxWidth()) { Text("Allow challenge reminders") }
        }
        if (healthAvailableOverride ?: (health.availability() == HealthConnectClient.SDK_AVAILABLE)) {
            item { OutlinedButton(onClick = { healthPermissions?.launch(setOf(health.permission)) }, modifier = Modifier.fillMaxWidth()) { Text("Allow workout import") } }
            item { OutlinedButton(onClick = { scope.launch {
                if (!health.hasPermission()) healthPermissions?.launch(setOf(health.permission))
                else healthCandidate = health.workoutsSince(Instant.now().minus(7, ChronoUnit.DAYS)).firstOrNull()
            } }, modifier = Modifier.fillMaxWidth()) { Text("Import latest workout…") } }
        } else item { Text("Health Connect is not available on this device.", style = MaterialTheme.typography.bodySmall) }
        item { HorizontalDivider() }
        item { Text("Challenge", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold) }
        item { Text("Mode: ${state.challenge?.ruleset?.name?.lowercase()?.replaceFirstChar(Char::uppercase)}") }
        item { Text("Start: ${state.challenge?.startDate}") }
        item { OutlinedButton(onClick = { confirmReset = true }, modifier = Modifier.fillMaxWidth()) { Text("Start over", color = MaterialTheme.colorScheme.error) } }
        item { HorizontalDivider() }
        item { Text("Privacy", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold) }
        item { Text("No analytics. Local photos are never synced. Android system backup excludes Drome’s database, sync cursors, and tokens; use Export backup for portable recovery.") }
    }
}
