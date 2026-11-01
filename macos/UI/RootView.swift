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
    @Environment(\.colorScheme) private var colorScheme
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

    private var palette: ZenPalette { ZenPalette(colorScheme) }

    public var body: some View {
        HStack(spacing: 0) {
            sidebarColumn
                .frame(width: 224)

            Rectangle()
                .fill(palette.border)
                .frame(width: 1)

            VStack(spacing: 0) {
                detailTopBar
                    .frame(height: 56)

                Rectangle()
                    .fill(palette.border)
                    .frame(height: 1)

                workspaceDetailBody
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.windowBackground)
        }
        .background(palette.windowBackground)
        .frame(minWidth: 700, minHeight: 500)
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

    // MARK: - Section 10 Minimalist Sidebar (224pt)

    private var sidebarColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Space for macOS window traffic lights
            Spacer()
                .frame(height: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text("USB LinkMic")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(palette.textPrimary)

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
                    Button("管理设备与权限…") {
                        selectedSection = .devices
                    }
                } label: {
                    Text(selectedDeviceSummary)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 22)

            VStack(alignment: .leading, spacing: 4) {
                sidebarNavButton(.microphone)
                sidebarNavButton(.network)

                Rectangle()
                    .fill(palette.border)
                    .frame(height: 1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)

                sidebarNavButton(.devices)
                sidebarNavButton(.logs)
            }
            .padding(.horizontal, 14)

            Spacer(minLength: 16)

            Text("协议 v\(Capabilities.protocolVersion) · \(Capabilities.version)")
                .font(.system(size: 11, weight: .regular).monospacedDigit())
                .foregroundStyle(palette.textTertiary)
                .padding(.horizontal, 22)
                .padding(.bottom, 18)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(palette.sidebarBackground)
    }

    private func sidebarNavButton(_ section: SidebarSection) -> some View {
        let isSelected = selectedSection == section
        return Button {
            selectedSection = section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? palette.textPrimary : palette.textSecondary)
                    .frame(width: 18)

                Text(section.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? palette.textPrimary : palette.textSecondary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? palette.sidebarSelectedFill : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Section 10 Unified Top Bar (56pt)

    private var detailTopBar: some View {
        HStack(alignment: .center, spacing: 14) {
            Text(selectedSection.title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)

            Text(selectedSection.subtitle)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Button {
                    send(.refresh)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                        .frame(width: 32, height: 32)
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
                .help("刷新设备与连接状态 (⌘R)")
            }
        }
        .padding(.horizontal, 40)
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
