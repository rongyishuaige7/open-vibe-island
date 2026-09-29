import Foundation
import Testing
@testable import OpenIslandApp
import OpenIslandCore

@MainActor
struct TodayTokenUsageMonitorTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()
    /// 2026-01-15 12:00 in Asia/Shanghai.
    private static let now = Date(timeIntervalSince1970: 1_768_449_600)
    private static let busy = CCSwitchUsageError.sqlite("database is locked")

    private func makeUsage(daysAgo: Int = 0, claudeTokens: Int) -> TodayTokenUsage {
        let today = Self.calendar.startOfDay(for: Self.now)
        let dayStart = Self.calendar.date(byAdding: .day, value: -daysAgo, to: today)!
        return TodayTokenUsage(dayStart: dayStart, claude: AgentTokenTotals(requestCount: 1, totalTokens: claudeTokens))
    }

    private func makeMonitor() -> TodayTokenUsageMonitor {
        TodayTokenUsageMonitor(databaseURL: URL(fileURLWithPath: "/nonexistent/cc-switch.db"))
    }

    @Test
    func successReplacesTotalsAndClearsTheError() {
        let monitor = makeMonitor()
        monitor.apply(.failure(Self.busy), now: Self.now, calendar: Self.calendar)
        monitor.apply(.success(makeUsage(claudeTokens: 42)), now: Self.now, calendar: Self.calendar)

        #expect(monitor.usage?.claude.totalTokens == 42)
        #expect(monitor.lastErrorMessage == nil)
    }

    @Test
    func transientFailureKeepsTodaysTotals() {
        let monitor = makeMonitor()
        monitor.apply(.success(makeUsage(claudeTokens: 42)), now: Self.now, calendar: Self.calendar)
        monitor.apply(.failure(Self.busy), now: Self.now, calendar: Self.calendar)

        #expect(monitor.usage?.claude.totalTokens == 42)
        #expect(monitor.lastErrorMessage == "database is locked")
    }

    @Test
    func failureDropsTotalsFromAnEarlierDay() {
        let monitor = makeMonitor()
        monitor.apply(.success(makeUsage(daysAgo: 1, claudeTokens: 42)), now: Self.now, calendar: Self.calendar)
        monitor.apply(.failure(Self.busy), now: Self.now, calendar: Self.calendar)

        #expect(monitor.usage == nil)
        #expect(monitor.lastErrorMessage == "database is locked")
    }

    @Test
    func missingDatabaseHidesTheChip() {
        let monitor = makeMonitor()
        monitor.apply(.success(makeUsage(claudeTokens: 42)), now: Self.now, calendar: Self.calendar)
        monitor.apply(.failure(CCSwitchUsageError.databaseMissing), now: Self.now, calendar: Self.calendar)

        #expect(monitor.usage == nil)
        #expect(monitor.lastErrorMessage == nil)
    }
}
