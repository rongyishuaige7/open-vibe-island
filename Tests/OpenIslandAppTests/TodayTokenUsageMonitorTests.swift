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

    @Test
    func antigravityPoolAndProTokensAreSupported() {
        let monitor = makeMonitor()
        let today = Self.calendar.startOfDay(for: Self.now)
        let usage = TodayTokenUsage(
            dayStart: today,
            claude: AgentTokenTotals(requestCount: 1, totalTokens: 100),
            agy: AgentTokenTotals(requestCount: 10, totalTokens: 50_000, cacheReadTokens: 40_000),
            agyPro: AgentTokenTotals(requestCount: 2, totalTokens: 8_000, cacheReadTokens: 6_000)
        )
        monitor.apply(.success(usage), now: Self.now, calendar: Self.calendar)

        #expect(monitor.usage?.claude.totalTokens == 100)
        #expect(monitor.usage?.agy.totalTokens == 50_000)
        #expect(monitor.usage?.agy.cacheReadTokens == 40_000)
        #expect(monitor.usage?.agyPro.totalTokens == 8_000)
        #expect(monitor.usage?.agyPro.cacheReadTokens == 6_000)
        #expect(monitor.lastErrorMessage == nil)
    }
}
