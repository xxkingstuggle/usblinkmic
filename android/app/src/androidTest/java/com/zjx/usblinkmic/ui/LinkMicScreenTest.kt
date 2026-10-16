package com.zjx.usblinkmic.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextReplacement
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.zjx.usblinkmic.contracts.AppSnapshot
import com.zjx.usblinkmic.contracts.ModuleStatus
import com.zjx.usblinkmic.contracts.Settings
import com.zjx.usblinkmic.contracts.TaskPhase
import com.zjx.usblinkmic.contracts.UserAction
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LinkMicScreenTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun rendersSnapshotStagesAndModuleNames() {
        val snapshot = AppSnapshot(
            microphone = ModuleStatus(TaskPhase.WAITING_USER, "等待手机确认", "请在手机上确认", "MIC_PERMISSION"),
            phoneInternet = ModuleStatus(TaskPhase.RUNNING, "出口验证中", "等待实际网络探测"),
            macInternet = ModuleStatus(TaskPhase.FAILED, "隧道失败", "请检查 Mac 网络", "TUNNEL_FAILED"),
            settings = Settings(wifiHost = "192.168.1.10"),
        )
        composeRule.setContent {
            MaterialTheme {
                LinkMicScreen(snapshot = snapshot, onAction = {})
            }
        }

        composeRule.onNodeWithText("Wi-Fi 麦克风").assertExists()
        composeRule.onNodeWithText("手机网络给 Mac").assertExists()
        composeRule.onNodeWithText("Mac 网络给手机").assertExists()
        composeRule.onNodeWithText("等待手机确认").assertExists()
        composeRule.onNodeWithText("出口验证中").assertExists()
        composeRule.onNodeWithText("隧道失败").assertExists()
    }

    @Test
    fun microphoneSwitchEmitsStopWithoutChangingSnapshot() {
        val snapshot = AppSnapshot(
            microphone = ModuleStatus(TaskPhase.RUNNING, "正在接收", "收到真实帧"),
            settings = Settings(wifiHost = "192.168.1.10"),
            frames = 7,
        )
        var action: UserAction? = null
        composeRule.setContent {
            MaterialTheme {
                LinkMicScreen(snapshot = snapshot, onAction = { action = it })
            }
        }

        composeRule.onNodeWithContentDescription("Wi-Fi 麦克风开关")
            .assertIsOn()
            .performClick()

        composeRule.runOnIdle {
            assertEquals(UserAction.StopAudio, action)
            assertEquals(TaskPhase.RUNNING, snapshot.microphone.phase)
            assertEquals(7L, snapshot.frames)
        }
    }

    @Test
    fun settingsSaveEmitsEditedDraft() {
        val snapshot = AppSnapshot(settings = Settings())
        var action: UserAction? = null
        composeRule.setContent {
            MaterialTheme {
                LinkMicScreen(snapshot = snapshot, onAction = { action = it })
            }
        }

        composeRule.onNodeWithText("设置").performClick()
        composeRule.onNodeWithTag("wifi-host").performTextReplacement("192.168.1.10")
        composeRule.onNodeWithTag("pairing-code")
            .performTextReplacement("0123456789abcdef0123456789abcdef")
        composeRule.onNodeWithTag("save-settings").performScrollTo().assertIsEnabled().performClick()

        composeRule.runOnIdle {
            val save = action as UserAction.SaveSettings
            assertEquals("192.168.1.10", save.settings.wifiHost)
            assertEquals("0123456789abcdef0123456789abcdef", save.settings.pairingCode)
            assertEquals("", snapshot.settings.wifiHost)
        }
    }
}
