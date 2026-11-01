import SwiftUI
import Contracts
import Support

struct MicrophoneSettingsDraft: Equatable {
    var transport: AudioTransport
    var purpose: OutputPurpose
    var outputUID: String
    var audio: AudioParameters
    var wifiHost: String
    var pairingCode: String
    var audioPort: Int
    var listenAddress: String

    init(from settings: Contracts.Settings) {
        self.transport = settings.transport
        self.purpose = settings.purpose
        self.outputUID = settings.outputUID
        self.audio = settings.audio
        self.wifiHost = settings.wifiHost
        self.pairingCode = settings.pairingCode
        self.audioPort = settings.audioPort
        self.listenAddress = settings.listenAddress
    }

    func merge(into baseline: Contracts.Settings) -> Contracts.Settings {
        var copy = baseline
        copy.transport = self.transport
        copy.purpose = self.purpose
        copy.outputUID = self.outputUID
        copy.audio = self.audio
        copy.wifiHost = self.wifiHost
        copy.pairingCode = self.pairingCode
        copy.audioPort = self.audioPort
        copy.listenAddress = self.listenAddress
        return copy
    }

    func diffSummaries(from baseline: Contracts.Settings) -> [String] {
        var diffs: [String] = []
        if transport != baseline.transport {
            diffs.append("通道: \(baseline.transport == .usb ? "USB" : "Wi-Fi") → \(transport == .usb ? "USB" : "Wi-Fi")")
        }
        if purpose != baseline.purpose {
            diffs.append("用途: \(baseline.purpose == .monitor ? "本机试听" : "虚拟麦克风") → \(purpose == .monitor ? "本机试听" : "虚拟麦克风")")
        }
        if outputUID != baseline.outputUID {
            diffs.append("输出声卡变更")
        }
        if audio.sampleRate != baseline.audio.sampleRate {
            diffs.append("采样率: \(baseline.audio.sampleRate)Hz → \(audio.sampleRate)Hz")
        }
        if audio.channels != baseline.audio.channels {
            diffs.append("声道: \(baseline.audio.channels == 1 ? "单声道" : "立体声") → \(audio.channels == 1 ? "单声道" : "立体声")")
        }
        if audio.format != baseline.audio.format {
            diffs.append("PCM \(audio.format.rawValue.uppercased())")
        }
        if audio.source != baseline.audio.source {
            diffs.append("音源变更")
        }
        if wifiHost != baseline.wifiHost {
            diffs.append("Wi-Fi 地址")
        }
        if pairingCode != baseline.pairingCode {
            diffs.append("配对码")
        }
        if audioPort != baseline.audioPort {
            diffs.append("音频端口 \(audioPort)")
        }
        if listenAddress != baseline.listenAddress {
            diffs.append("监听范围")
        }
        return diffs
    }
}

struct MicrophoneWorkspaceView: View {
    @Environment(\.colorScheme) private var colorScheme
    let snapshot: AppSnapshot
    var telemetry: AudioTelemetry? = nil
    let send: (UserAction) -> Void

    @State private var draft: MicrophoneSettingsDraft
    @State private var showAdvancedConnection: Bool
    @State private var showAudioOptions: Bool
    @State private var awaitingSaveCompletion: Bool = false

    public init(
        snapshot: AppSnapshot,
        telemetry: AudioTelemetry? = nil,
        initialShowAdvancedConnection: Bool = false,
        initialShowAudioOptions: Bool = false,
        send: @escaping (UserAction) -> Void
    ) {
        self.snapshot = snapshot
        self.telemetry = telemetry
        self.send = send
        _draft = State(initialValue: MicrophoneSettingsDraft(from: snapshot.settings))
        _showAdvancedConnection = State(initialValue: initialShowAdvancedConnection)
        _showAudioOptions = State(initialValue: initialShowAudioOptions)
    }

    private var palette: ZenPalette { ZenPalette(colorScheme) }
    private var status: ModuleStatus { snapshot.microphone }
    private var isStoppedOrFailed: Bool { status.phase == .stopped || status.phase == .failed }
    private var isRunning: Bool { status.phase == .running || snapshot.audioState == .streaming }

    private var isDirty: Bool {
        draft != MicrophoneSettingsDraft(from: snapshot.settings)
    }

    private var deviceDisplayName: String {
        if let id = snapshot.selectedDeviceID,
           let device = snapshot.devices.first(where: { $0.id == id }) {
            return device.name
        }
        if let first = snapshot.devices.first {
            return first.name
        }
        return "Android 手机"
    }

    private var effectiveAudio: AudioParameters {
        snapshot.effectiveAudio ?? snapshot.settings.audio
    }

    private var sampleRateKhzText: String {
        let rate = Double(effectiveAudio.sampleRate) / 1000.0
        if effectiveAudio.sampleRate % 1000 == 0 {
            return "\(effectiveAudio.sampleRate / 1000) kHz"
        }
        return String(format: "%.1f kHz", rate)
    }

    private var effectiveChannelsLabel: String {
        effectiveAudio.channels == 1 ? "单声道 1ch" : "立体声 2ch"
    }

    private var selectedOutputShortName: String {
        if let match = snapshot.outputs.first(where: { $0.id == snapshot.settings.outputUID }) {
            return match.name
        }
        if snapshot.settings.outputUID == "default" {
            return snapshot.outputs.first(where: { $0.isVirtual })?.name ?? "系统默认声卡"
        }
        return snapshot.settings.outputUID
    }

    private var selectedDraftOutputShortName: String {
        if let match = snapshot.outputs.first(where: { $0.id == draft.outputUID }) {
            return match.name
        }
        if draft.outputUID == "default" {
            return snapshot.outputs.first(where: { $0.isVirtual })?.name ?? "系统默认声卡"
        }
        return draft.outputUID
    }

    private var heroTitle: String {
        if isRunning {
            return "正在向 Mac 传输音频"
        }
        if isTaskBusy(status.phase) {
            return status.stage.isEmpty ? status.phase.label : status.stage
        }
        if status.phase == .failed {
            return status.stage.isEmpty ? "音频连接异常" : status.stage
        }
        return "随时就绪"
    }

    private var heroSubtitle: String {
        if isRunning {
            return snapshot.receivedFrames == 0
                ? "等待手机端首帧音频…"
                : "音频流稳定推送中 · 累计接收 \(snapshot.receivedFrames.formatted()) 帧"
        }
        if !status.detail.isEmpty && status.phase != .stopped {
            return status.detail
        }
        let channelName = snapshot.settings.transport == .usb ? "USB 有线" : "Wi-Fi 局域网"
        return "通过 \(channelName) 传输手机麦克风信号至 Mac，支持耳机实时试听或作为会议虚拟麦克风。"
    }

    // MARK: - Wi-Fi Candidates & Validation

    private var wifiListenCandidates: [String] {
        var result: [String] = []
        for candidate in snapshot.lanCandidates where SettingsValidator.isUsableWifiTargetHost(candidate) && !result.contains(candidate) {
            result.append(candidate)
        }
        return result
    }

    private var effectiveWifiListenAddress: String {
        var wifiSettings = draft.merge(into: snapshot.settings)
        wifiSettings.transport = .wifi
        return SettingsValidator.effectiveBindAddress(for: wifiSettings)
    }

    private var isStaleWifiListenAddress: Bool {
        draft.transport == .wifi &&
        effectiveWifiListenAddress != "0.0.0.0" &&
        !wifiListenCandidates.isEmpty &&
        !wifiListenCandidates.contains(effectiveWifiListenAddress)
    }

    private var isStaleWifiTargetAddress: Bool {
        let normalizedHost = SettingsValidator.normalizedWifiTargetHost(draft.wifiHost)
        guard draft.transport == .wifi,
              !normalizedHost.isEmpty,
              SettingsValidator.isValidIPv4(normalizedHost),
              !wifiListenCandidates.isEmpty else {
            return false
        }
        return !wifiListenCandidates.contains(normalizedHost)
    }

    private var listenAddressLabel: String {
        if draft.transport == .usb {
            return "127.0.0.1 (仅本机 USB 转发)"
        }
        switch effectiveWifiListenAddress {
        case "0.0.0.0":
            return "0.0.0.0 (监听局域网所有接口)"
        default:
            if isStaleWifiListenAddress {
                return "\(effectiveWifiListenAddress) (已选地址不可用，请重选)"
            }
            return "\(effectiveWifiListenAddress) (仅监听指定局域网网卡)"
        }
    }

    private var validationErrors: [String] {
        let merged = draft.merge(into: snapshot.settings)
        let checkOutput = SettingsValidator.requiresOutputValidation(from: snapshot.settings, to: merged, microphoneActive: isRunning)
        var result = SettingsValidator.errors(merged) + (checkOutput ? SettingsValidator.outputErrors(merged, outputs: snapshot.outputs) : [])
        if draft.transport == .wifi {
            let activeSet: Set<String>? = wifiListenCandidates.isEmpty ? nil : Set(wifiListenCandidates)
            for err in SettingsValidator.wifiEndpointErrors(merged, activeLanAddresses: activeSet) where !result.contains(err) {
                result.append(err)
            }
        }
        return result
    }

    private func sampleRateText(_ rate: Int) -> String {
        switch rate {
        case 16000: "16.0 kHz"
        case 44100: "44.1 kHz"
        case 48000: "48.0 kHz"
        case 96000: "96.0 kHz"
        default: "\(rate) Hz"
        }
    }

    private func channelsText(_ channels: Int) -> String {
        channels == 1 ? "单声道 (1 Channel)" : "立体声 (2 Channels)"
    }

    private func formatText(_ format: PCMFormat) -> String {
        switch format {
        case .i16: "PCM 16-bit 整数 (i16)"
        case .f32: "PCM 32-bit 浮点 (f32)"
        }
    }

    private func sourceText(_ source: RecordingSource) -> String {
        switch source {
        case .microphone: "内置主麦克风 (MIC)"
        case .unprocessed: "原始未处理音源 (UNPROCESSED)"
        case .voiceRecognition: "语音识别优化 (VOICE_RECOGNITION)"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ZenWorkspaceHeroHeader(
                    eyebrow: "麦克风输入",
                    title: heroTitle,
                    subtitle: heroSubtitle
                )

                heroMicrophoneCard

                draftBarAndErrors

                transportAndOutputCard

                audioOptionsCard

                quickTuningSection
            }
            .frame(maxWidth: 816, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 30)
        }
        .onChange(of: snapshot.settingsSavedRevision) { _, _ in
            if awaitingSaveCompletion {
                draft = MicrophoneSettingsDraft(from: snapshot.settings)
                awaitingSaveCompletion = false
            } else if !isDirty {
                draft = MicrophoneSettingsDraft(from: snapshot.settings)
            }
        }
        .onChange(of: snapshot.isSavingSettings) { _, isSaving in
            if !isSaving && snapshot.settingsError != nil {
                awaitingSaveCompletion = false
            }
        }
        .onChange(of: snapshot.settings) { _, newSettings in
            if !isDirty && !awaitingSaveCompletion && !snapshot.isSavingSettings && snapshot.settingsError == nil {
                draft = MicrophoneSettingsDraft(from: newSettings)
            }
        }
    }

    // MARK: - Hero Card

    private var heroMicrophoneCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 18) {
                LineArtMicIcon(
                    strokeColor: isRunning ? palette.waveBarBlue : palette.textPrimary,
                    size: 44
                )

                VStack(alignment: .leading, spacing: 5) {
                    Text(isRunning ? "\(deviceDisplayName) 麦克风 · 传输中" : "\(deviceDisplayName) 麦克风")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(palette.textPrimary)

                    if isRunning {
                        Text("PCM \(effectiveAudio.format.rawValue.uppercased()) · \(effectiveAudio.sampleRate) Hz · \(effectiveChannelsLabel)")
                            .font(.system(size: 13, weight: .regular).monospacedDigit())
                            .foregroundStyle(palette.textSecondary)
                    } else {
                        let transportDesc = snapshot.settings.transport == .usb ? "USB 有线连接" : "Wi-Fi 局域网传输"
                        Text("\(transportDesc) · \(sampleRateKhzText) · \(effectiveChannelsLabel)")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(palette.textSecondary)
                    }
                }
                .layoutPriority(1)

                Spacer(minLength: 16)

                ZenCapsuleActionButton(
                    title: isStoppedOrFailed ? "开始拾音" : "停止拾音",
                    isStop: !isStoppedOrFailed,
                    width: 144,
                    height: 48,
                    isDisabled: status.phase == .stopping || snapshot.isSavingSettings
                ) {
                    send(isStoppedOrFailed ? .start(.microphone) : .stop(.microphone))
                }
            }

            if isRunning {
                LiveWaveformWell(
                    telemetry: telemetry,
                    fallbackSamples: snapshot.waveform,
                    fallbackLevel: snapshot.level,
                    barCount: 48,
                    showDbPill: true
                )

                Rectangle()
                    .fill(palette.divider)
                    .frame(height: 1)

                activeFooterBar
            }

            if let errorCode = status.errorCode, !errorCode.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(palette.stopCrimson)
                    Text("\(errorCode)：\(status.detail.isEmpty ? "请检查设备连接或前往诊断日志排障" : status.detail)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.stopCrimson)
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .zenCard(isActive: isRunning, cornerRadius: 20)
    }

    private var activeFooterBar: some View {
        HStack(alignment: .center) {
            HStack(spacing: 10) {
                Text("当前输出")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(palette.textSecondary)

                Text("\(snapshot.settings.purpose == .monitor ? "本机试听" : "虚拟麦克风") · \(selectedOutputShortName)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
            }

            Spacer()

            Text("通道：\(snapshot.settings.transport == .usb ? "USB 有线" : "Wi-Fi")")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(palette.textSecondary)
        }
    }

    // MARK: - Draft & Feedback Bar

    @ViewBuilder
    private var draftBarAndErrors: some View {
        if !validationErrors.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(palette.stopCrimson)
                    Text("参数校验未通过")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.stopCrimson)
                    Spacer()
                }
                ForEach(validationErrors, id: \.self) { err in
                    Text("• \(err)")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.stopCrimson)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(palette.stopCrimson.opacity(0.1))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(palette.stopCrimson.opacity(0.3), lineWidth: 1)
            }
        }

        if let error = snapshot.settingsError, !error.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(palette.stopCrimson)
                Text(error)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.stopCrimson)
                Spacer()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(palette.stopCrimson.opacity(0.1))
            )
        }

        if snapshot.isSavingSettings, !snapshot.settingsMessage.isEmpty {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(snapshot.settingsMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                Spacer()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(palette.windowBackground)
            )
        }

        if isDirty {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("未应用修改")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(palette.accentBlue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(palette.accentBlue.opacity(0.15), in: Capsule())

                        Text(isRunning ? "应用修改将停止麦克风传输" : "修改将在点击保存后生效")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(palette.textPrimary)
                    }

                    let diffs = draft.diffSummaries(from: snapshot.settings)
                    if !diffs.isEmpty {
                        Text("待应用：\(diffs.joined(separator: " · "))")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Button("放弃修改") {
                    draft = MicrophoneSettingsDraft(from: snapshot.settings)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(palette.segmentedTrack, in: Capsule())
                .disabled(snapshot.isSavingSettings)

                Button {
                    saveDraft()
                } label: {
                    Text(snapshot.isSavingSettings ? "保存中…" : (isRunning ? "应用并停止麦克风" : "保存音频选项"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            isRunning ? palette.stopCrimson : palette.accentBlue,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .disabled(snapshot.isSavingSettings || !validationErrors.isEmpty)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(palette.cardBackground)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(palette.accentBlue.opacity(0.4), lineWidth: 1)
            }
        }
    }

    // MARK: - Transport & Output Settings Card

    private var transportAndOutputCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("传输与输出设置")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)

                Spacer()

                if draft.transport == .wifi {
                    Text("当前选择 Wi-Fi 直连")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textTertiary)
                }
            }

            VStack(spacing: 0) {
                // Row 1: Transport Channel
                settingRow(title: "传输通道", showDivider: true) {
                    HStack(spacing: 0) {
                        transportSegmentButton("USB 有线", transport: .usb)
                        transportSegmentButton("Wi-Fi 局域网", transport: .wifi)
                    }
                    .padding(2)
                    .frame(height: 32)
                    .background(palette.segmentedTrack, in: Capsule())
                }

                // Row 2: Purpose
                settingRow(title: "输出用途", showDivider: true) {
                    HStack(spacing: 0) {
                        purposeSegmentButton("本机试听", purpose: .monitor)
                        purposeSegmentButton("虚拟麦克风", purpose: .virtualMicrophone)
                    }
                    .padding(2)
                    .frame(height: 32)
                    .background(palette.segmentedTrack, in: Capsule())
                }

                // Row 3: Output Device
                settingRow(title: "目标声卡", showDivider: draft.transport == .wifi || showAdvancedConnection) {
                    outputDeviceMenu
                }

                // WiFi specific rows (only visible in WiFi mode)
                if draft.transport == .wifi {
                    wifiEndpointRows
                }

                // Advanced connection rows (collapsible)
                if showAdvancedConnection {
                    advancedConnectionRows
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(palette.cardBackground)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(palette.border, lineWidth: 1)
            }

            // Expand / Collapse Advanced Connection Options
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showAdvancedConnection.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showAdvancedConnection ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                    Text(showAdvancedConnection
                        ? "收起高级连接选项"
                        : (draft.transport == .usb ? "展开高级连接选项 (端口与监听范围)" : "展开 Wi-Fi 高级连接选项 (监听范围与端口)"))
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(palette.textSecondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)
        }
    }

    private func transportSegmentButton(_ title: String, transport: AudioTransport) -> some View {
        let isSelected = draft.transport == transport
        return Button {
            guard draft.transport != transport else { return }
            draft.transport = transport
            if transport == .wifi {
                let trimmed = draft.listenAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed == "127.0.0.1" {
                    draft.listenAddress = "0.0.0.0"
                }
            }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? palette.textPrimary : palette.textSecondary)
                .frame(width: 96, height: 28)
                .background(
                    Capsule()
                        .fill(isSelected ? palette.cardBackground : Color.clear)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func purposeSegmentButton(_ title: String, purpose: OutputPurpose) -> some View {
        let isSelected = draft.purpose == purpose
        return Button {
            guard draft.purpose != purpose else { return }
            draft.purpose = purpose
            if purpose == .virtualMicrophone,
               let firstVirtual = snapshot.outputs.first(where: { $0.isVirtual }) {
                draft.outputUID = firstVirtual.id
            } else if purpose == .monitor {
                draft.outputUID = "default"
            }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? palette.textPrimary : palette.textSecondary)
                .frame(width: 92, height: 28)
                .background(
                    Capsule()
                        .fill(isSelected ? palette.cardBackground : Color.clear)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var outputDeviceMenu: some View {
        Menu {
            Button("系统默认声卡") {
                draft.outputUID = "default"
            }
            if !snapshot.outputs.isEmpty {
                Divider()
                ForEach(snapshot.outputs) { output in
                    Button(output.name) {
                        draft.outputUID = output.id
                    }
                }
            }
            if draft.purpose == .virtualMicrophone {
                Divider()
                Button("虚拟声卡驱动指南…") {
                    send(.openDriverHelp)
                }
            }
        } label: {
            dropdownPillLabel(selectedDraftOutputShortName)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Wi-Fi Specific Inline Settings

    @ViewBuilder
    private var wifiEndpointRows: some View {
        settingRow(title: "供手机连接的 Mac 地址", showDivider: true) {
            HStack(spacing: 8) {
                if effectiveWifiListenAddress != "0.0.0.0" && !isStaleWifiListenAddress {
                    Menu {
                        Button("自动使用监听网卡 (\(effectiveWifiListenAddress))") { draft.wifiHost = "" }
                        Button(effectiveWifiListenAddress) { draft.wifiHost = effectiveWifiListenAddress }
                    } label: {
                        dropdownPillLabel("跟随监听网卡")
                    }
                    .buttonStyle(.plain)
                } else if !wifiListenCandidates.isEmpty {
                    Menu {
                        Button("留空自动识别") { draft.wifiHost = "" }
                        ForEach(wifiListenCandidates, id: \.self) { ip in
                            Button(ip) { draft.wifiHost = ip }
                        }
                        if isStaleWifiTargetAddress {
                            Divider()
                            Text("已保存不可用地址：\(SettingsValidator.normalizedWifiTargetHost(draft.wifiHost))（请改选上方有效网卡）")
                        }
                    } label: {
                        dropdownPillLabel(isStaleWifiTargetAddress ? "已选地址不可用" : "选择活动网卡")
                    }
                    .buttonStyle(.plain)
                }

                TextField(
                    effectiveWifiListenAddress != "0.0.0.0"
                        ? "留空默认使用 \(effectiveWifiListenAddress)"
                        : "留空自动识别 Mac 局域网 IP",
                    text: $draft.wifiHost
                )
                .textFieldStyle(.plain)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(palette.textPrimary)
                .multilineTextAlignment(.trailing)
                .frame(width: wifiListenCandidates.isEmpty && effectiveWifiListenAddress == "0.0.0.0" ? 210 : 150)
            }
        }

        settingRow(title: "Wi-Fi 会话配对码", showDivider: showAdvancedConnection) {
            TextField("留空免配对码，或填 32 位十六进制", text: $draft.pairingCode)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(palette.textPrimary)
                .multilineTextAlignment(.trailing)
                .frame(width: 220)
        }

        wifiGuidanceBanner
    }

    private var wifiGuidanceBanner: some View {
        let displayHost = draft.wifiHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (wifiListenCandidates.first ?? "Mac局域网IP")
            : draft.wifiHost
        let codeHint = draft.pairingCode.isEmpty ? "无需配对码" : "需配对码"

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wifi")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.accentBlue)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text("Wi-Fi 连接指引")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                Text(verbatim: "手机与 Mac 连至同一局域网；在手机 App 填写 Mac 地址「\(displayHost)」、端口「\(draft.audioPort)」（\(codeHint)）开启 Wi-Fi 麦克风。")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textSecondary)
            }
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(palette.windowBackground)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Advanced Connection Rows (Collapsed by Default)

    @ViewBuilder
    private var advancedConnectionRows: some View {
        if draft.transport == .usb {
            settingRow(title: "Mac 监听范围", showDivider: true) {
                Text("127.0.0.1 (仅本机 USB 转发)")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(palette.textSecondary)
            }
        } else {
            settingRow(title: "Mac 监听范围", showDivider: true) {
                Menu {
                    Button("0.0.0.0 (监听局域网所有接口)") { draft.listenAddress = "0.0.0.0" }
                    ForEach(wifiListenCandidates, id: \.self) { candidate in
                        Button("\(candidate) (仅监听指定局域网网卡)") {
                            draft.listenAddress = candidate
                            let normalizedTarget = SettingsValidator.normalizedWifiTargetHost(draft.wifiHost)
                            if !normalizedTarget.isEmpty,
                               SettingsValidator.isValidIPv4(normalizedTarget),
                               normalizedTarget != candidate {
                                draft.wifiHost = ""
                            }
                        }
                    }
                    if isStaleWifiListenAddress {
                        Divider()
                        Text("已选不可用地址：\(effectiveWifiListenAddress)（请改选有效接口）")
                    }
                } label: {
                    dropdownPillLabel(listenAddressLabel)
                }
                .buttonStyle(.plain)
            }
        }

        settingRow(title: "Mac 音频接收端口", showDivider: true) {
            TextField("48124", value: $draft.audioPort, format: .number.grouping(.never))
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(palette.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)
                .frame(width: 96, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(palette.windowBackground)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(palette.border, lineWidth: 1)
                }
        }

        settingRow(title: "手机控制端口（应用管理）", showDivider: false) {
            HStack(spacing: 8) {
                Text(verbatim: "\(snapshot.settings.controlPort)")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(palette.textSecondary)
                Text("（麦克风与网络共用，本页不修改）")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textTertiary)
            }
        }
    }

    // MARK: - Audio Options (Expandable in page)

    private var audioOptionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showAudioOptions.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: showAudioOptions ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(palette.textSecondary)

                    Text("音频选项")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)

                    Spacer()

                    Text("\(sampleRateText(draft.audio.sampleRate)) · \(draft.audio.channels == 1 ? "单声道" : "立体声") · PCM \(draft.audio.format.rawValue.uppercased()) · \(draft.audio.source.label)")
                        .font(.system(size: 11, weight: .regular).monospacedDigit())
                        .foregroundStyle(palette.textTertiary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)

            if showAudioOptions {
                VStack(spacing: 0) {
                    settingRow(title: "音频采样率", showDivider: true) {
                        Menu {
                            ForEach(Capabilities.sampleRates, id: \.self) { rate in
                                Button(sampleRateText(rate)) {
                                    draft.audio.sampleRate = rate
                                }
                            }
                        } label: {
                            dropdownPillLabel(sampleRateText(draft.audio.sampleRate))
                        }
                        .buttonStyle(.plain)
                    }

                    settingRow(title: "声道配置", showDivider: true) {
                        Menu {
                            Button("单声道 (1 Channel)") { draft.audio.channels = 1 }
                            Button("立体声 (2 Channels)") { draft.audio.channels = 2 }
                        } label: {
                            dropdownPillLabel(channelsText(draft.audio.channels))
                        }
                        .buttonStyle(.plain)
                    }

                    settingRow(title: "PCM 采样精度", showDivider: true) {
                        Menu {
                            ForEach(PCMFormat.allCases, id: \.self) { format in
                                Button(formatText(format)) {
                                    draft.audio.format = format
                                }
                            }
                        } label: {
                            dropdownPillLabel("PCM \(draft.audio.format.rawValue.uppercased())")
                        }
                        .buttonStyle(.plain)
                    }

                    settingRow(title: "手机硬件音源", showDivider: false) {
                        Menu {
                            ForEach(RecordingSource.allCases, id: \.self) { source in
                                Button(sourceText(source)) {
                                    draft.audio.source = source
                                }
                            }
                        } label: {
                            dropdownPillLabel(sourceText(draft.audio.source))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(palette.cardBackground)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(palette.border, lineWidth: 1)
                }
            }
        }
    }

    // MARK: - Section 2: Quick Tuning Card (immediate effect)

    private var quickTuningSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("快速调音")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.textSecondary)

            VStack(spacing: 0) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("静音 Mac 监听输出")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(palette.textPrimary)
                        Text("仅关闭 Mac 播放，手机采音不受影响")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(palette.textTertiary)
                    }

                    Spacer()

                    Toggle("静音 Mac 监听输出", isOn: Binding(
                        get: { snapshot.settings.muted },
                        set: { send(.setMuted($0)) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                .padding(.horizontal, 28)
                .frame(height: 88)

                Rectangle()
                    .fill(palette.divider)
                    .frame(height: 1)
                    .padding(.horizontal, 28)

                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("输入数字增益")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(palette.textPrimary)
                        Text("实时放大或衰减采样信号")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(palette.textTertiary)
                    }

                    Spacer()

                    HStack(spacing: 16) {
                        Slider(
                            value: Binding(
                                get: { snapshot.settings.gain },
                                set: { send(.setGain($0)) }
                            ),
                            in: 0...4
                        )
                        .tint(palette.accentBlue)
                        .frame(width: 180)

                        Button {
                            send(.setGain(1.0))
                        } label: {
                            Text("\(snapshot.settings.gain, format: .number.precision(.fractionLength(2)))×")
                                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                .foregroundStyle(palette.textPrimary)
                                .frame(width: 46, alignment: .trailing)
                        }
                        .buttonStyle(.plain)
                        .help("点击重置为 1.00×")
                    }
                }
                .padding(.horizontal, 28)
                .frame(height: 88)
            }
            .zenCard(isActive: false, cornerRadius: 18)
        }
    }

    // MARK: - Save Draft

    private func saveDraft() {
        guard !snapshot.isSavingSettings, validationErrors.isEmpty else { return }
        awaitingSaveCompletion = true
        let merged = draft.merge(into: snapshot.settings)
        send(.saveSettings(merged))
    }

    // MARK: - Helpers

    private func settingRow<Trailing: View>(
        title: String,
        showDivider: Bool,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)

                Spacer()

                trailing()
            }
            .padding(.horizontal, 20)
            .frame(height: 46)

            if showDivider {
                Rectangle()
                    .fill(palette.divider)
                    .frame(height: 1)
                    .padding(.horizontal, 20)
            }
        }
    }

    private func dropdownPillLabel(_ text: String) -> some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(palette.textSecondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(palette.windowBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 1)
        }
    }
}
