package com.zjx.usblinkmic.ui

import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.zjx.usblinkmic.contracts.AppSnapshot
import com.zjx.usblinkmic.contracts.AudioParameters
import com.zjx.usblinkmic.contracts.ModuleStatus
import com.zjx.usblinkmic.contracts.Settings
import com.zjx.usblinkmic.contracts.TaskPhase
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File

/** Dark-mode counterpart to [AndroidUiRenderTest]; catches unreadable surfaces. */
@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34], qualifiers = "w411dp-h891dp-night-xxhdpi")
class AndroidUiDarkRenderTest {
    @get:Rule
    val composeRule = createAndroidComposeRule<ComponentActivity>()

    private val outputDir = File("build/ui-renders").apply { mkdirs() }

    private val streamingSnapshot = AppSnapshot(
        microphone = ModuleStatus(TaskPhase.RUNNING, "正在采音", "系统静音状态通过 Android 录音状态回报"),
        settings = Settings(wifiHost = "192.168.1.10", audio = AudioParameters(channels = 2)),
        effectiveAudio = AudioParameters(channels = 2),
        frames = 18420,
        level = 0.42,
        waveform = listOf(0.12, 0.34, 0.58, 0.81, 0.46, 0.22, 0.63, 0.9, 0.51, 0.28, 0.7, 0.44),
    )

    @Test
    fun renderDarkMicrophoneScreen() {
        render("android-mic-streaming-dark", navigate = null)
    }

    @Test
    fun renderDarkSettingsScreen() {
        render("android-settings-dark") {
            composeRule.onNodeWithText("设置与诊断").performClick()
        }
    }

    private fun render(name: String, navigate: (() -> Unit)?) {
        composeRule.setContent {
            MaterialTheme {
                Surface(Modifier.fillMaxSize()) {
                    LinkMicScreen(snapshot = streamingSnapshot, onAction = {})
                }
            }
        }
        composeRule.waitForIdle()
        navigate?.invoke()
        composeRule.waitForIdle()

        val view = composeRule.activity.window.decorView
        val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
        view.draw(Canvas(bitmap))
        File(outputDir, "$name.png").outputStream().use {
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
        }
    }
}
