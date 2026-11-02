import Foundation
import OpenIslandCore
import Testing
@testable import OpenIslandApp

@MainActor
struct TodayTokenUsageMonitorPiDesktopTests {
    private func date(day: Int, hour: Int = 12) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    @Test
    func keepsTotalsAndSessionCountForToday() {
        let monitor = TodayTokenUsageMonitor()
        monitor.updatePiDesktopTotals(
            PiDesktopTodayTokens(totalTokens: 760_512, inputTokens: 100_000, outputTokens: 660_512, cacheReadTokens: 630_400, sessionCount: 3),
            at: date(day: 2)
        )

        #expect(monitor.piDesktopTotals?.totalTokens == 760_512)
        #expect(monitor.piDesktopTotals?.cacheReadTokens == 630_400)
        #expect(monitor.piDesktopTotals?.requestCount == 3)
    }

    @Test
    func dropsATotalLeftOverFromAnEarlierDay() {
        let monitor = TodayTokenUsageMonitor()
        monitor.updatePiDesktopTotals(
            PiDesktopTodayTokens(totalTokens: 500, inputTokens: 300, outputTokens: 200, sessionCount: 1),
            at: date(day: 1)
        )
        #expect(monitor.piDesktopTotals?.totalTokens == 500)

        monitor.updatePiDesktopTotals(
            PiDesktopTodayTokens(totalTokens: 90, inputTokens: 40, outputTokens: 50, sessionCount: 2),
            at: date(day: 2)
        )
        #expect(monitor.piDesktopTotals?.totalTokens == 90)
    }

    @Test
    func zeroClearsTheChipEntry() {
        let monitor = TodayTokenUsageMonitor()
        monitor.updatePiDesktopTotals(
            PiDesktopTodayTokens(totalTokens: 10, inputTokens: 5, outputTokens: 5, sessionCount: 1),
            at: date(day: 2)
        )
        monitor.updatePiDesktopTotals(.zero, at: date(day: 2))
        #expect(monitor.piDesktopTotals == nil)
    }
}
