import SwiftUI
import Contracts

struct DevicesWorkspaceView: View {
    @Environment(\.colorScheme) private var colorScheme
    let snapshot: AppSnapshot
    let send: (UserAction) -> Void

    private var palette: ZenPalette { ZenPalette(colorScheme) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ZenWorkspaceHeroHeader(
                    eyebrow: "硬件与授权",
                    title: snapshot.devices.isEmpty
                        ? "等待 Android 手机连接"
                        : "已识别 \(snapshot.devices.count) 台 Android 手机",
                    subtitle: snapshot.devices.isEmpty
                        ? "请通过 USB 数据线连接 Android 手机，并在手机弹窗中点击「允许 USB 调试」。"
                        : "已通过 USB 有线通道建立控制总线，设备与权限状态实时同步。"
                )

                deviceCardSection

                permissionTableSection

                adbHealthSection
            }
            .frame(maxWidth: 816, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 28)
        }
    }

    // MARK: - Device Card

    private var deviceCardSection: some View {
        VStack(spacing: 12) {
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
                    let isSelected = device.id == snapshot.selectedDeviceID || snapshot.selectedDeviceID == nil
                    HStack(alignment: .center, spacing: 20) {
                        LineArtPhoneIcon(strokeColor: palette.textPrimary)

                        VStack(alignment: .leading, spacing: 5) {
                            Text(device.name)
                                .font(.system(size: 19, weight: .bold))
                                .foregroundStyle(palette.textPrimary)

                            Text("序列号：\(device.id) · 物理接口：USB 有线直连 · \(device.state.label)")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(palette.textSecondary)

                            Button {
                                send(.selectDevice(device.id))
                            } label: {
                                Text(isSelected ? "已选为主要采音与网络桥接设备" : "点击设为当前目标设备 (\(device.state.label))")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(isSelected ? palette.emeraldGreen : palette.accentBlue)
                            }
                            .buttonStyle(.plain)
                        }

                        Spacer(minLength: 16)

                        rescanButton
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                    .zenCard(isActive: false, cornerRadius: 20)
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
    let snapshot: AppSnapshot
    let send: (UserAction) -> Void

    @State private var selectedFilter: LogFilter = .all
    @State private var searchQuery: String = ""

    private var palette: ZenPalette { ZenPalette(colorScheme) }

    enum LogFilter: String, CaseIterable, Identifiable {
        case all = "全部"
        case audio = "音频麦克风"
        case network = "网络共享"
        case system = "设备恢复"

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

    private func count(for filter: LogFilter) -> Int {
        snapshot.logs.filter { filter.matches($0.module) }.count
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
        VStack(alignment: .leading, spacing: 18) {
            filterToolbarCard
            logTableCard
        }
        .frame(maxWidth: 816, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 40)
        .padding(.vertical, 24)
    }

    // MARK: - Filter Toolbar Card

    private var filterToolbarCard: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(LogFilter.allCases) { filter in
                    let isSelected = selectedFilter == filter
                    Button {
                        selectedFilter = filter
                    } label: {
                        Text("\(filter.rawValue) (\(count(for: filter)))")
                            .font(.system(size: 12, weight: isSelected ? .bold : .medium).monospacedDigit())
                            .foregroundStyle(isSelected ? palette.accentBlue : palette.textSecondary)
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(isSelected ? palette.accentBlue.opacity(palette.isDark ? 0.22 : 0.12) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textTertiary)

                TextField("过滤关键字或错误码...", text: $searchQuery)
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
                }
            }
            .padding(.horizontal, 12)
            .frame(width: 196, height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(palette.windowBackground)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(palette.border, lineWidth: 1)
            }

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
        .padding(.horizontal, 12)
        .frame(height: 52)
        .zenCard(isActive: false, cornerRadius: 14)
    }

    // MARK: - Console Table Card

    private var logTableCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("时间戳")
                    .frame(width: 96, alignment: .leading)
                Text("模块")
                    .frame(width: 100, alignment: .leading)
                Text("阶段")
                    .frame(width: 136, alignment: .leading)
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
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(palette.segmentedTrack)
                    )
                Spacer(minLength: 0)
            }
            .frame(width: 100, alignment: .leading)

            Text(entry.stage)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(palette.textPrimary)
                .frame(width: 136, alignment: .leading)
                .lineLimit(1)

            Text(entry.message)
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
