# Fresh official dependencies
- SwiftUI/AVFoundation/Network/CoreAudio: macOS26 SDK, Xcode27. Apple SDK license, no vendored implementation.
- Gradle8.13 (Apache-2.0), AGP8.11.0 (Apache-2.0), JDK17 installed. https://docs.gradle.org/8.13/release-notes.html ; https://developer.android.com/build/releases/agp-8-11-0-release-notes
- Kotlin2.1.20 (Apache-2.0), Compose BOM2025.04.01 / AndroidX (Apache-2.0). https://android-developers.googleblog.com/2025/04/whats-new-in-jetpack-compose-april-25.html
- Gnirehtet2.5.1 from https://github.com/Genymobile/gnirehtet/tree/v2.5.1 (Apache-2.0): fresh official source, not old repository code. Transport integration changes documented separately.
- Android platform-tools: official Google source distribution will be bundled with source URL/hash/license.
- BlackHole: external optional user-installed GPL-3.0 audio driver; no automatic installation and no driver binary included. https://github.com/ExistentialAudio/BlackHole

Gnirehtet integration: selected Android packet forwarding classes under `third_party/gnirehtet-android`; original copyright headers retained. RelayTunnel abstract name changed to `usblinkmic-v4` to avoid legacy resource collision; verbose packet dumps disabled. Original official tar source remains under `third_party/gnirehtet` as reproducible provenance. Original app/service/UI is not part of the new build. Java relay compiled from original official source and invoked only in `relay` mode, with a bundled JDK runtime (OpenJDK GPLv2 + Classpath exception; runtime legal files retained). New companion owns explicit consent, Android permissions and lifecycle.
`IPPacketOutputStream` buffer-capacity invariant is enforced in release as well as debug; removed original package BuildConfig dependency. No original Gnirehtet Activity/Service/Notifier is built.
