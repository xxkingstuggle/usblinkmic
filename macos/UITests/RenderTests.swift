import XCTest
import SwiftUI
import AppKit
import Contracts
@testable import UI

final class RenderTests: XCTestCase {
    @MainActor func testStoppedViewsRenderAtNarrowAndWideSizes() throws {
        _ = NSApplication.shared
        let root = renderDirectory()

        for (width, height, appearance) in [
            (720, 520, NSAppearance.Name.aqua),
            (1280, 800, NSAppearance.Name.darkAqua)
        ] {
            var snapshot = AppSnapshot()
            snapshot.wizardSkipped = true
            snapshot.soundTestCompleted = true
            let view = NSHostingView(rootView: RootView(snapshot: snapshot, send: { _ in }))
            view.appearance = NSAppearance(named: appearance)
            view.frame = NSRect(x: 0, y: 0, width: width, height: height)
            view.layoutSubtreeIfNeeded()
            try write(view, to: root.appendingPathComponent("stopped-\(width)-\(appearance.rawValue).png"))
        }
    }

    @MainActor func testActiveStreamingAndMenuBarConsoleRender() throws {
        _ = NSApplication.shared
        let root = renderDirectory()

        let snapshot = activeSnapshot()

        let mainView = NSHostingView(rootView: RootView(snapshot: snapshot, send: { _ in }))
        mainView.appearance = NSAppearance(named: .darkAqua)
        mainView.frame = NSRect(x: 0, y: 0, width: 1120, height: 720)
        mainView.layoutSubtreeIfNeeded()
        try write(mainView, to: root.appendingPathComponent("streaming-1120-dark.png"))

        let menuView = NSHostingView(rootView: MenuBarConsoleView(snapshot: snapshot, send: { _ in }))
        menuView.appearance = NSAppearance(named: .darkAqua)
        menuView.frame = NSRect(x: 0, y: 0, width: 340, height: 340)
        menuView.layoutSubtreeIfNeeded()
        try write(menuView, to: root.appendingPathComponent("menubar-336-dark.png"))
    }

    /// Renders every workspace in light and dark so layout regressions are visible,
    /// not just the microphone screen.
    @MainActor func testEveryWorkspaceRendersInLightAndDark() throws {
        _ = NSApplication.shared
        let root = renderDirectory()
        let snapshot = activeSnapshot()

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for section in SidebarSection.allCases {
                let view = NSHostingView(
                    rootView: RootView(snapshot: snapshot, initialSection: section, send: { _ in })
                )
                view.appearance = NSAppearance(named: appearance)
                view.frame = NSRect(x: 0, y: 0, width: 1120, height: 720)
                view.layoutSubtreeIfNeeded()
                let suffix = appearance == .aqua ? "light" : "dark"
                try write(view, to: root.appendingPathComponent("workspace-\(section.rawValue)-\(suffix).png"))
            }
        }
    }

    /// The merged network page leads with whichever direction is actually
    /// running, so both orderings need their own render.
    @MainActor func testNetworkPageLeadsWithRunningDirection() throws {
        _ = NSApplication.shared
        let root = renderDirectory()

        var phoneRunning = activeSnapshot()
        phoneRunning.phoneInternet = ModuleStatus(phase: .running, stage: "USB共享已连接", detail: "")
        var macRunning = activeSnapshot()
        macRunning.macInternet = ModuleStatus(phase: .running, stage: "已连接", detail: "")

        for (name, snapshot) in [("phone-leads", phoneRunning), ("mac-leads", macRunning)] {
            let view = NSHostingView(
                rootView: RootView(snapshot: snapshot, initialSection: .network, send: { _ in })
            )
            view.appearance = NSAppearance(named: .aqua)
            view.frame = NSRect(x: 0, y: 0, width: 1120, height: 720)
            view.layoutSubtreeIfNeeded()
            try write(view, to: root.appendingPathComponent("network-\(name).png"))
        }
    }

    /// Renders in-page settings and onboarding wizard for visual verification.
    /// Outputs the 3 required artifacts: mic-usb-default, mic-wifi-expanded, network-options.
    @MainActor func testSettingsSheetAndWizardRender() throws {
        _ = NSApplication.shared
        let root = renderDirectory()
        let artifactsRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("artifacts")

        var usbSnapshot = AppSnapshot()
        usbSnapshot.wizardSkipped = true
        usbSnapshot.soundTestCompleted = true
        usbSnapshot.devices = [Device(id: "8A2X1094F", name: "Pixel 9 Pro", state: .online)]
        usbSnapshot.selectedDeviceID = "8A2X1094F"
        usbSnapshot.settings.transport = .usb

        let usbView = NSHostingView(
            rootView: RootView(snapshot: usbSnapshot, initialSection: .microphone, send: { _ in })
        )
        usbView.appearance = NSAppearance(named: .darkAqua)
        usbView.frame = NSRect(x: 0, y: 0, width: 1120, height: 720)
        usbView.layoutSubtreeIfNeeded()
        try write(usbView, to: root.appendingPathComponent("mic-usb-default.png"))
        let usbArtifact = artifactsRoot.appendingPathComponent("mic-usb-default.png")
        try? FileManager.default.removeItem(at: usbArtifact)
        try? FileManager.default.copyItem(at: root.appendingPathComponent("mic-usb-default.png"), to: usbArtifact)

        var wifiSnapshot = usbSnapshot
        wifiSnapshot.settings.transport = .wifi
        wifiSnapshot.settings.wifiHost = "192.168.1.108"
        wifiSnapshot.lanCandidates = ["192.168.1.108"]
        let wifiView = NSHostingView(
            rootView: RootView(snapshot: wifiSnapshot, initialSection: .microphone, initialShowAdvancedOptions: true, send: { _ in })
        )
        wifiView.appearance = NSAppearance(named: .darkAqua)
        wifiView.frame = NSRect(x: 0, y: 0, width: 1120, height: 720)
        wifiView.layoutSubtreeIfNeeded()
        try write(wifiView, to: root.appendingPathComponent("mic-wifi-expanded.png"))
        let wifiArtifact = artifactsRoot.appendingPathComponent("mic-wifi-expanded.png")
        try? FileManager.default.removeItem(at: wifiArtifact)
        try? FileManager.default.copyItem(at: root.appendingPathComponent("mic-wifi-expanded.png"), to: wifiArtifact)

        let netSnapshot = usbSnapshot
        let netView = NSHostingView(
            rootView: RootView(snapshot: netSnapshot, initialSection: .network, initialShowAdvancedOptions: true, send: { _ in })
        )
        netView.appearance = NSAppearance(named: .darkAqua)
        netView.frame = NSRect(x: 0, y: 0, width: 1120, height: 720)
        netView.layoutSubtreeIfNeeded()
        try write(netView, to: root.appendingPathComponent("network-options.png"))
        let netArtifact = artifactsRoot.appendingPathComponent("network-options.png")
        try? FileManager.default.removeItem(at: netArtifact)
        try? FileManager.default.copyItem(at: root.appendingPathComponent("network-options.png"), to: netArtifact)

        let wizard = NSHostingView(
            rootView: SetupWizard(snapshot: usbSnapshot, step: .constant(0), send: { _ in })
        )
        wizard.appearance = NSAppearance(named: .darkAqua)
        wizard.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
        wizard.layoutSubtreeIfNeeded()
        try write(wizard, to: root.appendingPathComponent("sheet-wizard-dark.png"))
    }

    func testSettingsSheetSessionStateIdempotentOpenAndScopedSaveCompletion() {
        let baseline = Contracts.Settings()
        var sessionA = SettingsSheetSessionState(draft: baseline)
        var sessionB = SettingsSheetSessionState(draft: baseline)

        // Open both sessions
        sessionA.open(baseline: baseline)
        sessionB.open(baseline: baseline)
        XCTAssertTrue(sessionA.isPresented)
        XCTAssertTrue(sessionB.isPresented)

        // Make dirty edits in both sessions
        var draftA = baseline
        draftA.dns = "8.8.8.8"
        sessionA.updateDraft(draftA, baseline: baseline)
        XCTAssertTrue(sessionA.isDirty)

        var draftB = baseline
        draftB.wifiHost = "192.168.1.99"
        sessionB.updateDraft(draftB, baseline: baseline)
        XCTAssertTrue(sessionB.isDirty)

        // Repeated open (e.g. Cmd+, notification) must be idempotent and preserve dirty draft
        sessionB.open(baseline: baseline)
        XCTAssertTrue(sessionB.isPresented)
        XCTAssertTrue(sessionB.isDirty)
        XCTAssertEqual(sessionB.draft.wifiHost, "192.168.1.99")

        // Session A initiates save; Session B does not
        sessionA.beginSave()
        XCTAssertTrue(sessionA.awaitingSaveCompletion)
        XCTAssertFalse(sessionB.awaitingSaveCompletion)

        // When save completes, only Session A closes and resets; Session B preserves its dirty draft and stays open
        sessionA.handleSavedRevisionChanged(newSettings: draftA)
        sessionB.handleSavedRevisionChanged(newSettings: draftA)

        XCTAssertFalse(sessionA.isPresented)
        XCTAssertFalse(sessionA.isDirty)
        XCTAssertEqual(sessionA.draft.dns, "8.8.8.8")

        XCTAssertTrue(sessionB.isPresented, "Other dirty settings draft must not be closed by global save revision")
        XCTAssertTrue(sessionB.isDirty, "Other dirty settings draft must remain dirty")
        XCTAssertEqual(sessionB.draft.wifiHost, "192.168.1.99")
    }

    // MARK: - Helpers

    private func renderDirectory() -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("artifacts/ui-renders")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func activeSnapshot() -> AppSnapshot {
        var snapshot = AppSnapshot()
        snapshot.wizardSkipped = true
        snapshot.soundTestCompleted = true
        snapshot.devices = [Device(id: "8A2X1094F", name: "Pixel 9 Pro", state: .online)]
        snapshot.selectedDeviceID = "8A2X1094F"
        snapshot.microphone = ModuleStatus(phase: .running, stage: "有效音频传输", detail: "正在通过 USB 通道接收手机实时 PCM 音频流")
        snapshot.audioState = .streaming
        snapshot.level = 0.64
        snapshot.waveform = [
            0.12, 0.25, 0.42, 0.68, 0.54, 0.31, 0.76, 0.88, 0.62, 0.40, 0.28, 0.51,
            0.73, 0.64, 0.39, 0.22, 0.48, 0.81, 0.69, 0.44, 0.30, 0.55, 0.72, 0.49
        ]
        snapshot.receivedFrames = 1842
        snapshot.settings.gain = 1.25
        return snapshot
    }

    @MainActor
    private func write(_ view: NSHostingView<some View>, to url: URL) throws {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1000)
        try png.write(to: url)
    }
}

private extension ModuleStatus {
    init(phase: TaskPhase, stage: String, detail: String) {
        self.init()
        self.phase = phase
        self.stage = stage
        self.detail = detail
    }
}
