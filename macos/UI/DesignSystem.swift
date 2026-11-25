import SwiftUI
import AppKit
import Contracts

// MARK: - Sidebar Sections & State Presentation

/// A sidebar destination. Network sharing is one page with both directions
/// rather than two entries, because the two directions live in the same
/// USB NCM channel and are mutually exclusive at runtime.
public enum SidebarSection: String, CaseIterable, Identifiable, Sendable {
    case microphone
    case network
    case devices
    case logs

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .microphone: "手机麦克风"
        case .network: "网络互联"
        case .devices: "设备与权限"
        case .logs: "诊断日志"
        }
    }

    public var symbol: String {
        switch self {
        case .microphone: "mic"
        case .network: "arrow.left.arrow.right"
        case .devices: "iphone"
        case .logs: "list.bullet.rectangle"
        }
    }

    public var shortcutKey: KeyEquivalent {
        switch self {
        case .microphone: "1"
        case .network: "2"
        case .devices: "3"
        case .logs: "4"
        }
    }

    public var shortcutHint: String {
        switch self {
        case .microphone: "⌘1"
        case .network: "⌘2"
        case .devices: "⌘3"
        case .logs: "⌘4"
        }
    }

    /// Workspace still names the runtime tasks that start/stop, not the pages.
    /// Mapping keeps the two in sync without a second source of truth.
    public init(workspace: Workspace) {
        switch workspace {
        case .microphone: self = .microphone
        case .phoneInternet, .macInternet: self = .network
        case .devices: self = .devices
        case .logs: self = .logs
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

// MARK: - Colors

public struct ZenPalette {
    public let colorScheme: ColorScheme

    public init(_ colorScheme: ColorScheme) {
        self.colorScheme = colorScheme
    }

    public var isDark: Bool { colorScheme == .dark }

    public var windowBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    public var cardBackground: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    public var border: Color {
        .primary.opacity(0.10)
    }

    public var divider: Color {
        Color(nsColor: .separatorColor)
    }

    public var activeBorder: Color {
        accentBlue.opacity(0.55)
    }

    public var recessedWell: Color {
        .black.opacity(isDark ? 0.22 : 0.05)
    }

    public var segmentedTrack: Color {
        .primary.opacity(0.08)
    }

    public var textPrimary: Color {
        .primary
    }

    public var textSecondary: Color {
        .secondary
    }

    public var textTertiary: Color {
        .secondary
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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let isActive: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let palette = ZenPalette(colorScheme)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                if reduceTransparency {
                    shape.fill(palette.cardBackground)
                } else {
                    shape.fill(.regularMaterial)
                }
            }
            .overlay {
                shape.strokeBorder(
                    isActive ? palette.activeBorder : (reduceTransparency ? palette.divider : palette.border),
                    lineWidth: 1
                )
                    .allowsHitTesting(false)
            }
    }
}

public extension View {
    func zenCard(isActive: Bool = false, cornerRadius: CGFloat = 20) -> some View {
        modifier(ZenCardModifier(isActive: isActive, cornerRadius: cornerRadius))
    }

    func insetGroupSurface(cornerRadius: CGFloat = 18) -> some View {
        modifier(ZenCardModifier(isActive: false, cornerRadius: cornerRadius))
    }
}

extension View {
    func workspaceMargins() -> some View {
        frame(maxWidth: 820, alignment: .topLeading)
            .padding(.horizontal, 30)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .top)
    }
}

struct WorkspaceHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 30, weight: .semibold))
                .accessibilityAddTraits(.isHeader)

            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
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

// MARK: - Start and stop controls

struct SessionActionButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let isStop: Bool
    var controlSize: ControlSize = .large
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: isStop ? "stop.fill" : "play.fill")
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .controlSize(controlSize)
        .tint(isStop ? ZenPalette(colorScheme).stopCrimson : .accentColor)
        .fixedSize()
        .disabled(isDisabled)
    }
}

// MARK: - Waveform display

public struct ZenWaveformWell: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
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
        if samples.isEmpty && level == 0 { return "— dB" }
        let clamped = level.isFinite ? max(min(level, 1.0), 0.001) : 0.001
        let db = max(-48.0, min(0.0, 20.0 * log10(clamped)))
        return String(format: "%.1f dB", db)
    }

    public var body: some View {
        let palette = ZenPalette(colorScheme)
        let bars = Self.normalizedBars(
            from: samples,
            level: level,
            targetCount: barCount,
            reduceMotion: reduceMotion
        )
        VStack(alignment: .leading, spacing: 3) {
            if showDbPill {
                HStack {
                    Label("输入电平", systemImage: "waveform")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(dbText)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                .font(.caption)
            }

            Canvas { context, size in
                guard !bars.isEmpty else { return }
                let step = size.width / CGFloat(bars.count)
                let barWidth = min(step * 0.48, 4)
                let barHeight = size.height - 4

                for (index, amplitude) in bars.enumerated() {
                    let height = max(2, CGFloat(amplitude) * barHeight)
                    let rect = CGRect(
                        x: (CGFloat(index) + 0.5) * step - barWidth / 2,
                        y: (size.height - height) / 2,
                        width: barWidth,
                        height: height
                    )
                    let tint = height <= 2 ? Color.secondary.opacity(0.35) : palette.waveBarBlue
                    context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(tint))
                }
            }
            .frame(height: 44)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            reduceTransparency ? Color(nsColor: .underPageBackgroundColor) : palette.recessedWell,
            in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(palette.divider, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("输入电平 \(dbText)")
    }

    public static func normalizedBars(
        from input: [Double],
        level: Double,
        targetCount: Int,
        reduceMotion: Bool = false
    ) -> [Double] {
        guard targetCount > 0 else { return [] }
        let clampedLevel = level.isFinite ? min(max(level, 0), 1) : 0
        if reduceMotion {
            let average = input.isEmpty
                ? clampedLevel
                : min(1, max(clampedLevel, input.reduce(0) { $0 + ($1.isFinite ? abs($1) : 0) } / Double(input.count)))
            return Array(repeating: average, count: targetCount)
        }
        guard !input.isEmpty else {
            return Array(repeating: clampedLevel, count: targetCount)
        }
        return (0..<targetCount).map { index in
            let position = Double(index) * Double(input.count - 1) / Double(max(targetCount - 1, 1))
            let low = Int(position.rounded(.down))
            let high = min(input.count - 1, low + 1)
            let fraction = position - Double(low)
            let amplitude = abs(input[low] * (1 - fraction) + input[high] * fraction)
            return amplitude.isFinite ? min(amplitude, 1) : 0
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

public struct LiveWaveformWell: View {
    public let telemetry: AudioTelemetry?
    public let fallbackSamples: [Double]
    public let fallbackLevel: Double
    public let barCount: Int
    public let showDbPill: Bool

    public init(
        telemetry: AudioTelemetry?,
        fallbackSamples: [Double],
        fallbackLevel: Double,
        barCount: Int = 48,
        showDbPill: Bool = true
    ) {
        self.telemetry = telemetry
        self.fallbackSamples = fallbackSamples
        self.fallbackLevel = fallbackLevel
        self.barCount = barCount
        self.showDbPill = showDbPill
    }

    public var body: some View {
        if let telemetry {
            ObservedWaveformWell(
                telemetry: telemetry,
                fallbackSamples: fallbackSamples,
                fallbackLevel: fallbackLevel,
                barCount: barCount,
                showDbPill: showDbPill
            )
        } else {
            ZenWaveformWell(
                samples: fallbackSamples,
                level: fallbackLevel,
                barCount: barCount,
                showDbPill: showDbPill
            )
        }
    }
}

public struct TelemetryVisibilityObserver: NSViewRepresentable {
    public let telemetry: AudioTelemetry
    public let consumerID: UUID

    public init(telemetry: AudioTelemetry, consumerID: UUID) {
        self.telemetry = telemetry
        self.consumerID = consumerID
    }

    public func makeNSView(context: Context) -> TelemetryVisibilityProbeView {
        let view = TelemetryVisibilityProbeView()
        view.configure(telemetry: telemetry, consumerID: consumerID)
        return view
    }

    public func updateNSView(_ nsView: TelemetryVisibilityProbeView, context: Context) {
        nsView.configure(telemetry: telemetry, consumerID: consumerID)
    }

    public static func dismantleNSView(_ nsView: TelemetryVisibilityProbeView, coordinator: ()) {
        nsView.deactivate()
    }
}

@MainActor public final class TelemetryVisibilityProbeView: NSView {
    private weak var telemetry: AudioTelemetry?
    private var consumerID = UUID()
    private var windowObservers: [NSObjectProtocol] = []
    private var appHideObserver: NSObjectProtocol?
    private var appUnhideObserver: NSObjectProtocol?

    func configure(telemetry: AudioTelemetry, consumerID: UUID) {
        if self.consumerID != consumerID, let oldTelemetry = self.telemetry {
            oldTelemetry.unregisterConsumer(self.consumerID)
        }
        self.telemetry = telemetry
        self.consumerID = consumerID
        updateVisibility()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeWindowObservers()
        if let window {
            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification
            ]
            for name in names {
                let observer = NotificationCenter.default.addObserver(
                    forName: name,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.updateVisibility()
                    }
                }
                windowObservers.append(observer)
            }
        }
        if appHideObserver == nil {
            appHideObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didHideNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateVisibility()
                }
            }
        }
        if appUnhideObserver == nil {
            appUnhideObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didUnhideNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateVisibility()
                }
            }
        }
        updateVisibility()
    }

    public override func viewDidHide() {
        super.viewDidHide()
        updateVisibility()
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        updateVisibility()
    }

    public func updateVisibility() {
        guard let telemetry else { return }
        guard let window else {
            telemetry.reportConsumerVisibility(
                consumerID,
                state: TelemetryVisibilityState(hasWindow: false)
            )
            return
        }
        let state = TelemetryVisibilityState(
            hasWindow: true,
            isViewHidden: isHiddenOrHasHiddenAncestor,
            isWindowVisible: window.isVisible && !window.isMiniaturized,
            isWindowUnoccluded: window.occlusionState.contains(.visible),
            isAppHidden: NSApplication.shared.isHidden
        )
        telemetry.reportConsumerVisibility(consumerID, state: state)
    }

    public func deactivate() {
        removeWindowObservers()
        if let appHideObserver {
            NotificationCenter.default.removeObserver(appHideObserver)
            self.appHideObserver = nil
        }
        if let appUnhideObserver {
            NotificationCenter.default.removeObserver(appUnhideObserver)
            self.appUnhideObserver = nil
        }
        telemetry?.unregisterConsumer(consumerID)
    }

    private func removeWindowObservers() {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers.removeAll()
    }
}

private struct ObservedWaveformWell: View {
    @ObservedObject var telemetry: AudioTelemetry
    @State private var consumerID = UUID()
    let fallbackSamples: [Double]
    let fallbackLevel: Double
    let barCount: Int
    let showDbPill: Bool

    var body: some View {
        let samples = telemetry.waveform.isEmpty ? fallbackSamples : telemetry.waveform
        let level = telemetry.receivedFrames > 0 ? telemetry.level : fallbackLevel
        ZenWaveformWell(
            samples: samples,
            level: level,
            barCount: barCount,
            showDbPill: showDbPill
        )
        .background(TelemetryVisibilityObserver(telemetry: telemetry, consumerID: consumerID))
        .onAppear {
            telemetry.registerConsumer(consumerID)
        }
        .onDisappear {
            telemetry.unregisterConsumer(consumerID)
        }
    }
}
