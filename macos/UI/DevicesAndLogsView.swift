import SwiftUI
import Contracts

struct DevicesWorkspaceView: View {
    let snapshot: AppSnapshot
    let send: (UserAction) -> Void

    private var onlineCount: Int {
        snapshot.devices.filter { $0.state == .online }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heroDeviceBanner
                deviceListSection
                permissionSection
                moduleSummarySection
                if !snapshot.recoveryMessage.isEmpty {
                    NativeGroupedSection("启动恢复记录") {
                        NativeSettingRow(
                            title: "持久化恢复摘要",
                            subtitle: snapshot.recoveryMessage,
                            symbol: "arrow.uturn.backward.circle.fill",
                            symbolTint: .orange,
                            showDivider: false
                        ) {
                            EmptyView()
                        }
                    }
                }
            }
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
    }

    private var heroDeviceBanner: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill((onlineCount > 0 ? Color.green : Color.accentColor).opacity(0.15))
                    .frame(width: 46, height: 46)
                Image(systemName: snapshot.devices.isEmpty ? "iphone.slash" : "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(onlineCount > 0 ? .green : .accentColor)
                    .symbolRenderingMode(.hierarchical)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(snapshot.devices.isEmpty ? "尚未检测到 USB 设备" : "已发现 \(snapshot.devices.count) 台设备（\(onlineCount) 台在线）")
                        .font(.title3.weight(.semibold))
                    if let selectedID = snapshot.selectedDeviceID,
                       let device = snapshot.devices.first(where: { $0.id == selectedID }) {
                        StatusPill(
                            label: "当前目标：\(device.name)",
                            symbol: "checkmark.circle.fill",
                            tint: device.state.tint
                        )
                    }
                }
                Text("连接 Android 手机并开启「开发者选项 → USB 调试」，在手机弹窗中点击「允许」后即可建立控制通道。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                if snapshot.selectedDeviceID != nil {
                    Button {
                        send(.openPhoneSettings)
                    } label: {
                        Label("手机应用设置", systemImage: "arrow.up.forward.app")
                    }
                }

                Button {
                    send(.refresh)
                } label: {
                    Label("刷新设备", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .heroGlassSurface(tint: onlineCount > 0 ? .green : .accentColor)
    }

    private var deviceListSection: some View {
        NativeGroupedSection("USB 设备列表") {
            if snapshot.devices.isEmpty {
                NativeSettingRow(
                    title: "没有检测到 Android 手机",
                    subtitle: "请使用支持数据传输的 USB 线连接手机，并在手机上确认 USB 调试信任。",
                    symbol: "cable.connector.slash",
                    symbolTint: .secondary,
                    showDivider: false
                ) {
                    Button("重新扫描") {
                        send(.refresh)
                    }
                    .controlSize(.small)
                }
            } else {
                ForEach(Array(snapshot.devices.enumerated()), id: \.element.id) { index, device in
                    let isSelected = device.id == snapshot.selectedDeviceID
                    Button {
                        send(.selectDevice(device.id))
                    } label: {
                        NativeSettingRow(
                            title: device.name,
                            subtitle: "序列号：\(device.id)",
                            symbol: isSelected ? "checkmark.circle.fill" : "iphone.gen3",
                            symbolTint: isSelected ? .accentColor : device.state.tint,
                            showDivider: index < snapshot.devices.count - 1
                        ) {
                            StatusPill(
                                label: device.state.label,
                                tint: device.state.tint
                            )
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var permissionSection: some View {
        NativeGroupedSection(
            "手机端系统权限状态",
            footer: "权限状态由手机端配套 App 实时上报；若某项显示「已拒绝」或「需在手机系统设置开启」，可点击上方「手机应用设置」直接跳转。"
        ) {
            NativeSettingRow(
                title: "麦克风录音授权",
                subtitle: "用于 USB / Wi-Fi 实时采集手机麦克风音频",
                symbol: "mic.fill",
                symbolTint: snapshot.microphonePermission.tint
            ) {
                StatusPill(
                    label: snapshot.microphonePermission.label,
                    symbol: snapshot.microphonePermission.symbol,
                    tint: snapshot.microphonePermission.tint
                )
            }

            NativeSettingRow(
                title: "前台常驻通知权限",
                subtitle: "Android 后台采音与网络共享保活所需的前台服务通知",
                symbol: "bell.badge.fill",
                symbolTint: snapshot.notificationPermission.tint
            ) {
                StatusPill(
                    label: snapshot.notificationPermission.label,
                    symbol: snapshot.notificationPermission.symbol,
                    tint: snapshot.notificationPermission.tint
                )
            }

            NativeSettingRow(
                title: "VPN 隧道授权",
                subtitle: "仅在「Mac 网络给手机」反向供网时由手机系统弹窗确认",
                symbol: "network.badge.shield.half.filled",
                symbolTint: snapshot.vpnPermission.tint,
                showDivider: false
            ) {
                StatusPill(
                    label: snapshot.vpnPermission.label,
                    symbol: snapshot.vpnPermission.symbol,
                    tint: snapshot.vpnPermission.tint
                )
            }
        }
    }

    private var moduleSummarySection: some View {
        NativeGroupedSection("三大功能模块运行概览") {
            NativeSettingRow(
                title: "手机麦克风",
                subtitle: snapshot.microphone.stage,
                symbol: "mic.fill",
                symbolTint: snapshot.microphone.phase.tint
            ) {
                StatusPill(
                    label: snapshot.microphone.phase.label,
                    symbol: snapshot.microphone.phase.symbol,
                    tint: snapshot.microphone.phase.tint
                )
            }

            NativeSettingRow(
                title: "手机网络给 Mac",
                subtitle: snapshot.phoneInternet.stage,
                symbol: "personalhotspot",
                symbolTint: snapshot.phoneInternet.phase.tint
            ) {
                StatusPill(
                    label: snapshot.phoneInternet.phase.label,
                    symbol: snapshot.phoneInternet.phase.symbol,
                    tint: snapshot.phoneInternet.phase.tint
                )
            }

            NativeSettingRow(
                title: "Mac 网络给手机",
                subtitle: snapshot.macInternet.stage,
                symbol: "network",
                symbolTint: snapshot.macInternet.phase.tint,
                showDivider: false
            ) {
                StatusPill(
                    label: snapshot.macInternet.phase.label,
                    symbol: snapshot.macInternet.phase.symbol,
                    tint: snapshot.macInternet.phase.tint
                )
            }
        }
    }
}

// MARK: - Console.app Style Diagnostic Logs Workspace

struct LogsWorkspaceView: View {
    let snapshot: AppSnapshot
    let send: (UserAction) -> Void

    @State private var selectedFilter: LogFilter = .all
    @State private var searchQuery: String = ""

    enum LogFilter: String, CaseIterable, Identifiable {
        case all = "全部"
        case audio = "音频与麦克风"
        case network = "网络共享"
        case system = "设备与恢复"

        var id: String { rawValue }

        func matches(_ module: String) -> Bool {
            switch self {
            case .all:
                return true
            case .audio:
                return module == "audio" || module == "microphone"
            case .network:
                return module == "phoneInternet" || module == "macInternet"
            case .system:
                return !["audio", "microphone", "phoneInternet", "macInternet"].contains(module)
            }
        }
    }

    private var filteredLogs: [LogEntry] {
        snapshot.logs.reversed().filter { entry in
            guard selectedFilter.matches(entry.module) else { return false }
            guard !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
            let query = searchQuery.lowercased()
            return entry.module.lowercased().contains(query)
                || entry.stage.lowercased().contains(query)
                || entry.message.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            consoleToolbar
            Divider()
            consoleBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var consoleToolbar: some View {
        HStack(spacing: 12) {
            Picker("筛选模块", selection: $selectedFilter) {
                ForEach(LogFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 340)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField("过滤阶段、错误码或关键字…", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.callout)
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: 240)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            Spacer()

            Text("\(filteredLogs.count) / \(snapshot.logs.count) 条")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                send(.exportLogs)
            } label: {
                Label("导出…", systemImage: "square.and.arrow.up")
            }
            .controlSize(.small)

            Button(role: .destructive) {
                send(.clearLogs)
            } label: {
                Label("清空", systemImage: "trash")
            }
            .controlSize(.small)
            .disabled(snapshot.logs.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    @ViewBuilder
    private var consoleBody: some View {
        if snapshot.logs.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "text.and.command.macwindow")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.secondary)
                Text("暂无诊断日志")
                    .font(.headline)
                Text("连接阶段、音频帧统计与错误详情将按时间倒序实时记录在此处。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
        } else if filteredLogs.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("没有匹配的日志条目")
                    .font(.headline)
                Button("重置筛选条件") {
                    selectedFilter = .all
                    searchQuery = ""
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(filteredLogs.enumerated()), id: \.element.id) { index, entry in
                        ConsoleLogRow(entry: entry, isEven: index.isMultiple(of: 2))
                        Divider()
                            .opacity(0.35)
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.45))
        }
    }
}

private struct ConsoleLogRow: View {
    let entry: LogEntry
    let isEven: Bool

    private var moduleTint: Color {
        switch entry.module {
        case "audio", "microphone": .blue
        case "phoneInternet": .green
        case "macInternet": .purple
        case "recovery", "shutdown": .orange
        default: .secondary
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(entry.date, style: .time)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)

            Text(entry.module)
                .font(.caption2.monospaced().weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(moduleTint.opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .foregroundStyle(moduleTint)
                .frame(width: 96, alignment: .leading)

            Text(entry.stage)
                .font(.caption.monospaced().weight(.medium))
                .foregroundStyle(.primary.opacity(0.85))
                .frame(width: 140, alignment: .leading)
                .lineLimit(1)

            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .background(isEven ? Color.clear : Color.primary.opacity(0.025))
    }
}
