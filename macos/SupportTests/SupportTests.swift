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
}
