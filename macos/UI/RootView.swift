import SwiftUI
import Contracts
import Support

public struct RootView: View {
    private let snapshot: AppSnapshot
    private let send: (UserAction) -> Void

    @State private var selectedWorkspace: Workspace = .microphone
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

    public var body: some View {
        GeometryReader { geometry in
            Group {
                if geometry.size.width < 860 {
                    compactLayout
                } else {
                    wideLayout
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
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
                .frame(minWidth: 480, minHeight: 390)
                .interactiveDismissDisabled()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("USBLinkMic.showSettings"))) { _ in openSettings() }
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

    private var wideLayout: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                brand
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Workspace.allCases, id: \.self) { workspace in
                        workspaceButton(workspace)
                    }
                }
                Spacer(minLength: 12)
                Label("协议 v\(Capabilities.protocolVersion)", systemImage: "cable.connector")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
            }
            .padding(18)
            .frame(width: 222, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))

            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)

            VStack(spacing: 0) {
                topBar
                Divider()
                workspaceBody
            }
        }
    }

    private var compactLayout: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                brand
                Spacer(minLength: 8)
                Menu {
                    ForEach(Workspace.allCases, id: \.self) { workspace in
                        Button {
                            selectedWorkspace = workspace
                        } label: {
                            Label(workspace.title, systemImage: workspace.symbol)
                        }
                    }
                } label: {
                    Label(selectedWorkspace.title, systemImage: selectedWorkspace.symbol)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
                .menuStyle(.borderlessButton)
                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("设置")
                .buttonStyle(.borderless)
                Button {
                    send(.stopAll)
                } label: {
                    Image(systemName: "stop.circle")
                }
                .help("全部停止")
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            Divider()
            workspaceBody
        }
    }

    private var brand: some View {
        HStack(spacing: 10) {
            Image(systemName: "cable.connector.horizontal")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("USB LinkMic")
                    .font(.headline)
                Text("手机连接与状态")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var topBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedWorkspace.title)
                    .font(.title2.weight(.semibold))
                Text(selectedWorkspace.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                send(.refresh)
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .help("刷新设备与状态")
            Button {
                openSettings()
            } label: {
                Label("设置", systemImage: "gearshape")
            }
            Button(role: .destructive) {
                send(.stopAll)
            } label: {
                Label("全部停止", systemImage: "stop.circle")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var workspaceBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch selectedWorkspace {
                case .microphone:
                    microphoneWorkspace
                case .phoneInternet:
                    networkWorkspace(
                        title: "手机网络给 Mac",
                        description: "通过 USB 使用手机网络。链路状态与实际网络可用性分别显示。",
                        status: snapshot.phoneInternet,
                        networkState: snapshot.phoneInternet.phase == .stopped ? .stopped:snapshot.networkState,
                        workspace: .phoneInternet
                    )
                case .macInternet:
                    networkWorkspace(
                        title: "Mac 网络给手机",
                        description: "等待手机 VPN 授权，并以实际网络探测确认连接结果。",
                        status: snapshot.macInternet,
                        networkState: snapshot.macInternet.phase == .stopped ? .stopped:snapshot.networkState,
                        workspace: .macInternet
                    )
                case .devices:
                    devicesWorkspace
                case .logs:
                    logsWorkspace
                }
            }
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(24)
        }
    }

    private var microphoneWorkspace: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionIntro(
                title: "手机麦克风",
                description: "使用手机拾音，在 Mac 试听或供其他软件选择为输入。",
                symbol: "mic"
            )

            DevicePickerCard(snapshot: snapshot, send: send)

            StatusCard(title: "麦克风任务", status: snapshot.microphone)

            HStack(spacing: 12) {
                Button {
                    send(snapshot.microphone.phase == .stopped || snapshot.microphone.phase == .failed
                         ? .start(.microphone) : .stop(.microphone))
                } label: {
                    Label(
                        snapshot.microphone.phase == .stopped || snapshot.microphone.phase == .failed ? "开始" : "停止",
                        systemImage: snapshot.microphone.phase == .stopped || snapshot.microphone.phase == .failed ? "play.fill" : "stop.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(snapshot.microphone.phase == .stopping)

                if settingsDraft.purpose == .virtualMicrophone {
                    Button {
                        send(.openDriverHelp)
                    } label: {
                        Label("虚拟声卡帮助", systemImage: "arrow.up.right.square")
                    }
                }
                Spacer()
            }

            AudioFactsCard(snapshot: snapshot)
        }
    }

    private func networkWorkspace(
        title: String,
        description: String,
        status: ModuleStatus,
        networkState: NetworkState,
        workspace: Workspace
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionIntro(title: title, description: description, symbol: workspace.symbol)
            StatusCard(title: "任务阶段", status: status)
            NetworkStateCard(state: networkState)
            HStack {
                Button {
                    send(status.phase == .stopped || status.phase == .failed ? .start(workspace) : .stop(workspace))
                } label: {
                    Label(status.phase == .stopped || status.phase == .failed ? "开始" : "停止", systemImage: status.phase == .stopped || status.phase == .failed ? "play.fill" : "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(status.phase == .stopping)
                Spacer()
            }
            if workspace == .macInternet {
                PermissionCard(title: "VPN 授权", state: snapshot.vpnPermission)
            }
            if !snapshot.recoveryMessage.isEmpty {
                InfoCard(title: "恢复", detail: snapshot.recoveryMessage, symbol: "arrow.uturn.backward.circle")
            }
        }
    }

    private var devicesWorkspace: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionIntro(
                title: "设备",
                description: "选择要连接的 Android 手机，并在手机上确认 USB 调试信任。",
                symbol: "iphone.gen3"
            )
            TaskOverviewCard(snapshot: snapshot)
            HStack {
                Button {
                    send(.refresh)
                } label: {
                    Label("刷新设备", systemImage: "arrow.clockwise")
                }
                Spacer()
            }
            if snapshot.devices.isEmpty {
                EmptyStateCard(title: "没有检测到设备", detail: "连接 Android 手机后刷新。", symbol: "iphone.slash")
            } else {
                VStack(spacing: 8) {
                    ForEach(snapshot.devices) { device in
                        DeviceRow(
                            device: device,
                            selected: device.id == snapshot.selectedDeviceID,
                            action: { send(.selectDevice(device.id)) }
                        )
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("权限状态").font(.headline)
                PermissionCard(title: "麦克风", state: snapshot.microphonePermission)
                PermissionCard(title: "通知", state: snapshot.notificationPermission)
                PermissionCard(title: "VPN", state: snapshot.vpnPermission)
            }
            if !snapshot.recoveryMessage.isEmpty {
                InfoCard(title: "启动恢复", detail: snapshot.recoveryMessage, symbol: "arrow.uturn.backward.circle")
            }
        }
    }

    private var logsWorkspace: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionIntro(
                title: "日志",
                description: "查看连接阶段和错误原因。导出前请检查内容。",
                symbol: "list.bullet.rectangle"
            )
            TaskOverviewCard(snapshot: snapshot)
            HStack {
                Button {
                    send(.exportLogs)
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive) {
                    send(.clearLogs)
                } label: {
                    Label("清空", systemImage: "trash")
                }
                Spacer()
                Text("\(snapshot.logs.count) 条")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            if snapshot.logs.isEmpty {
                EmptyStateCard(title: "暂无日志", detail: "发生的阶段与诊断会显示在这里。", symbol: "text.page.slash")
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(snapshot.logs) { entry in
                        LogRow(entry: entry)
                    }
                }
            }
        }
    }

    private func workspaceButton(_ workspace: Workspace) -> some View {
        Button {
            selectedWorkspace = workspace
        } label: {
            HStack(spacing: 11) {
                Image(systemName: workspace.symbol)
                    .frame(width: 18)
                Text(workspace.title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .background(selectedWorkspace == workspace ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(selectedWorkspace == workspace ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedWorkspace == workspace ? .isSelected : [])
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

private enum WorkspaceTitle {
    static func title(_ workspace: Workspace) -> String {
        switch workspace {
        case .microphone: "手机麦克风"
        case .phoneInternet: "手机网络给 Mac"
        case .macInternet: "Mac 网络给手机"
        case .devices: "设备"
        case .logs: "日志"
        }
    }

    static func symbol(_ workspace: Workspace) -> String {
        switch workspace {
        case .microphone: "mic"
        case .phoneInternet: "antenna.radiowaves.left.and.right"
        case .macInternet: "network"
        case .devices: "iphone.gen3"
        case .logs: "list.bullet.rectangle"
        }
    }

    static func subtitle(_ workspace: Workspace) -> String {
        switch workspace {
        case .microphone: "USB 或 Wi-Fi 音频接收"
        case .phoneInternet: "手机通过 USB 为 Mac 供网"
        case .macInternet: "Mac 通过 USB 为手机供网"
        case .devices: "连接与授权状态"
        case .logs: "阶段与诊断记录"
        }
    }
}

private enum RootSheet: String, Identifiable, Equatable {
    case settings
    case wizard

    var id: String { rawValue }
}

private extension Workspace {
    var title: String { WorkspaceTitle.title(self) }
    var symbol: String { WorkspaceTitle.symbol(self) }
    var subtitle: String { WorkspaceTitle.subtitle(self) }
}

private func isBusy(_ phase: TaskPhase) -> Bool {
    phase == .checking || phase == .preparing || phase == .waitingUser || phase == .connecting || phase == .stopping
}

private struct SectionIntro: View {
    let title: String
    let description: String
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 42, height: 42)
                .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.title3.weight(.semibold))
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct StatusCard: View {
    let title: String
    let status: ModuleStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(status.phase.label)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(status.phase.tint.opacity(0.13), in: Capsule())
                    .foregroundStyle(status.phase.tint)
            }
            LabeledContent("当前阶段", value: status.stage.isEmpty ? status.phase.label : status.stage)
            if !status.detail.isEmpty {
                Text(status.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let errorCode = status.errorCode, !errorCode.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("错误：\(errorCode)").font(.callout.weight(.semibold))
                        if status.detail.isEmpty {
                            Text("查看日志以获取后续处理建议。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(16)
        .cardStyle()
        .accessibilityElement(children: .contain)
    }
}

private struct TaskOverviewCard: View {
    let snapshot: AppSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("当前任务").font(.headline)
            StatusCard(title: "手机麦克风", status: snapshot.microphone)
            StatusCard(title: "手机网络给 Mac", status: snapshot.phoneInternet)
            StatusCard(title: "Mac 网络给手机", status: snapshot.macInternet)
        }
    }
}

private struct NetworkStateCard: View {
    let state: NetworkState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: state.symbol)
                .font(.title3)
                .foregroundStyle(state.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text("网络可用性：\(state.label)")
                    .font(.callout.weight(.semibold))
                Text(state.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .cardStyle()
    }
}

private struct DevicePickerCard: View {
    let snapshot: AppSnapshot
    let send: (UserAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("目标设备").font(.headline)
                Spacer()
                Button {
                    send(.refresh)
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
            if snapshot.devices.isEmpty {
                Text("未检测到手机。连接设备后刷新，任务阶段会显示检查结果。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker("选择手机", selection: selectedBinding) {
                    Text("请选择设备").tag(String?.none)
                    ForEach(snapshot.devices) { device in
                        Text("\(device.name) · \(device.state.label)")
                            .tag(Optional(device.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 440, alignment: .leading)
            }
        }
        .padding(16)
        .cardStyle()
    }

    private var selectedBinding: Binding<String?> {
        Binding(
            get: { snapshot.selectedDeviceID },
            set: { if let id = $0 { send(.selectDevice(id)) } }
        )
    }
}

private struct AudioFactsCard: View {
    let snapshot: AppSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("音频状态").font(.headline)
                Spacer()
                Text(snapshot.audioState.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(snapshot.audioState.tint)
            }
            if let effective = snapshot.effectiveAudio {
                Text("实际参数：\(effective.sampleRate) Hz · \(effective.channels) 声道 · \(effective.format.rawValue) · \(effective.source.label)")
                    .font(.callout)
            } else {
                Text("尚无实际生效参数")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                Text("有效帧：\(snapshot.receivedFrames)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("实时电平")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ProgressView(value: boundedLevel)
                    .frame(maxWidth: 220)
                    .tint(snapshot.audioState == .streaming ? .green : .secondary)
                Text("\(Int(boundedLevel * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !snapshot.waveform.isEmpty {
                WaveformView(samples: snapshot.waveform)
                    .frame(height: 42)
                    .accessibilityLabel("来自当前快照的音频波形")
            }
        }
        .padding(16)
        .cardStyle()
    }

    private var boundedLevel: Double {
        guard snapshot.level.isFinite else { return 0 }
        return min(max(snapshot.level, 0), 1)
    }
}

private struct WaveformView: View {
    let samples: [Double]

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(samples.enumerated()), id: \.offset) { _, value in
                    Capsule()
                        .fill(Color.accentColor.opacity(0.8))
                        .frame(width: barWidth(in: geometry.size.width, count: samples.count), height: barHeight(value, in: geometry.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func barWidth(in width: CGFloat, count: Int) -> CGFloat {
        max(2, (width - CGFloat(max(count - 1, 0)) * 2) / CGFloat(max(count, 1)))
    }

    private func barHeight(_ value: Double, in height: CGFloat) -> CGFloat {
        let sample = value.isFinite ? min(max(abs(value), 0), 1) : 0
        return max(2, CGFloat(sample) * height)
    }
}

private struct DeviceRow: View {
    let device: Device
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "iphone.gen3")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.name).font(.callout.weight(.semibold))
                    Text(device.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text(device.state.label)
                        .font(.caption)
                        .foregroundStyle(device.state.tint)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
            }
            .padding(13)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .background(selected ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .cardStyle()
        }
        .buttonStyle(.plain)
    }
}

private struct PermissionCard: View {
    let title: String
    let state: PermissionState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state.symbol)
                .foregroundStyle(state.tint)
                .frame(width: 18)
            Text(title).font(.callout)
            Spacer()
            Text(state.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(state.tint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct InfoCard: View {
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .cardStyle()
    }
}

private struct EmptyStateCard: View {
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .cardStyle()
    }
}

private struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.module).font(.caption.weight(.semibold))
                Text("· \(entry.stage)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(entry.date, style: .time)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(entry.message)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

private struct SettingsSheet: View {
    @Binding var settings: Contracts.Settings
    @Binding var isDirty: Bool
    let outputs: [OutputDevice]
    let onCancel: () -> Void
    let onSave: () -> Void

    private var errors: [String] {
        SettingsValidator.errors(settings)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("设置").font(.title2.weight(.semibold))
                    Text("更改只在保存后提交；取消会丢弃草稿。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("保存", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!errors.isEmpty)
            }
            .padding(20)
            Divider()
            Form {
                Section("音频") {
                    Picker("传输方式", selection: $settings.transport) {
                        Text("USB").tag(AudioTransport.usb)
                        Text("Wi-Fi").tag(AudioTransport.wifi)
                    }
                    Picker("采样率", selection: $settings.audio.sampleRate) {
                        ForEach(Capabilities.sampleRates, id: \.self) { rate in
                            Text("\(rate) Hz").tag(rate)
                        }
                    }
                    Picker("声道", selection: $settings.audio.channels) {
                        ForEach(Capabilities.channels, id: \.self) { channels in
                            Text(channels == 1 ? "单声道" : "立体声").tag(channels)
                        }
                    }
                    Picker("PCM 格式", selection: $settings.audio.format) {
                        ForEach(PCMFormat.allCases, id: \.self) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }
                    Picker("录音源", selection: $settings.audio.source) {
                        ForEach(RecordingSource.allCases, id: \.self) { source in
                            Text(source.label).tag(source)
                        }
                    }
                    Picker("输出用途", selection: $settings.purpose) {
                        Text("本机试听").tag(OutputPurpose.monitor)
                        Text("虚拟麦克风").tag(OutputPurpose.virtualMicrophone)
                    }
                    Picker("输出设备", selection: $settings.outputUID) {
                        Text("系统默认设备").tag("default")
                        if settings.outputUID != "default" && !outputs.contains(where: { $0.id == settings.outputUID }) {
                            Text("已选输出设备暂不可用").tag(settings.outputUID)
                        }
                        ForEach(outputs) { output in
                            Text(output.name).tag(output.id)
                        }
                    }
                    LabeledContent("增益") {
                        HStack {
                            Slider(value: $settings.gain, in: 0...4)
                                .frame(maxWidth: 220)
                            Text(settings.gain, format: .number.precision(.fractionLength(2)))
                                .monospacedDigit()
                                .frame(width: 48, alignment: .trailing)
                        }
                    }
                    Toggle("静音输出", isOn: $settings.muted)
                }
                Section("连接") {
                    TextField("监听 IPv4", text: $settings.listenAddress)
                    TextField("音频端口", value: $settings.audioPort, format: .number)
                    TextField("控制端口", value: $settings.controlPort, format: .number)
                    TextField("Wi-Fi 手机地址（可选）", text: $settings.wifiHost)
                    TextField("配对码（可选）", text: $settings.pairingCode)
                }
                Section("网络共享") {
                    TextField("DNS IPv4", text: $settings.dns)
                    TextField("IPv4 路由 CIDR", text: $settings.routes)
                }
                if !errors.isEmpty {
                    Section("需要修正") {
                        ForEach(Array(errors.enumerated()), id: \.offset) { _, error in
                            Label(error, systemImage: "exclamationmark.circle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 14)
        }
        .frame(minWidth: 560, minHeight: 570)
        .onChange(of: settings) { _, _ in isDirty = true }
    }
}

private struct SetupWizard: View {
    let snapshot: AppSnapshot
    @Binding var step: Int
    let send: (UserAction) -> Void

    private let titles = ["连接手机", "准备麦克风", "确认真实声音"]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("首次设置").font(.title2.weight(.semibold))
                    Text("第 \(step + 1) 步，共 3 步 · \(titles[step])")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("跳过向导") {
                    send(.skipWizard)
                }
                .disabled(snapshot.wizardSkipped)
            }
            ProgressView(value: Double(step + 1), total: 3)

            Group {
                switch step {
                case 0:
                    connectStep
                case 1:
                    microphoneStep
                default:
                    soundTestStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack {
                if step > 0 {
                    Button("上一步") { step -= 1 }
                }
                Spacer()
                if step < 2 {
                    Button("下一步") { step += 1 }
                        .buttonStyle(.borderedProminent)
                } else if snapshot.soundTestCompleted {
                    Label("声音测试已确认", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(24)
    }

    private var connectStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("连接 Android 手机，并在手机上确认 USB 调试授权。")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            if snapshot.devices.isEmpty {
                EmptyStateCard(title: "当前没有设备", detail: "连接手机后刷新设备状态。", symbol: "iphone.slash")
            } else {
                ForEach(snapshot.devices) { device in
                    DeviceRow(device: device, selected: device.id == snapshot.selectedDeviceID) {
                        send(.selectDevice(device.id))
                    }
                }
            }
            Button {
                send(.refresh)
            } label: {
                Label("刷新设备", systemImage: "arrow.clockwise")
            }
        }
    }

    private var microphoneStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("权限由手机系统实际确认。麦克风授权与通知权限分别显示。")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            PermissionCard(title: "麦克风", state: snapshot.microphonePermission)
            PermissionCard(title: "通知", state: snapshot.notificationPermission)
            StatusCard(title: "麦克风任务", status: snapshot.microphone)
            HStack {
                Button {
                    send(.start(.microphone))
                } label: {
                    Label("开始麦克风准备", systemImage: "mic")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    send(.openPhoneSettings)
                } label: {
                    Label("打开手机设置", systemImage: "arrow.up.right.square")
                }
            }
        }
    }

    private var soundTestStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("请实际听到手机声音，或在目标软件中确认收到输入。只有真实传输且你确认听到后，才完成此步骤。")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            StatusCard(title: "实际任务阶段", status: snapshot.microphone)
            AudioFactsCard(snapshot: snapshot)
            HStack {
                Button {
                    send(.start(.microphone))
                } label: {
                    Label("开始声音测试", systemImage: "play.fill")
                }
                .disabled(isBusy(snapshot.microphone.phase) || snapshot.microphone.phase == .running)
                Button {
                    send(.completeSoundTest)
                } label: {
                    Label("我已确认真实声音", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .disabled(snapshot.soundTestCompleted || snapshot.audioState != .streaming || snapshot.receivedFrames == 0)
            }
        }
    }
}

private extension TaskPhase {
    var label: String {
        switch self {
        case .stopped: "已停止"
        case .checking: "检查中"
        case .preparing: "准备中"
        case .waitingUser: "等待用户"
        case .connecting: "连接中"
        case .running: "运行中"
        case .stopping: "停止中"
        case .failed: "失败"
        }
    }

    var tint: Color {
        switch self {
        case .running: .green
        case .failed: .red
        case .waitingUser: .orange
        case .stopped: .secondary
        case .checking, .preparing, .connecting, .stopping: .blue
        }
    }
}

private extension AudioState {
    var label: String {
        switch self {
        case .disconnected: "未连接"
        case .handshake: "握手中"
        case .waitingFrame: "等待音频帧"
        case .streaming: "有效音频传输"
        case .interrupted: "输入中断"
        case .failed: "故障"
        }
    }

    var tint: Color {
        switch self {
        case .streaming: .green
        case .failed, .interrupted: .red
        case .handshake, .waitingFrame: .orange
        case .disconnected: .secondary
        }
    }
}

private extension NetworkState {
    var label: String {
        switch self {
        case .stopped: "已停止"
        case .preparing: "链路准备中"
        case .addressed: "已获得地址"
        case .verifying: "出口验证中"
        case .available: "网络可用"
        case .noInternet: "链路存在但无外网"
        case .unsupported: "设备不支持或受限"
        case .failed: "故障"
        }
    }

    var explanation: String {
        switch self {
        case .available: "控制器已完成实际网络探测。"
        case .noInternet: "连接链路已建立，但当前没有可用外网。"
        case .unsupported: "设备能力或系统限制阻止了此功能。"
        case .preparing, .addressed, .verifying: "仍在准备或验证，尚未确认网络可用。"
        case .failed: "查看当前任务阶段和日志中的错误原因。"
        case .stopped: "尚未启动网络共享任务。"
        }
    }

    var symbol: String {
        switch self {
        case .available: "checkmark.circle.fill"
        case .noInternet, .unsupported, .failed: "exclamationmark.triangle.fill"
        case .preparing, .addressed, .verifying: "arrow.triangle.2.circlepath"
        case .stopped: "network.slash"
        }
    }

    var tint: Color {
        switch self {
        case .available: .green
        case .noInternet, .unsupported, .failed: .orange
        case .preparing, .addressed, .verifying: .blue
        case .stopped: .secondary
        }
    }
}

private extension DeviceState {
    var label: String {
        switch self {
        case .unauthorized: "未授权"
        case .online: "在线"
        case .offline: "离线"
        case .reenumerating: "重新识别中"
        }
    }

    var tint: Color {
        switch self {
        case .online: .green
        case .unauthorized: .orange
        case .offline: .secondary
        case .reenumerating: .blue
        }
    }
}

private extension PermissionState {
    var label: String {
        switch self {
        case .notRequested: "尚未请求"
        case .waiting: "等待确认"
        case .allowed: "已允许"
        case .denied: "已拒绝"
        case .settingsRequired: "需要系统设置"
        }
    }

    var symbol: String {
        switch self {
        case .notRequested: "circle.dashed"
        case .waiting: "clock"
        case .allowed: "checkmark.circle.fill"
        case .denied: "xmark.circle.fill"
        case .settingsRequired: "gearshape"
        }
    }

    var tint: Color {
        switch self {
        case .allowed: .green
        case .denied, .settingsRequired: .orange
        case .waiting: .blue
        case .notRequested: .secondary
        }
    }
}

private extension RecordingSource {
    var label: String {
        switch self {
        case .microphone: "麦克风"
        case .unprocessed: "未处理"
        case .voiceRecognition: "语音识别"
        }
    }
}

private extension View {
    func cardStyle() -> some View {
        self
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
            }
    }
}
