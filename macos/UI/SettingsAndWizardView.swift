import SwiftUI
import Contracts
import Support

struct SettingsSheet: View {
    @Binding var settings: Contracts.Settings
    @Binding var isDirty: Bool
    let outputs: [OutputDevice]
    let onCancel: () -> Void
    let onSave: () -> Void

    @State private var selectedTab: SettingsTab = .audio

    enum SettingsTab: String, CaseIterable, Identifiable {
        case audio = "音频与输出"
        case connection = "传输与端口"
        case network = "网络共享"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .audio: "waveform.badge.mic"
            case .connection: "antenna.radiowaves.left.and.right"
            case .network: "network"
            }
        }
    }

    private var errors: [String] {
        SettingsValidator.errors(settings) + SettingsValidator.outputErrors(settings, outputs: outputs)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if !errors.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(errors.enumerated()), id: \.offset) { _, error in
                        Label(error, systemImage: "exclamationmark.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.red.opacity(0.09))
                Divider()
            }

            Form {
                switch selectedTab {
                case .audio:
                    audioSection
                case .connection:
                    connectionSection
                case .network:
                    networkSection
                }
            }
            .formStyle(.grouped)

            Divider()
            footerBar
        }
        .frame(minWidth: 580, minHeight: 540)
        .onChange(of: settings) { _, _ in isDirty = true }
        .onChange(of: settings.purpose) { old, purpose in
            if purpose == .virtualMicrophone {
                let virtualOutputs = outputs.filter { $0.isVirtual }
                if !virtualOutputs.contains(where: { $0.id == settings.outputUID }), virtualOutputs.count == 1 {
                    settings.outputUID = virtualOutputs[0].id
                }
            } else if old == .virtualMicrophone {
                settings.outputUID = "default"
            }
        }
    }

    private var headerBar: some View {
        VStack(spacing: 14) {
            HStack {
                HStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("偏好设置")
                            .font(.title3.weight(.semibold))
                        Text("保存连接或采样参数时将安全停止当前会话；取消将还原草稿。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isDirty {
                    StatusPill(label: "未保存更改", tint: .orange)
                }
            }

            Picker("设置分类", selection: $selectedTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.symbol).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(.bar)
    }

    private var footerBar: some View {
        HStack {
            Text("协议版本 v\(Capabilities.protocolVersion) · 应用版本 \(Capabilities.version)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("取消", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("保存并应用", action: onSave)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!errors.isEmpty)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(.bar)
    }

    @ViewBuilder
    private var audioSection: some View {
        Section("采集参数") {
            Picker("传输方式", selection: $settings.transport) {
                Text("USB 有线转发").tag(AudioTransport.usb)
                Text("Wi-Fi 局域网").tag(AudioTransport.wifi)
            }
            Picker("采样率", selection: $settings.audio.sampleRate) {
                ForEach(Capabilities.sampleRates, id: \.self) { rate in
                    Text("\(rate) Hz").tag(rate)
                }
            }
            Picker("声道数", selection: $settings.audio.channels) {
                ForEach(Capabilities.channels, id: \.self) { channels in
                    Text(channels == 1 ? "单声道 (Mono)" : "立体声 (Stereo)").tag(channels)
                }
            }
            Picker("PCM 采样格式", selection: $settings.audio.format) {
                ForEach(PCMFormat.allCases, id: \.self) { format in
                    Text(format.rawValue.uppercased()).tag(format)
                }
            }
            Picker("手机录音源", selection: $settings.audio.source) {
                ForEach(RecordingSource.allCases, id: \.self) { source in
                    Text(source.label).tag(source)
                }
            }
        }

        Section("输出设备与初始音量") {
            Picker("输出用途", selection: $settings.purpose) {
                Text("本机试听（耳机/扬声器）").tag(OutputPurpose.monitor)
                Text("虚拟麦克风（送入其他软件）").tag(OutputPurpose.virtualMicrophone)
            }
            Picker("目标输出设备", selection: $settings.outputUID) {
                if settings.purpose == .monitor {
                    Text("系统默认设备").tag("default")
                } else if !outputs.contains(where: { $0.id == settings.outputUID && $0.isVirtual }) {
                    Text("请选择虚拟声卡（如 BlackHole）").tag(settings.outputUID)
                }
                if settings.outputUID != "default" && !outputs.contains(where: { $0.id == settings.outputUID }) {
                    Text("已选输出设备暂不可用").tag(settings.outputUID)
                }
                ForEach(outputs.filter { settings.purpose == .monitor || $0.isVirtual }) { output in
                    Text(output.name).tag(output.id)
                }
            }
            LabeledContent("输出增益") {
                HStack {
                    Slider(value: $settings.gain, in: 0...4)
                        .frame(maxWidth: 220)
                    Text("\(settings.gain, format: .number.precision(.fractionLength(2)))×")
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
            }
            Toggle("静音 Mac 输出", isOn: $settings.muted)
        }
    }

    @ViewBuilder
    private var connectionSection: some View {
        Section {
            TextField("监听 IPv4 地址", text: $settings.listenAddress)
                .font(.body.monospaced())
            TextField("音频端口 (TCP)", value: $settings.audioPort, format: .number)
                .font(.body.monospacedDigit())
            TextField("控制端口 (TCP)", value: $settings.controlPort, format: .number)
                .font(.body.monospacedDigit())
        } header: {
            Text("本地监听与端口")
        } footer: {
            Text("USB 模式下监听地址固定使用 127.0.0.1；Wi-Fi 模式下若保持 127.0.0.1，启动时会自动绑定局域网地址。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Wi-Fi 无线麦克风选项") {
            TextField("手机 IPv4 地址（可选）", text: $settings.wifiHost)
                .font(.body.monospaced())
            TextField("会话配对码（留空则免配对码）", text: $settings.pairingCode)
                .font(.body.monospaced())
        }
    }

    @ViewBuilder
    private var networkSection: some View {
        Section {
            TextField("DNS 服务器 IPv4", text: $settings.dns)
                .font(.body.monospaced())
            TextField("转发路由 CIDR（逗号分隔）", text: $settings.routes)
                .font(.body.monospaced())
        } header: {
            Text("Mac 网络给手机（VPN 转发）")
        } footer: {
            Text("默认路由 0.0.0.0/0 会将手机全部 IPv4 流量经由 USB 转发至 Mac 当前网络出口。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Native Onboarding Setup Wizard

struct SetupWizard: View {
    let snapshot: AppSnapshot
    @Binding var step: Int
    let send: (UserAction) -> Void

    private let steps: [(title: String, subtitle: String, symbol: String)] = [
        ("连接 Android 手机", "通过 USB 连接手机并授权 USB 调试", "iphone.gen3.radiowaves.left.and.right"),
        ("确认手机麦克风权限", "由手机系统弹窗确认录音与前台通知权限", "mic.badge.plus"),
        ("验证真实声音输入", "确认收到真实音频帧并能听见声音", "waveform.badge.checkmark")
    ]

    var body: some View {
        VStack(spacing: 0) {
            wizardHeader
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch step {
                    case 0:
                        connectStep
                    case 1:
                        microphoneStep
                    default:
                        soundTestStep
                    }
                }
                .padding(24)
            }

            Divider()
            wizardFooter
        }
        .frame(minWidth: 540, minHeight: 430)
    }

    private var wizardHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                AppBrandIcon(size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("欢迎使用 USB LinkMic")
                        .font(.title3.weight(.semibold))
                    Text("第 \(step + 1) 步（共 3 步）：\(steps[step].subtitle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("跳过向导") {
                    send(.skipWizard)
                }
                .controlSize(.small)
                .disabled(snapshot.wizardSkipped)
            }

            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    let isDone = index < step || snapshot.soundTestCompleted
                    let isCurrent = index == step
                    HStack(spacing: 6) {
                        Image(systemName: isDone ? "checkmark.circle.fill" : "\(index + 1).circle.fill")
                            .foregroundStyle(isDone ? .green : (isCurrent ? Color.accentColor : .secondary))
                        Text(steps[index].title)
                            .font(.caption.weight(isCurrent ? .semibold : .regular))
                            .foregroundStyle(isCurrent || isDone ? .primary : .secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity)
                    .background(
                        (isCurrent ? Color.accentColor : (isDone ? Color.green : Color.secondary)).opacity(0.11),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(.bar)
    }

    private var wizardFooter: some View {
        HStack {
            if step > 0 {
                Button("上一步") { step -= 1 }
            }
            Spacer()
            if step < 2 {
                Button("下一步") { step += 1 }
                    .buttonStyle(.borderedProminent)
            } else if snapshot.soundTestCompleted {
                Label("声音测试已完成", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private var connectStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("请用数据线将 Android 手机连接到 Mac，并在手机弹出的「允许 USB 调试吗？」对话框中点击允许。")
                .font(.callout)
                .foregroundStyle(.secondary)

            if snapshot.devices.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "iphone.slash")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("当前未检测到手机")
                            .font(.callout.weight(.semibold))
                        Text("连接手机并开启 USB 调试后，点击下方「刷新设备」。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(16)
                .insetGroupSurface()
            } else {
                ForEach(snapshot.devices) { device in
                    let isSelected = device.id == snapshot.selectedDeviceID
                    Button {
                        send(.selectDevice(device.id))
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name).font(.callout.weight(.semibold))
                                Text(device.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            StatusPill(label: device.state.label, tint: device.state.tint)
                        }
                        .padding(12)
                        .insetGroupSurface()
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                send(.refresh)
            } label: {
                Label("刷新设备", systemImage: "arrow.clockwise")
            }
        }
    }

    private var microphoneStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("点击「开始麦克风准备」后，手机将自动启动配套服务并请求系统录音授权。")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                HStack {
                    Label("麦克风录音权限", systemImage: "mic.fill")
                    Spacer()
                    StatusPill(
                        label: snapshot.microphonePermission.label,
                        symbol: snapshot.microphonePermission.symbol,
                        tint: snapshot.microphonePermission.tint
                    )
                }
                Divider()
                HStack {
                    Label("前台通知权限", systemImage: "bell.badge.fill")
                    Spacer()
                    StatusPill(
                        label: snapshot.notificationPermission.label,
                        symbol: snapshot.notificationPermission.symbol,
                        tint: snapshot.notificationPermission.tint
                    )
                }
                Divider()
                HStack {
                    Label("当前任务阶段", systemImage: "bolt.horizontal.circle")
                    Spacer()
                    StatusPill(
                        label: snapshot.microphone.stage.isEmpty ? snapshot.microphone.phase.label : snapshot.microphone.stage,
                        tint: snapshot.microphone.phase.tint
                    )
                }
            }
            .padding(14)
            .insetGroupSurface()

            HStack(spacing: 10) {
                Button {
                    send(.start(.microphone))
                } label: {
                    Label("开始麦克风准备", systemImage: "mic.fill")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    send(.openPhoneSettings)
                } label: {
                    Label("打开手机应用设置", systemImage: "arrow.up.right.square")
                }
            }
        }
    }

    private var soundTestStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("请对着手机说话，确认下方电平条跳动并能实际听到声音（或在目标软件看到输入电平），然后点击确认。")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("音频传输状态")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    StatusPill(label: snapshot.audioState.label, tint: snapshot.audioState.tint)
                }
                StudioLevelMeter(
                    level: snapshot.level,
                    isStreaming: snapshot.audioState == .streaming,
                    isMuted: snapshot.settings.muted
                )
                Text("已接收有效音频帧：\(snapshot.receivedFrames)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .insetGroupSurface()

            HStack(spacing: 10) {
                Button {
                    send(.start(.microphone))
                } label: {
                    Label("开始声音测试", systemImage: "play.fill")
                }
                .disabled(isTaskBusy(snapshot.microphone.phase) || snapshot.microphone.phase == .running)

                Button {
                    send(.completeSoundTest)
                } label: {
                    Label("我已确认真实声音", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .disabled(snapshot.soundTestCompleted || snapshot.audioState != .streaming || snapshot.receivedFrames == 0)
            }
        }
    }
}
