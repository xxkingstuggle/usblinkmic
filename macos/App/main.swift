import SwiftUI
import AppKit
import Core
import UI

@main struct USBLinkMicApp: App {
    @StateObject private var controller = SessionController(wifiAutoConnect: true)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("USB LinkMic", id: "main") {
            RootView(
                snapshot: controller.snapshot,
                telemetry: controller.telemetry,
                send: { controller.send($0, source: .ui) }
            )
            .frame(minWidth: 800, minHeight: 560)
            .onAppear {
                delegate.controller = controller
                controller.boot()
            }
        }
        .defaultSize(width: 1000, height: 690)
        .commands {
            CommandMenu("连接") {
                Button("刷新") { controller.send(.refresh, source: .ui) }.keyboardShortcut("r")
                Button("全部停止") { controller.send(.stopAll, source: .ui) }.keyboardShortcut(".")
            }
        }

        MenuBarExtra {
            MenuBarConsoleView(
                snapshot: controller.snapshot,
                telemetry: controller.telemetry,
                send: { controller.send($0, source: .menuBar) }
            )
        } label: {
            MenuBarLabelView(snapshot: controller.snapshot)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var controller: SessionController?
    private let termination = TerminationCoordinator()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        termination.requestTermination(controller: controller) { shouldTerminate in
            NSApp.reply(toApplicationShouldTerminate: shouldTerminate)
        }
    }
}
