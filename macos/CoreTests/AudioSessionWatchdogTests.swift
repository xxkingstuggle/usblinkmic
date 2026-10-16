import XCTest
@testable import Core

final class AudioSessionWatchdogTests: XCTestCase {
 func testRestartDoesNotInheritOldFrameDeadline() {
  var clock=AudioSessionWatchdog()
  clock.begin("monitor");clock.frame("monitor",now:10)
  XCTAssertEqual(clock.failure("monitor",now:14),.interrupted)
  print("NEGATIVE original session: 4 seconds without frames detected")
  clock.stop("monitor");clock.begin("virtual")
  XCTAssertNil(clock.failure("virtual",now:300))
  clock.frame("monitor",now:1);clock.recording("monitor",now:1);clock.stop("monitor")
  XCTAssertNil(clock.failure("virtual",now:301),"Old callbacks must not arm or cancel the new session")
  clock.recording("virtual",now:302);clock.frame("virtual",now:303)
  XCTAssertNil(clock.failure("virtual",now:305))
  XCTAssertEqual(clock.failure("virtual",now:307),.interrupted)
  print("RECOVERY new session prepares without timeout, receives frames; genuine later interruption still detected")
 }
 func testPermissionWaitNeverStartsFirstFrameTimer() {
  var clock=AudioSessionWatchdog();clock.begin("permission")
  XCTAssertNil(clock.failure("permission",now:10000))
  clock.recording("permission",now:10001)
  XCTAssertNil(clock.failure("permission",now:10016))
  XCTAssertEqual(clock.failure("permission",now:10017),.firstFrame)
  clock.frame("permission",now:10018)
  XCTAssertNil(clock.failure("permission",now:10019))
 }
 func testStopDisarmsAllDeadlinesAndStaleSessionQueries() {
  var clock=AudioSessionWatchdog();clock.begin("a");clock.recording("a",now:0)
  clock.stop("a");XCTAssertNil(clock.failure("a",now:500))
  clock.begin("b");XCTAssertNil(clock.failure("a",now:500))
  clock.frame("b",now:600);XCTAssertNil(clock.failure("b",now:603))
  XCTAssertEqual(clock.failure("b",now:603.1),.interrupted)
 }
}
