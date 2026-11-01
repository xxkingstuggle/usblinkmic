import Contracts
import Foundation
import XCTest
@testable import Support

final class SupportTests: XCTestCase {
    func testDefaultSettingsPassValidation() {
        XCTAssertEqual(SettingsValidator.errors(Settings()), [])
    }

    func testValidatorRejectsUnsupportedSchemaAndInvalidValues() {
        var unsupported = Settings()
        unsupported.schemaVersion = 9
        XCTAssertEqual(SettingsValidator.errors(unsupported), ["Unsupported schemaVersion: 9"])

        var settings = Settings()
        settings.audio.sampleRate = 12345
        settings.audio.channels = 3
        settings.gain = .infinity
        settings.listenAddress = "256.1.2.3"
        settings.audioPort = 1023
        settings.controlPort = 1023
        settings.wifiHost = "bad host"
        settings.pairingCode = "xyz"
        settings.dns = "2001:db8::1"
        settings.routes = "10.0.0.0/33"

        let errors = SettingsValidator.errors(settings)
        XCTAssertTrue(errors.contains(where: { $0.hasPrefix("audio.sampleRate") }))
        XCTAssertTrue(errors.contains(where: { $0.hasPrefix("audio.channels") }))
        XCTAssertTrue(errors.contains(where: { $0.hasPrefix("gain") }))
        XCTAssertTrue(errors.contains(where: { $0.hasPrefix("listenAddress") }))
        XCTAssertTrue(errors.contains(where: { $0.hasPrefix("audioPort") }))
        XCTAssertTrue(errors.contains(where: { $0.hasPrefix("controlPort") }))
        XCTAssertTrue(errors.contains(where: { $0.contains("distinct") }))
        XCTAssertTrue(errors.contains(where: { $0.hasPrefix("wifiHost") }))
        XCTAssertTrue(errors.contains(where: { $0.hasPrefix("pairingCode") }))
        XCTAssertTrue(errors.contains(where: { $0.hasPrefix("dns") }))
        XCTAssertTrue(errors.contains(where: { $0.hasPrefix("routes") }))
    }

    func testStoreRoundTripsAndValidatesBeforeAtomicSave() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("artifacts/support-tests").appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("settings.json")
        let store = SettingsStore(url: url)

        var saved = Settings()
        saved.audio.sampleRate = 48000
        saved.gain = 2.5
        saved.wifiHost = "mic.example.local"
        try store.save(saved)
        XCTAssertEqual(try store.load(), saved)

        let originalFile = try Data(contentsOf: url)
        var invalid = saved
        invalid.gain = .nan
        XCTAssertThrowsError(try store.save(invalid))
        XCTAssertEqual(try Data(contentsOf: url), originalFile)
        XCTAssertEqual(try store.load(), saved)
    }

    func testStoreRejectsUnknownSchemaVersion() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("artifacts/support-tests").appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{\"schemaVersion\":77}".utf8).write(to: url)

        XCTAssertThrowsError(try SettingsStore(url: url).load()) { error in
            XCTAssertTrue(error.localizedDescription.contains("Unsupported schemaVersion: 77"))
        }
    }

    func testLogRedactorMasksStructuredSecretsIPsAndHomePaths() {
        let input = "serial=ABC123 token=secret pairingCode=001122 ip=192.168.1.5 v6=2001:db8::1 file=/Users/alice/private.log ~/Documents/secret"
        let output = LogRedactor.redact(input)

        XCTAssertFalse(output.contains("ABC123"))
        XCTAssertFalse(output.contains("secret"))
        XCTAssertFalse(output.contains("192.168.1.5"))
        XCTAssertFalse(output.contains("2001:db8::1"))
        XCTAssertFalse(output.contains("/Users/alice"))
        XCTAssertFalse(output.contains("~/Documents"))
        XCTAssertTrue(output.contains("serial=[REDACTED]"))
        XCTAssertTrue(output.contains("[IP]"))
        XCTAssertTrue(output.contains("[HOME]"))
    }

    func testWifiTargetHostNormalizationRejectsLocalhostTrailingDotAndSubdomains() {
        for invalid in [
            "localhost",
            "localhost.",
            "LOCALHOST.",
            "router.localhost",
            "router.localhost.",
            "sub.router.localhost.",
            "127.0.0.1",
            "0.0.0.0",
            "10.0.0.2",
            "255.255.255.255"
        ] {
            XCTAssertFalse(
                SettingsValidator.isUsableWifiTargetHost(invalid),
                "Expected \(invalid) to be rejected as Wi-Fi target host"
            )
            var settings = Settings()
            settings.wifiHost = invalid
            XCTAssertTrue(
                SettingsValidator.errors(settings).contains(where: { $0.hasPrefix("wifiHost") }),
                "Expected SettingsValidator.errors to reject \(invalid)"
            )
        }

        for valid in ["192.168.1.25", "10.0.1.5", "macbook.local", "macbook.local."] {
            XCTAssertTrue(
                SettingsValidator.isUsableWifiTargetHost(valid),
                "Expected \(valid) to be accepted as Wi-Fi target host"
            )
        }
        XCTAssertEqual(SettingsValidator.normalizedWifiTargetHost("  MacBook.Local. "), "MacBook.Local")
    }

    func testAffectedWorkspacesScopedByActiveMicrophoneTransport() {
        let base = Settings()
        var wifiFieldsEdited = base
        wifiFieldsEdited.transport = .usb
        wifiFieldsEdited.wifiHost = "192.168.1.88"
        wifiFieldsEdited.pairingCode = "00112233445566778899aabbccddeeff"
        wifiFieldsEdited.listenAddress = "192.168.1.25"

        // Active USB microphone must NOT be affected by Wi-Fi-only edits when saved in USB mode
        XCTAssertEqual(
            SettingsValidator.affectedWorkspaces(
                from: base,
                to: wifiFieldsEdited,
                activeMicrophoneTransport: .usb
            ),
            []
        )

        // Active Wi-Fi microphone IS affected by Wi-Fi field edits
        XCTAssertEqual(
            SettingsValidator.affectedWorkspaces(
                from: base,
                to: wifiFieldsEdited,
                activeMicrophoneTransport: .wifi
            ),
            [.microphone]
        )

        // Real audio parameter changes still affect USB microphone
        var sampleRateEdited = wifiFieldsEdited
        sampleRateEdited.audio.sampleRate = 48000
        XCTAssertEqual(
            SettingsValidator.affectedWorkspaces(
                from: base,
                to: sampleRateEdited,
                activeMicrophoneTransport: .usb
            ),
            [.microphone]
        )
    }

    func testEffectiveBindAddressAcrossTransportModeSwitches() {
        var settings = Settings()
        settings.transport = .wifi
        settings.listenAddress = "192.168.1.25"
        XCTAssertEqual(SettingsValidator.effectiveBindAddress(for: settings), "192.168.1.25")

        // Switching to USB must always bind 127.0.0.1 while preserving the custom Wi-Fi listenAddress
        settings.transport = .usb
        XCTAssertEqual(SettingsValidator.effectiveBindAddress(for: settings), "127.0.0.1")
        XCTAssertEqual(settings.listenAddress, "192.168.1.25")

        // Switching back to Wi-Fi restores the custom LAN listenAddress
        settings.transport = .wifi
        XCTAssertEqual(SettingsValidator.effectiveBindAddress(for: settings), "192.168.1.25")

        // Legacy 127.0.0.1 in Wi-Fi mode migrates to 0.0.0.0
        settings.listenAddress = "127.0.0.1"
        XCTAssertEqual(SettingsValidator.effectiveBindAddress(for: settings), "0.0.0.0")
    }

    func testWifiEndpointValidationCoversListenTargetMismatchStaleAddressAndHostnameResolution() {
        let activeLan: Set<String> = ["192.168.1.25", "192.168.50.10"]

        // 1. Listen A / Target B mismatch is rejected by both errors() and wifiEndpointErrors()
        var mismatch = Settings()
        mismatch.transport = .wifi
        mismatch.listenAddress = "192.168.1.25"
        mismatch.wifiHost = "192.168.50.10"
        XCTAssertTrue(SettingsValidator.errors(mismatch).contains { $0.contains("不一致") })
        XCTAssertTrue(SettingsValidator.wifiEndpointErrors(mismatch, activeLanAddresses: activeLan).contains { $0.contains("不一致") })

        // 2. Stale/inactive listenAddress is rejected
        var staleListen = Settings()
        staleListen.transport = .wifi
        staleListen.listenAddress = "192.168.99.10"
        staleListen.wifiHost = ""
        XCTAssertTrue(SettingsValidator.wifiEndpointErrors(staleListen, activeLanAddresses: activeLan).contains { $0.contains("当前不可用") })

        // 3. Stale/inactive target wifiHost under 0.0.0.0 is rejected
        var staleTarget = Settings()
        staleTarget.transport = .wifi
        staleTarget.listenAddress = "0.0.0.0"
        staleTarget.wifiHost = "192.168.99.10"
        XCTAssertTrue(SettingsValidator.wifiEndpointErrors(staleTarget, activeLanAddresses: activeLan).contains { $0.contains("不在本机当前活动局域网地址中") })

        // 4. Valid 0.0.0.0 + active target or single-interface + empty/matching target passes
        var validAll = Settings()
        validAll.transport = .wifi
        validAll.listenAddress = "0.0.0.0"
        validAll.wifiHost = "192.168.50.10"
        XCTAssertTrue(SettingsValidator.wifiEndpointErrors(validAll, activeLanAddresses: activeLan).isEmpty)

        var validSingle = Settings()
        validSingle.transport = .wifi
        validSingle.listenAddress = "192.168.1.25"
        validSingle.wifiHost = ""
        XCTAssertTrue(SettingsValidator.wifiEndpointErrors(validSingle, activeLanAddresses: activeLan).isEmpty)
        validSingle.wifiHost = "192.168.1.25"
        XCTAssertTrue(SettingsValidator.wifiEndpointErrors(validSingle, activeLanAddresses: activeLan).isEmpty)

        // 5. Hostname resolution checks:
        // 5a. Single-interface listen: requires resolution to be exactly {A}; rejects {A, B}, {B}, and empty
        var singleInterfaceHostname = Settings()
        singleInterfaceHostname.transport = .wifi
        singleInterfaceHostname.listenAddress = "192.168.1.25"
        singleInterfaceHostname.wifiHost = "macbook.local"

        // {A}: valid
        XCTAssertTrue(
            SettingsValidator.wifiEndpointErrors(
                singleInterfaceHostname,
                activeLanAddresses: activeLan,
                hostnameResolver: { _ in ["192.168.1.25"] }
            ).isEmpty
        )
        // {A, B}: rejected (multiple addresses cannot guarantee phone connects only to listening interface)
        let multiAddressErrors = SettingsValidator.wifiEndpointErrors(
            singleInterfaceHostname,
            activeLanAddresses: activeLan,
            hostnameResolver: { _ in ["192.168.1.25", "192.168.50.10"] }
        )
        XCTAssertTrue(multiAddressErrors.contains { $0.contains("多个地址") })

        // {B}: rejected (does not contain listen address A)
        let mismatchErrors = SettingsValidator.wifiEndpointErrors(
            singleInterfaceHostname,
            activeLanAddresses: activeLan,
            hostnameResolver: { _ in ["192.168.50.10"] }
        )
        XCTAssertTrue(mismatchErrors.contains { $0.contains("未解析到所选监听网卡地址") })

        // {}: empty resolution rejected
        let emptyErrors = SettingsValidator.wifiEndpointErrors(
            singleInterfaceHostname,
            activeLanAddresses: activeLan,
            hostnameResolver: { _ in [] }
        )
        XCTAssertTrue(emptyErrors.contains { $0.contains("未能解析到有效 IPv4 地址") })

        // 5b. All-interfaces listen (0.0.0.0): all resolved addresses must belong to active local LAN
        var allInterfacesHostname = Settings()
        allInterfacesHostname.transport = .wifi
        allInterfacesHostname.listenAddress = "0.0.0.0"
        allInterfacesHostname.wifiHost = "macbook.local"

        // Both in activeLan: valid
        XCTAssertTrue(
            SettingsValidator.wifiEndpointErrors(
                allInterfacesHostname,
                activeLanAddresses: activeLan,
                hostnameResolver: { _ in ["192.168.1.25", "192.168.50.10"] }
            ).isEmpty
        )
        // One local, one foreign: rejected (all addresses must belong to active local LAN)
        let mixedErrors = SettingsValidator.wifiEndpointErrors(
            allInterfacesHostname,
            activeLanAddresses: activeLan,
            hostnameResolver: { _ in ["192.168.1.25", "198.51.100.1"] }
        )
        XCTAssertTrue(mixedErrors.contains { $0.contains("非本机当前活动局域网") })

        // Completely foreign: rejected
        let foreignErrors = SettingsValidator.wifiEndpointErrors(
            allInterfacesHostname,
            activeLanAddresses: activeLan,
            hostnameResolver: { _ in ["198.51.100.1"] }
        )
        XCTAssertTrue(foreignErrors.contains { $0.contains("未解析到本机当前活动局域网地址") })

        // Empty resolution: rejected
        let allEmptyErrors = SettingsValidator.wifiEndpointErrors(
            allInterfacesHostname,
            activeLanAddresses: activeLan,
            hostnameResolver: { _ in [] }
        )
        XCTAssertTrue(allEmptyErrors.contains { $0.contains("未能解析到有效 IPv4 地址") })
    }
}
