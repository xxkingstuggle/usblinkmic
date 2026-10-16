import Contracts
import Foundation

private enum SettingsStoreError: LocalizedError {
    case unsupportedSchemaVersion(Int)
    case invalidSettings([String])

    var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return "Unsupported schemaVersion: \(version)"
        case .invalidSettings(let errors):
            return "Invalid settings: \(errors.joined(separator: "; "))"
        }
    }
}

private struct SettingsSchemaHeader: Decodable {
    let schemaVersion: Int
}

public final class SettingsStore {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> Settings {
        guard FileManager.default.fileExists(atPath: url.path) else { return Settings() }

        let data = try Data(contentsOf: url)
        let schemaVersion = try JSONDecoder().decode(SettingsSchemaHeader.self, from: data).schemaVersion
        guard schemaVersion == 1 else {
            throw SettingsStoreError.unsupportedSchemaVersion(schemaVersion)
        }
        let settings = try JSONDecoder().decode(Settings.self, from: data)
        let validationErrors = SettingsValidator.errors(settings)
        guard validationErrors.isEmpty else {
            throw SettingsStoreError.invalidSettings(validationErrors)
        }
        return settings
    }

    public func save(_ settings: Settings) throws {
        let validationErrors = SettingsValidator.errors(settings)
        guard validationErrors.isEmpty else {
            if settings.schemaVersion != 1 {
                throw SettingsStoreError.unsupportedSchemaVersion(settings.schemaVersion)
            }
            throw SettingsStoreError.invalidSettings(validationErrors)
        }

        let data = try JSONEncoder().encode(settings)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
