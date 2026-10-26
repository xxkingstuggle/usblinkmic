import XCTest
import SwiftUI
import AppKit
import Contracts
import UI

final class RenderTests: XCTestCase {
    @MainActor func testStoppedViewsRenderAtNarrowAndWideSizes() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("artifacts/ui-renders")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        for (width, height, appearance) in [
            (720, 520, NSAppearance.Name.aqua),
            (1280, 800, NSAppearance.Name.darkAqua)
        ] {
            var snapshot = AppSnapshot()
            snapshot.wizardSkipped = true
            let view = NSHostingView(rootView: RootView(snapshot: snapshot, send: { _ in }))
            view.appearance = NSAppearance(named: appearance)
            view.frame = NSRect(x: 0, y: 0, width: width, height: height)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 1000)
            try png.write(to: root.appendingPathComponent("stopped-\(width)-\(appearance.rawValue).png"))
        }
    }

    @MainActor func testActiveStreamingAndMenuBarConsoleRender() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("artifacts/ui-renders")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var snapshot = AppSnapshot()
        snapshot.wizardSkipped = true
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

        let mainView = NSHostingView(rootView: RootView(snapshot: snapshot, send: { _ in }))
        mainView.appearance = NSAppearance(named: .darkAqua)
        mainView.frame = NSRect(x: 0, y: 0, width: 1120, height: 720)
        mainView.layoutSubtreeIfNeeded()
        let mainBitmap = try XCTUnwrap(mainView.bitmapImageRepForCachingDisplay(in: mainView.bounds))
        mainView.cacheDisplay(in: mainView.bounds, to: mainBitmap)
        let mainPNG = try XCTUnwrap(mainBitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(mainPNG.count, 1000)
        try mainPNG.write(to: root.appendingPathComponent("streaming-1120-dark.png"))

        let menuView = NSHostingView(rootView: MenuBarConsoleView(snapshot: snapshot, send: { _ in }))
        menuView.appearance = NSAppearance(named: .darkAqua)
        menuView.frame = NSRect(x: 0, y: 0, width: 336, height: 310)
        menuView.layoutSubtreeIfNeeded()
        let menuBitmap = try XCTUnwrap(menuView.bitmapImageRepForCachingDisplay(in: menuView.bounds))
        menuView.cacheDisplay(in: menuView.bounds, to: menuBitmap)
        let menuPNG = try XCTUnwrap(menuBitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(menuPNG.count, 1000)
        try menuPNG.write(to: root.appendingPathComponent("menubar-336-dark.png"))
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
