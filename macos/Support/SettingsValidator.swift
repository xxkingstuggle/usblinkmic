import Contracts
import Darwin
import Foundation

public enum SettingsValidator {
    public static func outputErrors(_ settings: Settings, outputs: [OutputDevice]) -> [String] {
        guard settings.purpose == .virtualMicrophone else { return [] }
        guard outputs.contains(where: { $0.id == settings.outputUID && $0.isVirtual }) else {
            return ["虚拟麦克风需要选择已连接的 BlackHole 输出设备；请先安装 BlackHole 或改用本机试听。"]
        }
        return []
    }

    public static func requiresOutputValidation(from current: Settings, to updated: Settings, microphoneActive: Bool = false) -> Bool {
        guard updated.purpose == .virtualMicrophone else { return false }
        if microphoneActive { return true }
        return current.purpose != updated.purpose || current.outputUID != updated.outputUID
    }

    public static func changedKeys(from current: Settings, to updated: Settings) -> [String] {
        var keys: [String] = []
        if current.audio.sampleRate != updated.audio.sampleRate { keys.append("audio.sampleRate") }
        if current.audio.channels != updated.audio.channels { keys.append("audio.channels") }
        if current.audio.format != updated.audio.format { keys.append("audio.format") }
        if current.audio.source != updated.audio.source { keys.append("audio.source") }
        if current.transport != updated.transport { keys.append("transport") }
        if current.purpose != updated.purpose { keys.append("purpose") }
        if current.outputUID != updated.outputUID { keys.append("outputUID") }
        if current.listenAddress != updated.listenAddress { keys.append("listenAddress") }
        if current.audioPort != updated.audioPort { keys.append("audioPort") }
        if current.controlPort != updated.controlPort { keys.append("controlPort") }
        if current.wifiHost != updated.wifiHost { keys.append("wifiHost") }
        if current.pairingCode != updated.pairingCode { keys.append("pairingCode") }
        if current.gain != updated.gain { keys.append("gain") }
        if current.muted != updated.muted { keys.append("muted") }
        if current.dns != updated.dns { keys.append("dns") }
        if current.routes != updated.routes { keys.append("routes") }
        return keys
    }

    public static func effectiveBindAddress(for settings: Settings) -> String {
        let trimmed = settings.listenAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        switch settings.transport {
        case .usb:
            return "127.0.0.1"
        case .wifi:
            return (trimmed.isEmpty || trimmed == "127.0.0.1") ? "0.0.0.0" : trimmed
        }
    }

    public static func affectedWorkspaces(
        from current: Settings,
        to updated: Settings,
        activeMicrophoneTransport: AudioTransport? = nil
    ) -> Set<Workspace> {
        var affected = Set<Workspace>()
        let effectiveTransport = activeMicrophoneTransport ?? updated.transport
        let coreAudioChanged =
            current.audio != updated.audio ||
            current.transport != updated.transport ||
            current.purpose != updated.purpose ||
            current.outputUID != updated.outputUID ||
            current.audioPort != updated.audioPort ||
            effectiveBindAddress(for: current) != effectiveBindAddress(for: updated)
        let wifiSpecificChanged =
            effectiveTransport == .wifi && (
                normalizedWifiTargetHost(current.wifiHost) != normalizedWifiTargetHost(updated.wifiHost) ||
                current.pairingCode != updated.pairingCode ||
                effectiveBindAddress(for: current) != effectiveBindAddress(for: updated)
            )
        if coreAudioChanged || wifiSpecificChanged {
            affected.insert(.microphone)
        }
        if current.dns != updated.dns || current.routes != updated.routes {
            affected.insert(.macInternet)
        }
        if current.controlPort != updated.controlPort {
            if effectiveTransport == .usb {
                affected.insert(.microphone)
            }
            affected.insert(.phoneInternet)
            affected.insert(.macInternet)
        }
        return affected
    }

    public static func normalizedWifiTargetHost(_ rawHost: String) -> String {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        while host.hasSuffix(".") {
            host.removeLast()
        }
        return host
    }

    public static func isUsableWifiTargetHost(_ rawHost: String) -> Bool {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return false }
        guard isIPv4Address(host) || isHostname(host) else { return false }
        let normalized = normalizedWifiTargetHost(host).lowercased()
        guard !normalized.isEmpty else { return false }
        if normalized == "localhost" || normalized.hasSuffix(".localhost") || normalized == "0.0.0.0" || normalized == "255.255.255.255" || normalized == "10.0.0.2" {
            return false
        }
        if isIPv4Address(normalized) {
            if normalized.hasPrefix("127.") || normalized.hasPrefix("169.254.") || normalized.hasPrefix("0.") {
                return false
            }
            let octets = normalized.split(separator: ".").compactMap { Int($0) }
            if octets.count == 4 && octets[0] >= 224 {
                return false
            }
            return true
        }
        return isHostname(host)
    }

    public static func isValidIPv4(_ value: String) -> Bool {
        isIPv4Address(value)
    }

    public static func resolveHostnameIPv4s(_ rawHostname: String) -> Set<String> {
        let hostname = normalizedWifiTargetHost(rawHostname)
        guard !hostname.isEmpty else { return [] }
        if isIPv4Address(hostname) {
            return [hostname]
        }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(hostname, nil, &hints, &res)
        guard status == 0, let first = res else { return [] }
        defer { freeaddrinfo(first) }
        var addresses = Set<String>()
        var ptr: UnsafeMutablePointer<addrinfo>? = first
        while let info = ptr?.pointee {
            if info.ai_family == AF_INET, let addrPtr = info.ai_addr {
                var sin = addrPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &sin.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                    let ip = String(cString: buffer)
                    if isUsableWifiTargetHost(ip) {
                        addresses.insert(ip)
                    }
                }
            }
            ptr = info.ai_next
        }
        return addresses
    }

    public static func wifiEndpointErrors(
        _ settings: Settings,
        activeLanAddresses: Set<String>?,
        hostnameResolver: (String) -> Set<String> = resolveHostnameIPv4s
    ) -> [String] {
        guard settings.transport == .wifi else { return [] }
        var issues: [String] = []
        let bindAddr = effectiveBindAddress(for: settings)
        let targetHost = normalizedWifiTargetHost(settings.wifiHost)

        if bindAddr != "0.0.0.0" {
            if let active = activeLanAddresses, !active.contains(bindAddr) {
                issues.append("listenAddress 当前不可用：所选监听网卡地址 (\(bindAddr)) 未连接或已失效，请改选 0.0.0.0 或当前活动局域网网卡")
            }
            if !targetHost.isEmpty {
                if isIPv4Address(targetHost) {
                    if targetHost != bindAddr {
                        issues.append("wifiHost 与 Mac 监听范围 (\(bindAddr)) 不一致：指定单网卡监听时，供手机连接的 Mac 地址须留空由该网卡推导，或与该网卡地址一致")
                    }
                } else if isUsableWifiTargetHost(targetHost) {
                    let resolved = hostnameResolver(targetHost)
                    if resolved.isEmpty {
                        issues.append("wifiHost 主机名 (\(targetHost)) 未能解析到有效 IPv4 地址；请确认主机名、直接填写 \(bindAddr) 或留空")
                    } else if resolved != [bindAddr] {
                        if resolved.contains(bindAddr) {
                            issues.append("wifiHost 主机名 (\(targetHost)) 解析到多个地址（\(resolved.sorted().joined(separator: ", "))），无法保证手机仅连接监听网卡；指定单网卡监听时请直接填写监听 IP (\(bindAddr)) 或留空")
                        } else {
                            issues.append("wifiHost 主机名 (\(targetHost)) 未解析到所选监听网卡地址 (\(bindAddr))；请填写仅解析到该网卡的主机名、直接填写 \(bindAddr) 或留空")
                        }
                    }
                }
            }
        } else if !targetHost.isEmpty {
            if let active = activeLanAddresses {
                if isIPv4Address(targetHost) {
                    if !active.contains(targetHost) {
                        issues.append("wifiHost 当前不可用：供手机连接的 Mac 地址 (\(targetHost)) 不在本机当前活动局域网地址中，请重选活动网卡地址或留空自动识别")
                    }
                } else if isUsableWifiTargetHost(targetHost) {
                    let resolved = hostnameResolver(targetHost)
                    if resolved.isEmpty {
                        issues.append("wifiHost 主机名 (\(targetHost)) 未能解析到有效 IPv4 地址；请确认主机名或直接选择本机局域网地址")
                    } else if !resolved.isSubset(of: active) {
                        if resolved.isDisjoint(with: active) {
                            issues.append("wifiHost 主机名 (\(targetHost)) 未解析到本机当前活动局域网地址；请确认主机名或直接选择本机局域网地址")
                        } else {
                            let foreign = resolved.subtracting(active).sorted().joined(separator: ", ")
                            issues.append("wifiHost 主机名 (\(targetHost)) 包含非本机当前活动局域网地址 (\(foreign))；所有解析地址均须属于本机活动局域网，请确认主机名或直接选择本机局域网地址")
                        }
                    }
                }
            } else if !isIPv4Address(targetHost), isUsableWifiTargetHost(targetHost) {
                let resolved = hostnameResolver(targetHost)
                if resolved.isEmpty {
                    issues.append("wifiHost 主机名 (\(targetHost)) 未能解析到有效 IPv4 地址；请确认主机名或直接选择本机局域网地址")
                }
            }
        }
        return issues
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
        } else if settings.transport == .wifi && settings.listenAddress != "0.0.0.0" && settings.listenAddress != "127.0.0.1" && !isUsableWifiTargetHost(settings.listenAddress) {
            issues.append("listenAddress must be 0.0.0.0 or a valid local interface IPv4 address")
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
        let trimmedWifiHost = settings.wifiHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedWifiHost.isEmpty {
            if !isIPv4Address(trimmedWifiHost) && !isHostname(trimmedWifiHost) {
                issues.append("wifiHost must be empty or a valid hostname or IPv4 address")
            } else if !isUsableWifiTargetHost(trimmedWifiHost) {
                issues.append("wifiHost must not be loopback, link-local, 0.0.0.0, or VPN tunnel address 10.0.0.2")
            } else if settings.transport == .wifi {
                let bindAddr = effectiveBindAddress(for: settings)
                let normalizedHost = normalizedWifiTargetHost(trimmedWifiHost)
                if bindAddr != "0.0.0.0" && isIPv4Address(normalizedHost) && normalizedHost != bindAddr {
                    issues.append("wifiHost 与 Mac 监听范围 (\(bindAddr)) 不一致：指定单网卡监听时，供手机连接的 Mac 地址须留空由该网卡推导，或与该网卡地址一致")
                }
            }
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
