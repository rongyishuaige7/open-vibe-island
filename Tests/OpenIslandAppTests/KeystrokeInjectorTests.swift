import Testing
@testable import OpenIslandApp

@Suite(.serialized)
struct KeystrokeInjectorTests {
    @Test(.disabled("Executes AppleScript through System Events; requires TCC grants and is not deterministic in headless runs."))
    func defaultInjectorPostsCmdShiftRightBracketWithoutCrashing() {
        // We can't observe actual OS-level CGEvent delivery in a unit test,
        // but constructing and posting the event without throwing/crashing
        // covers the init-time correctness of the keycode and flags.
        // Kept as an opt-in manual check: invoking it can block on the macOS
        // Automation consent dialog, which previously hung the whole suite.
        let injector = DefaultKeystrokeInjector()
        injector.sendCmdShiftRightBracket()
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
