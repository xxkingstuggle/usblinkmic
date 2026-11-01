package com.zjx.usblinkmic.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Mic
import androidx.compose.material.icons.outlined.Public
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.zjx.usblinkmic.contracts.AppSnapshot
import com.zjx.usblinkmic.contracts.AudioParameters
import com.zjx.usblinkmic.contracts.Capabilities
import com.zjx.usblinkmic.contracts.LogEntry
import com.zjx.usblinkmic.contracts.ModuleStatus
import com.zjx.usblinkmic.contracts.PCMFormat
import com.zjx.usblinkmic.contracts.PermissionState
import com.zjx.usblinkmic.contracts.RecordingSource
import com.zjx.usblinkmic.contracts.Settings
import com.zjx.usblinkmic.contracts.TaskPhase
import com.zjx.usblinkmic.contracts.UserAction
import com.zjx.usblinkmic.support.LogRedactor
import com.zjx.usblinkmic.support.SettingsValidator
import java.text.DateFormat
import java.text.NumberFormat
import java.util.Date
import kotlin.math.abs
import kotlin.math.log10

/** Renders the current companion-app snapshot and reports user intent to its owner. */
@Composable
fun LinkMicScreen(snapshot: AppSnapshot, onAction: (UserAction) -> Unit) {
    val dark = isSystemInDarkTheme()
    val palette = ZenPalette.of(dark)

    var section by remember { mutableStateOf(ScreenSection.MIC) }
    var showLogs by remember { mutableStateOf(false) }
    var baselineSettings by remember { mutableStateOf(snapshot.settings) }
    var draft by remember { mutableStateOf(SettingsDraft.from(snapshot.settings)) }
    var awaitingSaveCompletion by remember { mutableStateOf(false) }

    LaunchedEffect(snapshot.settingsSavedRevision) {
        if (snapshot.settingsSavedRevision > 0L) {
            if (awaitingSaveCompletion || draft == SettingsDraft.from(baselineSettings)) {
                baselineSettings = snapshot.settings
                draft = SettingsDraft.from(snapshot.settings)
                awaitingSaveCompletion = false
            }
        }
    }

    LaunchedEffect(snapshot.isSavingSettings, snapshot.settingsError) {
        if (!snapshot.isSavingSettings && snapshot.settingsError != null) {
            awaitingSaveCompletion = false
        }
    }

    LaunchedEffect(snapshot.settings) {
        val draftWasClean = draft == SettingsDraft.from(baselineSettings)
        baselineSettings = snapshot.settings
        if (draftWasClean && !awaitingSaveCompletion && !snapshot.isSavingSettings && snapshot.settingsError == null) {
            draft = SettingsDraft.from(snapshot.settings)
        }
    }

    val settingsDirty = draft != SettingsDraft.from(baselineSettings)

    MaterialTheme(
        colorScheme = if (dark) {
            darkColorScheme(
                primary = palette.blue,
                background = palette.window,
                surface = palette.card,
                onSurface = palette.textPrimary,
                error = palette.red,
            )
        } else {
            lightColorScheme(
                primary = palette.blue,
                background = palette.window,
                surface = palette.card,
                onSurface = palette.textPrimary,
                error = palette.red,
            )
        },
    ) {
        Scaffold(
            containerColor = palette.window,
            bottomBar = {
                ZenTabBar(palette, section) { selected ->
                    section = selected
                    showLogs = false
                }
            },
        ) { contentPadding ->
            Box(
                Modifier
                    .padding(contentPadding)
                    .fillMaxSize()
            ) {
                when (section) {
                    ScreenSection.MIC -> MicrophonePage(
                        snapshot = snapshot,
                        settingsDirty = settingsDirty,
                        palette = palette,
                        onAction = onAction,
                        onOpenSettings = { section = ScreenSection.SETTINGS },
                    )

                    ScreenSection.NETWORK -> NetworkPage(
                        snapshot = snapshot,
                        palette = palette,
                        onAction = onAction,
                    )

                    ScreenSection.SETTINGS -> if (showLogs) {
                        LogsPage(
                            logs = snapshot.logs,
                            palette = palette,
                            onBack = { showLogs = false },
                            onClear = { onAction(UserAction.ClearLogs) },
                            onExport = { onAction(UserAction.ExportLogs) },
                        )
                    } else {
                        SettingsPage(
                            snapshot = snapshot,
                            draft = draft,
                            onDraftChange = { draft = it },
                            baseline = baselineSettings,
                            dirty = settingsDirty,
                            palette = palette,
                            onCancel = {
                                if (!snapshot.isSavingSettings) {
                                    draft = SettingsDraft.from(baselineSettings)
                                    awaitingSaveCompletion = false
                                }
                            },
                            onSave = { settings ->
                                if (!snapshot.isSavingSettings) {
                                    awaitingSaveCompletion = true
                                    onAction(UserAction.SaveSettings(settings))
                                }
                            },
                            onOpenLogs = { showLogs = true },
                            onAction = onAction,
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Microphone Page

@Composable
private fun MicrophonePage(
    snapshot: AppSnapshot,
    settingsDirty: Boolean,
    palette: ZenPalette,
    onAction: (UserAction) -> Unit,
    onOpenSettings: () -> Unit,
) {
    val status = snapshot.microphone
    val running = status.phase == TaskPhase.RUNNING
    val busy = status.phase in setOf(
        TaskPhase.CHECKING,
        TaskPhase.PREPARING,
        TaskPhase.WAITING_USER,
        TaskPhase.CONNECTING,
        TaskPhase.STOPPING,
    )
    val canStart = !settingsDirty && snapshot.settings.wifiHost.isNotBlank()
    val effectiveAudio = snapshot.effectiveAudio ?: snapshot.settings.audio

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp, vertical = 26.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        PageHeader(
            palette = palette,
            title = "USB LinkMic",
            subtitle = if (running) {
                "正在向 Mac 推送高品质音频"
            } else if (snapshot.controlledByMac) {
                "Mac 已接管 · 可远程启停采音"
            } else {
                "手机麦克风 · 随时就绪"
            },
            trailing = {
                Icon(
                    imageVector = Icons.Outlined.Refresh,
                    contentDescription = "刷新状态",
                    tint = palette.textSecondary,
                    modifier = Modifier
                        .clip(CircleShape)
                        .clickable { onAction(UserAction.Refresh) }
                        .padding(8.dp)
                        .size(20.dp),
                )
            },
        )

        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            ZenStatusBadge(palette, status.phase, running)
            Text(
                text = when {
                    running -> if (snapshot.controlledByMac) "Mac 控制 · 实时传输" else "手机端 · 实时传输"
                    snapshot.settings.wifiHost.isBlank() -> "未配置 Mac 地址"
                    else -> "随时就绪"
                },
                fontSize = 11.5.sp,
                color = palette.textSecondary,
                modifier = Modifier
                    .clip(CircleShape)
                    .background(palette.card)
                    .border(1.dp, palette.border, CircleShape)
                    .padding(horizontal = 10.dp, vertical = 5.dp),
            )
        }

        ZenCard(palette, active = running) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                LineArtMicIcon(
                    color = if (running) palette.blue else palette.textPrimary,
                    size = 40.dp,
                )
                Spacer(Modifier.width(14.dp))
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text(
                        text = when {
                            running -> "手机麦克风 · 采音中"
                            snapshot.controlledByMac -> "USB 麦克风"
                            else -> "Wi-Fi 麦克风"
                        },
                        fontSize = 19.sp,
                        fontWeight = FontWeight.Bold,
                        color = palette.textPrimary,
                    )
                    Text(
                        text = audioSummary(effectiveAudio),
                        fontSize = 12.5.sp,
                        color = palette.textSecondary,
                    )
                }
            }

            Spacer(Modifier.height(18.dp))

            if (running) {
                ZenWaveform(
                    samples = snapshot.waveform,
                    level = snapshot.level,
                    palette = palette,
                )
                Spacer(Modifier.height(12.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = if (snapshot.frames == 0L) {
                            "等待音频首帧"
                        } else {
                            "已推送 ${NumberFormat.getIntegerInstance().format(snapshot.frames)} 帧"
                        },
                        fontSize = 12.sp,
                        color = palette.textSecondary,
                    )
                    Spacer(Modifier.weight(1f))
                    Text(
                        text = "音频源 ${recordingSourceLabel(effectiveAudio.source)}",
                        fontSize = 12.sp,
                        color = palette.textSecondary,
                    )
                }
            } else {
                Column(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(
                        text = when {
                            busy -> status.stage
                            status.phase == TaskPhase.FAILED -> status.stage.ifBlank { "音频连接异常" }
                            else -> "随时就绪"
                        },
                        fontSize = 23.sp,
                        fontWeight = FontWeight.Bold,
                        color = palette.textPrimary,
                        textAlign = TextAlign.Center,
                    )
                    Text(
                        text = when {
                            status.phase == TaskPhase.FAILED && status.detail.isNotBlank() -> status.detail
                            status.detail.isNotBlank() && status.phase != TaskPhase.STOPPED -> status.detail
                            else -> "音频引擎已在后台就绪\n可在 Mac 端唤醒，或在下方手动开始拾音"
                        },
                        fontSize = 13.sp,
                        color = if (status.phase == TaskPhase.FAILED) palette.red else palette.textSecondary,
                        textAlign = TextAlign.Center,
                        lineHeight = 19.sp,
                    )
                }
            }

            Spacer(Modifier.height(18.dp))

            ZenPrimaryButton(
                title = if (running) "停止拾音" else "开始拾音",
                palette = palette,
                stop = running,
                enabled = status.phase != TaskPhase.STOPPING &&
                    snapshot.microphone.phase != TaskPhase.WAITING_USER &&
                    (running || canStart),
                modifier = Modifier
                    .fillMaxWidth()
                    .semantics { contentDescription = "Wi-Fi 麦克风开关" },
            ) {
                onAction(if (running) UserAction.StopAudio else UserAction.StartWifi)
            }

            if (!running && !canStart && status.phase == TaskPhase.STOPPED) {
                Spacer(Modifier.height(8.dp))
                Text(
                    text = if (settingsDirty) {
                        "设置草稿尚未保存；保存后才能使用新目标。"
                    } else {
                        "请先在「设置与诊断」中填写 Mac 的 Wi-Fi 地址。"
                    },
                    fontSize = 12.sp,
                    color = if (settingsDirty) palette.red else palette.textSecondary,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth(),
                )
            }

            if (status.errorCode != null) {
                Spacer(Modifier.height(10.dp))
                Text(
                    text = "错误代码 ${status.errorCode}：${status.detail.ifBlank { "请前往诊断日志排障" }}",
                    fontSize = 12.sp,
                    color = palette.red,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }

        ZenGroup(palette, "采音参数与配置") {
            ZenInfoRow(palette, "采样规格", "${rateLabel(effectiveAudio)} · ${channelsLabel(effectiveAudio)} · ${formatLabel(effectiveAudio)}")
            ZenInfoRow(palette, "音频源模式", recordingSourceLabel(effectiveAudio.source))
            ZenInfoRow(
                palette,
                "Mac 控制权",
                if (snapshot.controlledByMac) "由 Mac 控制中" else "手机端控制",
                valueColor = if (snapshot.controlledByMac) palette.green else palette.textSecondary,
            )
            ZenInfoRow(palette, "Mac 目标", "${snapshot.settings.wifiHost.ifBlank { "尚未配置" }}:${snapshot.settings.audioPort}")
            ZenInfoRow(
                palette,
                "配对码",
                if (snapshot.settings.pairingCode.isBlank()) "免配对码" else "已设置",
                showDivider = false,
            )
        }

        val permissionNeedsSettings = snapshot.microphonePermission == PermissionState.SETTINGS_REQUIRED ||
            snapshot.notificationPermission == PermissionState.SETTINGS_REQUIRED
        if (permissionNeedsSettings) {
            ZenSecondaryButton("打开应用设置", palette) { onAction(UserAction.OpenSystemSettings) }
        }

        Text(
            text = "麦克风权限：${permissionLabel(snapshot.microphonePermission)} · 通知权限：${permissionLabel(snapshot.notificationPermission)}",
            fontSize = 11.5.sp,
            color = palette.textTertiary,
            modifier = Modifier
                .fillMaxWidth()
                .clickable(onClick = onOpenSettings),
            textAlign = TextAlign.Center,
        )
    }
}

// MARK: - Network Page

@Composable
private fun NetworkPage(
    snapshot: AppSnapshot,
    palette: ZenPalette,
    onAction: (UserAction) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp, vertical = 26.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        PageHeader(
            palette = palette,
            title = "USB 有线网络共享",
            subtitle = "提供「手机网络给 Mac (USB NCM)」与「Mac 网络给手机 (ADB 隧道 + VPN)」两种互斥有线方式",
        )

        PhoneToMacCard(snapshot, palette)
        MacToPhoneCard(snapshot, palette, onAction)

        Text(
            text = "两个方向共用同一条 USB 通道，同一时间只能运行一个。链路就绪仅代表本地接口或隧道已建立，不等同于公网出口已验证。",
            fontSize = 11.5.sp,
            color = palette.textTertiary,
            modifier = Modifier.padding(horizontal = 4.dp),
        )
    }
}

@Composable
private fun PhoneToMacCard(snapshot: AppSnapshot, palette: ZenPalette) {
    val status = snapshot.phoneInternet
    val running = status.phase == TaskPhase.RUNNING
    val step = when (status.phase) {
        TaskPhase.STOPPED, TaskPhase.FAILED -> -1
        TaskPhase.CHECKING, TaskPhase.PREPARING -> 0
        TaskPhase.WAITING_USER -> 1
        TaskPhase.CONNECTING -> 2
        TaskPhase.RUNNING, TaskPhase.STOPPING -> 3
    }
    val steps = listOf("① USB 就绪", "② NCM 激活", "③ 地址分配", "④ 链路就绪")

    ZenCard(palette, active = running) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("手机网络给 Mac", fontSize = 19.sp, fontWeight = FontWeight.Bold, color = palette.textPrimary)
                Text(
                    text = when {
                        running -> "USB NCM 网卡与本地地址已就绪；公网出口取决于手机上游网络"
                        status.detail.isNotBlank() && status.phase != TaskPhase.STOPPED -> status.detail
                        else -> "通过 Android USB NCM 虚拟网卡，把手机蜂窝或 Wi-Fi 网络共享给 Mac"
                    },
                    fontSize = 12.5.sp,
                    color = palette.textSecondary,
                )
            }
            Spacer(Modifier.width(12.dp))
            ZenStatusBadge(palette, status.phase, running)
        }

        if (status.stage.isNotBlank() && status.phase != TaskPhase.STOPPED) {
            Spacer(Modifier.height(10.dp))
            Text(status.stage, fontSize = 12.5.sp, color = palette.textPrimary)
        }

        Spacer(Modifier.height(16.dp))

        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            steps.forEachIndexed { index, label ->
                val highlighted = index == step
                Text(
                    text = label,
                    fontSize = 11.5.sp,
                    fontWeight = if (highlighted) FontWeight.Bold else FontWeight.Normal,
                    color = if (highlighted) palette.blue else palette.textTertiary,
                )
                if (index < steps.lastIndex) Spacer(Modifier.weight(1f))
            }
        }

        if (status.errorCode != null) {
            Spacer(Modifier.height(10.dp))
            Text("错误代码 ${status.errorCode}：${status.detail}", fontSize = 12.sp, color = palette.red)
        }

        Spacer(Modifier.height(12.dp))

        Text(
            text = "由 Mac 端发起与停止；手机端报告本地 NCM 链路状态。",
            fontSize = 11.5.sp,
            color = palette.textTertiary,
        )
    }
}

@Composable
private fun MacToPhoneCard(
    snapshot: AppSnapshot,
    palette: ZenPalette,
    onAction: (UserAction) -> Unit,
) {
    val status = snapshot.macInternet
    val running = status.phase == TaskPhase.RUNNING
    val canStop = status.phase != TaskPhase.STOPPED && status.phase != TaskPhase.FAILED

    ZenCard(palette, active = running) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("Mac 网络给手机", fontSize = 19.sp, fontWeight = FontWeight.Bold, color = palette.textPrimary)
                Text(
                    text = when {
                        running -> "ADB USB 转发与手机 VPN 隧道已建立；外网连通取决于 Mac 出口"
                        status.detail.isNotBlank() && status.phase != TaskPhase.STOPPED -> status.detail
                        else -> "通过 ADB USB 端口转发与手机 VPN 服务，将 Mac 网络转发给手机"
                    },
                    fontSize = 12.5.sp,
                    color = palette.textSecondary,
                )
            }
            Spacer(Modifier.width(12.dp))
            ZenStatusBadge(palette, status.phase, running)
        }

        if (status.stage.isNotBlank() && status.phase != TaskPhase.STOPPED) {
            Spacer(Modifier.height(10.dp))
            Text(status.stage, fontSize = 12.5.sp, color = palette.textPrimary)
        }

        Spacer(Modifier.height(14.dp))

        ZenInfoRow(
            palette,
            "VPN 授权状态",
            permissionLabel(snapshot.vpnPermission),
            valueColor = permissionTint(snapshot.vpnPermission, palette),
            showDivider = false,
        )

        Spacer(Modifier.height(10.dp))

        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("DNS ${snapshot.settings.dns}", fontSize = 11.5.sp, color = palette.textSecondary)
            Spacer(Modifier.weight(1f))
            Text("路由 ${snapshot.settings.routes}", fontSize = 11.5.sp, color = palette.textSecondary)
        }

        if (canStop) {
            Spacer(Modifier.height(14.dp))
            ZenPrimaryButton(
                title = "停止供网",
                palette = palette,
                stop = true,
                enabled = status.phase != TaskPhase.STOPPING,
            ) {
                onAction(UserAction.StopVpn)
            }
        }

        if (snapshot.vpnPermission == PermissionState.SETTINGS_REQUIRED) {
            Spacer(Modifier.height(10.dp))
            ZenSecondaryButton("打开应用设置", palette) { onAction(UserAction.OpenSystemSettings) }
        }

        if (status.errorCode != null) {
            Spacer(Modifier.height(10.dp))
            Text("错误代码 ${status.errorCode}：${status.detail}", fontSize = 12.sp, color = palette.red)
        }
    }
}

// MARK: - Settings Page

@Composable
private fun SettingsPage(
    snapshot: AppSnapshot,
    draft: SettingsDraft,
    onDraftChange: (SettingsDraft) -> Unit,
    baseline: Settings,
    dirty: Boolean,
    palette: ZenPalette,
    onCancel: () -> Unit,
    onSave: (Settings) -> Unit,
    onOpenLogs: () -> Unit,
    onAction: (UserAction) -> Unit,
) {
    val parsedSettings = draft.toSettings(baseline)
    val errors = if (parsedSettings == null) draft.parseErrors() else SettingsValidator.errors(parsedSettings)

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp, vertical = 26.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        PageHeader(
            palette = palette,
            title = "设置与权限",
            subtitle = "控制音频引擎、通信参数与安卓底层权限",
        )

        ZenGroup(palette, "Wi-Fi 麦克风（连接 Mac 接收端）") {
            ZenFieldRow(
                palette,
                label = "Mac 目标地址",
                value = draft.wifiHost,
                onValueChange = { onDraftChange(draft.copy(wifiHost = it)) },
                tag = "wifi-host",
                placeholder = "例如 192.168.1.10",
            )
            ZenFieldRow(
                palette,
                label = "Mac 接收端口",
                value = draft.audioPort,
                onValueChange = { onDraftChange(draft.copy(audioPort = it)) },
                tag = "audio-port",
                keyboardType = KeyboardType.Number,
            )
            ZenFieldRow(
                palette,
                label = "USB 控制端口",
                value = draft.controlPort,
                onValueChange = { onDraftChange(draft.copy(controlPort = it)) },
                tag = "control-port",
                keyboardType = KeyboardType.Number,
            )
            PairingCodeRow(
                palette = palette,
                value = draft.pairingCode,
                onValueChange = { onDraftChange(draft.copy(pairingCode = it)) },
            )
        }

        ZenGroup(palette, "音频采集规格") {
            ZenChoiceRow(
                palette,
                title = "采样率",
                options = Capabilities.SAMPLE_RATES,
                selected = draft.sampleRate.toIntOrNull(),
                label = { "${it / 1000} kHz" },
                onSelect = { onDraftChange(draft.copy(sampleRate = it.toString())) },
            )
            ZenChoiceRow(
                palette,
                title = "声道",
                options = Capabilities.CHANNELS,
                selected = draft.channels.toIntOrNull(),
                label = { if (it == 1) "单声道" else "立体声" },
                onSelect = { onDraftChange(draft.copy(channels = it.toString())) },
            )
            ZenChoiceRow(
                palette,
                title = "PCM 格式",
                options = PCMFormat.entries,
                selected = draft.format,
                label = { if (it == PCMFormat.I16) "i16" else "f32" },
                onSelect = { onDraftChange(draft.copy(format = it)) },
            )
            ZenChoiceRow(
                palette,
                title = "录音源",
                options = RecordingSource.entries,
                selected = draft.source,
                label = ::recordingSourceLabel,
                onSelect = { onDraftChange(draft.copy(source = it)) },
                showDivider = false,
            )
        }

        ZenGroup(palette, "Mac 网络给手机 (VPN 隧道参数)") {
            ZenFieldRow(
                palette,
                label = "DNS IPv4",
                value = draft.dns,
                onValueChange = { onDraftChange(draft.copy(dns = it)) },
                tag = "dns",
            )
            ZenFieldRow(
                palette,
                label = "IPv4 CIDR 路由",
                value = draft.routes,
                onValueChange = { onDraftChange(draft.copy(routes = it)) },
                tag = "routes",
                showDivider = false,
            )
        }

        if (!snapshot.settingsError.isNullOrBlank()) {
            Surface(
                shape = RoundedCornerShape(16.dp),
                color = palette.red.copy(alpha = if (palette.isDark) 0.16f else 0.07f),
                modifier = Modifier.testTag("settings-save-error"),
            ) {
                Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("保存设置失败", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = palette.red)
                    Text(snapshot.settingsError, fontSize = 12.sp, color = palette.red)
                }
            }
        } else if (snapshot.isSavingSettings && snapshot.settingsMessage.isNotBlank()) {
            Surface(
                shape = RoundedCornerShape(16.dp),
                color = palette.card,
                border = BorderStroke(1.dp, palette.border),
                modifier = Modifier.testTag("settings-saving-banner"),
            ) {
                Row(
                    Modifier.fillMaxWidth().padding(16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(snapshot.settingsMessage, fontSize = 12.5.sp, color = palette.textSecondary)
                }
            }
        }

        if (errors.isNotEmpty()) {
            Surface(
                shape = RoundedCornerShape(16.dp),
                color = palette.red.copy(alpha = if (palette.isDark) 0.16f else 0.07f),
            ) {
                Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("设置校验未通过", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = palette.red)
                    errors.forEach { Text("• $it", fontSize = 12.sp, color = palette.red) }
                }
            }
        }

        val canRetryOrSave = (dirty || !snapshot.settingsError.isNullOrBlank()) &&
            !snapshot.isSavingSettings &&
            parsedSettings != null &&
            errors.isEmpty()

        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(
                text = "取消草稿",
                fontSize = 13.sp,
                color = if (dirty && !snapshot.isSavingSettings) palette.textSecondary else palette.textTertiary,
                modifier = Modifier
                    .clip(CircleShape)
                    .clickable(enabled = dirty && !snapshot.isSavingSettings, onClick = onCancel)
                    .padding(horizontal = 14.dp, vertical = 10.dp),
            )
            ZenPrimaryButton(
                title = if (snapshot.isSavingSettings) "正在保存…" else "保存设置",
                palette = palette,
                enabled = canRetryOrSave,
                modifier = Modifier
                    .weight(1f)
                    .testTag("save-settings"),
            ) {
                parsedSettings?.let(onSave)
            }
        }

        ZenGroup(palette, "安卓系统底层权限") {
            ZenInfoRow(
                palette,
                "麦克风录音权限",
                permissionLabel(snapshot.microphonePermission),
                valueColor = permissionTint(snapshot.microphonePermission, palette),
            )
            ZenInfoRow(
                palette,
                "前台常驻服务通知",
                permissionLabel(snapshot.notificationPermission),
                valueColor = permissionTint(snapshot.notificationPermission, palette),
            )
            ZenInfoRow(
                palette,
                "本地 VPN 隧道网络",
                permissionLabel(snapshot.vpnPermission),
                valueColor = permissionTint(snapshot.vpnPermission, palette),
                showDivider = false,
            )
        }

        if (snapshot.microphonePermission == PermissionState.SETTINGS_REQUIRED ||
            snapshot.notificationPermission == PermissionState.SETTINGS_REQUIRED ||
            snapshot.vpnPermission == PermissionState.SETTINGS_REQUIRED
        ) {
            ZenSecondaryButton("打开应用设置", palette) { onAction(UserAction.OpenSystemSettings) }
        }

        ZenGroup(palette) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(onClick = onOpenLogs)
                    .padding(horizontal = 16.dp, vertical = 15.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text("诊断日志", fontSize = 13.5.sp, color = palette.textPrimary)
                    Text("查看底层音频与通讯管道事件", fontSize = 11.5.sp, color = palette.textSecondary)
                }
                Text("${snapshot.logs.size} 条 ›", fontSize = 12.sp, color = palette.textTertiary)
            }
        }
    }
}

@Composable
private fun PairingCodeRow(
    palette: ZenPalette,
    value: String,
    onValueChange: (String) -> Unit,
) {
    var revealed by remember { mutableStateOf(false) }
    Column {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Wi-Fi 配对码", fontSize = 13.5.sp, color = palette.textPrimary)
            Spacer(Modifier.weight(1f))
            OutlinedTextField(
                value = value,
                onValueChange = onValueChange,
                modifier = Modifier.width(178.dp).testTag("pairing-code"),
                singleLine = true,
                textStyle = TextStyle(fontSize = 13.sp, color = palette.textPrimary, textAlign = TextAlign.End),
                placeholder = { Text("留空则免配对码", fontSize = 12.sp, color = palette.textTertiary) },
                visualTransformation = if (revealed) VisualTransformation.None else PasswordVisualTransformation(),
                shape = RoundedCornerShape(10.dp),
                trailingIcon = {
                    Text(
                        text = if (revealed) "隐藏" else "显示",
                        fontSize = 11.5.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = palette.blue,
                        modifier = Modifier
                            .clip(RoundedCornerShape(6.dp))
                            .clickable { revealed = !revealed }
                            .padding(horizontal = 6.dp, vertical = 4.dp),
                    )
                },
                colors = fieldColors(palette),
            )
        }
        HorizontalDivider(color = palette.divider)
    }
}

// MARK: - Logs Page

@Composable
private fun LogsPage(
    logs: List<LogEntry>,
    palette: ZenPalette,
    onBack: () -> Unit,
    onClear: () -> Unit,
    onExport: () -> Unit = {},
) {
    var filter by remember { mutableStateOf(LogFilter.ALL) }
    val filtered = logs.asReversed().filter { filter.matches(it.module) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 20.dp, vertical = 26.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                imageVector = Icons.AutoMirrored.Outlined.ArrowBack,
                contentDescription = "返回设置",
                tint = palette.textSecondary,
                modifier = Modifier
                    .clip(CircleShape)
                    .clickable(onClick = onBack)
                    .padding(8.dp)
                    .size(20.dp),
            )
            Spacer(Modifier.width(6.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("诊断日志", fontSize = 27.sp, fontWeight = FontWeight.Bold, color = palette.textPrimary)
                Text("手机端底层音频与通讯管道实时事件", fontSize = 13.sp, color = palette.textSecondary)
            }
            Text(
                text = "导出",
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                color = palette.blue,
                modifier = Modifier
                    .clip(CircleShape)
                    .clickable(onClick = onExport)
                    .padding(horizontal = 10.dp, vertical = 8.dp)
                    .testTag("export-logs"),
            )
            Text(
                text = "清空",
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                color = if (logs.isEmpty()) palette.textTertiary else palette.red,
                modifier = Modifier
                    .clip(CircleShape)
                    .clickable(enabled = logs.isNotEmpty(), onClick = onClear)
                    .padding(horizontal = 10.dp, vertical = 8.dp),
            )
        }

        Row(
            modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            LogFilter.entries.forEach { item ->
                val count = logs.count { item.matches(it.module) }
                ZenPillToggle(
                    palette = palette,
                    title = "${item.label} ($count)",
                    selected = filter == item,
                ) { filter = item }
            }
        }

        if (filtered.isEmpty()) {
            Column(
                modifier = Modifier.fillMaxWidth().padding(vertical = 48.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Text(
                    text = if (logs.isEmpty()) "暂无日志" else "没有匹配的日志记录",
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = palette.textSecondary,
                )
                Text("连接手机后，音频与网络事件会实时出现在这里。", fontSize = 12.sp, color = palette.textTertiary)
            }
        } else {
            Surface(
                shape = RoundedCornerShape(18.dp),
                color = palette.card,
                border = BorderStroke(1.dp, palette.border),
                modifier = Modifier.fillMaxWidth().weight(1f, fill = false),
            ) {
                LazyColumn {
                    itemsIndexed(filtered) { index, entry ->
                        LogRow(palette, entry)
                        if (index < filtered.lastIndex) {
                            HorizontalDivider(
                                color = palette.divider,
                                modifier = Modifier.padding(horizontal = 16.dp),
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun LogRow(palette: ZenPalette, entry: LogEntry) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 13.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            val module = LogRedactor.redact(entry.module)
            Text(
                text = module.uppercase(),
                fontSize = 10.sp,
                fontWeight = FontWeight.Bold,
                color = palette.blue,
                modifier = Modifier
                    .background(palette.blue.copy(alpha = 0.10f), RoundedCornerShape(5.dp))
                    .padding(horizontal = 6.dp, vertical = 2.dp),
            )
            Spacer(Modifier.width(8.dp))
            Text(
                text = formatTimestamp(entry.timestamp),
                fontSize = 11.sp,
                color = palette.textTertiary,
            )
        }
        Text(
            text = LogRedactor.redact(entry.message),
            fontSize = 12.5.sp,
            color = palette.textPrimary,
            lineHeight = 18.sp,
        )
        if (entry.stage.isNotBlank()) {
            Text(
                text = LogRedactor.redact(entry.stage),
                fontSize = 11.sp,
                color = palette.textSecondary,
            )
        }
    }
}

private enum class LogFilter(val label: String) {
    ALL("全部"),
    AUDIO("麦克风"),
    NETWORK("网络"),
    SYSTEM("系统");

    fun matches(module: String): Boolean = when (this) {
        ALL -> true
        AUDIO -> module == "audio" || module == "microphone"
        NETWORK -> module in setOf("phoneInternet", "macInternet", "vpn", "ncm")
        SYSTEM -> module !in setOf("audio", "microphone", "phoneInternet", "macInternet", "vpn", "ncm")
    }
}

// MARK: - Shared components

private enum class ScreenSection(val label: String, val icon: ImageVector) {
    MIC("麦克风", Icons.Outlined.Mic),
    NETWORK("网络互联", Icons.Outlined.Public),
    SETTINGS("设置与诊断", Icons.Outlined.Settings),
}

@Composable
private fun ZenTabBar(palette: ZenPalette, selected: ScreenSection, onSelect: (ScreenSection) -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .background(palette.card)
            .navigationBarsPadding()
    ) {
        HorizontalDivider(color = palette.divider)
        Row(
            modifier = Modifier.fillMaxWidth().height(62.dp).padding(horizontal = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            ScreenSection.entries.forEach { item ->
                val active = item == selected
                Column(
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(14.dp))
                        .clickable { onSelect(item) }
                        .padding(vertical = 6.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(3.dp),
                ) {
                    Box(
                        modifier = Modifier
                            .width(46.dp)
                            .height(26.dp)
                            .background(
                                if (active) palette.blue.copy(alpha = 0.12f) else Color.Transparent,
                                CircleShape,
                            ),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            imageVector = item.icon,
                            contentDescription = null,
                            tint = if (active) palette.blue else palette.textSecondary,
                            modifier = Modifier.size(19.dp),
                        )
                    }
                    Text(
                        text = item.label,
                        fontSize = 10.5.sp,
                        fontWeight = if (active) FontWeight.SemiBold else FontWeight.Normal,
                        color = if (active) palette.blue else palette.textSecondary,
                    )
                }
            }
        }
    }
}

@Composable
private fun PageHeader(
    palette: ZenPalette,
    title: String,
    subtitle: String,
    trailing: (@Composable () -> Unit)? = null,
) {
    Row(verticalAlignment = Alignment.Top) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Text(title, fontSize = 27.sp, fontWeight = FontWeight.Bold, color = palette.textPrimary)
            Text(subtitle, fontSize = 13.sp, color = palette.textSecondary)
        }
        trailing?.invoke()
    }
}

@Composable
private fun ZenCard(
    palette: ZenPalette,
    active: Boolean = false,
    content: @Composable ColumnScope.() -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(22.dp),
        color = palette.card,
        border = BorderStroke(if (active) 1.5.dp else 1.dp, if (active) palette.blue else palette.border),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(0.dp),
            content = content,
        )
    }
}

@Composable
private fun ZenGroup(
    palette: ZenPalette,
    title: String? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (title != null) {
            Text(title, fontSize = 12.5.sp, fontWeight = FontWeight.Medium, color = palette.textSecondary)
        }
        Surface(
            shape = RoundedCornerShape(18.dp),
            color = palette.card,
            border = BorderStroke(1.dp, palette.border),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(Modifier.fillMaxWidth(), content = content)
        }
    }
}

@Composable
private fun ZenInfoRow(
    palette: ZenPalette,
    label: String,
    value: String,
    valueColor: Color = palette.textSecondary,
    showDivider: Boolean = true,
) {
    Column {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 13.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(label, fontSize = 13.5.sp, color = palette.textPrimary)
            Spacer(Modifier.weight(1f))
            Text(value, fontSize = 13.sp, fontWeight = FontWeight.Medium, color = valueColor, textAlign = TextAlign.End)
        }
        if (showDivider) HorizontalDivider(color = palette.divider)
    }
}

@Composable
private fun ZenFieldRow(
    palette: ZenPalette,
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    tag: String,
    placeholder: String? = null,
    keyboardType: KeyboardType = KeyboardType.Text,
    showDivider: Boolean = true,
) {
    Column {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(label, fontSize = 13.5.sp, color = palette.textPrimary)
            Spacer(Modifier.weight(1f))
            OutlinedTextField(
                value = value,
                onValueChange = onValueChange,
                modifier = Modifier.width(178.dp).testTag(tag),
                singleLine = true,
                textStyle = TextStyle(fontSize = 13.sp, color = palette.textPrimary, textAlign = TextAlign.End),
                placeholder = if (placeholder != null) {
                    { Text(placeholder, fontSize = 12.sp, color = palette.textTertiary) }
                } else {
                    null
                },
                keyboardOptions = KeyboardOptions(keyboardType = keyboardType),
                shape = RoundedCornerShape(10.dp),
                colors = fieldColors(palette),
            )
        }
        if (showDivider) HorizontalDivider(color = palette.divider)
    }
}

@Composable
private fun fieldColors(palette: ZenPalette) = OutlinedTextFieldDefaults.colors(
    focusedBorderColor = palette.blue,
    unfocusedBorderColor = palette.border,
    focusedContainerColor = palette.window,
    unfocusedContainerColor = palette.window,
    cursorColor = palette.blue,
)

@Composable
private fun <T> ZenChoiceRow(
    palette: ZenPalette,
    title: String,
    options: List<T>,
    selected: T?,
    label: (T) -> String,
    onSelect: (T) -> Unit,
    showDivider: Boolean = true,
) {
    Column {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(9.dp),
        ) {
            Text(title, fontSize = 13.5.sp, color = palette.textPrimary)
            Row(
                modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                options.forEach { option ->
                    ZenPillToggle(
                        palette = palette,
                        title = label(option),
                        selected = option == selected,
                    ) { onSelect(option) }
                }
            }
        }
        if (showDivider) HorizontalDivider(color = palette.divider)
    }
}

@Composable
private fun ZenPillToggle(
    palette: ZenPalette,
    title: String,
    selected: Boolean,
    onClick: () -> Unit,
) {
    Text(
        text = title,
        fontSize = 12.sp,
        fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
        color = if (selected) palette.blue else palette.textSecondary,
        modifier = Modifier
            .clip(CircleShape)
            .background(if (selected) palette.blue.copy(alpha = 0.10f) else palette.window)
            .border(1.dp, if (selected) palette.blue.copy(alpha = 0.55f) else palette.border, CircleShape)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 7.dp),
    )
}

@Composable
private fun ZenStatusBadge(palette: ZenPalette, phase: TaskPhase, running: Boolean) {
    val (label, color) = when (phase) {
        TaskPhase.STOPPED -> "待命中" to palette.textSecondary
        TaskPhase.CHECKING -> "检查中" to palette.blue
        TaskPhase.PREPARING -> "准备中" to palette.blue
        TaskPhase.WAITING_USER -> "等待确认" to palette.orange
        TaskPhase.CONNECTING -> "连接中" to palette.blue
        TaskPhase.RUNNING -> (if (running) "运行中" else "运行中") to palette.green
        TaskPhase.STOPPING -> "停止中" to palette.blue
        TaskPhase.FAILED -> "异常" to palette.red
    }
    Row(
        modifier = Modifier
            .clip(CircleShape)
            .background(color.copy(alpha = if (palette.isDark) 0.16f else 0.09f))
            .padding(horizontal = 10.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Box(Modifier.size(6.dp).background(color, CircleShape))
        Text(label, fontSize = 11.5.sp, fontWeight = FontWeight.Medium, color = color)
    }
}

@Composable
private fun ZenPrimaryButton(
    title: String,
    palette: ZenPalette,
    stop: Boolean = false,
    enabled: Boolean = true,
    modifier: Modifier = Modifier.fillMaxWidth(),
    onClick: () -> Unit,
) {
    val background = if (stop) palette.red else palette.blue
    Row(
        modifier = modifier
            .height(52.dp)
            .clip(CircleShape)
            .background(if (enabled) background else background.copy(alpha = 0.4f))
            .clickable(enabled = enabled, onClick = onClick),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
        Spacer(Modifier.width(8.dp))
        Icon(
            imageVector = if (stop) Icons.Filled.Stop else Icons.Filled.PlayArrow,
            contentDescription = null,
            tint = Color.White,
            modifier = Modifier.size(if (stop) 12.dp else 16.dp),
        )
    }
}

@Composable
private fun ZenSecondaryButton(title: String, palette: ZenPalette, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(46.dp)
            .clip(CircleShape)
            .border(1.dp, palette.border, CircleShape)
            .clickable(onClick = onClick),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, fontSize = 13.5.sp, fontWeight = FontWeight.Medium, color = palette.textPrimary)
    }
}

@Composable
private fun ZenWaveform(
    samples: List<Double>,
    level: Double,
    palette: ZenPalette,
    barCount: Int = 36,
    height: androidx.compose.ui.unit.Dp = 76.dp,
) {
    val values = remember(samples, level, barCount) {
        if (samples.isNotEmpty()) resample(samples, barCount)
        else List(barCount) { level.coerceIn(0.0, 1.0) }
    }
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(height)
            .clip(RoundedCornerShape(14.dp))
            .background(palette.well),
    ) {
        Canvas(Modifier.fillMaxSize().padding(horizontal = 16.dp, vertical = 14.dp)) {
            if (values.isEmpty()) return@Canvas
            val barWidth = 4.dp.toPx()
            val gap = ((size.width - barWidth * barCount) / (barCount - 1).coerceAtLeast(1)).coerceAtLeast(2.dp.toPx())
            values.forEachIndexed { index, raw ->
                val amplitude = raw.coerceIn(0.05, 1.0).toFloat()
                val barHeight = (size.height * amplitude).coerceAtLeast(4.dp.toPx())
                drawRoundRect(
                    color = if (index % 3 == 0) palette.blue.copy(alpha = 0.78f) else palette.blue,
                    topLeft = Offset(index * (barWidth + gap), (size.height - barHeight) / 2f),
                    size = Size(barWidth, barHeight),
                    cornerRadius = CornerRadius(barWidth / 2f, barWidth / 2f),
                )
            }
        }

        Row(
            modifier = Modifier
                .align(Alignment.TopEnd)
                .padding(top = 8.dp, end = 10.dp)
                .clip(CircleShape)
                .background(palette.card)
                .border(1.dp, palette.border, CircleShape)
                .padding(horizontal = 9.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            Box(Modifier.size(6.dp).background(palette.green, CircleShape))
            Text(levelText(level), fontSize = 10.5.sp, fontWeight = FontWeight.SemiBold, color = palette.textPrimary)
        }
    }
}

@Composable
private fun LineArtMicIcon(color: Color, size: androidx.compose.ui.unit.Dp) {
    Canvas(Modifier.size(size)) {
        val w = this.size.width
        val h = this.size.height
        val stroke = Stroke(width = 2.dp.toPx(), cap = StrokeCap.Round)
        drawRoundRect(
            color = color,
            topLeft = Offset(w * 0.31f, h * 0.08f),
            size = Size(w * 0.38f, h * 0.50f),
            cornerRadius = CornerRadius(w * 0.19f, h * 0.19f),
            style = stroke,
        )
        val cradle = Path().apply {
            moveTo(w * 0.20f, h * 0.40f)
            cubicTo(w * 0.20f, h * 0.84f, w * 0.80f, h * 0.84f, w * 0.80f, h * 0.40f)
        }
        drawPath(cradle, color = color, style = stroke)
        val stand = Path().apply {
            moveTo(w * 0.50f, h * 0.80f)
            lineTo(w * 0.50f, h * 0.92f)
            moveTo(w * 0.30f, h * 0.92f)
            lineTo(w * 0.70f, h * 0.92f)
        }
        drawPath(stand, color = color, style = stroke)
    }
}

// MARK: - Palette

private data class ZenPalette(
    val isDark: Boolean,
    val window: Color,
    val card: Color,
    val well: Color,
    val border: Color,
    val divider: Color,
    val textPrimary: Color,
    val textSecondary: Color,
    val textTertiary: Color,
    val blue: Color,
    val green: Color,
    val red: Color,
    val orange: Color,
) {
    companion object {
        fun of(dark: Boolean): ZenPalette = if (dark) {
            ZenPalette(
                isDark = true,
                window = Color(0xFF0D1117),
                card = Color(0xFF181E2B),
                well = Color(0xFF0B111A),
                border = Color(0xFF21283B),
                divider = Color.White.copy(alpha = 0.08f),
                textPrimary = Color.White,
                textSecondary = Color(0xFF8B949E),
                textTertiary = Color(0xFF6E7681),
                blue = Color(0xFF388BFD),
                green = Color(0xFF3FB950),
                red = Color(0xFFF43F5E),
                orange = Color(0xFFF59E0B),
            )
        } else {
            ZenPalette(
                isDark = false,
                window = Color(0xFFF7F8FA),
                card = Color.White,
                well = Color(0xFFF4F7FC),
                border = Color(0xFFE2E8F0),
                divider = Color(0xFFE2E8F0),
                textPrimary = Color(0xFF1D1D1F),
                textSecondary = Color(0xFF6E6E73),
                textTertiary = Color(0xFFA1A1A6),
                blue = Color(0xFF0071E3),
                green = Color(0xFF10B981),
                red = Color(0xFFE11D48),
                orange = Color(0xFFD97706),
            )
        }
    }
}

// MARK: - Presentation helpers

private fun resample(samples: List<Double>, count: Int): List<Double> = List(count) { index ->
    val position = index.toDouble() * (samples.size - 1) / (count - 1).coerceAtLeast(1)
    val low = position.toInt().coerceIn(0, samples.size - 1)
    val high = (low + 1).coerceAtMost(samples.size - 1)
    val fraction = position - low
    abs(samples[low] * (1 - fraction) + samples[high] * fraction)
}

private fun levelText(level: Double): String {
    val clamped = if (level.isFinite()) maxOf(minOf(level, 1.0), 0.001) else 0.001
    val db = maxOf(-48.0, minOf(0.0, 20.0 * log10(clamped)))
    return String.format("%.1f dB", db)
}

private fun rateLabel(audio: AudioParameters): String =
    if (audio.sampleRate % 1000 == 0) "${audio.sampleRate / 1000} kHz" else "${audio.sampleRate} Hz"

private fun channelsLabel(audio: AudioParameters): String =
    if (audio.channels == 1) "单声道" else "立体声"

private fun formatLabel(audio: AudioParameters): String =
    if (audio.format == PCMFormat.I16) "i16" else "f32"

private fun audioSummary(audio: AudioParameters): String =
    "PCM ${formatLabel(audio)} · ${rateLabel(audio)} · ${channelsLabel(audio)} · ${recordingSourceLabel(audio.source)}"

private fun permissionLabel(state: PermissionState): String = when (state) {
    PermissionState.NOT_REQUESTED -> "尚未请求"
    PermissionState.WAITING -> "等待确认"
    PermissionState.ALLOWED -> "已授权"
    PermissionState.DENIED -> "已拒绝"
    PermissionState.SETTINGS_REQUIRED -> "需要系统设置"
}

private fun permissionTint(state: PermissionState, palette: ZenPalette): Color = when (state) {
    PermissionState.ALLOWED, PermissionState.NOT_REQUESTED -> palette.green
    PermissionState.WAITING -> palette.blue
    PermissionState.DENIED, PermissionState.SETTINGS_REQUIRED -> palette.orange
}

private fun recordingSourceLabel(source: RecordingSource): String = when (source) {
    RecordingSource.MICROPHONE -> "内置主麦克风"
    RecordingSource.UNPROCESSED -> "原始未处理"
    RecordingSource.VOICE_RECOGNITION -> "语音识别"
}

private fun formatTimestamp(timestamp: Long): String =
    DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.MEDIUM).format(Date(timestamp))

private data class SettingsDraft(
    val sampleRate: String,
    val channels: String,
    val format: PCMFormat,
    val source: RecordingSource,
    val wifiHost: String,
    val audioPort: String,
    val controlPort: String,
    val pairingCode: String,
    val dns: String,
    val routes: String,
) {
    fun toSettings(base: Settings): Settings? {
        val parsedRate = sampleRate.toIntOrNull() ?: return null
        val parsedChannels = channels.toIntOrNull() ?: return null
        val parsedAudioPort = audioPort.toIntOrNull() ?: return null
        val parsedControlPort = controlPort.toIntOrNull() ?: return null
        return base.copy(
            audio = AudioParameters(
                sampleRate = parsedRate,
                channels = parsedChannels,
                format = format,
                source = source,
            ),
            wifiHost = wifiHost.trim(),
            audioPort = parsedAudioPort,
            controlPort = parsedControlPort,
            pairingCode = pairingCode.trim(),
            dns = dns.trim(),
            routes = routes.trim(),
        )
    }

    fun parseErrors(): List<String> = buildList {
        if (sampleRate.toIntOrNull() == null) add("采样率必须是整数")
        if (channels.toIntOrNull() == null) add("声道数必须是整数")
        if (audioPort.toIntOrNull() == null) add("音频端口必须是整数")
        if (controlPort.toIntOrNull() == null) add("控制端口必须是整数")
    }

    companion object {
        fun from(settings: Settings) = SettingsDraft(
            sampleRate = settings.audio.sampleRate.toString(),
            channels = settings.audio.channels.toString(),
            format = settings.audio.format,
            source = settings.audio.source,
            wifiHost = settings.wifiHost,
            audioPort = settings.audioPort.toString(),
            controlPort = settings.controlPort.toString(),
            pairingCode = settings.pairingCode,
            dns = settings.dns,
            routes = settings.routes,
        )
    }
}
