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
            return "personalhotspot"
        }
        if snapshot.macInternet.phase == .running {
            return "network"
        }
        if snapshot.microphone.phase == .failed
            || snapshot.phoneInternet.phase == .failed
            || snapshot.macInternet.phase == .failed {
            return "exclamationmark.triangle.fill"
        }
        return "waveform.badge.mic"
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
            if snapshot.microphone.phase == .running {
                Text(snapshot.settings.muted ? "静音" : "\(Int((min(max(snapshot.level, 0), 1) * 100).rounded()))%")
                    .font(.caption2.monospacedDigit())
            }
        }
    }
}

public struct MenuBarConsoleView: View {
    private let snapshot: AppSnapshot
    private let send: (UserAction) -> Void
    @Environment(\.openWindow) private var openWindow

    public init(snapshot: AppSnapshot, send: @escaping (UserAction) -> Void) {
        self.snapshot = snapshot
        self.send = send
    }

    private var selectedDeviceText: String {
        guard let id = snapshot.selectedDeviceID,
              let device = snapshot.devices.first(where: { $0.id == id }) else {
            return snapshot.devices.isEmpty ? "未连接手机" : "未选择手机"
        }
        return "\(device.name) · \(device.state.shortLabel)"
    }

    private var anyActiveTask: Bool {
        snapshot.microphone.phase != .stopped
            || snapshot.phoneInternet.phase != .stopped
            || snapshot.macInternet.phase != .stopped
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection
            microphoneQuickCard
            networkQuickTiles
            Divider()
                .opacity(0.6)
            footerBar
        }
        .padding(14)
        .frame(width: 336)
        .background(.ultraThinMaterial)
    }

    private var headerSection: some View {
        HStack(spacing: 10) {
            AppBrandIcon(size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("USB LinkMic")
                    .font(.headline)
                HStack(spacing: 5) {
                    Circle()
                        .fill(snapshot.devices.contains(where: { $0.state == .online }) ? Color.green : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text(selectedDeviceText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button {
                send(.refresh)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.callout.weight(.medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("刷新设备与状态")
        }
    }

    private var microphoneQuickCard: some View {
        let isStopped = snapshot.microphone.phase == .stopped || snapshot.microphone.phase == .failed
        let isStreaming = snapshot.audioState == .streaming

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("手机麦克风", systemImage: snapshot.settings.muted ? "mic.slash.fill" : "mic.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(snapshot.microphone.phase == .running ? .primary : .secondary)
                Spacer()
                StatusPill(
                    label: snapshot.microphone.phase.label,
                    tint: snapshot.microphone.phase.tint
                )
                Button {
                    send(isStopped ? .start(.microphone) : .stop(.microphone))
                } label: {
                    Text(isStopped ? "开启" : "停止")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(isStopped ? .accentColor : .red)
                .controlSize(.small)
                .disabled(snapshot.microphone.phase == .stopping || snapshot.isSavingSettings)
            }

            StudioLevelMeter(
                level: snapshot.level,
                isStreaming: isStreaming,
                isMuted: snapshot.settings.muted
            )

            HStack(spacing: 8) {
                Button {
                    send(.setMuted(!snapshot.settings.muted))
                } label: {
                    Image(systemName: snapshot.settings.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(snapshot.settings.muted ? .orange : .secondary)
                        .frame(width: 18)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(snapshot.settings.muted ? "取消静音" : "静音输出")

                Slider(
                    value: Binding(
                        get: { snapshot.settings.gain },
                        set: { send(.setGain($0)) }
                    ),
                    in: 0...4
                )
                .controlSize(.small)

                Text("\(snapshot.settings.gain, format: .number.precision(.fractionLength(1)))×")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
        }
        .padding(12)
        .insetGroupSurface(cornerRadius: 12)
    }

    private var networkQuickTiles: some View {
        HStack(spacing: 8) {
            networkTile(
                title: "手机供网",
                subtitle: snapshot.phoneInternet.phase.label,
                symbol: "personalhotspot",
                status: snapshot.phoneInternet,
                workspace: .phoneInternet
            )
            networkTile(
                title: "反向供网",
                subtitle: snapshot.macInternet.phase.label,
                symbol: "network",
                status: snapshot.macInternet,
                workspace: .macInternet
            )
        }
    }

    private func networkTile(
        title: String,
        subtitle: String,
        symbol: String,
        status: ModuleStatus,
        workspace: Workspace
    ) -> some View {
        let isStopped = status.phase == .stopped || status.phase == .failed
        let isActive = status.phase == .running

        return Button {
            send(isStopped ? .start(workspace) : .stop(workspace))
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    Circle()
                        .fill(isActive ? Color.accentColor : Color.primary.opacity(0.08))
                        .frame(width: 30, height: 30)
                    Image(systemName: symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isActive ? .white : status.phase.tint)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(status.phase.tint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .insetGroupSurface(cornerRadius: 10)
        }
        .buttonStyle(.plain)
        .disabled(status.phase == .stopping)
    }

    private var footerBar: some View {
        HStack {
            Button {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            } label: {
                Label("打开主窗口", systemImage: "macwindow")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.borderless)

            Spacer()

            if anyActiveTask {
                Button(role: .destructive) {
                    send(.stopAll)
                } label: {
                    Label("全部停止", systemImage: "stop.circle")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)
            }

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text("退出")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
    }
}
