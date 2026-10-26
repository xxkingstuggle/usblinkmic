import SwiftUI
import AppKit
import Core
import UI

@main struct USBLinkMicApp: App {
 @StateObject private var controller = SessionController()
 @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
 var body: some Scene {
  WindowGroup("USB LinkMic") {RootView(snapshot:controller.snapshot,send:controller.send).frame(minWidth:720,minHeight:520).onAppear{delegate.controller=controller;controller.boot()}}
  .commands {
   CommandGroup(after:.appSettings) {Button("设置…"){NotificationCenter.default.post(name:Notification.Name("USBLinkMic.showSettings"),object:nil)}.keyboardShortcut(",")}
   CommandMenu("连接") {Button("刷新"){controller.send(.refresh)}.keyboardShortcut("r");Button("全部停止"){controller.send(.stopAll)}.keyboardShortcut(".")}
  }
 }
}
@MainActor final class AppDelegate:NSObject,NSApplicationDelegate {
 weak var controller:SessionController?
 private let termination=TerminationCoordinator()
 func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
  termination.requestTermination(controller:controller) { shouldTerminate in
   NSApp.reply(toApplicationShouldTerminate:shouldTerminate)
  }
 }
}
