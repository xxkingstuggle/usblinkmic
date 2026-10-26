import SwiftUI
import AppKit
import Contracts
import Support

public struct RootView: View {
    private let snapshot: AppSnapshot
    private let send: (UserAction) -> Void

    @State private var selectedWorkspace: Workspace = .microphone
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var settingsDraft: Contracts.Settings
    @State private var settingsDirty = false
    @State private var activeSheet: RootSheet?
    @State private var wizardStep = 0

    public init(snapshot: AppSnapshot, send: @escaping (UserAction) -> Void) {
        self.snapshot = snapshot
        self.send = send
        _settingsDraft = State(initialValue: snapshot.settings)
        _activeSheet = State(initialValue: !snapshot.wizardSkipped && !snapshot.soundTestCompleted ? .wizard : nil)
    }

    private var anyActiveTask: Bool {
        snapshot.microphone.phase != .stopped
            || snapshot.phoneInternet.phase != .stopped
            || snapshot.macInternet.phase != .stopped
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 205, ideal: 224, max: 252)
        } detail: {
            VStack(spacing: 0) {
                detailUnifiedHeader
                Divider()
                    .opacity(0.65)
                workspaceDetailBody
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle(selectedWorkspace.title)
            .navigationSubtitle(selectedWorkspace.subtitle)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    targetDeviceToolbarMenu
                    Button {
                        send(.refresh)
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .help("刷新设备与连接状态 (⌘R)")

                    Button {
                        openSettings()
                    } label: {
                        Label("设置", systemImage: "slider.horizontal.3")
                    }
                    .help("偏好设置 (⌘,)")

                    Button(role: .destructive) {
                        send(.stopAll)
                    } label: {
                        Label("全部停止", systemImage: "stop.circle")
                    }
                    .disabled(!anyActiveTask)
                    .help("停止所有运行中的音频与网络任务 (⌘.)")
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, minHeight: 520)
        .sheet(item: $activeSheet, onDismiss: resetSettingsDraft) { sheet in
            switch sheet {
            case .settings:
                SettingsSheet(
                    settings: $settingsDraft,
                    isDirty: $settingsDirty,
                    outputs: snapshot.outputs,
                    onCancel: {
                        resetSettingsDraft()
                        activeSheet = nil
                    },
                    onSave: {
                        send(.saveSettings(settingsDraft))
                        settingsDirty = false
                        activeSheet = nil
                    }
                )
            case .wizard:
                SetupWizard(
                    snapshot: snapshot,
                    step: $wizardStep,
                    send: send
                )
                .interactiveDismissDisabled()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("USBLinkMic.showSettings"))) { _ in
            openSettings()
        }
        .onChange(of: snapshot.settings) { _, settings in
            if !settingsDirty {
                settingsDraft = settings
            }
        }
        .onChange(of: snapshot.wizardSkipped) { _, skipped in
            if skipped, activeSheet == .wizard { activeSheet = nil }
        }
        .onChange(of: snapshot.soundTestCompleted) { _, completed in
            if completed, activeSheet == .wizard { activeSheet = nil }
        }
    }

    // MARK: - Native macOS 27 Sidebar

    private var sidebarContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarBrandHeader
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 16) {
                sidebarGroup(title: "音频与网络桥接") {
                    sidebarTaskButton(.microphone, status: snapshot.microphone)
                    sidebarTaskButton(.phoneInternet, status: snapshot.phoneInternet)
                    sidebarTaskButton(.macInternet, status: snapshot.macInternet)
                }

                sidebarGroup(title: "系统与诊断") {
                    sidebarDevicesButton
                    sidebarLogsButton
                }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 12)

            Divider()
                .opacity(0.5)
                .padding(.horizontal, 12)

            sidebarFooter
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
        }
        .background(VisualEffectSurface(material: .sidebar, blendingMode: .behindWindow))
    }

    private func sidebarGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 2)
            content()
        }
    }

    private var sidebarBrandHeader: some View {
        HStack(spacing: 10) {
            AppBrandIcon(size: 32)
            VStack(alignment: .leading, spacing: 1.5) {
                Text("USB LinkMic")
                    .font(.headline)
                HStack(spacing: 5) {
                    Circle()
                        .fill(snapshot.devices.contains(where: { $0.state == .online }) ? Color.green : Color.secondary.opacity(0.6))
                        .frame(width: 6, height: 6)
                    Text(selectedDeviceSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func sidebarTaskButton(_ workspace: Workspace, status: ModuleStatus) -> some View {
        let isSelected = selectedWorkspace == workspace
        return Button {
            selectedWorkspace = workspace
        } label: {
            HStack(spacing: 10) {
                Image(systemName: workspace.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary.opacity(0.72))
                    .frame(width: 18)

                Text(workspace.title)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.88))
                    .lineLimit(1)

                Spacer(minLength: 4)

                Circle()
                    .fill(status.phase == .stopped ? Color.secondary.opacity(0.28) : status.phase.tint)
                    .frame(width: 7, height: 7)
                    .help(status.phase.label)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7.5)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(
                isSelected ? Color.accentColor.opacity(0.15) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var sidebarDevicesButton: some View {
        let isSelected = selectedWorkspace == .devices
        let onlineCount = snapshot.devices.filter { $0.state == .online }.count
        return Button {
            selectedWorkspace = .devices
        } label: {
            HStack(spacing: 10) {
                Image(systemName: Workspace.devices.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary.opacity(0.72))
                    .frame(width: 18)

                Text(Workspace.devices.title)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.88))
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text("\(onlineCount)/\(snapshot.devices.count)")
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(
                        (onlineCount > 0 ? Color.green : Color.secondary).opacity(0.15),
                        in: Capsule()
                    )
                    .foregroundStyle(onlineCount > 0 ? .green : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7.5)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(
                isSelected ? Color.accentColor.opacity(0.15) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var sidebarLogsButton: some View {
        let isSelected = selectedWorkspace == .logs
        return Button {
            selectedWorkspace = .logs
        } label: {
            HStack(spacing: 10) {
                Image(systemName: Workspace.logs.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary.opacity(0.72))
                    .frame(width: 18)

                Text(Workspace.logs.title)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.88))
                    .lineLimit(1)

                Spacer(minLength: 4)

                if !snapshot.logs.isEmpty {
                    Text("\(snapshot.logs.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7.5)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(
                isSelected ? Color.accentColor.opacity(0.15) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var sidebarFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.shield")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("协议 v\(Capabilities.protocolVersion) · \(Capabilities.version)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Detail Header & Workspace Body

    private var detailUnifiedHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedWorkspace.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(selectedWorkspace.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(-1)

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                targetDeviceCapsuleButton

                Button {
                    send(.refresh)
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("刷新设备与连接状态")

                Button {
                    openSettings()
                } label: {
                    Label("偏好设置", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)

                if anyActiveTask {
                    Button(role: .destructive) {
                        send(.stopAll)
                    } label: {
                        Label("全部停止", systemImage: "stop.circle.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.bar)
    }

    @ViewBuilder
    private var workspaceDetailBody: some View {
        switch selectedWorkspace {
        case .microphone:
            MicrophoneWorkspaceView(
                snapshot: snapshot,
                send: send,
                onOpenSettings: openSettings
            )
        case .phoneInternet:
            NetworkWorkspaceView(
                workspace: .phoneInternet,
                snapshot: snapshot,
                send: send,
                onOpenSettings: openSettings
            )
        case .macInternet:
            NetworkWorkspaceView(
                workspace: .macInternet,
                snapshot: snapshot,
                send: send,
                onOpenSettings: openSettings
            )
        case .devices:
            DevicesWorkspaceView(
                snapshot: snapshot,
                send: send
            )
        case .logs:
            LogsWorkspaceView(
                snapshot: snapshot,
                send: send
            )
        }
    }

    // MARK: - Target Device Selector Helpers

    private var selectedDeviceSummary: String {
        guard let id = snapshot.selectedDeviceID,
              let device = snapshot.devices.first(where: { $0.id == id }) else {
            return snapshot.devices.isEmpty ? "等待手机连接" : "请选择目标手机"
        }
        return "\(device.name) · \(device.state.shortLabel)"
    }

    private var targetDeviceToolbarMenu: some View {
        Menu {
            if snapshot.devices.isEmpty {
                Text("未检测到 USB 手机")
            } else {
                ForEach(snapshot.devices) { device in
                    Button {
                        send(.selectDevice(device.id))
                    } label: {
                        Label(
                            "\(device.name) (\(device.state.shortLabel))",
                            systemImage: device.id == snapshot.selectedDeviceID ? "checkmark.circle.fill" : "iphone.gen3"
                        )
                    }
                }
            }
            Divider()
            Button {
                selectedWorkspace = .devices
            } label: {
                Label("管理设备与权限…", systemImage: "iphone.gen3")
            }
        } label: {
            Label(selectedDeviceSummary, systemImage: "iphone.gen3")
        }
        .help("切换当前目标 Android 手机")
    }

    private var targetDeviceCapsuleButton: some View {
        Menu {
            if snapshot.devices.isEmpty {
                Text("未检测到 USB 手机")
            } else {
                ForEach(snapshot.devices) { device in
                    Button {
                        send(.selectDevice(device.id))
                    } label: {
                        Text("\(device.name) · \(device.state.label)")
                    }
                }
            }
            Divider()
            Button("查看设备与权限…") {
                selectedWorkspace = .devices
            }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(snapshot.devices.contains(where: { $0.state == .online }) ? Color.green : Color.secondary)
                    .frame(width: 6, height: 6)
                Text(selectedDeviceSummary)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .controlSize(.small)
    }

    private func openSettings() {
        settingsDraft = snapshot.settings
        settingsDirty = false
        activeSheet = .settings
    }

    private func resetSettingsDraft() {
        settingsDraft = snapshot.settings
        settingsDirty = false
    }
}

private enum RootSheet: String, Identifiable, Equatable {
    case settings
    case wizard

    var id: String { rawValue }
}
