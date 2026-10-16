// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "USBLinkMic", platforms: [.macOS("26.0")], products: [.executable(name: "USBLinkMic", targets: ["USBLinkMic"])], targets: [
 .target(name: "Contracts", path: "macos/Contracts"),
 .target(name: "Support", dependencies: ["Contracts"], path: "macos/Support"),
 .target(name: "UI", dependencies: ["Contracts", "Support"], path: "macos/UI"),
 .target(name: "Core", dependencies: ["Contracts", "Support"], path: "macos/Core"),
 .testTarget(name: "CoreTests", dependencies: ["Core", "Contracts"], path: "macos/CoreTests"),
 .executableTarget(name: "USBLinkMic", dependencies: ["Contracts", "Support", "UI", "Core"], path: "macos/App"),
 .testTarget(name: "SupportTests", dependencies: ["Contracts", "Support"], path: "macos/SupportTests"),
 .testTarget(name: "UITests", dependencies: ["Contracts", "UI"], path: "macos/UITests")
], swiftLanguageModes: [.v5])
