import Foundation
import Support

public struct NetworkInterface: Equatable, Sendable {
 public let name: String
 public let address: String
 public init(name: String, address: String) {
  self.name = name
  self.address = address
 }
}

public struct WifiTargetResolution: Equatable, Sendable {
 public let host: String?
 public let isUserSpecified: Bool
 public let candidates: [NetworkInterface]
 public let isAmbiguous: Bool
 public let errorCode: String?
 public let errorDetail: String?

 public init(
  host: String?,
  isUserSpecified: Bool,
  candidates: [NetworkInterface] = [],
  isAmbiguous: Bool = false,
  errorCode: String? = nil,
  errorDetail: String? = nil
 ) {
  self.host = host
  self.isUserSpecified = isUserSpecified
  self.candidates = candidates
  self.isAmbiguous = isAmbiguous
  self.errorCode = errorCode
  self.errorDetail = errorDetail
 }
}

public enum NetworkProbe {
 public static func interfaceNames() async throws -> Set<String> {
  let result=try await ProcessRunner.run(URL(fileURLWithPath:"/sbin/ifconfig"),["-l"],timeout:3)
  guard result.code==0 else{throw LinkError.failure("INTERFACE_SCAN",result.output)}
  return Set(result.output.split(whereSeparator:{$0.isWhitespace}).map(String.init).filter{$0.hasPrefix("en")})
 }
 public static func interfaces() async throws -> [NetworkInterface] {
  let result=try await ProcessRunner.run(URL(fileURLWithPath:"/sbin/ifconfig"),["-a"],timeout:3)
  guard result.code==0 else{throw LinkError.failure("INTERFACE_SCAN",result.output)}
  return parseInterfaces(result.output)
 }
 public static func parseInterfaces(_ text:String)->[NetworkInterface] {
  var current="";var values=[NetworkInterface]()
  for line in text.split(separator:"\n") {
   if !line.hasPrefix("\t"),!line.hasPrefix(" "),let name=line.split(separator:":").first {current=String(name)}
   let fields=line.split(whereSeparator:{$0.isWhitespace})
   if fields.count>1,fields[0]=="inet",current.hasPrefix("en") {
    let addr=String(fields[1])
    if SettingsValidator.isUsableWifiTargetHost(addr) {
     values.append(NetworkInterface(name:current,address:addr))
    }
   }
  }
  return values
 }
 public static func isUnsuitableWifiHardware(name: String, hardware: String) -> Bool {
  let combined = (name + " " + hardware).lowercased()
  let unsuitableKeywords = [
   "usb", "ncm", "android", "iphone", "ipad", "ipod",
   "xiaomi", "redmi", "pixel", "samsung", "huawei", "honor", "oppo", "vivo", "oneplus", "手机",
   "bluetooth", "thunderbolt bridge", "firewire", "vpn", "utun", "awdl", "llw"
  ]
  return unsuitableKeywords.contains { combined.contains($0) }
 }
 public static func resolveWifiTargetHost(
  configuredHost: String,
  interfaces: [NetworkInterface],
  activeInterfaces: Set<String>? = nil,
  excludedInterfaces: Set<String> = [],
  listenAddress: String = "0.0.0.0",
  hostnameResolver: (String) -> Set<String> = SettingsValidator.resolveHostnameIPv4s
 ) -> WifiTargetResolution {
  var seenAddresses = Set<String>()
  let suitableCandidates = interfaces.filter { iface in
   guard iface.name.range(of: #"^en[0-9]+$"#, options: .regularExpression) != nil else { return false }
   guard !excludedInterfaces.contains(iface.name) else { return false }
   if let activeInterfaces, !activeInterfaces.contains(iface.name) { return false }
   guard SettingsValidator.isUsableWifiTargetHost(iface.address),
         isPrivateLanIPv4(iface.address) else { return false }
   return seenAddresses.insert(iface.address).inserted
  }
  let activeAddresses = Set(suitableCandidates.map(\.address))
  let trimmedListen = listenAddress.trimmingCharacters(in: .whitespacesAndNewlines)
  let effectiveListen = (trimmedListen.isEmpty || trimmedListen == "127.0.0.1") ? "0.0.0.0" : trimmedListen
  let normalizedConfigured = SettingsValidator.normalizedWifiTargetHost(configuredHost)

  // Rule 1: Specific interface listen address selected
  if effectiveListen != "0.0.0.0" {
   guard SettingsValidator.isUsableWifiTargetHost(effectiveListen),
         activeAddresses.contains(effectiveListen) else {
    return WifiTargetResolution(
     host: nil,
     isUserSpecified: true,
     candidates: suitableCandidates,
     isAmbiguous: false,
     errorCode: "WIFI_LISTEN_ADDRESS_UNAVAILABLE",
     errorDetail: "所选 Mac 监听网卡地址（\(effectiveListen)）当前未连接或不可用；请在设置中改选「0.0.0.0」或当前活动局域网网卡"
    )
   }
   if normalizedConfigured.isEmpty || !SettingsValidator.isUsableWifiTargetHost(normalizedConfigured) {
    return WifiTargetResolution(
     host: effectiveListen,
     isUserSpecified: true,
     candidates: suitableCandidates,
     isAmbiguous: false
    )
   }
   if SettingsValidator.isValidIPv4(normalizedConfigured) {
    guard normalizedConfigured == effectiveListen else {
     return WifiTargetResolution(
      host: nil,
      isUserSpecified: true,
      candidates: suitableCandidates,
      isAmbiguous: false,
      errorCode: "WIFI_ENDPOINT_MISMATCH",
      errorDetail: "Mac 监听地址（\(effectiveListen)）与供手机连接的 Mac 地址（\(normalizedConfigured)）不一致；请保持一致或将手机连接地址留空"
     )
    }
    return WifiTargetResolution(
     host: effectiveListen,
     isUserSpecified: true,
     candidates: suitableCandidates,
     isAmbiguous: false
    )
   }
   let resolvedIPs = hostnameResolver(normalizedConfigured)
   guard !resolvedIPs.isEmpty else {
    return WifiTargetResolution(
     host: nil,
     isUserSpecified: true,
     candidates: suitableCandidates,
     isAmbiguous: false,
     errorCode: "WIFI_HOSTNAME_UNAVAILABLE",
     errorDetail: "供手机连接的 Mac 主机名（\(normalizedConfigured)）未能解析到有效 IPv4 地址；请确认主机名或直接填写 \(effectiveListen)"
    )
   }
   guard resolvedIPs == [effectiveListen] else {
    let errorCode = resolvedIPs.contains(effectiveListen) ? "WIFI_HOSTNAME_MULTI_ADDRESS" : "WIFI_HOSTNAME_MISMATCH"
    let detail = resolvedIPs.contains(effectiveListen)
     ? "供手机连接的 Mac 主机名（\(normalizedConfigured)）解析到多个地址（\(resolvedIPs.sorted().joined(separator: ", "))），无法保证手机仅连接监听网卡；指定单网卡监听时请直接填写监听 IP（\(effectiveListen)）或留空"
     : "供手机连接的 Mac 主机名（\(normalizedConfigured)）未解析到所选监听网卡地址（\(effectiveListen)）；请直接填写 \(effectiveListen) 或留空"
    return WifiTargetResolution(
     host: nil,
     isUserSpecified: true,
     candidates: suitableCandidates,
     isAmbiguous: false,
     errorCode: errorCode,
     errorDetail: detail
    )
   }
   return WifiTargetResolution(
    host: normalizedConfigured,
    isUserSpecified: true,
    candidates: suitableCandidates,
    isAmbiguous: false
   )
  }

  // Rule 2: All-interfaces listen (0.0.0.0)
  if !normalizedConfigured.isEmpty, SettingsValidator.isUsableWifiTargetHost(normalizedConfigured) {
   if SettingsValidator.isValidIPv4(normalizedConfigured) {
    guard activeAddresses.contains(normalizedConfigured) else {
     return WifiTargetResolution(
      host: nil,
      isUserSpecified: true,
      candidates: suitableCandidates,
      isAmbiguous: false,
      errorCode: "WIFI_TARGET_UNAVAILABLE",
      errorDetail: "供手机连接的 Mac 地址（\(normalizedConfigured)）不在本机当前活动局域网接口中；请在设置中重选当前可用网卡地址或留空自动识别"
     )
    }
    return WifiTargetResolution(
     host: normalizedConfigured,
     isUserSpecified: true,
     candidates: suitableCandidates,
     isAmbiguous: false
    )
   }
   let resolvedIPs = hostnameResolver(normalizedConfigured)
   guard !resolvedIPs.isEmpty else {
    return WifiTargetResolution(
     host: nil,
     isUserSpecified: true,
     candidates: suitableCandidates,
     isAmbiguous: false,
     errorCode: "WIFI_HOSTNAME_UNAVAILABLE",
     errorDetail: "供手机连接的 Mac 主机名（\(normalizedConfigured)）未能解析到有效 IPv4 地址；请确认主机名或直接选择本机局域网 IP"
    )
   }
   guard resolvedIPs.isSubset(of: activeAddresses) else {
    let errorCode = resolvedIPs.isDisjoint(with: activeAddresses) ? "WIFI_HOSTNAME_UNAVAILABLE" : "WIFI_HOSTNAME_NOT_ALL_LOCAL"
    let foreign = resolvedIPs.subtracting(activeAddresses).sorted().joined(separator: ", ")
    let detail = resolvedIPs.isDisjoint(with: activeAddresses)
     ? "供手机连接的 Mac 主机名（\(normalizedConfigured)）未解析到本机当前活动局域网地址；请确认主机名或直接选择本机局域网 IP"
     : "供手机连接的 Mac 主机名（\(normalizedConfigured)）包含非本机当前活动局域网地址（\(foreign)）；所有解析地址均须属于本机活动局域网，请确认主机名或直接选择本机局域网 IP"
    return WifiTargetResolution(
     host: nil,
     isUserSpecified: true,
     candidates: suitableCandidates,
     isAmbiguous: false,
     errorCode: errorCode,
     errorDetail: detail
    )
   }
   return WifiTargetResolution(
    host: normalizedConfigured,
    isUserSpecified: true,
    candidates: suitableCandidates,
    isAmbiguous: false
   )
  }

  if suitableCandidates.count == 1 {
   return WifiTargetResolution(
    host: suitableCandidates[0].address,
    isUserSpecified: false,
    candidates: suitableCandidates,
    isAmbiguous: false
   )
  }
  if suitableCandidates.count > 1 {
   return WifiTargetResolution(
    host: nil,
    isUserSpecified: false,
    candidates: suitableCandidates,
    isAmbiguous: true
   )
  }
  return WifiTargetResolution(
   host: nil,
   isUserSpecified: false,
   candidates: [],
   isAmbiguous: false
  )
 }
 public static func probeWifiTargetHost(
  configuredHost: String,
  listenAddress: String = "0.0.0.0",
  additionalExcludedInterfaces: Set<String> = [],
  interfacesLoader: () async throws -> [NetworkInterface] = { try await interfaces() },
  linkActiveChecker: (String) async throws -> Bool = { try await linkActive($0) },
  hostnameResolver: (String) -> Set<String> = SettingsValidator.resolveHostnameIPv4s
 ) async -> WifiTargetResolution {
  let allInterfaces = (try? await interfacesLoader()) ?? []
  var activeNames = Set<String>()
  for name in Set(allInterfaces.map(\.name)) {
   if (try? await linkActiveChecker(name)) == true {
    activeNames.insert(name)
   }
  }
  return resolveWifiTargetHost(
   configuredHost: configuredHost,
   interfaces: allInterfaces,
   activeInterfaces: activeNames,
   excludedInterfaces: additionalExcludedInterfaces,
   listenAddress: listenAddress,
   hostnameResolver: hostnameResolver
  )
 }
 private static func isPrivateLanIPv4(_ address: String) -> Bool {
  if address.hasPrefix("192.168.") { return true }
  if address.hasPrefix("10.") && address != "10.0.0.2" { return true }
  let parts = address.split(separator: ".").compactMap { Int($0) }
  if parts.count == 4 && parts[0] == 172 && (16...31).contains(parts[1]) {
   return true
  }
  return false
 }
 public static func linkActive(_ interface:String) async throws -> Bool {
  guard interface.range(of:#"^en[0-9]+$"#,options:.regularExpression) != nil else{return false}
  let result=try await ProcessRunner.run(URL(fileURLWithPath:"/sbin/ifconfig"),[interface],timeout:3)
  guard result.code==0 else{return false}
  return result.output.split(separator:"\n").contains {line in
   let fields=line.split(whereSeparator:{$0.isWhitespace})
   return fields.count==2 && fields[0]=="status:" && fields[1]=="active"
  }
 }
 public static func defaultInterface() async throws -> String? {
  let result=try await ProcessRunner.run(URL(fileURLWithPath:"/sbin/route"),["-n","get","default"],timeout:3)
  guard result.code==0 else{return nil}
  return result.output.split(separator:"\n").first(where:{$0.contains("interface:")})?.split(separator:":").last.map{String($0).trimmingCharacters(in:.whitespaces)}
 }
}
