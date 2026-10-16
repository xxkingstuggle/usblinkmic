import Contracts
import Foundation

public enum SettingsValidator {
    public static func outputErrors(_ settings: Settings, outputs: [OutputDevice]) -> [String] {
        guard settings.purpose == .virtualMicrophone else { return [] }
        guard outputs.contains(where: { $0.id == settings.outputUID && $0.isVirtual }) else {
            return ["虚拟麦克风需要选择已连接的 BlackHole 输出设备；请先安装 BlackHole 或改用本机试听。"]
        }
        return []
    }
    public static func errors(_ settings: Settings) -> [String] {
        guard settings.schemaVersion == 1 else {
            return ["Unsupported schemaVersion: \(settings.schemaVersion)"]
        }

        var issues: [String] = []
        if !Capabilities.sampleRates.contains(settings.audio.sampleRate) {
            issues.append("audio.sampleRate must be one of \(Capabilities.sampleRates)")
        }
        if !Capabilities.channels.contains(settings.audio.channels) {
            issues.append("audio.channels must be one of \(Capabilities.channels)")
        }
        if !settings.gain.isFinite || !(0...4).contains(settings.gain) {
            issues.append("gain must be finite and between 0 and 4")
        }
        if !isIPv4Address(settings.listenAddress) {
            issues.append("listenAddress must be a valid IPv4 address")
        }
        if !(1024...65535).contains(settings.audioPort) {
            issues.append("audioPort must be between 1024 and 65535")
        }
        if !(1024...65535).contains(settings.controlPort) {
            issues.append("controlPort must be between 1024 and 65535")
        }
        if settings.audioPort == settings.controlPort {
            issues.append("audioPort and controlPort must be distinct")
        }
        if !settings.wifiHost.isEmpty && !isIPv4Address(settings.wifiHost) && !isHostname(settings.wifiHost) {
            issues.append("wifiHost must be empty or a valid hostname or IPv4 address")
        }
        if !settings.pairingCode.isEmpty && !isHexString(settings.pairingCode, length: 32) {
            issues.append("pairingCode must be empty or 32 hexadecimal characters")
        }
        if !isIPv4Address(settings.dns) {
            issues.append("dns must be a valid IPv4 address")
        }
        if !isIPv4CIDRList(settings.routes) {
            issues.append("routes must contain one or more IPv4 CIDR routes")
        }
        return issues
    }
}

func isIPv4Address(_ value: String) -> Bool {
    let octets = value.split(separator: ".", omittingEmptySubsequences: false)
    guard octets.count == 4 else { return false }
    return octets.allSatisfy { octet in
        guard !octet.isEmpty,
              octet.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              !(octet.count > 1 && octet.first == "0"),
              let number = Int(octet), (0...255).contains(number) else {
            return false
        }
        return true
    }
}

private func isIPv4CIDRList(_ value: String) -> Bool {
    let routes = value.split(separator: ",", omittingEmptySubsequences: false)
    guard !routes.isEmpty else { return false }
    return routes.allSatisfy { route in
        let parts = route.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              isIPv4Address(String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)),
              parts[1].utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let prefix = Int(parts[1]), (0...32).contains(prefix) else {
            return false
        }
        return true
    }
}

private func isHostname(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 254,
          value.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 46 }),
          !(value.allSatisfy({ $0.isNumber || $0 == "." })) else {
        return false
    }

    let hostname = value.hasSuffix(".") ? String(value.dropLast()) : value
    guard !hostname.isEmpty else { return false }
    let labels = hostname.split(separator: ".", omittingEmptySubsequences: false)
    return labels.allSatisfy { label in
        label.count <= 63 && !label.isEmpty && label.first != "-" && label.last != "-"
    }
}

private func isHexString(_ value: String, length: Int) -> Bool {
    value.utf8.count == length && value.utf8.allSatisfy {
        ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102)
    }
}
