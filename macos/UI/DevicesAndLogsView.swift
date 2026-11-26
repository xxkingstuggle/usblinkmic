import AppKit
import SwiftUI
import Contracts
import Support

struct DevicesWorkspaceView: View {
    @Environment(\.colorScheme) private var colorScheme
    let snapshot: AppSnapshot
    let send: (UserAction) -> Void

    private var palette: ZenPalette { ZenPalette(colorScheme) }

    static func effectiveSelectedDeviceID(for snapshot: AppSnapshot) -> String? {
        if let selected = snapshot.selectedDeviceID,
           snapshot.devices.contains(where: { $0.id == selected }) {
            return selected
        }
        return snapshot.devices.first?.id
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .bottom, spacing: 12) {
                    WorkspaceHeading(
                        title: "设备与权限",
                        subtitle: snapshot.devices.isEmpty
                            ? "查看 USB 调试状态、已绑定的 Wi-Fi 手机和手机权限。"
                            : "已识别 \(snapshot.devices.count) 台 USB 设备。可在此选择目标设备并管理 Wi-Fi 绑定与手机权限。"
                    )

                    Spacer(minLength: 8)

                    if !snapshot.devices.isEmpty {
                        compactRescanButton
                    }
                }

                deviceCardSection

                wifiDevicesSection

                permissionTableSection

                adbHealthSection

                AboutUSBLinkMicCard()
            }
            .workspaceMargins()
        }
    }

    // MARK: - Device Card

    private var deviceCardSection: some View {
        let effectiveSelectedID = Self.effectiveSelectedDeviceID(for: snapshot)
        return VStack(spacing: 12) {
            if snapshot.devices.isEmpty {
                HStack(alignment: .center, spacing: 20) {
                    LineArtPhoneIcon(strokeColor: palette.textSecondary)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("尚未检测到 Android 手机")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(palette.textPrimary)

                        Text("支持 Android 8.0+ 手机 · 请确认已开启开发者选项与 USB 调试")
                            .font(.system(size: 13))
                            .foregroundStyle(palette.textSecondary)

                        Text("连接后将自动同步配套服务与系统权限")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(palette.textTertiary)
                    }

                    Spacer(minLength: 16)

                    rescanButton
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .zenCard(isActive: false, cornerRadius: 20)
            } else {
                ForEach(snapshot.devices) { device in
                    let isSelected = device.id == effectiveSelectedID
                    HStack(alignment: .center, spacing: 20) {
                        LineArtPhoneIcon(strokeColor: isSelected ? palette.accentBlue : palette.textSecondary)

                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text(device.name)
                                    .font(.system(size: 19, weight: .bold))
                                    .foregroundStyle(palette.textPrimary)
                                    .lineLimit(1)

                                StatusPill(
                                    label: device.state.label,
                                    tint: device.state == .online ? palette.emeraldGreen : .orange
                                )
                            }

                            Text("序列号：\(device.id) · 物理接口：USB 有线直连")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(palette.textSecondary)

                            Text(
                                isSelected
                                    ? "已选为主要采音与网络桥接设备"
                                    : (device.state == .online ? "已连接 · 可随时切换为当前目标设备" : "\(device.state.label) · 切换后可查看对应指引")
                            )
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(isSelected ? palette.emeraldGreen : palette.textTertiary)
                        }

                        Spacer(minLength: 16)

                        if isSelected {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("当前目标")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(palette.emeraldGreen)
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .background(
                                palette.emeraldGreen.opacity(palette.isDark ? 0.18 : 0.12),
                                in: Capsule()
                            )
                            .accessibilityLabel("\(device.name) 已选为当前目标设备")
                        } else {
                            Button {
                                send(.selectDevice(device.id))
                            } label: {
                                Text("设为当前目标")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(palette.accentBlue)
                                    .padding(.horizontal, 14)
                                    .frame(height: 34)
                                    .background(
                                        palette.accentBlue.opacity(palette.isDark ? 0.18 : 0.10),
                                        in: Capsule()
                                    )
                                    .overlay {
                                        Capsule()
                                            .strokeBorder(palette.accentBlue.opacity(0.35), lineWidth: 1)
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("将 \(device.name) 设为当前目标设备")
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                    .zenCard(isActive: isSelected, cornerRadius: 20)
                }
            }
        }
    }

    private var rescanButton: some View {
        Button {
            send(.refresh)
        } label: {
            HStack(spacing: 6) {
                Text("重新扫描")
                    .font(.system(size: 13, weight: .semibold))
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(width: 120, height: 42)
            .background(
                Color(red: 0x00 / 255.0, green: 0x71 / 255.0, blue: 0xE3 / 255.0),
                in: Capsule()
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("重新扫描 USB 设备 (⌘R)")
    }

    private var compactRescanButton: some View {
        Button {
            send(.refresh)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                Text("重新扫描")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(palette.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(palette.cardBackground, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(palette.border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help("重新扫描 USB 设备 (⌘R)")
    }

    // MARK: - Section: Wi-Fi 信任与自动连接设备

    private var wifiDevicesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Wi-Fi 局域网配对与信任设备")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.textSecondary)

                Spacer()

                Button {
                    send(.setWifiAutoConnect(!snapshot.settings.wifiAutoConnect))
                } label: {
                    Text(snapshot.settings.wifiAutoConnect ? "停用 Wi-Fi 自动连接" : "启用 Wi-Fi 自动连接")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.accentBlue)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "wifi")
                        .font(.system(size: 18))
                        .foregroundStyle(snapshot.wifiAuto.phase == .failed ? palette.stopCrimson : palette.accentBlue)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(snapshot.wifiAuto.message)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.textPrimary)

                        if let connected = snapshot.wifiAuto.connectedPhoneName {
                            Text("已连接：\(connected)")
                                .font(.system(size: 12))
                                .foregroundStyle(palette.emeraldGreen)
                        }
                    }

                    Spacer()
                }

                if !snapshot.wifiAuto.trusted.isEmpty {
                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("已信任并允许自动连接的手机（\(snapshot.wifiAuto.trusted.count)）")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(palette.textSecondary)

                        ForEach(snapshot.wifiAuto.trusted) { phone in
                            HStack {
                                Image(systemName: "iphone")
                                    .foregroundStyle(palette.textSecondary)

                                Text(phone.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(palette.textPrimary)

                                Text("(\(phone.id.prefix(8)))")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(palette.textTertiary)

                                Spacer()

                                Button("解除信任") {
                                    send(.forgetWifiPhone(phone.id))
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 12))
                                .foregroundStyle(palette.stopCrimson)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .padding(18)
            .zenCard(isActive: snapshot.wifiAuto.connectedPhoneName != nil, cornerRadius: 16)
        }
    }

    // MARK: - Section 2: 手机端系统权限状态

    private var permissionTableSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("手机端系统权限状态 (自动双向同步)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.textSecondary)

                Spacer()

                if snapshot.selectedDeviceID != nil {
                    Button {
                        send(.openPhoneSettings)
                    } label: {
                        Text("打开手机端系统设置 ↗")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(palette.accentBlue)
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(spacing: 0) {
                permissionRow(
                    title: "麦克风录音权限 (RECORD_AUDIO)",
                    description: "用于 USB / Wi-Fi 实时采集手机麦克风音频流",
                    statusText: snapshot.microphonePermission.label,
                    tint: snapshot.microphonePermission.tint,
                    showDivider: true
                )
                permissionRow(
                    title: "前台常驻服务通知 (POST_NOTIFICATIONS)",
                    description: "维持 Android 后台音频引擎常驻，不被系统冻结",
                    statusText: snapshot.notificationPermission.label,
                    tint: snapshot.notificationPermission.tint,
                    showDivider: true
                )
                permissionRow(
                    title: "VPN 虚拟网卡隧道 (VpnService)",
                    description: "用于「Mac 网络给手机」时建立本地环回网络隧道",
                    statusText: snapshot.vpnPermission.label,
                    tint: snapshot.vpnPermission.tint,
                    showDivider: false
                )
            }
            .zenCard(isActive: false, cornerRadius: 18)
        }
    }

    private func permissionRow(
        title: String,
        description: String,
        statusText: String,
        tint: Color,
        showDivider: Bool
    ) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .frame(width: 280, alignment: .leading)
                    .lineLimit(1)

                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)

                Spacer(minLength: 12)

                StatusPill(label: statusText, tint: tint)
            }
            .padding(.horizontal, 24)
            .frame(height: 50)

            if showDivider {
                Rectangle()
                    .fill(palette.divider)
                    .frame(height: 1)
                    .padding(.horizontal, 24)
            }
        }
    }

    // MARK: - Section 3: ADB 通信与链路健康度

    private var adbHealthSection: some View {
        let rateKhz = String(format: "%.1f", Double(snapshot.settings.audio.sampleRate) / 1000.0)
        return VStack(alignment: .leading, spacing: 10) {
            Text("ADB 通信与链路健康度")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.textSecondary)

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("控制端口：TCP \(snapshot.settings.controlPort)")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(palette.textPrimary)
                    Text("物理连接状态：\(snapshot.devices.isEmpty ? "待连接" : "USB 有线直连")")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    Text("音频流端口：TCP \(snapshot.settings.audioPort) (\(snapshot.settings.audio.format.rawValue.uppercased()) \(rateKhz)kHz)")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(palette.textPrimary)
                    Text("累计接收音频帧：\(snapshot.receivedFrames.formatted()) 帧")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(palette.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    Text("网络共享：USB NCM 虚拟网卡")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                    Text("隧道出口：\(snapshot.settings.routes)")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(palette.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .zenCard(isActive: false, cornerRadius: 18)
        }
    }
}

// MARK: - Section 10 Diagnostic Logs Workspace (1H & 1I)

struct LogsWorkspaceView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let snapshot: AppSnapshot
    let send: (UserAction) -> Void

    @State private var selectedFilter: LogFilter = .all
    @State private var searchQuery: String = ""
    @State private var copiedFeedback = false

    private var palette: ZenPalette { ZenPalette(colorScheme) }

    enum LogFilter: String, CaseIterable, Identifiable {
        case all = "全部"
        case audio = "音频"
        case network = "网络"
        case wifi = "Wi-Fi"
        case system = "系统"

        var id: String { rawValue }

        func matches(_ module: String) -> Bool {
            let normalized = module.lowercased()
            switch self {
            case .all:
                return true
            case .audio:
                return normalized == "audio" || normalized == "microphone"
            case .network:
                return normalized == "phoneinternet" || normalized == "macinternet" || normalized == "network"
            case .wifi:
                return normalized == "wifi" || normalized == "wifiauto"
            case .system:
                return !["audio", "microphone", "phoneinternet", "macinternet", "network", "wifi", "wifiauto"].contains(normalized)
            }
        }
    }

    static func filteredEntries(_ logs: [LogEntry], filter: LogFilter, query: String) -> [LogEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return logs.reversed().filter { entry in
            guard filter.matches(entry.module) else { return false }
            guard !trimmed.isEmpty else { return true }
            return entry.module.lowercased().contains(trimmed)
                || entry.stage.lowercased().contains(trimmed)
                || entry.message.lowercased().contains(trimmed)
        }
    }

    static func formattedRedactedLogs(_ entries: [LogEntry]) -> String {
        let header = "# USBLinkMic Diagnostics (Redacted) v=\(Capabilities.version) count=\(entries.count)"
        let lines = entries.map { entry in
            let module = LogRedactor.redact(entry.module)
            let stage = LogRedactor.redact(entry.stage)
            let message = LogRedactor.redact(entry.message)
            return "\(entry.date.ISO8601Format()) \(module) \(stage) \(message)"
        }
        return ([header] + lines).joined(separator: "\n") + "\n"
    }

    private func count(for filter: LogFilter) -> Int {
        snapshot.logs.filter { filter.matches($0.module) }.count
    }

    private var filteredLogs: [LogEntry] {
        Self.filteredEntries(snapshot.logs, filter: selectedFilter, query: searchQuery)
    }

    private func copyRedactedLogs() {
        let entries = filteredLogs
        guard !entries.isEmpty else { return }
        let text = Self.formattedRedactedLogs(entries)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if reduceMotion {
            copiedFeedback = true
        } else {
            withAnimation(.easeInOut(duration: 0.15)) {
                copiedFeedback = true
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            if reduceMotion {
                copiedFeedback = false
            } else {
                withAnimation(.easeInOut(duration: 0.15)) {
                    copiedFeedback = false
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WorkspaceHeading(title: "诊断日志", subtitle: "按模块与关键字实时检索连接事件、权限提示与错误记录，复制与导出均自动脱敏。")
            filterToolbarCard
            logTableCard
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .workspaceMargins()
    }

    // MARK: - Filter Toolbar Card

    private var filterToolbarCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(LogFilter.allCases) { filter in
                    let isSelected = selectedFilter == filter
                    Button {
                        selectedFilter = filter
                    } label: {
                        Text("\(filter.rawValue) (\(count(for: filter)))")
                            .font(.system(size: 12, weight: isSelected ? .bold : .medium).monospacedDigit())
                            .foregroundStyle(isSelected ? palette.accentBlue : palette.textSecondary)
                            .padding(.horizontal, 11)
                            .frame(height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(isSelected ? palette.accentBlue.opacity(palette.isDark ? 0.22 : 0.12) : palette.cardBackground)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(isSelected ? palette.accentBlue.opacity(0.45) : palette.border, lineWidth: 1)
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textTertiary)

                    TextField("过滤关键字、模块或错误码...", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textPrimary)

                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(palette.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清空搜索关键字")
                    }
                }
                .padding(.horizontal, 12)
                .frame(minWidth: 160, maxWidth: .infinity)
                .frame(height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(palette.windowBackground)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(palette.border, lineWidth: 1)
                }

                Button {
                    copyRedactedLogs()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: copiedFeedback ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold))
                        Text(copiedFeedback ? "已复制脱敏日志" : "复制脱敏")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(copiedFeedback ? palette.emeraldGreen : palette.accentBlue)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(palette.cardBackground)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(copiedFeedback ? palette.emeraldGreen.opacity(0.5) : palette.border, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .disabled(filteredLogs.isEmpty)
                .help("将当前筛选出的脱敏诊断日志复制到剪贴板")

                Button {
                    send(.exportLogs)
                } label: {
                    Text("导出 ↻")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
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
                .help("导出脱敏诊断日志到文件")

                Button {
                    send(.clearLogs)
                } label: {
                    Text("清空 ⌫")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.stopCrimson)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
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
                .disabled(snapshot.logs.isEmpty)
            }
        }
        .padding(12)
        .zenCard(isActive: false, cornerRadius: 14)
    }

    // MARK: - Console Table Card

    private var logTableCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("时间戳")
                    .frame(width: 96, alignment: .leading)
                Text("模块")
                    .frame(width: 116, alignment: .leading)
                Text("阶段")
                    .frame(width: 124, alignment: .leading)
                Text("日志消息与遥测内容")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(palette.textTertiary)
            .padding(.horizontal, 20)
            .frame(height: 38)
            .background(palette.windowBackground.opacity(0.65))

            Rectangle()
                .fill(palette.divider)
                .frame(height: 1)

            if filteredLogs.isEmpty {
                VStack(spacing: 8) {
                    Text(snapshot.logs.isEmpty ? "暂无诊断日志" : "没有匹配的日志记录")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.textSecondary)
                    Text("系统控制台实时输出与排障事件将按时间倒序流式展示在此处。")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredLogs) { entry in
                            ZenConsoleLogRow(entry: entry, palette: palette)
                            Rectangle()
                                .fill(palette.divider)
                                .frame(height: 1)
                        }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .zenCard(isActive: false, cornerRadius: 18)
    }
}

private struct ZenConsoleLogRow: View {
    let entry: LogEntry
    let palette: ZenPalette

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(Self.timeFormatter.string(from: entry.date))
                .font(.system(size: 12, design: .monospaced).monospacedDigit())
                .foregroundStyle(palette.textSecondary)
                .frame(width: 96, alignment: .leading)

            HStack {
                Text(entry.module)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(palette.segmentedTrack)
                    )
                Spacer(minLength: 0)
            }
            .frame(width: 116, alignment: .leading)

            Text(entry.stage)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(palette.textPrimary)
                .frame(width: 124, alignment: .leading)
                .lineLimit(1)

            Text(LogRedactor.redact(entry.message))
                .font(.system(size: 12))
                .foregroundStyle(palette.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
    }
}
