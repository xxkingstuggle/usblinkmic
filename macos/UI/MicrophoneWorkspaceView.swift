import SwiftUI
import AppKit
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

    private var usbDevice: Device? {
        snapshot.devices.first { $0.id == snapshot.selectedDeviceID } ?? snapshot.devices.first
    }

    private var deviceDisplayName: String {
        if snapshot.settings.transport == .wifi {
            return snapshot.wifiAuto.connectedPhoneName ?? "Wi-Fi 手机"
        }
        return usbDevice?.name ?? "Android 手机"
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
        outputName(for: snapshot.settings.outputUID)
    }

    private var selectedDraftOutputShortName: String {
        outputName(for: draft.outputUID)
    }

    private func outputName(for id: String) -> String {
        if id == "default" { return "系统默认声卡" }
        return snapshot.outputs.first(where: { $0.id == id })?.name ?? id
    }

    private var heroTitle: String {
        if isTaskBusy(status.phase) || status.phase == .failed {
            return status.stage.isEmpty ? status.phase.label : status.stage
        }
        if isRunning { return "正在拾音" }
        if snapshot.settings.transport == .wifi {
            return snapshot.wifiAuto.connectedPhoneName == nil ? "等待 Wi-Fi 手机" : "已就绪"
        }
        guard let usbDevice else { return "等待 USB 手机" }
        switch usbDevice.state {
        case .online: return "已就绪"
        case .unauthorized: return "等待 USB 调试授权"
        case .offline, .reenumerating: return "等待手机重新连接"
        }
    }

    private var heroSubtitle: String {
        if isRunning {
            return snapshot.receivedFrames == 0
                ? "等待手机传来音频"
                : "\(deviceDisplayName) → 此 Mac · 已接收 \(snapshot.receivedFrames.formatted()) 帧"
        }
        if !status.detail.isEmpty && status.phase != .stopped { return status.detail }
        if snapshot.settings.transport == .wifi {
            return snapshot.settings.wifiAutoConnect && snapshot.wifiAuto.phase != .off
                ? snapshot.wifiAuto.message
                : "让手机与 Mac 接入同一个局域网"
        }
        if usbDevice?.state == .online { return "\(deviceDisplayName) 已连接" }
        return "用数据线连接手机，并在手机上允许 USB 调试"
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
            VStack(alignment: .leading, spacing: 20) {
                WorkspaceHeading(
                    title: "手机麦克风",
                    subtitle: "用 Android 手机为 Mac 拾音，支持本机试听和虚拟麦克风。"
                )

                if let pair = snapshot.wifiAuto.pendingPair {
                    wifiPairPromptBanner(pair)
                }

                microphonePanel
                draftBarAndErrors

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        transportAndOutputCard
                            .frame(minWidth: 310)
                        quickTuningSection
                            .frame(width: 248)
                    }

                    VStack(spacing: 16) {
                        transportAndOutputCard
                        quickTuningSection
                    }
                }

                if draft.transport == .wifi {
                    VStack(alignment: .leading, spacing: 8) {
                        settingsHeading("Wi-Fi 连接")
                        VStack(spacing: 0) { wifiEndpointRows }
                            .insetGroupSurface()
                    }
                }

                advancedConnectionSection
                audioOptionsCard
            }
            .workspaceMargins()
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

    // MARK: - Microphone status and input

    private var microphonePanel: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(isRunning ? palette.waveBarBlue : palette.accentBlue)
                    .frame(width: 50, height: 50)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(heroTitle)
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(heroSubtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 6)

                SessionActionButton(
                    title: isStoppedOrFailed ? "开始拾音" : "停止拾音",
                    isStop: !isStoppedOrFailed,
                    isDisabled: status.phase == .stopping || snapshot.isSavingSettings
                ) {
                    send(isStoppedOrFailed ? .start(.microphone) : .stop(.microphone))
                }
            }

            if isRunning {
                LiveWaveformWell(
                    telemetry: telemetry,
                    fallbackSamples: snapshot.waveform,
                    fallbackLevel: snapshot.level
                )
            } else {
                ZenWaveformWell(samples: [], level: 0)
            }

            HStack(spacing: 10) {
                Label(snapshot.settings.transport == .usb ? "USB 有线" : "Wi-Fi",
                      systemImage: snapshot.settings.transport == .usb ? "cable.connector" : "wifi")
                Text("PCM \(effectiveAudio.format.rawValue.uppercased()) · \(sampleRateKhzText) · \(effectiveChannelsLabel)")
                    .monospacedDigit()

                if isRunning {
                    Spacer(minLength: 4)
                    Text("\(snapshot.settings.purpose == .monitor ? "本机试听" : "虚拟麦克风") · \(selectedOutputShortName)")
                        .lineLimit(1)
                        .help(selectedOutputShortName)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let errorCode = status.errorCode, !errorCode.isEmpty {
                Label("\(errorCode)：\(status.detail.isEmpty ? "请检查设备连接或查看诊断日志" : status.detail)",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(palette.stopCrimson)
            }
        }
        .padding(18)
        .background {
            shape.fill(.regularMaterial)
            shape.fill(RadialGradient(
                colors: [palette.accentBlue.opacity(palette.isDark ? 0.20 : 0.12), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 420
            ))
        }
        .overlay {
            shape.strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(palette.isDark ? 0.22 : 0.68), palette.border],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
            .allowsHitTesting(false)
        }
    }

    private func wifiPairPromptBanner(_ pair: WifiPairPrompt) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "wifi.badge.plus")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(palette.accentBlue)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("请求绑定 Wi-Fi 麦克风")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                    Text(pair.phoneName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                }
                HStack(spacing: 6) {
                    Text("确认两端显示的一致验证码：")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textSecondary)
                    Text(pair.code)
                        .font(.system(size: 16, weight: .heavy, design: .monospaced))
                        .foregroundStyle(palette.accentBlue)
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Button("拒绝") {
                    send(.rejectWifiPair(pair.requestID))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).stroke(palette.divider, lineWidth: 1))
                .foregroundStyle(palette.textSecondary)

                Button("允许并绑定") {
                    send(.approveWifiPair(pair.requestID))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(palette.accentBlue))
                .foregroundStyle(.white)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.accentBlue.opacity(0.08))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.accentBlue.opacity(0.35), lineWidth: 1)
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

    // MARK: - Connection and output

    private let connectionControlWidth: CGFloat = 168

    private var transportAndOutputCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            settingsHeading("连接与输出")

            VStack(spacing: 0) {
                settingRow(title: "传输通道", showDivider: true) {
                    ConnectionSegments(
                        title: "传输通道",
                        labels: ["USB", "Wi-Fi"],
                        width: connectionControlWidth,
                        selectedIndex: draft.transport == .usb ? 0 : 1
                    ) { index in
                        selectTransport(index == 0 ? .usb : .wifi)
                    }
                }

                settingRow(title: "输出用途", showDivider: true) {
                    ConnectionSegments(
                        title: "输出用途",
                        labels: ["本机试听", "虚拟麦克风"],
                        width: connectionControlWidth,
                        selectedIndex: draft.purpose == .monitor ? 0 : 1
                    ) { index in
                        selectPurpose(index == 0 ? .monitor : .virtualMicrophone)
                    }
                }

                settingRow(title: "目标声卡", showDivider: false) {
                    outputDeviceMenu
                }
            }
            .insetGroupSurface()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func selectTransport(_ transport: AudioTransport) {
        guard draft.transport != transport else { return }
        draft.transport = transport
        if transport == .wifi {
            let trimmed = draft.listenAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "127.0.0.1" {
                draft.listenAddress = "0.0.0.0"
            }
        }
    }

    private func selectPurpose(_ purpose: OutputPurpose) {
        guard draft.purpose != purpose else { return }
        draft.purpose = purpose
        if purpose == .virtualMicrophone,
           let firstVirtual = snapshot.outputs.first(where: { $0.isVirtual }) {
            draft.outputUID = firstVirtual.id
        } else if purpose == .monitor {
            draft.outputUID = "default"
        }
    }

    private var outputDeviceMenu: some View {
        ConnectionOutputMenu(
            width: connectionControlWidth,
            value: selectedDraftOutputShortName,
            selectedID: draft.outputUID,
            outputs: snapshot.outputs,
            showsDriverGuide: draft.purpose == .virtualMicrophone,
            selectOutput: { draft.outputUID = $0 },
            openDriverGuide: { send(.openDriverHelp) }
        )
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
                        menuLabel("跟随监听网卡")
                    }
                    .controlSize(.small)
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
                        menuLabel(isStaleWifiTargetAddress ? "已选地址不可用" : "选择活动网卡")
                    }
                    .controlSize(.small)
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

        settingRow(title: "Wi-Fi 会话配对码", showDivider: false) {
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

    private var advancedConnectionSection: some View {
        DisclosureGroup(isExpanded: $showAdvancedConnection) {
            VStack(spacing: 0) { advancedConnectionRows }
                .padding(.top, 8)
        } label: {
            Label("高级连接", systemImage: "point.3.connected.trianglepath.dotted")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .insetGroupSurface(cornerRadius: 14)
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
                    menuLabel(listenAddressLabel)
                }
                .controlSize(.small)
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
        DisclosureGroup(isExpanded: $showAudioOptions) {
            VStack(spacing: 0) {
                settingRow(title: "音频采样率", showDivider: true) {
                    Menu {
                        ForEach(Capabilities.sampleRates, id: \.self) { rate in
                            Button(sampleRateText(rate)) {
                                draft.audio.sampleRate = rate
                            }
                        }
                    } label: {
                        menuLabel(sampleRateText(draft.audio.sampleRate))
                    }
                    .controlSize(.small)
                }

                settingRow(title: "声道配置", showDivider: true) {
                    Menu {
                        Button("单声道 (1 Channel)") { draft.audio.channels = 1 }
                        Button("立体声 (2 Channels)") { draft.audio.channels = 2 }
                    } label: {
                        menuLabel(channelsText(draft.audio.channels))
                    }
                    .controlSize(.small)
                }

                settingRow(title: "PCM 采样精度", showDivider: true) {
                    Menu {
                        ForEach(PCMFormat.allCases, id: \.self) { format in
                            Button(formatText(format)) {
                                draft.audio.format = format
                            }
                        }
                    } label: {
                        menuLabel("PCM \(draft.audio.format.rawValue.uppercased())")
                    }
                    .controlSize(.small)
                }

                settingRow(title: "手机硬件音源", showDivider: false) {
                    Menu {
                        ForEach(RecordingSource.allCases, id: \.self) { source in
                            Button(sourceText(source)) {
                                draft.audio.source = source
                            }
                        }
                    } label: {
                        menuLabel(sourceText(draft.audio.source))
                    }
                    .controlSize(.small)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Label("音频参数", systemImage: "slider.horizontal.3")
                Spacer()
                Text("\(sampleRateText(draft.audio.sampleRate)) · \(draft.audio.channels == 1 ? "单声道" : "立体声") · PCM \(draft.audio.format.rawValue.uppercased())")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .insetGroupSurface(cornerRadius: 14)
    }

    // MARK: - Live controls

    private var quickTuningSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            settingsHeading("快速调音")

            VStack(spacing: 0) {
                settingRow(title: "静音 Mac 监听", showDivider: true) {
                    Toggle("静音 Mac 监听输出", isOn: Binding(
                        get: { snapshot.settings.muted },
                        set: { send(.setMuted($0)) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .help("仅关闭 Mac 播放，手机采音不受影响")
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("输入增益")
                            .fontWeight(.medium)
                        Spacer()
                        Button {
                            send(.setGain(1.0))
                        } label: {
                            Text("\(snapshot.settings.gain, format: .number.precision(.fractionLength(2)))×")
                                .monospacedDigit()
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .help("重置增益为 1.00×")
                    }

                    Slider(value: Binding(
                        get: { snapshot.settings.gain },
                        set: { send(.setGain($0)) }
                    ), in: 0...4) {
                        Text("输入数字增益")
                    }
                    .labelsHidden()
                    .help("实时放大或衰减采样信号")
                }
                .font(.callout)
                .padding(.horizontal, 14)
                .frame(minHeight: 85)
            }
            .insetGroupSurface()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsHeading(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
            .padding(.leading, 4)
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
            HStack(spacing: 8) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .layoutPriority(1)
                Spacer(minLength: 0)
                trailing()
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 42)

            if showDivider {
                Divider().padding(.horizontal, 14)
            }
        }
    }

    private func menuLabel(_ text: String) -> some View {
        Text(text)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

private struct ConnectionSegments: NSViewRepresentable {
    let title: String
    let labels: [String]
    let width: CGFloat
    let selectedIndex: Int
    let select: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(select: select) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: labels,
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.selectSegment(_:))
        )
        control.segmentDistribution = .fillEqually
        for index in labels.indices {
            control.setWidth(width / CGFloat(labels.count), forSegment: index)
        }
        control.setAccessibilityLabel(title)
        if #available(macOS 27.0, *) {
            control.role = .valueSelection
        }
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.select = select
        control.selectedSegment = selectedIndex
        control.isEnabled = context.environment.isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: width, height: nsView.intrinsicContentSize.height)
    }

    final class Coordinator: NSObject {
        var select: (Int) -> Void

        init(select: @escaping (Int) -> Void) { self.select = select }

        @objc func selectSegment(_ control: NSSegmentedControl) {
            if control.selectedSegment >= 0 { select(control.selectedSegment) }
        }
    }
}

private struct ConnectionOutputMenu: NSViewRepresentable {
    let width: CGFloat
    let value: String
    let selectedID: String
    let outputs: [OutputDevice]
    let showsDriverGuide: Bool
    let selectOutput: (String) -> Void
    let openDriverGuide: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.setAccessibilityLabel("目标声卡")
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.selectOutput = selectOutput
        coordinator.openDriverGuide = openDriverGuide
        button.isEnabled = context.environment.isEnabled
        button.setAccessibilityValue(value)

        let choices = [OutputDevice(id: "default", name: "系统默认声卡", isVirtual: false)] + outputs
        let content = MenuContent(value: value, selectedID: selectedID, choices: choices, showsDriverGuide: showsDriverGuide)
        guard coordinator.content != content else { return }
        coordinator.content = content

        let menu = NSMenu()
        menu.addItem(withTitle: value, action: nil, keyEquivalent: "")
        for choice in choices {
            let item = menu.addItem(
                withTitle: choice.name,
                action: #selector(Coordinator.chooseOutput(_:)),
                keyEquivalent: ""
            )
            item.target = coordinator
            item.representedObject = choice.id
            item.state = choice.id == selectedID ? .on : .off
            if choice.id == "default", !outputs.isEmpty {
                menu.addItem(.separator())
            }
        }
        if showsDriverGuide {
            menu.addItem(.separator())
            let item = menu.addItem(
                withTitle: "虚拟声卡驱动指南…",
                action: #selector(Coordinator.showGuide),
                keyEquivalent: ""
            )
            item.target = coordinator
        }
        button.menu = menu
        button.selectItem(at: 0)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: width, height: nsView.intrinsicContentSize.height)
    }

    struct MenuContent: Equatable {
        let value: String
        let selectedID: String
        let choices: [OutputDevice]
        let showsDriverGuide: Bool
    }

    final class Coordinator: NSObject {
        var content: MenuContent?
        var selectOutput: ((String) -> Void)?
        var openDriverGuide: (() -> Void)?

        @objc func chooseOutput(_ item: NSMenuItem) {
            if let id = item.representedObject as? String { selectOutput?(id) }
        }

        @objc func showGuide() { openDriverGuide?() }
    }
}
