import Contracts
import Foundation
import XCTest
@testable import Core

final class USBChargingTests: XCTestCase {
 func testOnlyAnAuthorizedWiredTransportCanBeTargeted() {
  let listing = """
  List of devices attached
  phone      device       product:android usb:0-1 transport_id:12
  phone      device       product:android transport_id:17
  locked     unauthorized usb:0-2 transport_id:13
  gone       offline      usb:0-3 transport_id:14
  local      device       usb:0-4
  emulator-5554 device    transport_id:18
  """
  let devices = USBCharging.Target.wiredDevices(listing)
  XCTAssertEqual(devices, [.init(serial: "phone", transportID: 12)])
  XCTAssertNil(USBCharging.Target.match("phone", in: devices + devices))
 }

 func testOnlyAUniqueRealConnectedDevicePortWithIndependentPowerCanSwitch() {
  func canRequest(_ records: String, simulated: Bool = false) -> Bool {
   USBCharging.Reading(usb: dump(records, simulated: simulated), battery: battery(3, ac: false), serial: "phone").status.canRequest
  }
  XCTAssertTrue(canRequest(port()))
  XCTAssertFalse(canRequest(port(canChange: false)))
  XCTAssertFalse(canRequest(port(), simulated: true))
  XCTAssertFalse(canRequest(port(id: "port;reboot")))
  XCTAssertFalse(canRequest(port(role: "sink")), "Role combinations must not be mistaken for the active power role")
  let host = port(id: "accessory", data: "host")
  XCTAssertTrue(canRequest(array(host, port())))
  XCTAssertFalse(canRequest(array(port(), port(id: "other-device-port"))))
 }

 func testBatteryStatusUsesWiredPowerAndHandlesHyperOSAndSimulation() {
  let sink = dump(port(role: "sink"))
  let charging = USBCharging.Reading(usb: sink, battery: battery(2, ac: true), serial: "phone").status
  XCTAssertEqual(charging.phase, .charging, "HyperOS can classify wired input as AC")
  XCTAssertEqual(charging.batteryPercent, 7)
  XCTAssertEqual(USBCharging.Reading(usb: sink, battery: battery(5, ac: true), serial: "phone").status.phase, .full)
  XCTAssertEqual(USBCharging.Reading(usb: sink, battery: battery(4, ac: true), serial: "phone").status.phase, .powered)
  XCTAssertEqual(USBCharging.Reading(usb: sink, battery: battery(2, ac: false, wireless: true), serial: "phone").status.phase, .notCharging)
  let simulated = battery(2, ac: true) + "\n  (UPDATES STOPPED -- use 'reset' to restart)"
  XCTAssertEqual(USBCharging.Reading(usb: sink, battery: simulated, serial: "phone").status.phase, .unknown)
 }

 func testSwitchIsSentOnceAndVerifiedAfterTheSamePhoneReconnects() async throws {
  let result = try await exerciseRequest(reconnect: true)
  XCTAssertEqual(result.phase, .charging)
  XCTAssertEqual(result.writes, ["-t 12 shell dumpsys -t 3 usb set-port-roles typec0 sink device"])
 }

 func testAcknowledgementWithoutRoleChangeDoesNotReportCharging() async throws {
  let result = try await exerciseRequest(reconnect: false)
  XCTAssertEqual(result.phase, .unconfirmed)
  XCTAssertEqual(result.writes.count, 1)
 }

 private func exerciseRequest(reconnect: Bool) async throws -> (phase: USBChargingStatus.Phase, writes: [String]) {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  let executable = dir.appendingPathComponent("adb")
  let script = """
  #!/bin/sh
  dir=$(/usr/bin/dirname "$0")
  if [ -f "$dir/swapped" ]; then active=19; else active=12; fi
  if [ "$*" = 'devices -l' ]; then
    printf 'phone device usb:0-1 transport_id:%s\\nphone device transport_id:17\\n' "$active"
    exit 0
  fi
  if [ "$1" != '-t' ] || [ "$2" != "$active" ] || [ "$3" != 'shell' ] || [ "$4" != 'dumpsys' ] || [ "$5" != '-t' ]; then
    echo 'adb: transport not found' >&2
    exit 1
  fi
  args="$*"
  shift 6
  case "$*" in
    'usb') /bin/cat "$dir/usb-$active" ;;
    'battery') /bin/cat "$dir/battery-$active" ;;
    'usb set-port-roles typec0 sink device')
      printf '%s\\n' "$args" >> "$dir/writes"
      \(reconnect ? "touch \"$dir/swapped\"; exit 1" : "echo 'Setting USB port mode and role'") ;;
    *) exit 91 ;;
  esac
  """
  try script.write(to: executable, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
  for (name, contents) in ["usb-12": dump(port()), "usb-19": dump(port(role: "sink")),
                           "battery-12": battery(3, ac: false), "battery-19": battery(2, ac: true)] {
   try contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
  }
  let service = USBCharging(adb: ADB(executable: executable))
  let wired = try await service.target(for: "phone")
  let target = try XCTUnwrap(wired)
  let reading = try await service.read(target)
  let result = try await service.request(target, from: reading, settleSeconds: 2)
  let writes = try String(contentsOf: dir.appendingPathComponent("writes"), encoding: .utf8)
  return (result.phase, writes.split(whereSeparator: \.isNewline).map(String.init))
 }

 private func battery(_ status: Int, ac: Bool, wireless: Bool = false) -> String {
  """
  Current Battery Service state:
    AC powered: \(ac)
    USB powered: false
    Wireless powered: \(wireless)
    status: \(status)
    present: true
    level: 7
    scale: 100
  """
 }

 private func dump(_ records: String, simulated: Bool = false) -> String {
  "USB MANAGER STATE (dumpsys usb):\n  port_manager={\n    is_simulation_active=\(simulated)\n\(records)\n  }"
 }

 private func port(id: String = "typec0", role: String = "source", data: String = "device", canChange: Bool = true) -> String {
  """
      usb_ports={
        port={
          id=\(id)
        }
        status={
          connected=true
          power_role=\(role)
          data_role=\(data)
          role_combinations=[
            {
              power_role=source
              data_role=device
            }
            {
              power_role=sink
              data_role=device
            }
          ]
        }
        can_change_power_role=\(canChange)
      }
  """
 }

 private func array(_ records: String...) -> String {
  let items = records.map { record in
   record.replacingOccurrences(of: "usb_ports={", with: "{")
    .split(whereSeparator: \.isNewline).map { "  " + $0 }.joined(separator: "\n")
  }
  return "    usb_ports=[\n" + items.joined(separator: "\n") + "\n    ]"
 }
}
