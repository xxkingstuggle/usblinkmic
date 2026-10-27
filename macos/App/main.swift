import SwiftUI
import AppKit
import Core
import UI

@main struct USBLinkMicApp: App {
    @StateObject private var controller = SessionController()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("USB LinkMic", id: "main") {
            RootView(snapshot: controller.snapshot, send: controller.send)
                .frame(minWidth: 860, minHeight: 580)
                .ignoresSafeArea(.container, edges: .top)
                .onAppear {
                    delegate.controller = controller
                    controller.boot()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 720)
        .commands {
            CommandGroup(after: .appSettings) {
                Button("偏好设置…") {
                    NotificationCenter.default.post(name: Notification.Name("USBLinkMic.showSettings"), object: nil)
                }
                .keyboardShortcut(",")
            }
            CommandMenu("连接") {
                Button("刷新") { controller.send(.refresh) }.keyboardShortcut("r")
                Button("全部停止") { controller.send(.stopAll) }.keyboardShortcut(".")
            }
        }

        MenuBarExtra {
            MenuBarConsoleView(snapshot: controller.snapshot, send: controller.send)
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
