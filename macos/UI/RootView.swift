import SwiftUI
import AppKit
import Contracts
import Support

public struct SettingsSheetSessionState: Equatable, Sendable {
    public var draft: Contracts.Settings
    public var isDirty: Bool = false
    public var isPresented: Bool = false
    public var awaitingSaveCompletion: Bool = false

    public init(
        draft: Contracts.Settings,
        isDirty: Bool = false,
        isPresented: Bool = false,
        awaitingSaveCompletion: Bool = false
    ) {
        self.draft = draft
        self.isDirty = isDirty
        self.isPresented = isPresented
        self.awaitingSaveCompletion = awaitingSaveCompletion
    }

    public mutating func open(baseline: Contracts.Settings) {
        if isPresented || isDirty {
            isPresented = true
            return
        }
        draft = baseline
        isDirty = false
        isPresented = true
    }

    public mutating func updateDraft(_ newDraft: Contracts.Settings, baseline: Contracts.Settings) {
        draft = newDraft
        isDirty = (newDraft != baseline)
    }

    public mutating func beginSave() {
        awaitingSaveCompletion = true
    }

    public mutating func cancel(baseline: Contracts.Settings, isSaving: Bool) {
        guard !isSaving else { return }
        draft = baseline
        isDirty = false
        awaitingSaveCompletion = false
        isPresented = false
    }

    public mutating func handleDismiss(baseline: Contracts.Settings, isSaving: Bool, settingsError: String?) {
        guard !isSaving else { return }
        if settingsError == nil && !isDirty {
            draft = baseline
            isDirty = false
            awaitingSaveCompletion = false
        }
        isPresented = false
    }

    public mutating func handleSavedRevisionChanged(newSettings: Contracts.Settings) {
        if awaitingSaveCompletion {
            draft = newSettings
            isDirty = false
            awaitingSaveCompletion = false
            isPresented = false
        } else if !isDirty {
            draft = newSettings
        }
    }

    public mutating func handleSavingStateChanged(isSaving: Bool, settingsError: String?) {
        if !isSaving && settingsError != nil {
            awaitingSaveCompletion = false
        }
    }

    public mutating func handleExternalSettingsChanged(
        newSettings: Contracts.Settings,
        isSaving: Bool,
        settingsError: String?
    ) {
        if !isDirty && !awaitingSaveCompletion && !isSaving && settingsError == nil {
            draft = newSettings
        }
    }
}

public struct RootView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let snapshot: AppSnapshot
    private let telemetry: AudioTelemetry?
    private let send: (UserAction) -> Void

    private let initialShowAdvancedOptions: Bool

    @State private var selectedSection: SidebarSection = .microphone
    @State private var activeSheet: RootSheet?
    @State private var wizardStep = 0

    public init(
        snapshot: AppSnapshot,
        telemetry: AudioTelemetry? = nil,
        initialSection: SidebarSection = .microphone,
        initialShowAdvancedOptions: Bool = false,
        send: @escaping (UserAction) -> Void
    ) {
        self.snapshot = snapshot
        self.telemetry = telemetry
        self.initialShowAdvancedOptions = initialShowAdvancedOptions
        self.send = send
        _selectedSection = State(initialValue: initialSection)
        _activeSheet = State(initialValue: !snapshot.wizardSkipped && !snapshot.soundTestCompleted ? .wizard : nil)
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 165, ideal: 188, max: 230)
        } detail: {
            workspaceDetailBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("USB LinkMic")
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        deviceMenu

                        Button {
                            send(.refresh)
                        } label: {
                            Label("刷新设备", systemImage: "arrow.clockwise")
                        }
                        .keyboardShortcut("r", modifiers: .command)
                        .help("刷新设备与连接状态 (⌘R)")
                    }
                }
        }
        .containerBackground(
            reduceTransparency
                ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
                : AnyShapeStyle(.thinMaterial),
            for: .window
        )
        .frame(minWidth: 720, minHeight: 520)
        .background {
            VStack {
                ForEach(SidebarSection.allCases) { section in
                    Button(section.title) {
                        selectedSection = section
                    }
                    .keyboardShortcut(section.shortcutKey, modifiers: .command)
                }
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .wizard:
                SetupWizard(
                    snapshot: snapshot,
                    telemetry: telemetry,
                    step: $wizardStep,
                    send: send
                )
                .interactiveDismissDisabled()
            }
        }
        .onChange(of: snapshot.wizardSkipped) { _, skipped in
            if skipped, activeSheet == .wizard { activeSheet = nil }
        }
        .onChange(of: snapshot.soundTestCompleted) { _, completed in
            if completed, activeSheet == .wizard { activeSheet = nil }
        }
    }

    private var sidebar: some View {
        List(selection: Binding<SidebarSection?>(
            get: { selectedSection },
            set: { if let section = $0 { selectedSection = section } }
        )) {
            Section("连接") {
                sidebarItem(.microphone)
                sidebarItem(.network)
            }
            Section("管理") {
                sidebarItem(.devices)
                sidebarItem(.logs)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(Capabilities.version) · 协议 v\(Capabilities.protocolVersion)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Link("@xxkingstuggle", destination: USBLinkMicBrand.githubURL)
                    Text("·")
                    Link("myzjx.com", destination: USBLinkMicBrand.productURL)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
    }

    private func sidebarItem(_ section: SidebarSection) -> some View {
        Label(section.title, systemImage: section.symbol)
            .tag(section)
            .help("\(section.title) (\(section.shortcutHint))")
    }

    private var deviceMenu: some View {
        let effectiveSelectedID = DevicesWorkspaceView.effectiveSelectedDeviceID(for: snapshot)
        return Menu {
            if snapshot.devices.isEmpty {
                Text("未检测到 USB 手机")
            } else {
                ForEach(snapshot.devices) { device in
                    Button {
                        send(.selectDevice(device.id))
                    } label: {
                        if effectiveSelectedID == device.id {
                            Label("\(device.name) · \(device.state.label)", systemImage: "checkmark")
                        } else {
                            Text("\(device.name) · \(device.state.label)")
                        }
                    }
                }
            }
            Divider()
            Button("管理设备与权限…") { selectedSection = .devices }
        } label: {
            Label {
                Text(selectedDeviceSummary)
                    .lineLimit(1)
            } icon: {
                Image(systemName: snapshot.settings.transport == .usb ? "iphone" : "wifi")
            }
            .labelStyle(.titleAndIcon)
        }
        .help("查看与切换手机")
    }

    @ViewBuilder
    private var workspaceDetailBody: some View {
        switch selectedSection {
        case .microphone:
            MicrophoneWorkspaceView(
                snapshot: snapshot,
                telemetry: telemetry,
                initialShowAdvancedConnection: initialShowAdvancedOptions,
                initialShowAudioOptions: initialShowAdvancedOptions,
                send: send
            )
        case .network:
            NetworkWorkspaceView(
                snapshot: snapshot,
                initialShowAdvanced: initialShowAdvancedOptions,
                send: send
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

    private var selectedDeviceSummary: String {
        if snapshot.settings.transport == .wifi {
            if let connected = snapshot.wifiAuto.connectedPhoneName, !connected.isEmpty {
                return "\(connected) · Wi-Fi"
            }
            if let first = snapshot.wifiAuto.trusted.first {
                return "\(first.name) · Wi-Fi"
            }
            return "Wi-Fi 等待手机"
        }
        if let id = snapshot.selectedDeviceID,
           let device = snapshot.devices.first(where: { $0.id == id }) {
            return "\(device.name) · \(device.state.shortLabel)"
        }
        if let first = snapshot.devices.first {
            return "\(first.name) · \(first.state.shortLabel)"
        }
        return "等待手机连接"
    }
}

private enum RootSheet: String, Identifiable, Equatable {
    case wizard

    var id: String { rawValue }
}
