package day.drome.app.ui

import app.cash.paparazzi.DeviceConfig
import app.cash.paparazzi.Paparazzi
import com.android.resources.NightMode
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import day.drome.app.AppUiState
import day.drome.app.DromeActions
import day.drome.app.DromeTheme
import day.drome.app.account.GroupDetail
import day.drome.app.account.GroupMember
import day.drome.app.account.GroupSummary
import day.drome.app.account.PendingNudge
import day.drome.core.MockDromeCore
import kotlinx.coroutines.runBlocking
import org.junit.Rule
import org.junit.Test

abstract class DromeScreensSnapshotContract(nightMode: NightMode) {
    @get:Rule
    val paparazzi = Paparazzi(
        deviceConfig = DeviceConfig.PIXEL_5.copy(nightMode = nightMode),
        showSystemUi = false,
    )

    private val actions = object : DromeActions {}
    private val fixture = runBlocking {
        val core = MockDromeCore()
        AppUiState(
            loading = false,
            challenge = core.activeChallenge(),
            today = core.today(),
            summary = core.summary(),
            presets = core.containerPresets(),
            history = core.calendar("2026-06-21", "2026-07-04"),
        )
    }

    @Test fun onboarding() = snapshot { OnboardingScreen(actions) }

    @Test fun today() = snapshot { TodayScreen(fixture, actions, choosePhoto = {}) }

    @Test fun history() = snapshot { HistoryScreen(fixture, actions) }

    @Test fun groupsSignedOut() = snapshot { GroupsScreen(fixture, actions) }

    @Test fun groupsSignedIn() = snapshot {
        GroupsScreen(
            fixture.copy(
                accountId = 42,
                groups = listOf(GroupSummary("trail", "Sunday Crew", "CAMEL7", "Sarah", 2)),
                nudges = listOf(PendingNudge("Maya", "Sunday Crew")),
                selectedGroup = GroupDetail(
                    "trail",
                    "Sunday Crew",
                    "CAMEL7",
                    listOf(
                        GroupMember("self", "Sarah", true, true, 14, 12, 4),
                        GroupMember("maya", "Maya", false, true, 11, 8, 6),
                    ),
                ),
            ),
            actions,
        )
    }

    @Test fun settings() = snapshot {
        SettingsScreen(fixture, actions, enableSystemLaunchers = false, healthAvailableOverride = false)
    }

    private fun snapshot(content: @androidx.compose.runtime.Composable () -> Unit) {
        paparazzi.snapshot {
            DromeTheme {
                Surface(Modifier.fillMaxSize(), content = content)
            }
        }
    }
}

class DromeScreensLightSnapshotTest : DromeScreensSnapshotContract(NightMode.NOTNIGHT)

class DromeScreensDarkSnapshotTest : DromeScreensSnapshotContract(NightMode.NIGHT)
