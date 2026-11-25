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
    private let snapshot: AppSnapshot
    private let telemetry: AudioTelemetry?
    private let send: (UserAction) -> Void
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(snapshot: AppSnapshot, telemetry: AudioTelemetry? = nil, send: @escaping (UserAction) -> Void) {
        self.snapshot = snapshot
        self.telemetry = telemetry
        self.send = send
    }

    private var deviceDisplayName: String {
        if let connected = snapshot.wifiAuto.connectedPhoneName, !connected.isEmpty {
            return connected
        }
        if snapshot.settings.transport == .wifi, let first = snapshot.wifiAuto.trusted.first {
            return first.name
        }
        if let id = snapshot.selectedDeviceID,
           let device = snapshot.devices.first(where: { $0.id == id }) {
            return device.name
        }
        if let first = snapshot.devices.first {
            return first.name
        }
        return snapshot.settings.transport == .wifi ? "等待 Wi-Fi 手机" : "等待手机连接"
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

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection
            Divider()
            microphoneControls
            Divider()
            networkControls
            Divider()
            footerBar
        }
        .padding(16)
        .frame(width: 336)
        .background(reduceTransparency ? Color(nsColor: .windowBackgroundColor) : Color.clear)
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("USB LinkMic")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            Label(deviceDisplayName, systemImage: snapshot.settings.transport == .usb ? "cable.connector" : "wifi")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var microphoneControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Label("手机麦克风", systemImage: "mic")
                        .font(.headline)

                    Text(microphoneSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                SessionActionButton(
                    title: isMicStopped ? "开启" : "停止",
                    isStop: !isMicStopped,
                    controlSize: .regular,
                    isDisabled: snapshot.microphone.phase == .stopping || snapshot.isSavingSettings
                ) {
                    send(isMicStopped ? .start(.microphone) : .stop(.microphone))
                }
            }

            if isMicRunning {
                LiveWaveformWell(
                    telemetry: telemetry,
                    fallbackSamples: snapshot.waveform,
                    fallbackLevel: snapshot.level,
                    barCount: 28
                )
            }
        }
    }

    private var microphoneSummary: String {
        let phase = snapshot.microphone.phase
        if isTaskBusy(phase) || phase == .failed {
            return snapshot.microphone.stage.isEmpty ? phase.label : snapshot.microphone.stage
        }

        let purpose = snapshot.settings.purpose == .monitor ? "本机试听" : "虚拟麦克风"
        return "\(isMicRunning ? "拾音中" : "待命") · \(purpose) · \(outputShortName)"
    }

    private var networkControls: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Label("USB 网络共享", systemImage: "arrow.left.arrow.right")
                    .font(.headline)

                Text(isPhoneNetRunning ? "手机 → Mac · USB NCM"
                     : isMacNetRunning ? "Mac → 手机 · USB 隧道与 VPN"
                     : "未启用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(isAnyNetRunning ? "断开" : "共享") {
                if isPhoneNetRunning {
                    send(.stop(.phoneInternet))
                } else if isMacNetRunning {
                    send(.stop(.macInternet))
                } else {
                    send(.start(.phoneInternet))
                }
            }
            .buttonStyle(.glass)
            .help(isAnyNetRunning ? "停止当前网络共享" : "将手机网络共享给 Mac")
        }
    }

    private var footerBar: some View {
        HStack {
            Button {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            } label: {
                Label("打开主窗口", systemImage: "macwindow")
            }
            .buttonStyle(.glass)

            Spacer()

            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.glass)
        }
        .controlSize(.small)
    }
}
