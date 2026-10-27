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
        case .microphone: "mic"
        case .phoneInternet: "arrow.left.arrow.right"
        case .macInternet: "globe"
        case .devices: "iphone"
        case .logs: "list.bullet.rectangle"
        }
    }

    var subtitle: String {
        switch self {
        case .microphone: "作为 Mac 的低延迟音频输入"
        case .phoneInternet: "USB NCM 原生共享网络至 macOS"
        case .macInternet: "通过 USB 隧道将 Mac 网络共享给手机"
        case .devices: "管理连接的 Android 设备与端到端授权"
        case .logs: "系统控制台实时输出与排障记录"
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
        case .running: Color(red: 0.063, green: 0.725, blue: 0.506)
        case .failed: Color(red: 0.882, green: 0.114, blue: 0.282)
        case .waitingUser: .orange
        case .stopped: .secondary
        case .checking, .preparing, .connecting, .stopping: Color(red: 0.0, green: 0.443, blue: 0.890)
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
        case .streaming: Color(red: 0.063, green: 0.725, blue: 0.506)
        case .failed, .interrupted: Color(red: 0.882, green: 0.114, blue: 0.282)
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
        case .available: "出口连通"
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
        case .stopped: "点击「开启供网」以建立连接。"
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
        case .available: Color(red: 0.063, green: 0.725, blue: 0.506)
        case .noInternet, .unsupported: .orange
        case .failed: Color(red: 0.882, green: 0.114, blue: 0.282)
        case .preparing, .addressed, .verifying: Color(red: 0.0, green: 0.443, blue: 0.890)
        case .stopped: .secondary
        }
    }
}

public extension DeviceState {
    var label: String {
        switch self {
        case .unauthorized: "待手机授权 USB 调试"
        case .online: "已连接"
        case .offline: "离线"
        case .reenumerating: "USB 重枚举中"
        }
    }

    var shortLabel: String {
        switch self {
        case .unauthorized: "未授权"
        case .online: "已连接"
        case .offline: "离线"
        case .reenumerating: "重识别"
        }
    }

    var tint: Color {
        switch self {
        case .online: Color(red: 0.063, green: 0.725, blue: 0.506)
        case .unauthorized: .orange
        case .offline: .secondary
        case .reenumerating: Color(red: 0.0, green: 0.443, blue: 0.890)
        }
    }
}

public extension PermissionState {
    var label: String {
        switch self {
        case .notRequested: "已就绪"
        case .waiting: "等待手机确认"
        case .allowed: "已授权"
        case .denied: "已拒绝"
        case .settingsRequired: "需在手机设置开启"
        }
    }

    var symbol: String {
        switch self {
        case .notRequested: "circle.fill"
        case .waiting: "clock.badge.exclamationmark"
        case .allowed: "checkmark.circle.fill"
        case .denied: "xmark.circle.fill"
        case .settingsRequired: "gear.badge.questionmark"
        }
    }

    var tint: Color {
        switch self {
        case .allowed, .notRequested: Color(red: 0.063, green: 0.725, blue: 0.506)
        case .denied, .settingsRequired: .orange
        case .waiting: Color(red: 0.0, green: 0.443, blue: 0.890)
        }
    }
}

public extension RecordingSource {
    var label: String {
        switch self {
        case .microphone: "内置主麦克风"
        case .unprocessed: "原始未处理"
        case .voiceRecognition: "语音识别"
        }
    }
}

// MARK: - Section 10 "静如止水，动如雷霆" Color Palette

public struct ZenPalette {
    public let colorScheme: ColorScheme

    public init(_ colorScheme: ColorScheme) {
        self.colorScheme = colorScheme
    }

    public var isDark: Bool { colorScheme == .dark }

    /// #F7F8FA (Light) / #0D1117 (Dark)
    public var windowBackground: Color {
        isDark
            ? Color(red: 0x0D / 255.0, green: 0x11 / 255.0, blue: 0x17 / 255.0)
            : Color(red: 0xF7 / 255.0, green: 0xF8 / 255.0, blue: 0xFA / 255.0)
    }

    /// #F0F2F5 (Light) / #131822 (Dark)
    public var sidebarBackground: Color {
        isDark
            ? Color(red: 0x13 / 255.0, green: 0x18 / 255.0, blue: 0x22 / 255.0)
            : Color(red: 0xF0 / 255.0, green: 0xF2 / 255.0, blue: 0xF5 / 255.0)
    }

    /// #E4E7EB (Light) / #21283B (Dark)
    public var sidebarSelectedFill: Color {
        isDark
            ? Color(red: 0x21 / 255.0, green: 0x28 / 255.0, blue: 0x3B / 255.0)
            : Color(red: 0xE4 / 255.0, green: 0xE7 / 255.0, blue: 0xEB / 255.0)
    }

    /// #FFFFFF (Light) / #181E2B (Dark)
    public var cardBackground: Color {
        isDark
            ? Color(red: 0x18 / 255.0, green: 0x1E / 255.0, blue: 0x2B / 255.0)
            : Color.white
    }

    /// #E2E8F0 (Light) / #21283B (Dark)
    public var border: Color {
        isDark
            ? Color(red: 0x21 / 255.0, green: 0x28 / 255.0, blue: 0x3B / 255.0)
            : Color(red: 0xE2 / 255.0, green: 0xE8 / 255.0, blue: 0xF0 / 255.0)
    }

    /// #E2E8F0 (Light) / subtle white line (Dark)
    public var divider: Color {
        isDark
            ? Color.white.opacity(0.08)
            : Color(red: 0xE2 / 255.0, green: 0xE8 / 255.0, blue: 0xF0 / 255.0)
    }

    /// #0071E3 (Light) / #388BFD (Dark)
    public var activeBorder: Color {
        isDark
            ? Color(red: 0x38 / 255.0, green: 0x8B / 255.0, blue: 0xFD / 255.0)
            : Color(red: 0x00 / 255.0, green: 0x71 / 255.0, blue: 0xE3 / 255.0)
    }

    /// #F4F7FC (Light) / #0B111A (Dark)
    public var recessedWell: Color {
        isDark
            ? Color(red: 0x0B / 255.0, green: 0x11 / 255.0, blue: 0x1A / 255.0)
            : Color(red: 0xF4 / 255.0, green: 0xF7 / 255.0, blue: 0xFC / 255.0)
    }

    /// #F1F3F5 (Light) / #21283B (Dark)
    public var segmentedTrack: Color {
        isDark
            ? Color(red: 0x21 / 255.0, green: 0x28 / 255.0, blue: 0x3B / 255.0)
            : Color(red: 0xF1 / 255.0, green: 0xF3 / 255.0, blue: 0xF5 / 255.0)
    }

    /// #1D1D1F (Light) / #FFFFFF (Dark)
    public var textPrimary: Color {
        isDark
            ? Color.white
            : Color(red: 0x1D / 255.0, green: 0x1D / 255.0, blue: 0x1F / 255.0)
    }

    /// #6E6E73 (Light) / #8B949E (Dark)
    public var textSecondary: Color {
        isDark
            ? Color(red: 0x8B / 255.0, green: 0x94 / 255.0, blue: 0x9E / 255.0)
            : Color(red: 0x6E / 255.0, green: 0x6E / 255.0, blue: 0x73 / 255.0)
    }

    /// #A1A1A6 (Light) / #6E7681 (Dark)
    public var textTertiary: Color {
        isDark
            ? Color(red: 0x6E / 255.0, green: 0x76 / 255.0, blue: 0x81 / 255.0)
            : Color(red: 0xA1 / 255.0, green: 0xA1 / 255.0, blue: 0xA6 / 255.0)
    }

    /// #0071E3 (Light) / #388BFD (Dark)
    public var accentBlue: Color {
        isDark
            ? Color(red: 0x38 / 255.0, green: 0x8B / 255.0, blue: 0xFD / 255.0)
            : Color(red: 0x00 / 255.0, green: 0x71 / 255.0, blue: 0xE3 / 255.0)
    }

    /// #0071E3 (Light) / #58A6FF (Dark)
    public var waveBarBlue: Color {
        isDark
            ? Color(red: 0x58 / 255.0, green: 0xA6 / 255.0, blue: 0xFF / 255.0)
            : Color(red: 0x00 / 255.0, green: 0x71 / 255.0, blue: 0xE3 / 255.0)
    }

    /// #E11D48 (Light) / #F43F5E (Dark)
    public var stopCrimson: Color {
        isDark
            ? Color(red: 0xF4 / 255.0, green: 0x3F / 255.0, blue: 0x5E / 255.0)
            : Color(red: 0xE1 / 255.0, green: 0x1D / 255.0, blue: 0x48 / 255.0)
    }

    /// #10B981 (Light) / #3FB950 (Dark)
    public var emeraldGreen: Color {
        isDark
            ? Color(red: 0x3F / 255.0, green: 0xB9 / 255.0, blue: 0x50 / 255.0)
            : Color(red: 0x10 / 255.0, green: 0xB9 / 255.0, blue: 0x81 / 255.0)
    }
}

// MARK: - Card Modifiers

private struct ZenCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let isActive: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let palette = ZenPalette(colorScheme)
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(palette.cardBackground)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        isActive ? palette.activeBorder : palette.border,
                        lineWidth: isActive ? 1.25 : 1.0
                    )
            }
    }
}

public extension View {
    func zenCard(isActive: Bool = false, cornerRadius: CGFloat = 20) -> some View {
        modifier(ZenCardModifier(isActive: isActive, cornerRadius: cornerRadius))
    }

    func heroGlassSurface(tint: Color = .accentColor, cornerRadius: CGFloat = 20) -> some View {
        modifier(ZenCardModifier(isActive: false, cornerRadius: cornerRadius))
    }

    func insetGroupSurface(cornerRadius: CGFloat = 18) -> some View {
        modifier(ZenCardModifier(isActive: false, cornerRadius: cornerRadius))
    }
}

// MARK: - Section 10 Hero Typography Header

public struct ZenWorkspaceHeroHeader: View {
    @Environment(\.colorScheme) private var colorScheme
    public let eyebrow: String
    public let title: String
    public let subtitle: String

    public init(eyebrow: String, title: String, subtitle: String) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        let palette = ZenPalette(colorScheme)
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.textSecondary)

            Text(title)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(palette.textPrimary)

            Text(subtitle)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(palette.textSecondary)
        }
    }
}

// MARK: - Line-Art Icons Matching Figma Section 10

public struct LineArtMicIcon: View {
    public var strokeColor: Color
    public var size: CGFloat = 44

    public init(strokeColor: Color, size: CGFloat = 44) {
        self.strokeColor = strokeColor
        self.size = size
    }

    public var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            let stroke = StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round)

            // Capsule head
            let capsuleRect = CGRect(x: w * 0.31, y: h * 0.08, width: w * 0.38, height: h * 0.50)
            let capsulePath = Path(roundedRect: capsuleRect, cornerRadius: w * 0.19)
            context.stroke(capsulePath, with: .color(strokeColor), style: stroke)

            // U-cradle arc
            var arcPath = Path()
            arcPath.addArc(
                center: CGPoint(x: w * 0.5, y: h * 0.42),
                radius: w * 0.32,
                startAngle: .degrees(0),
                endAngle: .degrees(180),
                clockwise: false
            )
            context.stroke(arcPath, with: .color(strokeColor), style: stroke)

            // Stem & Base
            var standPath = Path()
            standPath.move(to: CGPoint(x: w * 0.5, y: h * 0.74))
            standPath.addLine(to: CGPoint(x: w * 0.5, y: h * 0.92))
            standPath.move(to: CGPoint(x: w * 0.28, y: h * 0.92))
            standPath.addLine(to: CGPoint(x: w * 0.72, y: h * 0.92))
            context.stroke(standPath, with: .color(strokeColor), style: stroke)
        }
        .frame(width: size, height: size)
    }
}

public struct LineArtPhoneIcon: View {
    public var strokeColor: Color

    public init(strokeColor: Color) {
        self.strokeColor = strokeColor
    }

    public var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(strokeColor, lineWidth: 1.8)
                .frame(width: 30, height: 50)

            Capsule()
                .fill(strokeColor)
                .frame(width: 8, height: 2)
                .padding(.top, 6)
        }
    }
}

// MARK: - Primary Capsule Action Button (Start Blue / Stop Crimson)

public struct ZenCapsuleActionButton: View {
    @Environment(\.colorScheme) private var colorScheme
    public let title: String
    public let isStop: Bool
    public var width: CGFloat = 144
    public var height: CGFloat = 48
    public var isDisabled: Bool = false
    public let action: () -> Void

    public init(
        title: String,
        isStop: Bool,
        width: CGFloat = 144,
        height: CGFloat = 48,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.isStop = isStop
        self.width = width
        self.height = height
        self.isDisabled = isDisabled
        self.action = action
    }

    public var body: some View {
        let palette = ZenPalette(colorScheme)
        let bgColor = isStop ? palette.stopCrimson : Color(red: 0x00 / 255.0, green: 0x71 / 255.0, blue: 0xE3 / 255.0)

        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)

                if isStop {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color.white)
                        .frame(width: 9, height: 9)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.white.opacity(0.24))
                            .frame(width: 16, height: 16)
                        Image(systemName: "play.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .frame(width: width, height: height)
            .background(bgColor.opacity(isDisabled ? 0.5 : 1.0), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

// MARK: - Recessed Waveform Well with Floating dB Pill ("动如雷霆")

public struct ZenWaveformWell: View {
    @Environment(\.colorScheme) private var colorScheme
    public let samples: [Double]
    public let level: Double
    public var barCount: Int = 48
    public var showDbPill: Bool = true

    public init(
        samples: [Double],
        level: Double,
        barCount: Int = 48,
        showDbPill: Bool = true
    ) {
        self.samples = samples
        self.level = level
        self.barCount = barCount
        self.showDbPill = showDbPill
    }

    private var dbText: String {
        let clamped = level.isFinite ? max(min(level, 1.0), 0.001) : 0.12
        let db = max(-48.0, min(0.0, 20.0 * log10(clamped)))
        return String(format: "%.1f dB", db)
    }

    public var body: some View {
        let palette = ZenPalette(colorScheme)
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.recessedWell)
                .overlay {
                    if palette.isDark {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(palette.border, lineWidth: 1)
                    }
                }

            GeometryReader { geo in
                let bars = Self.normalizedBars(from: samples, level: level, targetCount: barCount)
                let barWidth: CGFloat = 4.5
                let totalBarsWidth = CGFloat(barCount) * barWidth
                let spacing = max(3, (geo.size.width - 36 - totalBarsWidth) / CGFloat(max(barCount - 1, 1)))
                let maxBarHeight = max(12, geo.size.height - 14)

                HStack(alignment: .center, spacing: spacing) {
                    ForEach(Array(bars.enumerated()), id: \.offset) { idx, amp in
                        let barHeight = max(6, CGFloat(amp) * maxBarHeight)
                        Capsule()
                            .fill(palette.waveBarBlue.opacity(idx.isMultiple(of: 3) ? 0.78 : 1.0))
                            .frame(width: barWidth, height: barHeight)
                    }
                }
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if showDbPill {
                HStack(spacing: 5) {
                    Circle()
                        .fill(palette.emeraldGreen)
                        .frame(width: 6, height: 6)
                    Text(dbText)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(palette.textPrimary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(palette.isDark ? Color(red: 0x16 / 255.0, green: 0x1B / 255.0, blue: 0x22 / 255.0) : Color.white)
                )
                .overlay {
                    Capsule()
                        .strokeBorder(
                            palette.isDark ? Color(red: 0x30 / 255.0, green: 0x36 / 255.0, blue: 0x3D / 255.0) : palette.activeBorder.opacity(0.45),
                            lineWidth: 0.9
                        )
                }
                .padding(.top, 10)
                .padding(.trailing, 14)
            }
        }
        .frame(height: 76)
        .accessibilityLabel("来自当前快照的音频波形 \(dbText)")
    }

    public static func normalizedBars(from input: [Double], level: Double, targetCount: Int) -> [Double] {
        let pattern: [Double] = [
            0.12, 0.22, 0.35, 0.56, 0.81, 0.96, 0.72, 0.50,
            0.28, 0.44, 0.75, 0.91, 0.95, 0.68, 0.40, 0.25,
            0.46, 0.74, 0.92, 0.84, 0.58, 0.34, 0.22, 0.40,
            0.68, 0.86, 0.96, 0.76, 0.52, 0.30, 0.18, 0.38,
            0.65, 0.84, 0.90, 0.62, 0.40, 0.25, 0.44, 0.72,
            0.90, 0.74, 0.50, 0.28, 0.18, 0.32, 0.50, 0.25
        ]
        let nonZeroInput = input.filter { $0.isFinite && abs($0) > 0.01 }
        guard !nonZeroInput.isEmpty else {
            let scale = level.isFinite && level > 0.02 ? min(max(level * 1.25, 0.45), 1.0) : 0.88
            return (0..<targetCount).map { i in
                min(1.0, max(0.10, pattern[i % pattern.count] * scale))
            }
        }
        return (0..<targetCount).map { i in
            let pos = Double(i) * Double(max(input.count - 1, 0)) / Double(max(targetCount - 1, 1))
            let low = Int(pos.rounded(.down))
            let high = min(input.count - 1, low + 1)
            let frac = pos - Double(low)
            let raw = abs(input[low] * (1 - frac) + input[high] * frac)
            letFloor: do {
                let shaped = min(1.0, max(0.12, raw * 1.35))
                return max(shaped, pattern[i % pattern.count] * 0.45)
            }
        }
    }
}

// MARK: - App Icon & Legacy Helpers

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
                    .fill(Color(red: 0x00 / 255.0, green: 0x71 / 255.0, blue: 0xE3 / 255.0))
                Image(systemName: "mic.fill")
                    .font(.system(size: size * 0.5, weight: .semibold))
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
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(tint)
    }
}

public struct StudioLevelMeter: View {
    public let level: Double
    public let isStreaming: Bool
    public let isMuted: Bool

    public init(level: Double, isStreaming: Bool, isMuted: Bool = false) {
        self.level = level.isFinite ? min(max(level, 0), 1) : 0
        self.isStreaming = isStreaming
        self.isMuted = isMuted
    }

    public var body: some View {
        ZenWaveformWell(samples: [], level: level, barCount: 24, showDbPill: false)
    }
}
