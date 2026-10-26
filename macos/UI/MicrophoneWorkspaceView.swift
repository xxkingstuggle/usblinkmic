import SwiftUI
import Contracts

struct MicrophoneWorkspaceView: View {
    let snapshot: AppSnapshot
    let send: (UserAction) -> Void
    let onOpenSettings: () -> Void

    private var status: ModuleStatus { snapshot.microphone }
    private var isStoppedOrFailed: Bool { status.phase == .stopped || status.phase == .failed }
    private var isStreaming: Bool { snapshot.audioState == .streaming }

    private var boundedLevel: Double {
        guard snapshot.level.isFinite else { return 0 }
        return min(max(snapshot.level, 0), 1)
    }

    private var selectedOutputName: String {
        if snapshot.settings.outputUID == "default" {
            return "系统默认输出设备"
        }
        return snapshot.outputs.first(where: { $0.id == snapshot.settings.outputUID })?.name
            ?? "已选设备暂不可用 (\(snapshot.settings.outputUID))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heroConsoleCard
                realtimeAudioControlSection
                transportAndDeviceSection
            }
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
    }

    // MARK: - Studio Hero Console Card

    private var heroConsoleCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(status.phase.tint.opacity(0.15))
                        .frame(width: 46, height: 46)
                    Image(systemName: snapshot.settings.muted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(snapshot.settings.muted ? .orange : status.phase.tint)
                        .symbolRenderingMode(.hierarchical)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(status.stage.isEmpty ? status.phase.label : status.stage)
                            .font(.title3.weight(.semibold))
                        StatusPill(
                            label: snapshot.audioState.label,
                            symbol: isStreaming ? "waveform" : nil,
                            tint: snapshot.audioState.tint
                        )
                        if snapshot.settings.muted {
                            StatusPill(
                                label: "Mac 输出已静音",
                                symbol: "speaker.slash.fill",
                                tint: .orange
                            )
                        }
                    }

                    Text(
                        status.detail.isEmpty
                            ? "将 Android 手机作为低延迟麦克风接入 Mac，支持耳机实时试听或通过虚拟声卡送入会议软件。"
                            : status.detail
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 5) {
                    Button {
                        send(isStoppedOrFailed ? .start(.microphone) : .stop(.microphone))
                    } label: {
                        Label(
                            isStoppedOrFailed ? "开始拾音" : "停止拾音",
                            systemImage: isStoppedOrFailed ? "play.fill" : "stop.fill"
                        )
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isStoppedOrFailed ? .accentColor : .red)
                    .controlSize(.large)
                    .disabled(status.phase == .stopping || snapshot.isSavingSettings)

                    if !snapshot.settingsMessage.isEmpty {
                        Text(snapshot.settingsMessage)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Divider()
                .opacity(0.55)

            // Live Level Meter & Waveform Visualizer
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    Label("实时输入电平", systemImage: "gauge.with.dots.needle.67percent")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)

                    StudioLevelMeter(
                        level: boundedLevel,
                        isStreaming: isStreaming,
                        isMuted: snapshot.settings.muted
                    )

                    Text("\(Int((boundedLevel * 100).rounded()))%")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(isStreaming ? .primary : .secondary)
                        .frame(width: 38, alignment: .trailing)
                }

                if !snapshot.waveform.isEmpty || isStreaming {
                    WaveformView(
                        samples: snapshot.waveform,
                        tint: snapshot.settings.muted ? .orange : (isStreaming ? .green : .accentColor)
                    )
                    .frame(height: 36)
                    .padding(.vertical, 2)
                    .accessibilityLabel("来自当前快照的音频波形")
                }
            }

            // Effective Audio Parameters & Frame Telemetry Bar
            HStack(spacing: 6) {
                let effective = snapshot.effectiveAudio ?? snapshot.settings.audio
                ParameterTag(
                    snapshot.settings.transport == .usb ? "USB 通道" : "Wi-Fi 无线",
                    symbol: snapshot.settings.transport == .usb ? "cable.connector" : "wifi"
                )
                ParameterTag("\(effective.sampleRate) Hz")
                ParameterTag(effective.channels == 1 ? "单声道" : "立体声")
                ParameterTag("PCM \(effective.format.rawValue.uppercased())")
                ParameterTag(effective.source.label)
                Spacer(minLength: 4)
                Text("有效帧：\(snapshot.receivedFrames)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }

            if let errorCode = status.errorCode, !errorCode.isEmpty {
                errorBanner(code: errorCode, detail: status.detail)
            }
        }
        .padding(18)
        .heroGlassSurface(tint: status.phase.tint)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Pixel-Aligned Native Grouped Sections

    private var realtimeAudioControlSection: some View {
        NativeGroupedSection("实时调音与输出路由") {
            NativeSettingRow(
                title: "静音 Mac 输出",
                subtitle: "仅静音 Mac 端播放或声卡输出，不会中断手机端采音会话",
                symbol: snapshot.settings.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                symbolTint: snapshot.settings.muted ? .orange : .accentColor
            ) {
                Toggle("静音 Mac 输出", isOn: Binding(
                    get: { snapshot.settings.muted },
                    set: { send(.setMuted($0)) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            NativeSettingRow(
                title: "输入数字增益",
                subtitle: "实时放大或衰减 PCM 样本，无需重启录音",
                symbol: "dial.medium.fill",
                symbolTint: .blue
            ) {
                HStack(spacing: 8) {
                    Slider(
                        value: Binding(
                            get: { snapshot.settings.gain },
                            set: { send(.setGain($0)) }
                        ),
                        in: 0...4
                    )
                    .frame(width: 150)

                    Text("\(snapshot.settings.gain, format: .number.precision(.fractionLength(2)))×")
                        .font(.callout.monospacedDigit().weight(.medium))
                        .frame(width: 48, alignment: .trailing)

                    if abs(snapshot.settings.gain - 1.0) >= 0.005 {
                        Button("重置") {
                            send(.setGain(1.0))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .fixedSize(horizontal: true, vertical: false)
                    } else {
                        Text("标准")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.quaternary.opacity(0.6), in: Capsule())
                    }
                }
            }

            NativeSettingRow(
                title: "音频输出路由",
                subtitle: selectedOutputName,
                symbol: snapshot.settings.purpose == .monitor ? "headphones" : "mic.and.signal.meter",
                symbolTint: .indigo,
                showDivider: false
            ) {
                HStack(spacing: 8) {
                    StatusPill(
                        label: snapshot.settings.purpose == .monitor ? "本机试听" : "虚拟麦克风",
                        tint: .accentColor
                    )

                    if snapshot.settings.purpose == .virtualMicrophone {
                        Button {
                            send(.openDriverHelp)
                        } label: {
                            Label("驱动指南", systemImage: "arrow.up.right.square")
                        }
                        .controlSize(.small)
                    }

                    Button("更改…", action: onOpenSettings)
                        .controlSize(.small)
                }
            }
        }
    }

    private var transportAndDeviceSection: some View {
        NativeGroupedSection(
            "连接与目标设备",
            footer: snapshot.settings.transport == .wifi
                ? "点击「开始拾音」后 Mac 将监听局域网连接；若此时手机插着 USB，会自动将本机局域网 IP 同步至手机。"
                : nil
        ) {
            NativeSettingRow(
                title: "目标 Android 手机",
                subtitle: snapshot.devices.isEmpty ? "连接手机并开启 USB 调试后点击刷新" : "选择用于拾音或同步参数的手机",
                symbol: "iphone.gen3",
                symbolTint: snapshot.devices.isEmpty ? .secondary : .green
            ) {
                HStack(spacing: 8) {
                    if snapshot.devices.isEmpty {
                        Text("未检测到手机")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("选择手机", selection: selectedDeviceBinding) {
                            Text("请选择设备").tag(String?.none)
                            ForEach(snapshot.devices) { device in
                                Text("\(device.name) (\(device.state.shortLabel))")
                                    .tag(Optional(device.id))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 210)
                    }
                    Button {
                        send(.refresh)
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                }
            }

            NativeSettingRow(
                title: "当前传输通道",
                subtitle: snapshot.settings.transport == .usb
                    ? "通过 ADB TCP 转发实现超低延迟有线传输"
                    : "音频端口 \(snapshot.settings.audioPort) · 配对码：\(snapshot.settings.pairingCode.isEmpty ? "免配对码" : snapshot.settings.pairingCode)",
                symbol: snapshot.settings.transport == .usb ? "cable.connector" : "wifi",
                symbolTint: .teal,
                showDivider: false
            ) {
                HStack(spacing: 8) {
                    StatusPill(
                        label: snapshot.settings.transport == .usb ? "USB 有线" : "Wi-Fi 局域网",
                        tint: .teal
                    )
                    Button("传输设置…", action: onOpenSettings)
                        .controlSize(.small)
                }
            }
        }
    }

    private var selectedDeviceBinding: Binding<String?> {
        Binding(
            get: { snapshot.selectedDeviceID },
            set: { if let id = $0 { send(.selectDevice(id)) } }
        )
    }

    private func errorBanner(code: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.body)
            VStack(alignment: .leading, spacing: 2) {
                Text("诊断代码：\(code)")
                    .font(.callout.weight(.semibold))
                Text(detail.isEmpty ? "请前往「诊断日志」查看详细原因与排障建议。" : detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.red.opacity(0.25), lineWidth: 0.8)
        }
    }
}
