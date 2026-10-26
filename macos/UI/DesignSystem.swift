import SwiftUI
import AppKit
import Contracts

// MARK: - Workspace & State Presentation

public extension Workspace {
    var title: String {
        switch self {
        case .microphone: "手机麦克风"
        case .phoneInternet: "手机网络给 Mac"
        case .macInternet: "Mac 网络给手机"
        case .devices: "设备与权限"
        case .logs: "诊断日志"
        }
    }

    var shortTitle: String {
        switch self {
        case .microphone: "手机麦克风"
        case .phoneInternet: "手机供网"
        case .macInternet: "反向供网"
        case .devices: "设备"
        case .logs: "日志"
        }
    }

    var symbol: String {
        switch self {
        case .microphone: "mic.fill"
        case .phoneInternet: "personalhotspot"
        case .macInternet: "network"
        case .devices: "iphone.gen3"
        case .logs: "text.and.command.macwindow"
        }
    }

    var subtitle: String {
        switch self {
        case .microphone: "通过 USB 或 Wi-Fi 接收手机实时拾音，支持本机试听或虚拟声卡输入"
        case .phoneInternet: "通过 USB NCM 硬件共享通道，将手机蜂窝或无线网络提供给 Mac"
        case .macInternet: "通过 ADB 与 VPN 转发通道，将 Mac 当前可用网络共享给手机"
        case .devices: "管理已连接的 Android 手机、USB 调试信任与手机端系统权限"
        case .logs: "按模块筛选、搜索或导出脱敏后的连接阶段与诊断日志"
        }
    }
}

public func isTaskBusy(_ phase: TaskPhase) -> Bool {
    switch phase {
    case .checking, .preparing, .waitingUser, .connecting, .stopping:
        return true
    case .stopped, .running, .failed:
        return false
    }
}

public extension TaskPhase {
    var label: String {
        switch self {
        case .stopped: "已停止"
        case .checking: "检查中"
        case .preparing: "准备中"
        case .waitingUser: "等待确认"
        case .connecting: "连接中"
        case .running: "运行中"
        case .stopping: "停止中"
        case .failed: "异常"
        }
    }

    var symbol: String {
        switch self {
        case .stopped: "circle.fill"
        case .checking, .preparing, .connecting, .stopping: "arrow.trianglehead.2.clockwise.rotate.90"
        case .waitingUser: "hand.raised.fill"
        case .running: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
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

public extension AudioState {
    var label: String {
        switch self {
        case .disconnected: "未连接"
        case .handshake: "握手中"
        case .waitingFrame: "等待首包"
        case .streaming: "实时传输中"
        case .interrupted: "输入中断"
        case .failed: "传输故障"
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

public extension NetworkState {
    var label: String {
        switch self {
        case .stopped: "未启用"
        case .preparing: "链路准备中"
        case .addressed: "已分配地址"
        case .verifying: "连通性校验"
        case .available: "网络已就绪"
        case .noInternet: "无外网连接"
        case .unsupported: "设备受限或不支持"
        case .failed: "链路故障"
        }
    }

    var explanation: String {
        switch self {
        case .available: "USB 共享接口或 VPN 转发通道已完成地址分配与连通性确认。"
        case .noInternet: "通道已建立，但上游出口不可达，请检查源网络或转发配置。"
        case .unsupported: "当前手机 ROM 或系统策略不支持此 USB 共享能力。"
        case .preparing, .addressed, .verifying: "正在协商 USB 接口、等待授权或验证路由，请稍候。"
        case .failed: "请查看任务阶段详情与诊断日志定位失败原因。"
        case .stopped: "点击右上角「开始共享」以建立连接。"
        }
    }

    var symbol: String {
        switch self {
        case .available: "checkmark.seal.fill"
        case .noInternet, .unsupported, .failed: "exclamationmark.triangle.fill"
        case .preparing, .addressed, .verifying: "arrow.trianglehead.2.clockwise"
        case .stopped: "network.slash"
        }
    }

    var tint: Color {
        switch self {
        case .available: .green
        case .noInternet, .unsupported: .orange
        case .failed: .red
        case .preparing, .addressed, .verifying: .blue
        case .stopped: .secondary
        }
    }
}

public extension DeviceState {
    var label: String {
        switch self {
        case .unauthorized: "待手机授权 USB 调试"
        case .online: "在线"
        case .offline: "离线"
        case .reenumerating: "USB 重枚举中"
        }
    }

    var shortLabel: String {
        switch self {
        case .unauthorized: "未授权"
        case .online: "在线"
        case .offline: "离线"
        case .reenumerating: "重识别"
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

public extension PermissionState {
    var label: String {
        switch self {
        case .notRequested: "尚未请求"
        case .waiting: "等待手机确认"
        case .allowed: "已允许"
        case .denied: "已拒绝"
        case .settingsRequired: "需在手机系统设置开启"
        }
    }

    var symbol: String {
        switch self {
        case .notRequested: "circle.dashed"
        case .waiting: "clock.badge.exclamationmark"
        case .allowed: "checkmark.circle.fill"
        case .denied: "xmark.circle.fill"
        case .settingsRequired: "gear.badge.questionmark"
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

public extension RecordingSource {
    var label: String {
        switch self {
        case .microphone: "主麦克风"
        case .unprocessed: "原始未处理"
        case .voiceRecognition: "语音识别"
        }
    }
}

// MARK: - Native macOS 27 Materials & Surfaces

public struct VisualEffectSurface: NSViewRepresentable {
    public let material: NSVisualEffectView.Material
    public let blendingMode: NSVisualEffectView.BlendingMode
    public let isEmphasized: Bool

    public init(
        material: NSVisualEffectView.Material,
        blendingMode: NSVisualEffectView.BlendingMode = .withinWindow,
        isEmphasized: Bool = false
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.isEmphasized = isEmphasized
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = isEmphasized
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.isEmphasized = isEmphasized
    }
}

public extension View {
    /// macOS 27 Liquid Glass Hero Card surface with subtle specular rim and tint wash.
    func heroGlassSurface(tint: Color = .accentColor, cornerRadius: CGFloat = 14) -> some View {
        self
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.regularMaterial)
                    LinearGradient(
                        colors: [
                            tint.opacity(0.11),
                            tint.opacity(0.02),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.primary.opacity(0.15),
                                Color.primary.opacity(0.06)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            }
    }

    /// Secondary grouped inset container matching macOS System Settings group boxes.
    func insetGroupSurface(cornerRadius: CGFloat = 12) -> some View {
        self
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 0.8)
            }
    }
}

// MARK: - Native System Settings Grouped Section & Row

public struct NativeGroupedSection<Content: View>: View {
    public let title: String?
    public let footer: String?
    @ViewBuilder public let content: Content

    public init(
        _ title: String? = nil,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .insetGroupSurface(cornerRadius: 12)

            if let footer, !footer.isEmpty {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

public struct NativeSettingRow<Trailing: View>: View {
    public let title: String
    public let subtitle: String?
    public let symbol: String?
    public let symbolTint: Color
    public let showDivider: Bool
    @ViewBuilder public let trailing: Trailing

    public init(
        title: String,
        subtitle: String? = nil,
        symbol: String? = nil,
        symbolTint: Color = .accentColor,
        showDivider: Bool = true,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.symbolTint = symbolTint
        self.showDivider = showDivider
        self.trailing = trailing()
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                if let symbol {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(symbolTint.opacity(0.14))
                            .frame(width: 28, height: 28)
                        Image(systemName: symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(symbolTint)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 16)

                trailing
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)

            if showDivider {
                Divider()
                    .padding(.leading, symbol != nil ? 56 : 16)
                    .opacity(0.55)
            }
        }
    }
}

// MARK: - App Icon Loader (Prevents Generic Folder Icon in CLI/Tests)

public struct AppBrandIcon: View {
    public var size: CGFloat = 28

    public init(size: CGFloat = 28) {
        self.size = size
    }

    public var body: some View {
        if let image = Self.resolvedIcon() {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.blue, Color.cyan.opacity(0.85)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
        }
    }

    private static func resolvedIcon() -> NSImage? {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        }
        if let icnsURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: icnsURL) {
            return image
        }
        let repoIconURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("macos/Resources/AppIcon.iconset/icon_128x128.png")
        if let image = NSImage(contentsOf: repoIconURL) {
            return image
        }
        return nil
    }
}

// MARK: - Reusable Native Badges & Meters

public struct StatusPill: View {
    public let label: String
    public let symbol: String?
    public let tint: Color

    public init(label: String, symbol: String? = nil, tint: Color) {
        self.label = label
        self.symbol = symbol
        self.tint = tint
    }

    public var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption2.weight(.bold))
            } else {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
            }
            Text(label)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(tint.opacity(0.14), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(tint.opacity(0.26), lineWidth: 0.75)
        }
        .foregroundStyle(tint)
    }
}

public struct ParameterTag: View {
    public let text: String
    public var symbol: String? = nil

    public init(_ text: String, symbol: String? = nil) {
        self.text = text
        self.symbol = symbol
    }

    public var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(text)
                .font(.caption.monospacedDigit().weight(.medium))
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .foregroundStyle(.primary.opacity(0.88))
    }
}

/// Studio-style segmented tri-zone level meter (Green -> Yellow -> Peak Red)
public struct StudioLevelMeter: View {
    public let level: Double
    public let isStreaming: Bool
    public let isMuted: Bool

    public init(level: Double, isStreaming: Bool, isMuted: Bool = false) {
        self.level = level.isFinite ? min(max(level, 0), 1) : 0
        self.isStreaming = isStreaming
        self.isMuted = isMuted
    }

    private let segmentCount = 28

    public var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 2.5
            let totalSpacing = spacing * CGFloat(segmentCount - 1)
            let barWidth = max(2, (geometry.size.width - totalSpacing) / CGFloat(segmentCount))
            let activeSegments = Int((level * Double(segmentCount)).rounded(.up))

            HStack(spacing: spacing) {
                ForEach(0..<segmentCount, id: \.self) { index in
                    let isLit = isStreaming && index < activeSegments && level > 0.001
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(segmentColor(for: index, isLit: isLit))
                        .frame(width: barWidth, height: geometry.size.height)
                }
            }
        }
        .frame(height: 10)
        .accessibilityLabel("实时输入电平 \(Int(level * 100))%")
    }

    private func segmentColor(for index: Int, isLit: Bool) -> Color {
        let fraction = Double(index) / Double(segmentCount)
        let baseColor: Color = if isMuted {
            .orange
        } else if fraction < 0.68 {
            .green
        } else if fraction < 0.88 {
            .yellow
        } else {
            .red
        }
        return isLit ? baseColor : Color.primary.opacity(0.11)
    }
}

public struct WaveformView: View {
    public let samples: [Double]
    public var tint: Color = .accentColor

    public init(samples: [Double], tint: Color = .accentColor) {
        self.samples = samples
        self.tint = tint
    }

    public var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 3.5
            let targetBars = max(36, Int((geometry.size.width + spacing) / (4.5 + spacing)))
            let resampled = Self.resample(samples, targetCount: targetBars)
            let barWidth = max(3, (geometry.size.width - CGFloat(targetBars - 1) * spacing) / CGFloat(targetBars))

            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(resampled.enumerated()), id: \.offset) { _, value in
                    let clamped = value.isFinite ? min(max(abs(value), 0), 1) : 0
                    let height = max(4, CGFloat(clamped) * geometry.size.height)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.95), tint.opacity(0.55)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: barWidth, height: height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private static func resample(_ input: [Double], targetCount: Int) -> [Double] {
        guard !input.isEmpty, targetCount > 0 else {
            return Array(repeating: 0.06, count: max(targetCount, 1))
        }
        if input.count == targetCount { return input }
        return (0..<targetCount).map { i in
            let position = Double(i) * Double(max(input.count - 1, 0)) / Double(max(targetCount - 1, 1))
            let low = Int(position.rounded(.down))
            let high = min(input.count - 1, low + 1)
            let fraction = position - Double(low)
            return input[low] * (1 - fraction) + input[high] * fraction
        }
    }
}
