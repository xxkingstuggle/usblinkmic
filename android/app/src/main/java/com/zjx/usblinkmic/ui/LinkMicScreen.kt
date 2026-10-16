package com.zjx.usblinkmic.ui

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ListAlt
import androidx.compose.material.icons.outlined.Mic
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.HorizontalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.unit.dp
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
import java.util.Date

/** Renders the current companion-app snapshot and reports user intent to its owner. */
@Composable
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
fun LinkMicScreen(snapshot: AppSnapshot, onAction: (UserAction) -> Unit) {
    var section by remember { mutableStateOf(ScreenSection.MODULES) }
    var baselineSettings by remember { mutableStateOf(snapshot.settings) }
    var draft by remember { mutableStateOf(SettingsDraft.from(snapshot.settings)) }

    LaunchedEffect(snapshot.settings) {
        val draftWasClean = draft == SettingsDraft.from(baselineSettings)
        baselineSettings = snapshot.settings
        if (draftWasClean) draft = SettingsDraft.from(snapshot.settings)
    }

    val settingsDirty = draft != SettingsDraft.from(baselineSettings)

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("USB LinkMic") },
                actions = {
                    IconButton(onClick = { onAction(UserAction.Refresh) }) {
                        Icon(Icons.Outlined.Refresh, contentDescription = "刷新状态")
                    }
                },
            )
        },
        bottomBar = {
            NavigationBar {
                ScreenSection.entries.forEach { item ->
                    NavigationBarItem(
                        selected = section == item,
                        onClick = { section = item },
                        icon = {
                            Icon(
                                imageVector = item.icon,
                                contentDescription = null,
                                modifier = Modifier.size(20.dp),
                            )
                        },
                        label = { Text(item.label) },
                    )
                }
            }
        },
    ) { contentPadding ->
        when (section) {
            ScreenSection.MODULES -> ModulesPage(
                snapshot = snapshot,
                settingsDirty = settingsDirty,
                onAction = onAction,
                modifier = Modifier.padding(contentPadding),
            )

            ScreenSection.SETTINGS -> SettingsPage(
                draft = draft,
                onDraftChange = { draft = it },
                baseline = baselineSettings,
                dirty = settingsDirty,
                onCancel = { draft = SettingsDraft.from(baselineSettings) },
                onSave = { settings -> onAction(UserAction.SaveSettings(settings)) },
                modifier = Modifier.padding(contentPadding),
            )

            ScreenSection.LOGS -> LogsPage(
                logs = snapshot.logs,
                onClear = { onAction(UserAction.ClearLogs) },
                modifier = Modifier.padding(contentPadding),
            )
        }
    }
}

@Composable
private fun ModulesPage(
    snapshot: AppSnapshot,
    settingsDirty: Boolean,
    onAction: (UserAction) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("模块状态", style = MaterialTheme.typography.headlineSmall)

        MicrophoneCard(
            status = snapshot.microphone,
            settings = snapshot.settings,
            microphonePermission = snapshot.microphonePermission,
            notificationPermission = snapshot.notificationPermission,
            controlledByMac = snapshot.controlledByMac,
            effectiveAudio = snapshot.effectiveAudio,
            frames = snapshot.frames,
            level = snapshot.level,
            settingsDirty = settingsDirty,
            onAction = onAction,
        )

        ModuleStatusCard(
            title = "手机网络给 Mac",
            status = snapshot.phoneInternet,
            footer = "通过 USB 共享手机网络；状态由 Mac 端任务报告。",
        )

        ModuleStatusCard(
            title = "Mac 网络给手机",
            status = snapshot.macInternet,
            footer = "VPN 授权：${permissionLabel(snapshot.vpnPermission)}",
            action = if (snapshot.macInternet.phase.isActive() ||
                snapshot.vpnPermission == PermissionState.SETTINGS_REQUIRED
            ) {
                {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        if (snapshot.macInternet.phase.isActive()) {
                            OutlinedButton(
                                onClick = { onAction(UserAction.StopVpn) },
                                enabled = snapshot.macInternet.phase != TaskPhase.STOPPING,
                            ) { Text("停止 Mac 供网") }
                        }
                        if (snapshot.vpnPermission == PermissionState.SETTINGS_REQUIRED) {
                            OutlinedButton(onClick = { onAction(UserAction.OpenSystemSettings) }) {
                                Text("打开应用设置")
                            }
                        }
                    }
                }
            } else {
                null
            },
        )
    }
}

@Composable
private fun MicrophoneCard(
    status: ModuleStatus,
    settings: Settings,
    microphonePermission: PermissionState,
    notificationPermission: PermissionState,
    controlledByMac: Boolean,
    effectiveAudio: AudioParameters?,
    frames: Long,
    level: Double,
    settingsDirty: Boolean,
    onAction: (UserAction) -> Unit,
) {
    Card(Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(if(controlledByMac) "USB 麦克风" else "Wi-Fi 麦克风", style = MaterialTheme.typography.titleLarge)
                    StatusLabel(status.phase)
                }
                val active = status.phase !in setOf(TaskPhase.STOPPED, TaskPhase.FAILED)
                Switch(
                    checked = active,
                    enabled = status.phase != TaskPhase.STOPPING &&
                        (active || (!settingsDirty && settings.wifiHost.isNotBlank())),
                    onCheckedChange = { checked ->
                        if (checked) onAction(UserAction.StartWifi)
                        else onAction(UserAction.StopAudio)
                    },
                    modifier = Modifier.semantics { contentDescription = "Wi-Fi 麦克风开关" },
                )
            }

            StatusDetails(status)
            Text("Mac 目标：${settings.wifiHost.ifBlank { "尚未配置" }}:${settings.audioPort}")
            Text("配对码：${if (settings.pairingCode.isBlank()) "尚未配置" else "••••••••"}")
            Text("控制方式：${if (controlledByMac) "由 Mac 控制" else "手机端"}")

            if (settingsDirty) {
                Text(
                    "设置草稿尚未保存；保存后才能使用新目标。",
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodySmall,
                )
            } else if (settings.wifiHost.isBlank()) {
                Text(
                    "请先在设置中填写 Mac 的 Wi-Fi 地址。",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.bodySmall,
                )
            }

            HorizontalDivider()
            Text("麦克风权限：${permissionLabel(microphonePermission)}")
            Text("通知权限：${permissionLabel(notificationPermission)}")
            if (microphonePermission == PermissionState.SETTINGS_REQUIRED ||
                notificationPermission == PermissionState.SETTINGS_REQUIRED
            ) {
                OutlinedButton(onClick = { onAction(UserAction.OpenSystemSettings) }) {
                    Text("打开应用设置")
                }
            }
            effectiveAudio?.let { Text("实际音频参数：${audioSummary(it)}") }
            if (status.phase == TaskPhase.RUNNING) {
                if (frames > 0) {
                    Text("有效音频帧：$frames · 样本电平：${"%.3f".format(level)}")
                } else {
                    Text("等待音频首帧")
                }
            }
        }
    }
}

@Composable
private fun ModuleStatusCard(
    title: String,
    status: ModuleStatus,
    footer: String? = null,
    action: (@Composable () -> Unit)? = null,
) {
    Card(Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(title, style = MaterialTheme.typography.titleLarge)
                    StatusLabel(status.phase)
                }
                action?.invoke()
            }
            StatusDetails(status)
            footer?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
        }
    }
}

@Composable
private fun StatusLabel(phase: TaskPhase) {
    val (label, container) = when (phase) {
        TaskPhase.STOPPED -> "已停止" to MaterialTheme.colorScheme.surfaceVariant
        TaskPhase.CHECKING -> "检查中" to MaterialTheme.colorScheme.secondaryContainer
        TaskPhase.PREPARING -> "准备中" to MaterialTheme.colorScheme.secondaryContainer
        TaskPhase.WAITING_USER -> "等待你确认" to MaterialTheme.colorScheme.tertiaryContainer
        TaskPhase.CONNECTING -> "连接中" to MaterialTheme.colorScheme.secondaryContainer
        TaskPhase.RUNNING -> "运行中" to MaterialTheme.colorScheme.primaryContainer
        TaskPhase.STOPPING -> "停止中" to MaterialTheme.colorScheme.secondaryContainer
        TaskPhase.FAILED -> "失败" to MaterialTheme.colorScheme.errorContainer
    }
    Surface(shape = MaterialTheme.shapes.small, color = container) {
        Text(
            label,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
            style = MaterialTheme.typography.labelLarge,
        )
    }
}

@Composable
private fun StatusDetails(status: ModuleStatus) {
    Text(status.stage, style = MaterialTheme.typography.bodyMedium)
    if (status.detail.isNotBlank()) {
        Text(status.detail, style = MaterialTheme.typography.bodySmall)
    }
    status.errorCode?.let {
        Text("错误代码：$it", color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
    }
}

@Composable
private fun SettingsPage(
    draft: SettingsDraft,
    onDraftChange: (SettingsDraft) -> Unit,
    baseline: Settings,
    dirty: Boolean,
    onCancel: () -> Unit,
    onSave: (Settings) -> Unit,
    modifier: Modifier = Modifier,
) {
    val parsedSettings = draft.toSettings(baseline)
    val errors = if (parsedSettings == null) draft.parseErrors() else SettingsValidator.errors(parsedSettings)

    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("设置草稿", style = MaterialTheme.typography.headlineSmall)
        Text("修改保存在本页草稿中；保存后等待应用状态确认。")

        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Wi-Fi 麦克风", style = MaterialTheme.typography.titleMedium)
                DraftTextField(
                    value = draft.wifiHost,
                    onValueChange = { onDraftChange(draft.copy(wifiHost = it)) },
                    label = "Mac 目标地址",
                    tag = "wifi-host",
                    placeholder = "例如 192.168.1.10",
                )
                DraftTextField(
                    value = draft.audioPort,
                    onValueChange = { onDraftChange(draft.copy(audioPort = it)) },
                    label = "音频端口",
                    tag = "audio-port",
                    keyboardType = KeyboardType.Number,
                )
                DraftTextField(
                    value = draft.controlPort,
                    onValueChange = { onDraftChange(draft.copy(controlPort = it)) },
                    label = "控制端口",
                    tag = "control-port",
                    keyboardType = KeyboardType.Number,
                )
                PairingCodeField(draft.pairingCode) {
                    onDraftChange(draft.copy(pairingCode = it))
                }
            }
        }

        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("音频采集", style = MaterialTheme.typography.titleMedium)
                ChoiceRow(
                    title = "采样率",
                    options = Capabilities.SAMPLE_RATES,
                    selected = draft.sampleRate.toIntOrNull(),
                    label = { "$it Hz" },
                    onSelect = { onDraftChange(draft.copy(sampleRate = it.toString())) },
                )
                ChoiceRow(
                    title = "声道",
                    options = Capabilities.CHANNELS,
                    selected = draft.channels.toIntOrNull(),
                    label = { if (it == 1) "单声道" else "${it} 声道" },
                    onSelect = { onDraftChange(draft.copy(channels = it.toString())) },
                )
                ChoiceRow(
                    title = "PCM 格式",
                    options = PCMFormat.entries,
                    selected = draft.format,
                    label = { if (it == PCMFormat.I16) "i16" else "f32" },
                    onSelect = { onDraftChange(draft.copy(format = it)) },
                )
                ChoiceRow(
                    title = "录音源",
                    options = RecordingSource.entries,
                    selected = draft.source,
                    label = ::recordingSourceLabel,
                    onSelect = { onDraftChange(draft.copy(source = it)) },
                )
            }
        }

        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("网络设置", style = MaterialTheme.typography.titleMedium)
                DraftTextField(
                    value = draft.dns,
                    onValueChange = { onDraftChange(draft.copy(dns = it)) },
                    label = "DNS IPv4",
                    tag = "dns",
                )
                DraftTextField(
                    value = draft.routes,
                    onValueChange = { onDraftChange(draft.copy(routes = it)) },
                    label = "IPv4 CIDR 路由",
                    tag = "routes",
                    singleLine = false,
                )
            }
        }

        if (errors.isNotEmpty()) {
            Card(
                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("设置校验未通过", style = MaterialTheme.typography.titleSmall)
                    errors.forEach { Text("• $it", style = MaterialTheme.typography.bodySmall) }
                }
            }
        }

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = onCancel, enabled = dirty) { Text("取消草稿") }
            Button(
                onClick = { parsedSettings?.let(onSave) },
                enabled = dirty && parsedSettings != null && errors.isEmpty(),
                modifier = Modifier.testTag("save-settings"),
            ) { Text("保存设置") }
        }
        Spacer(Modifier.height(8.dp))
    }
}

@Composable
private fun PairingCodeField(value: String, onValueChange: (String) -> Unit) {
    var revealed by remember { mutableStateOf(false) }
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = Modifier.fillMaxWidth().testTag("pairing-code"),
        label = { Text("Wi-Fi 配对码") },
        singleLine = true,
        visualTransformation = if (revealed) VisualTransformation.None else PasswordVisualTransformation(),
        trailingIcon = {
            OutlinedButton(onClick = { revealed = !revealed }) {
                Text(if (revealed) "隐藏" else "显示")
            }
        },
    )
}

@Composable
private fun DraftTextField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    tag: String,
    placeholder: String? = null,
    keyboardType: KeyboardType = KeyboardType.Text,
    singleLine: Boolean = true,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = Modifier.fillMaxWidth().testTag(tag),
        label = { Text(label) },
        placeholder = if (placeholder != null) ({ Text(placeholder) }) else null,
        singleLine = singleLine,
        keyboardOptions = KeyboardOptions(keyboardType = keyboardType),
    )
}

@Composable
private fun <T> ChoiceRow(
    title: String,
    options: List<T>,
    selected: T?,
    label: (T) -> String,
    onSelect: (T) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(title, style = MaterialTheme.typography.labelLarge)
        Row(
            modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            options.forEach { option ->
                FilterChip(
                    selected = option == selected,
                    onClick = { onSelect(option) },
                    label = { Text(label(option)) },
                )
            }
        }
    }
}

@Composable
private fun LogsPage(logs: List<LogEntry>, onClear: () -> Unit, modifier: Modifier = Modifier) {
    Column(modifier = modifier.fillMaxSize().padding(16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("运行日志", style = MaterialTheme.typography.headlineSmall)
                Text("${logs.size} 条")
            }
            OutlinedButton(onClick = onClear, enabled = logs.isNotEmpty()) { Text("清空") }
        }
        Spacer(Modifier.height(12.dp))
        if (logs.isEmpty()) {
            Text("暂无日志")
        } else {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                items(logs) { entry ->
                    Card(Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text(
                                "${formatTimestamp(entry.timestamp)} · ${LogRedactor.redact(entry.module)} · ${LogRedactor.redact(entry.stage)}",
                                style = MaterialTheme.typography.labelMedium,
                            )
                            Text(LogRedactor.redact(entry.message), style = MaterialTheme.typography.bodyMedium)
                        }
                    }
                }
            }
        }
    }
}

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

private enum class ScreenSection(val label: String, val icon: androidx.compose.ui.graphics.vector.ImageVector) {
    MODULES("模块", Icons.Outlined.Mic),
    SETTINGS("设置", Icons.Outlined.Settings),
    LOGS("日志", Icons.Outlined.ListAlt),
}

private fun TaskPhase.isActive(): Boolean = this !in setOf(TaskPhase.STOPPED, TaskPhase.FAILED)

private fun permissionLabel(state: PermissionState): String = when (state) {
    PermissionState.NOT_REQUESTED -> "尚未请求"
    PermissionState.WAITING -> "等待确认"
    PermissionState.ALLOWED -> "已允许"
    PermissionState.DENIED -> "已拒绝"
    PermissionState.SETTINGS_REQUIRED -> "需要系统设置"
}

private fun audioSummary(audio: AudioParameters): String =
    "${audio.sampleRate} Hz · ${audio.channels} 声道 · ${if (audio.format == PCMFormat.I16) "i16" else "f32"} · ${recordingSourceLabel(audio.source)}"

private fun recordingSourceLabel(source: RecordingSource): String = when (source) {
    RecordingSource.MICROPHONE -> "普通麦克风"
    RecordingSource.UNPROCESSED -> "未处理输入"
    RecordingSource.VOICE_RECOGNITION -> "语音识别"
}

private fun formatTimestamp(timestamp: Long): String =
    DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.MEDIUM).format(Date(timestamp))
