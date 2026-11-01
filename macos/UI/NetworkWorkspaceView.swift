import SwiftUI
import Contracts
import Support

struct NetworkWorkspaceView: View {
    @Environment(\.colorScheme) private var colorScheme
    let snapshot: AppSnapshot
    let send: (UserAction) -> Void

    @State private var draftDns: String
    @State private var draftRoutes: String
    @State private var showAdvancedNetwork: Bool
    @State private var awaitingSaveCompletion: Bool = false

    public init(
        snapshot: AppSnapshot,
        initialShowAdvanced: Bool = false,
        send: @escaping (UserAction) -> Void
    ) {
        self.snapshot = snapshot
        self.send = send
        _draftDns = State(initialValue: snapshot.settings.dns)
        _draftRoutes = State(initialValue: snapshot.settings.routes)
        _showAdvancedNetwork = State(initialValue: initialShowAdvanced)
    }

    private var palette: ZenPalette { ZenPalette(colorScheme) }

    private var isNetworkDirty: Bool {
        draftDns != snapshot.settings.dns || draftRoutes != snapshot.settings.routes
    }

    private var hasFailureOrRecovery: Bool {
        snapshot.phoneInternet.phase == .failed
            || snapshot.macInternet.phase == .failed
            || !snapshot.recoveryMessage.isEmpty
    }

    private var deviceDisplayName: String {
        if let id = snapshot.selectedDeviceID,
           let device = snapshot.devices.first(where: { $0.id == id }) {
            return device.name
        }
        if let first = snapshot.devices.first {
            return first.name
        }
        return "Android 手机"
    }

    private var networkValidationErrors: [String] {
        var issues: [String] = []
        let trimmedDns = draftDns.trimmingCharacters(in: .whitespacesAndNewlines)
        if !SettingsValidator.isValidIPv4(trimmedDns) {
            issues.append("DNS 必须是有效的 IPv4 地址 (例如 1.1.1.1)")
        }
        var copy = snapshot.settings
        copy.dns = trimmedDns
        copy.routes = draftRoutes.trimmingCharacters(in: .whitespacesAndNewlines)
        for err in SettingsValidator.errors(copy) where err.contains("routes") || err.contains("IPv4 CIDR") {
            issues.append("路由必须包含一个或多个以逗号分隔的 IPv4 CIDR 网段 (例如 0.0.0.0/0)")
        }
        return issues
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ZenWorkspaceHeroHeader(
                    eyebrow: "网络互联",
                    title: "USB 有线网络共享",
                    subtitle: "提供「手机网络给 Mac (USB NCM 网卡)」与「Mac 网络给手机 (ADB 隧道 + VPN)」两种互斥有线供网方式。"
                )

                phoneToMacCard
                macToPhoneCard

                HStack(alignment: .center, spacing: 12) {
                    Text("两个方向共用同一条 USB 链路，同一时间只能运行一个；切换方向前会自动停止当前方向。链路就绪仅代表本地接口或隧道已建立，不等同于公网出口已验证。")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textTertiary)

                    Spacer(minLength: 8)

                    if hasFailureOrRecovery {
                        Button("刷新设备") {
                            send(.refresh)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("全部停止并清理") {
                            send(.stopAll)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 4)

                if !snapshot.recoveryMessage.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.shield")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.textSecondary)
                        Text("会话安全与恢复状态：\(snapshot.recoveryMessage)")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.textSecondary)
                    }
                    .padding(.horizontal, 4)
                }
            }
            .frame(maxWidth: 816, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 30)
        }
        .onChange(of: snapshot.settingsSavedRevision) { _, _ in
            if awaitingSaveCompletion {
                draftDns = snapshot.settings.dns
                draftRoutes = snapshot.settings.routes
                awaitingSaveCompletion = false
            } else if !isNetworkDirty {
                draftDns = snapshot.settings.dns
                draftRoutes = snapshot.settings.routes
            }
        }
        .onChange(of: snapshot.isSavingSettings) { _, isSaving in
            if !isSaving && snapshot.settingsError != nil {
                awaitingSaveCompletion = false
            }
        }
        .onChange(of: snapshot.settings) { _, newSettings in
            if !isNetworkDirty && !awaitingSaveCompletion && !snapshot.isSavingSettings && snapshot.settingsError == nil {
                draftDns = newSettings.dns
                draftRoutes = newSettings.routes
            }
        }
    }

    // MARK: - Card 1: 手机网络提供给 Mac (USB NCM)

    private var phoneToMacCard: some View {
        let status = snapshot.phoneInternet
        let isRunning = status.phase == .running
        let isStoppedOrFailed = status.phase == .stopped || status.phase == .failed
        let stepIndex = activeStepIndex(for: status)

        let subtitleText: String = if isRunning {
            "USB NCM 网卡与本地地址已就绪（\(deviceDisplayName)）；公网出口取决于手机蜂窝或 Wi-Fi 连通性"
        } else if !status.detail.isEmpty && status.phase != .stopped {
            status.detail
        } else {
            "通过 Android USB NCM 虚拟网卡将手机蜂窝数据或 Wi-Fi 共享给 Mac"
        }

        return VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("手机网络提供给 Mac (USB NCM)")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(palette.textPrimary)

                    Text(subtitleText)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(palette.textSecondary)
                }

                Spacer(minLength: 16)

                ZenCapsuleActionButton(
                    title: isStoppedOrFailed ? (status.phase == .failed ? "重试开启" : "开启供网") : "停止供网",
                    isStop: !isStoppedOrFailed,
                    width: 138,
                    height: 44,
                    isDisabled: status.phase == .stopping || snapshot.isSavingSettings
                ) {
                    send(isStoppedOrFailed ? .start(.phoneInternet) : .stop(.phoneInternet))
                }
            }

            if isRunning || isTaskBusy(status.phase) {
                linkStateWell(
                    primaryText: isRunning ? "NCM 链路与地址已就绪" : status.stage,
                    secondaryText: isRunning ? "本地 USB 网卡已配置；公网连通性取决于手机上游网络" : "正在协商 USB 共享接口与本地地址"
                )
            } else {
                Rectangle()
                    .fill(palette.divider)
                    .frame(height: 1)
            }

            HStack(spacing: 0) {
                let steps = ["① USB 就绪", "② NCM 激活", "③ DHCP 分配", "④ 链路就绪"]
                ForEach(Array(steps.enumerated()), id: \.offset) { idx, label in
                    let isHighlighted = (isRunning && idx == 3) || (!isRunning && stepIndex == idx)
                    Text(label)
                        .font(.system(size: 12, weight: isHighlighted ? .bold : .regular))
                        .foregroundStyle(isHighlighted ? palette.accentBlue : palette.textSecondary)
                    if idx < steps.count - 1 {
                        Spacer()
                    }
                }
            }

            if let errorCode = status.errorCode, !errorCode.isEmpty {
                HStack(alignment: .center, spacing: 12) {
                    Text("错误代码：\(errorCode) · \(status.detail)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.stopCrimson)
                    Spacer()
                    Button("停止并清理") {
                        send(.stop(.phoneInternet))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .zenCard(isActive: isRunning, cornerRadius: 20)
    }

    // MARK: - Card 2: Mac 网络共享给手机 (ADB 隧道 / VPN)

    private var macToPhoneCard: some View {
        let status = snapshot.macInternet
        let isRunning = status.phase == .running
        let isStoppedOrFailed = status.phase == .stopped || status.phase == .failed

        let subtitleText: String = if isRunning {
            "ADB USB 转发与手机 VPN 隧道已建立（\(deviceDisplayName)）；实际联网取决于 Mac 当前出口"
        } else if !status.detail.isEmpty && status.phase != .stopped {
            status.detail
        } else {
            "通过 ADB USB 端口转发与手机端 VPN 服务，将 Mac 当前网络转发给 Android 手机"
        }

        return VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Mac 网络共享给手机 (ADB 隧道 / VPN)")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(palette.textPrimary)

                    Text(subtitleText)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(palette.textSecondary)
                }

                Spacer(minLength: 16)

                ZenCapsuleActionButton(
                    title: isStoppedOrFailed ? (status.phase == .failed ? "重试开启" : "开启供网") : "停止供网",
                    isStop: !isStoppedOrFailed,
                    width: 138,
                    height: 44,
                    isDisabled: status.phase == .stopping || snapshot.isSavingSettings
                ) {
                    send(isStoppedOrFailed ? .start(.macInternet) : .stop(.macInternet))
                }
            }

            if isRunning || isTaskBusy(status.phase) {
                linkStateWell(
                    primaryText: isRunning ? "USB 转发与 VPN 隧道已建立" : status.stage,
                    secondaryText: isRunning ? "仅代表本地隧道已连通；请以手机实际访问验证外网出口" : "正在建立 ADB 转发与手机 VPN 隧道"
                )
            }

            Rectangle()
                .fill(palette.divider)
                .frame(height: 1)

            // Status overview row
            HStack(alignment: .center) {
                HStack(spacing: 8) {
                    Text("DNS 配置")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textSecondary)
                    Text(snapshot.settings.dns)
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(palette.textPrimary)
                }

                Spacer()

                HStack(spacing: 8) {
                    Text("路由网段")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textSecondary)
                    Text(snapshot.settings.routes)
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(palette.textPrimary)
                }

                Spacer()

                HStack(spacing: 8) {
                    Text("手机状态")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textSecondary)
                    Text("VPN 权限\(snapshot.vpnPermission.label)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(snapshot.vpnPermission == .allowed ? palette.emeraldGreen : palette.textSecondary)
                }
            }

            // Expandable in-page DNS and Routes settings
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showAdvancedNetwork.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showAdvancedNetwork ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                        Text(showAdvancedNetwork ? "收起供网高级选项" : "展开供网高级选项 (DNS 与路由设置)")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(palette.textSecondary)
                }
                .buttonStyle(.plain)

                if showAdvancedNetwork {
                    VStack(spacing: 0) {
                        networkSettingRow(title: "VPN 下发 DNS 服务器", showDivider: true) {
                            TextField("1.1.1.1", text: $draftDns)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, weight: .medium).monospacedDigit())
                                .foregroundStyle(palette.textPrimary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 12)
                                .frame(width: 144, height: 30)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(palette.cardBackground)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(palette.border, lineWidth: 1)
                                }
                        }

                        networkSettingRow(title: "VPN 转发路由网段", showDivider: false) {
                            TextField("0.0.0.0/0", text: $draftRoutes)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(palette.textPrimary)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 180)
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(palette.windowBackground)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(palette.border, lineWidth: 1)
                    }

                    // Scoped feedback and action bar for network draft
                    macNetworkDraftBar(isRunning: isRunning)
                }
            }

            if let errorCode = status.errorCode, !errorCode.isEmpty {
                HStack(alignment: .center, spacing: 12) {
                    Text("错误代码：\(errorCode) · \(status.detail)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.stopCrimson)
                    Spacer()
                    Button("停止并清理") {
                        send(.stop(.macInternet))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .zenCard(isActive: isRunning, cornerRadius: 20)
    }

    private var networkDraftDiffs: [String] {
        var changes: [String] = []
        if draftDns != snapshot.settings.dns {
            changes.append("DNS: \(snapshot.settings.dns) → \(draftDns)")
        }
        if draftRoutes != snapshot.settings.routes {
            changes.append("路由: \(snapshot.settings.routes) → \(draftRoutes)")
        }
        return changes
    }

    // MARK: - Mac Network Scoped Draft Bar

    @ViewBuilder
    private func macNetworkDraftBar(isRunning: Bool) -> some View {
        if !networkValidationErrors.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(networkValidationErrors, id: \.self) { err in
                    Text("• \(err)")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.stopCrimson)
                }
            }
            .padding(.horizontal, 4)
        }

        if let error = snapshot.settingsError, awaitingSaveCompletion {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(palette.stopCrimson)
                Text(error)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.stopCrimson)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(palette.stopCrimson.opacity(0.1))
            )
        }

        if snapshot.isSavingSettings, awaitingSaveCompletion {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(snapshot.settingsMessage.isEmpty ? "正在保存网络设置…" : snapshot.settingsMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
            }
            .padding(10)
        }

        if isNetworkDirty {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("未应用修改")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(palette.accentBlue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(palette.accentBlue.opacity(0.15), in: Capsule())

                        Text(isRunning ? "生效修改将停止供网服务" : "修改尚未保存")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(palette.textPrimary)
                    }

                    let diffs = networkDraftDiffs
                    if !diffs.isEmpty {
                        Text(diffs.joined(separator: " · "))
                            .font(.system(size: 11))
                            .foregroundStyle(palette.textSecondary)
                    }
                }

                Spacer()

                Button("放弃修改") {
                    draftDns = snapshot.settings.dns
                    draftRoutes = snapshot.settings.routes
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(palette.segmentedTrack, in: Capsule())
                .disabled(snapshot.isSavingSettings)

                Button {
                    saveNetworkSettings()
                } label: {
                    Text(snapshot.isSavingSettings ? "保存中…" : (isRunning ? "应用并停止供网" : "保存网络选项"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            isRunning ? palette.stopCrimson : palette.accentBlue,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .disabled(snapshot.isSavingSettings || !networkValidationErrors.isEmpty)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(palette.cardBackground)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(palette.accentBlue.opacity(0.3), lineWidth: 1)
            }
        }
    }

    private func saveNetworkSettings() {
        guard !snapshot.isSavingSettings, networkValidationErrors.isEmpty else { return }
        awaitingSaveCompletion = true
        var merged = snapshot.settings
        merged.dns = draftDns.trimmingCharacters(in: .whitespacesAndNewlines)
        merged.routes = draftRoutes.trimmingCharacters(in: .whitespacesAndNewlines)
        send(.saveSettings(merged))
    }

    private func networkSettingRow<Trailing: View>(
        title: String,
        showDivider: Bool,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)

                Spacer()

                trailing()
            }
            .padding(.horizontal, 20)
            .frame(height: 46)

            if showDivider {
                Rectangle()
                    .fill(palette.divider)
                    .frame(height: 1)
                    .padding(.horizontal, 20)
            }
        }
    }

    // MARK: - Link State Well

    private func linkStateWell(primaryText: String, secondaryText: String) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(palette.emeraldGreen)
                .frame(width: 7, height: 7)

            Text(primaryText)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.textPrimary)

            Text(secondaryText)
                .font(.system(size: 12))
                .foregroundStyle(palette.textSecondary)

            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(height: 54)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(palette.recessedWell)
        )
    }

    private func activeStepIndex(for status: ModuleStatus) -> Int {
        switch status.phase {
        case .stopped: return -1
        case .checking: return 0
        case .preparing, .waitingUser: return 1
        case .connecting: return 2
        case .running: return 3
        case .stopping: return 1
        case .failed: return 0
        }
    }
}
