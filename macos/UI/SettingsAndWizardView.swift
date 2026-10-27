import SwiftUI
import Contracts
import Support

struct SettingsSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var settings: Contracts.Settings
    @Binding var isDirty: Bool
    let outputs: [OutputDevice]
    let onCancel: () -> Void
    let onSave: () -> Void

    private var palette: ZenPalette { ZenPalette(colorScheme) }

    private var errors: [String] {
        SettingsValidator.errors(settings) + SettingsValidator.outputErrors(settings, outputs: outputs)
    }

    private var sampleRateLabel: String {
        switch settings.audio.sampleRate {
        case 16000: "16.0 kHz (语音级)"
        case 44100: "44.1 kHz (CD 级)"
        case 48000: "48.0 kHz (录音室)"
        case 96000: "96.0 kHz (母带级)"
        default: "\(settings.audio.sampleRate) Hz"
        }
    }

    private var channelsLabel: String {
        settings.audio.channels == 1 ? "单声道 (1 Channel)" : "立体声 (2 Channels)"
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            Rectangle()
                .fill(palette.divider)
                .frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    audioSamplingGroup
                    networkParamsGroup
                    sessionSafetyGroup

                    if !errors.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(errors.enumerated()), id: \.offset) { _, error in
                                Text("• \(error)")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(palette.stopCrimson)
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
            }

            footerBar
        }
        .frame(width: 520, height: settings.transport == .wifi ? 700 : 640)
        .background(palette.cardBackground)
        .onChange(of: settings) { _, _ in isDirty = true }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Text("偏好设置")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(palette.textPrimary)

            Spacer()

            Text("⌘,")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.textTertiary)
        }
        .padding(.horizontal, 28)
        .frame(height: 58)
    }

    // MARK: - Group 1: 音频采样与缓冲区

    private var audioSamplingGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("音频采样与编码")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.textSecondary)

            VStack(spacing: 0) {
                settingRow(title: "音频采样率", showDivider: true) {
                    Menu {
                        ForEach(Capabilities.sampleRates, id: \.self) { rate in
                            Button(rate == 44100 ? "44.1 kHz (CD 级)" : "\(rate) Hz") {
                                settings.audio.sampleRate = rate
                            }
                        }
                    } label: {
                        dropdownPillLabel(sampleRateLabel)
                    }
                    .buttonStyle(.plain)
                }

                settingRow(title: "声道配置", showDivider: true) {
                    Menu {
                        Button("单声道 (1 Channel)") { settings.audio.channels = 1 }
                        Button("立体声 (2 Channels)") { settings.audio.channels = 2 }
                    } label: {
                        dropdownPillLabel(channelsLabel)
                    }
                    .buttonStyle(.plain)
                }

                settingRow(title: "PCM 采样精度", showDivider: true) {
                    Menu {
                        ForEach(PCMFormat.allCases, id: \.self) { format in
                            Button("PCM \(format.rawValue.uppercased())") {
                                settings.audio.format = format
                            }
                        }
                    } label: {
                        dropdownPillLabel("PCM \(settings.audio.format.rawValue.uppercased())")
                    }
                    .buttonStyle(.plain)
                }

                settingRow(title: "手机硬件音源", showDivider: false) {
                    Menu {
                        ForEach(RecordingSource.allCases, id: \.self) { source in
                            Button(source.label) {
                                settings.audio.source = source
                            }
                        }
                    } label: {
                        dropdownPillLabel(settings.audio.source.label)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(palette.windowBackground)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(palette.border, lineWidth: 1)
            }
        }
    }

    // MARK: - Group 2: 网络共享高级参数

    private var networkParamsGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("网络共享高级参数")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.textSecondary)

            VStack(spacing: 0) {
                settingRow(title: "物理共享协议", showDivider: true) {
                    Menu {
                        Button("USB NCM 原生以太网") { settings.transport = .usb }
                        Button("Wi-Fi 局域网音频传输") { settings.transport = .wifi }
                    } label: {
                        Text(settings.transport == .usb ? "USB NCM 原生以太网" : "Wi-Fi 无线局域网")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(palette.emeraldGreen)
                    }
                    .buttonStyle(.plain)
                }

                settingRow(title: "下发 DNS 服务器", showDivider: true) {
                    TextField("223.5.5.5", text: $settings.dns)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(palette.textPrimary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .frame(width: 144, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(palette.cardBackground)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(palette.border, lineWidth: 1)
                        }
                }

                settingRow(title: "转发路由网段", showDivider: settings.transport == .wifi) {
                    TextField("0.0.0.0/0", text: $settings.routes)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(palette.textSecondary)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 180)
                }

                if settings.transport == .wifi {
                    settingRow(title: "手机 Wi-Fi 地址", showDivider: true) {
                        TextField("如 192.168.1.10", text: $settings.wifiHost)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(palette.textPrimary)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 160)
                    }

                    settingRow(title: "会话配对码", showDivider: false) {
                        TextField("留空则免配对码", text: $settings.pairingCode)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(palette.textPrimary)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 180)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(palette.windowBackground)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(palette.border, lineWidth: 1)
            }
        }
    }

    // MARK: - Group 3: 会话安全边界

    private var sessionSafetyGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("会话安全边界")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.textSecondary)

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("退出时恢复设备原生模式")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                    Text("自动关闭 NCM 与 ADB TCP 转发，不留残余")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textTertiary)
                }

                Spacer()

                Text("始终启用")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.emeraldGreen)
            }
            .padding(.horizontal, 20)
            .frame(height: 68)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(palette.windowBackground)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(palette.border, lineWidth: 1)
            }
        }
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 12) {
            Spacer()

            Button(action: onCancel) {
                Text("取消")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                    .frame(width: 78, height: 36)
                    .background(palette.segmentedTrack, in: Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)

            Button(action: onSave) {
                Text("保存应用")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 96, height: 36)
                    .background(
                        palette.isDark
                            ? Color(red: 0x2E / 255.0, green: 0xA0 / 255.0, blue: 0x43 / 255.0)
                            : Color(red: 0x00 / 255.0, green: 0x71 / 255.0, blue: 0xE3 / 255.0),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(!errors.isEmpty)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 22)
    }

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
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 7))
                .foregroundStyle(palette.textSecondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(palette.cardBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 1)
        }
    }
}

// MARK: - Onboarding Setup Wizard

struct SetupWizard: View {
    @Environment(\.colorScheme) private var colorScheme
    let snapshot: AppSnapshot
    @Binding var step: Int
    let send: (UserAction) -> Void

    private var palette: ZenPalette { ZenPalette(colorScheme) }

    private let steps: [(title: String, subtitle: String)] = [
        ("连接 Android 手机", "通过 USB 连接手机并授权 USB 调试"),
        ("确认手机麦克风权限", "由手机系统弹窗确认录音与前台通知权限"),
        ("验证真实声音输入", "确认收到真实音频帧并能听见声音")
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("欢迎使用 USB LinkMic")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                    Text("第 \(step + 1) 步（共 3 步）：\(steps[step].subtitle)")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textSecondary)
                }
                Spacer()
                Button("跳过向导") {
                    send(.skipWizard)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .disabled(snapshot.wizardSkipped)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            Rectangle()
                .fill(palette.divider)
                .frame(height: 1)

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

            Rectangle()
                .fill(palette.divider)
                .frame(height: 1)

            HStack {
                if step > 0 {
                    Button("上一步") { step -= 1 }
                }
                Spacer()
                if step < 2 {
                    Button("下一步") { step += 1 }
                        .buttonStyle(.borderedProminent)
                } else if snapshot.soundTestCompleted {
                    Text("声音测试已完成")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.emeraldGreen)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 520, height: 420)
        .background(palette.cardBackground)
    }

    private var connectStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("请用数据线将 Android 手机连接到 Mac，并在手机弹出的「允许 USB 调试吗？」对话框中点击允许。")
                .font(.system(size: 13))
                .foregroundStyle(palette.textSecondary)

            if snapshot.devices.isEmpty {
                HStack(spacing: 12) {
                    LineArtPhoneIcon(strokeColor: palette.textSecondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("当前未检测到手机")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(palette.textPrimary)
                        Text("连接手机并开启 USB 调试后，点击下方「刷新设备」。")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.textSecondary)
                    }
                    Spacer()
                }
                .padding(16)
                .zenCard(cornerRadius: 14)
            } else {
                ForEach(snapshot.devices) { device in
                    let isSelected = device.id == snapshot.selectedDeviceID
                    Button {
                        send(.selectDevice(device.id))
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isSelected ? palette.accentBlue : palette.textSecondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name).font(.system(size: 14, weight: .semibold))
                                Text(device.id).font(.system(size: 12, design: .monospaced)).foregroundStyle(palette.textSecondary)
                            }
                            Spacer()
                            StatusPill(label: device.state.label, tint: device.state.tint)
                        }
                        .padding(14)
                        .zenCard(cornerRadius: 14)
                    }
                    .buttonStyle(.plain)
                }
            }

            Button("刷新设备") {
                send(.refresh)
            }
        }
    }

    private var microphoneStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("点击「开始麦克风准备」后，手机将自动启动配套服务并请求系统录音授权。")
                .font(.system(size: 13))
                .foregroundStyle(palette.textSecondary)

            VStack(spacing: 10) {
                HStack {
                    Text("麦克风录音权限")
                    Spacer()
                    StatusPill(label: snapshot.microphonePermission.label, tint: snapshot.microphonePermission.tint)
                }
                Divider()
                HStack {
                    Text("前台通知权限")
                    Spacer()
                    StatusPill(label: snapshot.notificationPermission.label, tint: snapshot.notificationPermission.tint)
                }
            }
            .padding(16)
            .zenCard(cornerRadius: 14)

            HStack(spacing: 10) {
                Button("开始麦克风准备") {
                    send(.start(.microphone))
                }
                .buttonStyle(.borderedProminent)

                Button("打开手机应用设置") {
                    send(.openPhoneSettings)
                }
            }
        }
    }

    private var soundTestStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("请对着手机说话，确认下方声波跳动并能实际听到声音，然后点击确认。")
                .font(.system(size: 13))
                .foregroundStyle(palette.textSecondary)

            ZenWaveformWell(samples: snapshot.waveform, level: snapshot.level, barCount: 36, showDbPill: true)

            HStack(spacing: 10) {
                Button("开始声音测试") {
                    send(.start(.microphone))
                }
                .disabled(isTaskBusy(snapshot.microphone.phase) || snapshot.microphone.phase == .running)

                Button("我已确认真实声音") {
                    send(.completeSoundTest)
                }
                .buttonStyle(.borderedProminent)
                .disabled(snapshot.soundTestCompleted || snapshot.audioState != .streaming || snapshot.receivedFrames == 0)
            }
        }
    }
}
