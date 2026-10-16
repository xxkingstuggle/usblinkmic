import XCTest
import Foundation
@testable import Core
import Contracts
final class CoreTests:XCTestCase {
 func testMappingCleanupRequiresExactDeviceAndEndpoints(){
  let listing="phoneA tcp:12345 tcp:48125\nphoneB tcp:45678 tcp:48125\n"
  XCTAssertTrue(ADB.ownsMapping(listing,serial:"phoneA",local:"tcp:12345",remote:"tcp:48125"))
  XCTAssertFalse(ADB.ownsMapping(listing,serial:"phoneB",local:"tcp:12345",remote:"tcp:48125"))
  XCTAssertFalse(ADB.ownsMapping(listing,serial:"phoneA",local:"tcp:12345",remote:"tcp:9999"))
 }
 func testDeviceParsingKeepsUnauthorizedAndOfflineSeparate(){
  let values=ADB.devices("List of devices attached\na unauthorized\nb device product:x\nc offline\n")
  XCTAssertEqual(values.map{$0.0},["a","b","c"]);XCTAssertEqual(values.map{$0.1},["unauthorized","device","offline"])
 }
 func testInstallErrorsDoNotSuggestUninstall(){
  XCTAssertEqual(ADB.classify("INSTALL_FAILED_UPDATE_INCOMPATIBLE"),"INSTALL_SIGNATURE_CONFLICT")
  XCTAssertEqual(ADB.classify("INSTALL_FAILED_VERSION_DOWNGRADE"),"INSTALL_DOWNGRADE")
  XCTAssertEqual(ADB.classify("INSTALL_FAILED_USER_RESTRICTED"),"INSTALL_DENIED")
 }
 func testFragmentedSilentFramesRemainValid()throws{
  var decoder=FrameDecoder()
  XCTAssertTrue(try decoder.append(Data([0,0]),bytesPerFrame:2).isEmpty)
  XCTAssertTrue(try decoder.append(Data([0,4,0]),bytesPerFrame:2).isEmpty)
  let result=try decoder.append(Data([0,0,0,0,0,0,2,1,0]),bytesPerFrame:2)
  XCTAssertEqual(result,[Data([0,0,0,0]),Data([1,0])])
 }
 func testBadFrameDetectedThenFreshDecoderRecovers()throws{
  var decoder=FrameDecoder()
  XCTAssertThrowsError(try decoder.append(Data([0,0,0,3,1,2,3]),bytesPerFrame:2))
  print("NEGATIVE BAD_FRAME detected (unaligned length=3)")
  decoder=FrameDecoder()
  XCTAssertEqual(try decoder.append(Data([0,0,0,2,1,0]),bytesPerFrame:2),[Data([1,0])])
  print("RECOVERY fresh decoder accepted aligned frame")
 }
 func testOversizedAndZeroFramesRejected(){
  for bytes:[UInt8] in [[0,0,0,0],[0,4,0,1]]{var decoder=FrameDecoder();XCTAssertThrowsError(try decoder.append(Data(bytes),bytesPerFrame:2))}
 }
 func testInterfacesIgnoreLoopbackAndNonEthernet(){
  let list=NetworkProbe.parseInterfaces("lo0: flags=0\n\tinet 127.0.0.1 netmask 0xff\nen9: flags=0\n\tinet 192.0.2.1 netmask 0xff\nutun1: flags=0\n\tinet 10.0.0.2 netmask 0xff\n")
  XCTAssertEqual(list,[NetworkInterface(name:"en9",address:"192.0.2.1")])
 }
 func testTaskCancellationTerminatesOwnedProcess() async throws {
  let started=Date()
  let task=Task{try await ProcessRunner.run(URL(fileURLWithPath:"/bin/sleep"),["10"])}
  try await Task.sleep(nanoseconds:100_000_000);task.cancel()
  let result=try await task.value
  XCTAssertNotEqual(result.code,0);XCTAssertLessThan(Date().timeIntervalSince(started),3)
  print("PASS cancellation terminated only owned process")
 }
 func testCommandExitCodeAndTimeoutAreObserved() async throws {
  let bad=try await ProcessRunner.run(URL(fileURLWithPath:"/usr/bin/false"),[])
  XCTAssertNotEqual(bad.code,0);print("NEGATIVE process exit=\(bad.code) detected")
  let good=try await ProcessRunner.run(URL(fileURLWithPath:"/usr/bin/true"),[])
  XCTAssertEqual(good.code,0);print("RECOVERY process exit=\(good.code)")
  let begin=Date();let timed=try await ProcessRunner.run(URL(fileURLWithPath:"/bin/sleep"),["10"],timeout:0.1)
  XCTAssertNotEqual(timed.code,0);XCTAssertLessThan(Date().timeIntervalSince(begin),3)
 }
}
