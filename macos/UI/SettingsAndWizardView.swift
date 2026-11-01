import SwiftUI
import Contracts
import Support

public struct SetupWizard: View {
    @Environment(\.colorScheme) private var colorScheme
    let snapshot: AppSnapshot
    var telemetry: AudioTelemetry? = nil
    @Binding var step: Int
    let send: (UserAction) -> Void

    public init(
        snapshot: AppSnapshot,
        telemetry: AudioTelemetry? = nil,
        step: Binding<Int>,
        send: @escaping (UserAction) -> Void
    ) {
        self.snapshot = snapshot
        self.telemetry = telemetry
        self._step = step
        self.send = send
    }

    private var palette: ZenPalette { ZenPalette(colorScheme) }

    private let steps: [(title: String, subtitle: String)] = [
        ("连接 Android 手机", "通过 USB 连接手机并授权 USB 调试"),
        ("确认手机麦克风权限", "由手机系统弹窗确认录音与前台通知权限"),
        ("验证真实声音输入", "确认收到真实音频帧并能听见声音")
    ]

    public var body: some View {
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

            LiveWaveformWell(
                telemetry: telemetry,
                fallbackSamples: snapshot.waveform,
                fallbackLevel: snapshot.level,
                barCount: 36,
                showDbPill: true
            )

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
