import SwiftUI
import Contracts

struct MicrophoneWorkspaceView: View {
    @Environment(\.colorScheme) private var colorScheme
    let snapshot: AppSnapshot
    let send: (UserAction) -> Void
    let onOpenSettings: () -> Void

    private var palette: ZenPalette { ZenPalette(colorScheme) }
    private var status: ModuleStatus { snapshot.microphone }
    private var isStoppedOrFailed: Bool { status.phase == .stopped || status.phase == .failed }
    private var isRunning: Bool { status.phase == .running || snapshot.audioState == .streaming }

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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ZenWorkspaceHeroHeader(
                    eyebrow: "麦克风输入",
                    title: heroTitle,
                    subtitle: heroSubtitle
                )

                heroMicrophoneCard

                quickTuningSection
            }
            .frame(maxWidth: 816, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 30)
        }
    }

    // MARK: - Hero Card ("静如止水" vs "动如雷霆")

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
                        let transportDesc = snapshot.settings.transport == .usb ? "USB 有线连接" : "Wi-Fi 无线局域网传输"
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
                ZenWaveformWell(
                    samples: snapshot.waveform,
                    level: snapshot.level,
                    barCount: 48,
                    showDbPill: true
                )

                Rectangle()
                    .fill(palette.divider)
                    .frame(height: 1)

                activeFooterBar
            } else {
                Rectangle()
                    .fill(palette.divider)
                    .frame(height: 1)

                stillInlineConfigBar
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

    // MARK: - Still Mode Inline Configuration Row

    private var stillInlineConfigBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 20) {
                routeControlGroup
                outputControlGroup
                Spacer(minLength: 8)
                transportControlGroup
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 16) {
                    routeControlGroup
                    Spacer(minLength: 8)
                    transportControlGroup
                }
                outputControlGroup
            }
        }
    }

    private var routeControlGroup: some View {
        HStack(spacing: 12) {
            Text("输出路由")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(palette.textSecondary)
                .fixedSize()

            purposeSegmentedPill
        }
    }

    private var outputControlGroup: some View {
        HStack(spacing: 12) {
            Text("目标声卡")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(palette.textSecondary)
                .fixedSize()

            outputDeviceMenu
        }
    }

    private var transportControlGroup: some View {
        HStack(spacing: 10) {
            Text("通道")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(palette.textSecondary)
                .fixedSize()

            Menu {
                Button("USB 有线 (低延迟)") {
                    updateSettings { $0.transport = .usb }
                }
                Button("Wi-Fi 局域网") {
                    updateSettings { $0.transport = .wifi }
                }
                Divider()
                Button("高级传输设置…", action: onOpenSettings)
            } label: {
                Text(snapshot.settings.transport == .usb ? "USB 有线 (低延迟)" : "Wi-Fi 局域网")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .fixedSize()
            }
            .buttonStyle(.plain)
        }
    }

    private var purposeSegmentedPill: some View {
        HStack(spacing: 0) {
            purposeSegmentButton(title: "本机试听", purpose: .monitor)
            purposeSegmentButton(title: "虚拟麦克风", purpose: .virtualMicrophone)
        }
        .padding(2)
        .frame(height: 34)
        .background(palette.segmentedTrack, in: Capsule())
    }

    private func purposeSegmentButton(title: String, purpose: OutputPurpose) -> some View {
        let isSelected = snapshot.settings.purpose == purpose
        return Button {
            guard snapshot.settings.purpose != purpose else { return }
            updateSettings { draft in
                draft.purpose = purpose
                if purpose == .virtualMicrophone,
                   let firstVirtual = snapshot.outputs.first(where: { $0.isVirtual }) {
                    draft.outputUID = firstVirtual.id
                } else if purpose == .monitor {
                    draft.outputUID = "default"
                }
            }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? palette.textPrimary : palette.textSecondary)
                .frame(width: 92, height: 30)
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
                updateSettings { $0.outputUID = "default" }
            }
            if !snapshot.outputs.isEmpty {
                Divider()
                ForEach(snapshot.outputs) { output in
                    Button(output.name) {
                        updateSettings { $0.outputUID = output.id }
                    }
                }
            }
            Divider()
            Button("声卡与采样设置…", action: onOpenSettings)
            if snapshot.settings.purpose == .virtualMicrophone {
                Button("虚拟声卡驱动指南…") {
                    send(.openDriverHelp)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(selectedOutputShortName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(palette.textSecondary)
            }
            .padding(.horizontal, 14)
            .frame(minWidth: 164, minHeight: 34)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(palette.cardBackground)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(palette.border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Active Mode Footer Row

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

    // MARK: - Section 2: 快速调音 Card

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

    private func updateSettings(_ mutate: (inout Contracts.Settings) -> Void) {
        var next = snapshot.settings
        mutate(&next)
        send(.saveSettings(next))
    }
}
