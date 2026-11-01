import SwiftUI
import AppKit
import Contracts

public struct MenuBarLabelView: View {
    private let snapshot: AppSnapshot

    public init(snapshot: AppSnapshot) {
        self.snapshot = snapshot
    }

    private var iconName: String {
        if snapshot.microphone.phase == .running {
            return snapshot.settings.muted ? "mic.slash.fill" : "mic.fill"
        }
        if snapshot.phoneInternet.phase == .running {
            return "arrow.left.arrow.right"
        }
        if snapshot.macInternet.phase == .running {
            return "globe"
        }
        if snapshot.microphone.phase == .failed
            || snapshot.phoneInternet.phase == .failed
            || snapshot.macInternet.phase == .failed {
            return "exclamationmark.triangle.fill"
        }
        return "mic"
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
            if snapshot.microphone.phase == .running {
                let clamped = snapshot.level.isFinite ? max(min(snapshot.level, 1.0), 0.001) : 0.12
                let db = max(-48.0, min(0.0, 20.0 * log10(clamped)))
                Text(snapshot.settings.muted ? "静音" : String(format: "%.0fdB", db))
                    .font(.caption2.monospacedDigit())
            }
        }
    }
}

public struct MenuBarConsoleView: View {
    @Environment(\.colorScheme) private var colorScheme
    private let snapshot: AppSnapshot
    private let telemetry: AudioTelemetry?
    private let send: (UserAction) -> Void
    @Environment(\.openWindow) private var openWindow

    public init(snapshot: AppSnapshot, telemetry: AudioTelemetry? = nil, send: @escaping (UserAction) -> Void) {
        self.snapshot = snapshot
        self.telemetry = telemetry
        self.send = send
    }

    private var palette: ZenPalette { ZenPalette(colorScheme) }

    private var deviceDisplayName: String {
        if let id = snapshot.selectedDeviceID,
           let device = snapshot.devices.first(where: { $0.id == id }) {
            return device.name
        }
        if let first = snapshot.devices.first {
            return first.name
        }
        return "等待手机连接"
    }

    private var isMicRunning: Bool {
        snapshot.microphone.phase == .running || snapshot.audioState == .streaming
    }

    private var isMicStopped: Bool {
        snapshot.microphone.phase == .stopped || snapshot.microphone.phase == .failed
    }

    private var isPhoneNetRunning: Bool {
        snapshot.phoneInternet.phase == .running
    }

    private var isMacNetRunning: Bool {
        snapshot.macInternet.phase == .running
    }

    private var isAnyNetRunning: Bool {
        isPhoneNetRunning || isMacNetRunning
    }

    private var outputShortName: String {
        if let match = snapshot.outputs.first(where: { $0.id == snapshot.settings.outputUID }) {
            return match.name
        }
        return "系统默认"
    }

    private var dbText: String {
        let clamped = snapshot.level.isFinite ? max(min(snapshot.level, 1.0), 0.001) : 0.12
        let db = max(-48.0, min(0.0, 20.0 * log10(clamped)))
        return String(format: "%.1f dB", db)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            headerSection

            microphoneCard

            networkCard

            Rectangle()
                .fill(palette.divider)
                .frame(height: 1)
                .padding(.top, 2)

            footerBar
        }
        .padding(16)
        .frame(width: 340)
        .background(palette.cardBackground)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(isMicRunning ? "USB LinkMic · 拾音中" : "USB LinkMic")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(palette.textPrimary)

            if isMicRunning {
                Text("\(deviceDisplayName) · 正在传输")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.accentBlue)
            } else {
                Text("\(deviceDisplayName) · \(snapshot.settings.transport == .usb ? "USB 有线" : "Wi-Fi")")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textSecondary)
            }
        }
    }

    // MARK: - Microphone Quick Card

    private var microphoneCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(isMicRunning ? "手机麦克风 · 采音中" : "手机麦克风")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(palette.textPrimary)

                    if !isMicRunning {
                        Text(isMicStopped ? "随时就绪 · 未采音" : snapshot.microphone.stage)
                            .font(.system(size: 12))
                            .foregroundStyle(palette.textSecondary)
                    }
                }

                Spacer()

                ZenCapsuleActionButton(
                    title: isMicStopped ? "开启" : "停止",
                    isStop: !isMicStopped,
                    width: 82,
                    height: 32,
                    isDisabled: snapshot.microphone.phase == .stopping || snapshot.isSavingSettings
                ) {
                    send(isMicStopped ? .start(.microphone) : .stop(.microphone))
                }
            }

            if isMicRunning {
                VStack(alignment: .trailing, spacing: 4) {
                    if let telemetry {
                        ObservedMenuBarWaveform(telemetry: telemetry)
                    } else {
                        let bars = ZenWaveformWell.normalizedBars(from: snapshot.waveform, level: snapshot.level, targetCount: 20)
                        HStack(alignment: .center, spacing: 7) {
                            ForEach(Array(bars.enumerated()), id: \.offset) { idx, amp in
                                Capsule()
                                    .fill(palette.waveBarBlue.opacity(idx.isMultiple(of: 3) ? 0.78 : 1.0))
                                    .frame(width: 4.5, height: max(6, CGFloat(amp) * 44))
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 46)
                    }

                    Text(dbText)
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(palette.accentBlue)
                }
            } else {
                Text("输出：\(snapshot.settings.purpose == .monitor ? "本机试听" : "虚拟麦克风") (\(outputShortName))")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isMicRunning ? palette.recessedWell : palette.windowBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isMicRunning ? palette.activeBorder : palette.border, lineWidth: 1)
        }
    }

    // MARK: - Network Quick Card

    private var networkCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(isAnyNetRunning ? (isPhoneNetRunning ? "手机网络给 Mac" : "Mac 网络给手机") : "网络共享")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(palette.textPrimary)

                    if isAnyNetRunning {
                        Text(isPhoneNetRunning ? "NCM 链路已就绪" : "USB 隧道与 VPN 已建立")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(palette.accentBlue)
                    } else {
                        Text("未启用 · 点击开启供网")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.textSecondary)
                    }
                }

                Spacer()

                Button {
                    if isPhoneNetRunning {
                        send(.stop(.phoneInternet))
                    } else if isMacNetRunning {
                        send(.stop(.macInternet))
                    } else {
                        send(.start(.phoneInternet))
                    }
                } label: {
                    Text(isAnyNetRunning ? "断开" : "共享")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isAnyNetRunning ? palette.stopCrimson : palette.textPrimary)
                        .frame(width: 76, height: 32)
                        .background(
                            Capsule()
                                .fill(palette.cardBackground)
                        )
                        .overlay {
                            Capsule()
                                .strokeBorder(palette.border, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
            }

            Text(isAnyNetRunning ? (isPhoneNetRunning ? "已连接 · USB NCM 网卡" : "已连接 · ADB 隧道 + VPN") : "模式：手机给 Mac (NCM) / Mac 给手机 (VPN)")
                .font(.system(size: 11))
                .foregroundStyle(palette.textSecondary)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(palette.windowBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 1)
        }
    }

    // MARK: - Footer Bar

    private var footerBar: some View {
        HStack {
            Button {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            } label: {
                Text("打开主窗口")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.accentBlue)
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openWindow(id: "main")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NotificationCenter.default.post(name: Notification.Name("USBLinkMic.showSettings"), object: nil)
                }
            } label: {
                Text("偏好设置... (⌘,)")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textSecondary)
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text("退出")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textSecondary)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct ObservedMenuBarWaveform: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var telemetry: AudioTelemetry
    @State private var consumerID = UUID()

    private var palette: ZenPalette { ZenPalette(colorScheme) }

    var body: some View {
        let bars = ZenWaveformWell.normalizedBars(from: telemetry.waveform, level: telemetry.level, targetCount: 20)
        HStack(alignment: .center, spacing: 7) {
            ForEach(Array(bars.enumerated()), id: \.offset) { idx, amp in
                Capsule()
                    .fill(palette.waveBarBlue.opacity(idx.isMultiple(of: 3) ? 0.78 : 1.0))
                    .frame(width: 4.5, height: max(6, CGFloat(amp) * 44))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 46)
        .background(TelemetryVisibilityObserver(telemetry: telemetry, consumerID: consumerID))
        .onAppear {
            telemetry.registerConsumer(consumerID)
        }
        .onDisappear {
            telemetry.unregisterConsumer(consumerID)
        }
    }
}
