import Foundation
import Observation
import os
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
    func identicalRefreshDoesNotNotifyObservers() {
        let monitor = makeMonitor()
        monitor.apply(.success(makeUsage(claudeTokens: 42)), now: Self.now, calendar: Self.calendar)

        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = monitor.usage
            _ = monitor.lastErrorMessage
        } onChange: {
            changed.withLock { $0 = true }
        }
        monitor.apply(.success(makeUsage(claudeTokens: 42)), now: Self.now, calendar: Self.calendar)
        #expect(!changed.withLock { $0 })

        monitor.apply(.success(makeUsage(claudeTokens: 43)), now: Self.now, calendar: Self.calendar)
        #expect(changed.withLock { $0 })
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

    @Test
    func codexAndClaudeCombinedFromKeeperAndCCSwitch() {
        let monitor = makeMonitor()
        let today = Self.calendar.startOfDay(for: Self.now)
        let ccCodex = AgentTokenTotals(requestCount: 10, totalTokens: 5_000, cacheReadTokens: 1_000)
        let keeperCodex = AgentTokenTotals(requestCount: 77, totalTokens: 10_138_778, cacheReadTokens: 9_395_456)
        let combinedCodex = ccCodex + keeperCodex

        let usage = TodayTokenUsage(
            dayStart: today,
            claude: AgentTokenTotals(requestCount: 5, totalTokens: 2_000),
            codex: combinedCodex,
            agy: AgentTokenTotals(requestCount: 9, totalTokens: 1_705_198, cacheReadTokens: 1_084_686),
            agyPro: AgentTokenTotals(requestCount: 46, totalTokens: 264_017, cacheReadTokens: 1_941_049)
        )
        monitor.apply(.success(usage), now: Self.now, calendar: Self.calendar)

        #expect(monitor.usage?.codex.requestCount == 87)
        #expect(monitor.usage?.codex.totalTokens == 10_143_778)
        #expect(monitor.usage?.codex.cacheReadTokens == 9_396_456)
        #expect(monitor.usage?.agy.totalTokens == 1_705_198)
        #expect(monitor.usage?.agyPro.totalTokens == 264_017)
        #expect(monitor.usage?.codexAccountHint == "CC Switch")
        #expect(monitor.usage?.agyAccountHint == "")
        #expect(monitor.usage?.totalTokens == 2_000 + 10_143_778 + 1_705_198 + 264_017)

        let dynamicUsage = TodayTokenUsage(
            dayStart: today,
            agyAccounts: ["sk44989", "victorcranston465"],
            agyProAccounts: ["wisnumandala302"],
            codexAccounts: ["rongyiplus4", "rongyiplus5"],
            claudeAccounts: ["keeper-claude"]
        )
        #expect(dynamicUsage.claudeAccountHint == "keeper-claude, CC Switch")
        #expect(dynamicUsage.codexAccountHint == "rongyiplus4, rongyiplus5, CC Switch")
        #expect(dynamicUsage.agyAccountHint == "sk44989, victorcranston465")
        #expect(dynamicUsage.agyProAccountHint == "wisnumandala302")
    }

    @Test
    func claudeProUsageIncludedInTotals() {
        let monitor = makeMonitor()
        let today = Self.calendar.startOfDay(for: Self.now)
        let usage = TodayTokenUsage(
            dayStart: today,
            claude: AgentTokenTotals(requestCount: 2, totalTokens: 10_000),
            claudePro: AgentTokenTotals(requestCount: 50, totalTokens: 2_000_000, cacheReadTokens: 1_800_000),
            claudeProAccounts: ["Pro-Sandbox"],
            claudeProCostUSD: 4.50,
            claudeProRateLimit5h: 30,
            claudeProRateLimit7d: 45
        )
        monitor.apply(.success(usage), now: Self.now, calendar: Self.calendar)

        #expect(monitor.usage?.claudePro.requestCount == 50)
        #expect(monitor.usage?.claudePro.totalTokens == 2_000_000)
        #expect(monitor.usage?.claudePro.cacheReadTokens == 1_800_000)
        #expect(monitor.usage?.claudeProCostUSD == 4.50)
        #expect(monitor.usage?.claudeProRateLimit5h == 30)
        #expect(monitor.usage?.claudeProRateLimit7d == 45)
        #expect(monitor.usage?.claudeProAccountHint == "Pro-Sandbox")
        #expect(monitor.usage?.totalTokens == 10_000 + 2_000_000)
    }
}
