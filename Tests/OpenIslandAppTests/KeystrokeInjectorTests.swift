import Foundation
import Testing
@testable import OpenIslandApp

@Suite(.serialized)
struct KeystrokeInjectorTests {
    @Test
    func defaultInjectorPostsCmdShiftRightBracketWithoutCrashing() throws {
        // The default injector runs a real AppleScript that activates Warp
        // (launching it if needed) and advances its tab, so it only runs
        // when explicitly requested.
        guard ProcessInfo.processInfo.environment["OPEN_ISLAND_RUN_WARP_KEYSTROKE_INTEGRATION"] == "1" else {
            try Test.cancel("Set OPEN_ISLAND_RUN_WARP_KEYSTROKE_INTEGRATION=1 to run the live Warp keystroke check.")
        }

        let injector = DefaultKeystrokeInjector()
        injector.sendCmdShiftRightBracket()  // no XCTAssert — if this crashes the test fails
    }

    @Test
    func spyKeystrokerRecordsCalls() {
        let spy = KeystrokeInjectorSpy()
        spy.sendCmdShiftRightBracket()
        spy.sendCmdShiftRightBracket()
        #expect(spy.callCount == 2)
    }
}

final class KeystrokeInjectorSpy: KeystrokeInjector, @unchecked Sendable {
    var callCount = 0
    func sendCmdShiftRightBracket() {
        callCount += 1
    }
}
