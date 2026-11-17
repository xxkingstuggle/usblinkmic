import Foundation
import Contracts

/// A USB-C power role change; the ADB data role and gadget functions stay as they are.
struct USBCharging {
 let adb: ADB

 struct Target: Equatable {
  let serial: String
  let transportID: UInt64

  static func wiredDevices(_ listing: String) -> [Self] {
   listing.split(whereSeparator: \.isNewline).compactMap { line in
    let fields = line.split(whereSeparator: \.isWhitespace)
    guard fields.count >= 4, fields[1] == "device",
          fields.dropFirst(2).contains(where: { $0.hasPrefix("usb:") && $0.count > 4 }),
          let transport = fields.dropFirst(2).first(where: { $0.hasPrefix("transport_id:") }),
          let id = UInt64(transport.dropFirst("transport_id:".count)), id > 0 else { return nil }
    return Self(serial: String(fields[0]), transportID: id)
   }
  }

  static func match(_ serial: String?, in devices: [Self]) -> Self? {
   let matches = devices.filter { $0.serial == serial }
   return matches.count == 1 ? matches[0] : nil
  }
 }

 struct Reading {
  fileprivate let port: Port?
  let status: USBChargingStatus

  init(usb: String, battery: String, serial: String) {
   port = Port.read(usb)
   let battery = Battery(battery)
   // Some ROMs (including HyperOS) report USB-C input as AC. Require a sink
   // role for that case, and a separate battery state before claiming charging.
   let wired = battery.usbPowered || (port?.powerRole == "sink" && battery.acPowered)
   let phase: USBChargingStatus.Phase
   let canRequest = port?.powerRole == "source" && port?.canChangePower == true
   if port?.powerRole == "source" {
    phase = canRequest ? .supplyingPower : .unsupported
   } else if wired {
    switch battery.status {
    case 2: phase = .charging
    case 5: phase = .full
    default: phase = .powered
    }
   } else {
    phase = battery.status == nil || battery.acPowered ? .unknown : .notCharging
   }
   status = USBChargingStatus(phase, batteryPercent: battery.percent, canRequest: canRequest, deviceID: serial)
  }
 }

 func target(for serial: String, timeout: TimeInterval = 3) async throws -> Target? {
  let listing = try await adb.run(nil, ["devices", "-l"], timeout: timeout, cancellable: true)
  return Target.match(serial, in: Target.wiredDevices(listing))
 }

 func read(_ target: Target, timeout: TimeInterval = 3) async throws -> Reading {
  async let usb = shell(target, ["usb"], timeout: timeout)
  async let battery = shell(target, ["battery"], timeout: timeout)
  return try await Reading(usb: usb, battery: battery, serial: target.serial)
 }

 func request(_ target: Target, from reading: Reading, settleSeconds: TimeInterval = 5) async throws -> USBChargingStatus {
  guard reading.status.deviceID == target.serial, reading.status.canRequest, let port = reading.port else { return reading.status }
  try Task.checkCancellation()
  // Even exit 0 only acknowledges the request. A power swap may also briefly
  // drop the transport, so re-read the same phone without repeating the write.
  _ = try? await shell(target, ["usb", "set-port-roles", port.id, "sink", "device"])
  let deadline = ProcessInfo.processInfo.systemUptime + settleSeconds
  var current = target
  var latest: Reading?
  repeat {
   try Task.checkCancellation()
   let remaining = max(0.2, deadline - ProcessInfo.processInfo.systemUptime)
   do {
    latest = try await read(current, timeout: min(remaining, 2))
    if latest?.port?.id == port.id, latest?.port?.powerRole == "sink",
       let status = latest?.status, status.phase == .charging || status.phase == .full {
     return status
    }
   } catch {
    latest = nil
    try Task.checkCancellation()
    let timeLeft = deadline - ProcessInfo.processInfo.systemUptime
    if timeLeft > 0, let reconnected = try? await self.target(for: target.serial, timeout: min(timeLeft, 1)) {
     current = reconnected
    }
   }
   let delay = min(0.65, deadline - ProcessInfo.processInfo.systemUptime)
   if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
  } while ProcessInfo.processInfo.systemUptime < deadline
  try Task.checkCancellation()
  if let latest, latest.port?.id == port.id, latest.port?.powerRole == "sink" { return latest.status }
  return USBChargingStatus(.unconfirmed, batteryPercent: latest?.status.batteryPercent,
                           canRequest: latest?.status.canRequest == true, deviceID: target.serial)
 }

 private func shell(_ target: Target, _ args: [String], timeout: TimeInterval = 3) async throws -> String {
  let dumpTimeout = String(max(1, Int(timeout.rounded(.down))))
  return try await adb.run(nil, ["-t", String(target.transportID), "shell", "dumpsys", "-t", dumpTimeout] + args,
                           timeout: timeout, cancellable: true)
 }
}

private struct Battery {
 let status: Int?
 let percent: Int?
 let usbPowered: Bool
 let acPowered: Bool

 init(_ text: String) {
  var fields: [Substring: Substring] = [:]
  if !text.contains("UPDATES STOPPED") {
   for line in text.split(whereSeparator: \.isNewline) {
    let pair = line.split(separator: ":", maxSplits: 1).map { $0.drop(while: \.isWhitespace) }
    if pair.count == 2, fields[pair[0]] == nil { fields[pair[0]] = pair[1] }
   }
  }
  let present = fields["present"] != "false"
  status = present ? fields["status"].flatMap { Int($0) }.flatMap { (2...5).contains($0) ? $0 : nil } : nil
  usbPowered = fields["USB powered"] == "true"
  acPowered = fields["AC powered"] == "true"
  if present, let level = fields["level"].flatMap({ Int($0) }),
     let scale = fields["scale"].flatMap({ Int($0) }), scale > 0, (0...scale).contains(level) {
   percent = Int((100 * Double(level) / Double(scale)).rounded())
  } else { percent = nil }
 }
}

private struct Port {
 let id: String
 let powerRole: Substring
 let canChangePower: Bool

 static func read(_ text: String) -> Self? {
  let lines = text.split(whereSeparator: \.isNewline).map(DumpLine.init)
  guard let manager = block("port_manager={", in: lines[...]),
        value("is_simulation_active", in: manager) == "false" else { return nil }
  let records: [ArraySlice<DumpLine>]
  if let single = block("usb_ports={", in: manager) {
   records = [single]
  } else if let list = block("usb_ports=[", in: manager), let indent = list.first?.indent {
   records = list.indices.filter { list[$0].indent == indent && list[$0].value == "{" }
    .compactMap { block("{", in: list[$0...]) }
  } else { return nil }
  var device: Self?
  for record in records {
   guard let status = block("status={", in: record), let connected = value("connected", in: status) else { return nil }
   if connected == "false" { continue }
   guard connected == "true", let data = value("data_role", in: status) else { return nil }
   if data != "device" { continue }
   guard device == nil, let port = block("port={", in: record), let id = value("id", in: port),
         id.range(of: #"^[a-zA-Z0-9_][a-zA-Z0-9_.:-]{0,79}$"#, options: .regularExpression) != nil,
         let power = value("power_role", in: status) else { return nil }
   device = Self(id: String(id), powerRole: power, canChangePower: value("can_change_power_role", in: record) == "true")
  }
  return device
 }

 private struct DumpLine {
  let indent: Int
  let value: Substring
  init(_ line: Substring) {
   value = line.drop(while: \.isWhitespace)
   indent = line.count - value.count
  }
 }

 private static func block(_ opener: String, in lines: ArraySlice<DumpLine>) -> ArraySlice<DumpLine>? {
  guard let start = lines.firstIndex(where: { $0.value == opener }) else { return nil }
  let body = lines[lines.index(after: start)...]
  guard let end = body.firstIndex(where: { $0.indent <= lines[start].indent }),
        body[end].value == (opener.hasSuffix("[") ? "]" : "}") else { return nil }
  return body[..<end]
 }

 private static func value(_ key: String, in lines: ArraySlice<DumpLine>) -> Substring? {
  let prefix = key + "="
  return lines.first { $0.indent == lines.first?.indent && $0.value.hasPrefix(prefix) }?.value.dropFirst(prefix.count)
 }
}
