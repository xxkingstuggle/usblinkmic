import SwiftUI
import AppKit
import Contracts
import Support

public enum USBLinkMicBrand {
    public static let authorDisplay = "Xin (@xxkingstuggle)"
    public static let copyright = "© 2026 Xin (@xxkingstuggle)"
    public static let websiteURL = URL(string: "https://myzjx.com")!
    public static let productURL = URL(string: "https://myzjx.com/software/usblinkmic/")!
    public static let githubURL = URL(string: "https://github.com/xxkingstuggle")!
    public static let repositoryURL = URL(string: "https://github.com/xxkingstuggle/usblinkmic")!
}

public struct AboutUSBLinkMicCard: View {
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    private var palette: ZenPalette { ZenPalette(colorScheme) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                appBadgeView

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("关于 USB LinkMic")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(palette.textPrimary)
                        Text("v\(Capabilities.version)")
                            .font(.caption.monospacedDigit().weight(.medium))
                            .foregroundStyle(palette.textSecondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(palette.segmentedTrack, in: Capsule())
                    }

                    Text("由 \(USBLinkMicBrand.authorDisplay) 设计与开发 · 协议 v\(Capabilities.protocolVersion)")
                        .font(.system(size: 12.5))
                        .foregroundStyle(palette.textSecondary)

                    Text("\(USBLinkMicBrand.copyright) · 保留所有权利")
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.textTertiary)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                brandLinkPill(
                    title: "官方网站 · myzjx.com",
                    symbol: "globe",
                    destination: USBLinkMicBrand.websiteURL,
                    emphasized: true
                )
                brandLinkPill(
                    title: "产品主页",
                    symbol: "safari",
                    destination: USBLinkMicBrand.productURL
                )
                brandLinkPill(
                    title: "GitHub · @xxkingstuggle",
                    symbol: "chevron.left.forwardslash.chevron.right",
                    destination: USBLinkMicBrand.githubURL
                )

                Spacer(minLength: 0)
            }
        }
        .padding(18)
        .zenCard(isActive: false, cornerRadius: 18)
    }

    @ViewBuilder
    private var appBadgeView: some View {
        if Bundle.main.bundleURL.pathExtension == "app" {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.19, green: 0.49, blue: 0.96), Color(red: 0.08, green: 0.31, blue: 0.78)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "mic.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 48, height: 48)
        }
    }

    private func brandLinkPill(
        title: String,
        symbol: String,
        destination: URL,
        emphasized: Bool = false
    ) -> some View {
        Link(destination: destination) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(emphasized ? .white : palette.accentBlue)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(emphasized ? .white : palette.textPrimary)
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(emphasized ? palette.accentBlue : palette.segmentedTrack)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(emphasized ? Color.clear : palette.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

public struct AboutUSBLinkMicWindowView: View {
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    private var palette: ZenPalette { ZenPalette(colorScheme) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AboutUSBLinkMicCard()
            Text("Android 手机作为 Mac 麦克风与 USB 双向网络共享工具。")
                .font(.system(size: 12))
                .foregroundStyle(palette.textSecondary)
                .padding(.horizontal, 4)
        }
        .padding(20)
        .frame(width: 520)
        .background(palette.windowBackground)
    }
}

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
