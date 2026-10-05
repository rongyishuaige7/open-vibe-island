import Foundation
import Observation
import OpenIslandCore

/// Polls CC Switch's local request log for today's Claude and Codex token
/// totals, shown as the "Today" chip in the island header.
@MainActor
@Observable
final class TodayTokenUsageMonitor {
    private(set) var usage: TodayTokenUsage?
    /// Why the last refresh failed. Today's last good totals stay visible.
    private(set) var lastErrorMessage: String?

    private let databaseURL: URL
    private let keeperDatabaseURL: URL
    private let interval: Duration
    @ObservationIgnored private var task: Task<Void, Never>?

    init(
        databaseURL: URL = CCSwitchUsageReader.defaultDatabaseURL,
        keeperDatabaseURL: URL = KeeperUsageReader.defaultDatabaseURL,
        interval: Duration = .seconds(30)
    ) {
        self.databaseURL = databaseURL
        self.keeperDatabaseURL = keeperDatabaseURL
        self.interval = interval
    }

    func start() {
        guard task == nil else { return }
        let interval = self.interval
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        usage = nil
        lastErrorMessage = nil
    }

    func refresh() async {
        let databaseURL = self.databaseURL
        let keeperDatabaseURL = self.keeperDatabaseURL
        let result = await Task.detached(priority: .utility) { () -> Result<TodayTokenUsage, any Error> in
            let calendar = Calendar.current
            let now = Date()
            let dayStart = calendar.startOfDay(for: now)

            var usage = TodayTokenUsage(dayStart: dayStart)
            var ccError: (any Error)?
            var keeperError: (any Error)?
            var hasAnyDatabase = false

            // 1. Try reading CC Switch for Claude and Codex
            do {
                let ccUsage = try CCSwitchUsageReader.loadToday(databaseURL: databaseURL, now: now, calendar: calendar)
                usage.claude = ccUsage.claude
                usage.codex = ccUsage.codex
                hasAnyDatabase = true
            } catch {
                ccError = error
            }

            // 2. Try reading KEEPER for Antigravity (Pool and Pro)
            do {
                let keeperUsage = try KeeperUsageReader.loadToday(databaseURL: keeperDatabaseURL, now: now, calendar: calendar)
                usage.agy = keeperUsage.agy
                usage.agyPro = keeperUsage.agyPro
                hasAnyDatabase = true
            } catch {
                keeperError = error
            }

            let ccMissing = (ccError as? CCSwitchUsageError) == .databaseMissing
            let keeperMissing = (keeperError as? KeeperUsageError) == .databaseMissing

            // If both databases are missing, return missing error
            if ccMissing && keeperMissing {
                return .failure(CCSwitchUsageError.databaseMissing)
            }

            // If both failed with actual query/sqlite errors
            if !hasAnyDatabase {
                if let ccError, !ccMissing {
                    return .failure(ccError)
                }
                if let keeperError, !keeperMissing {
                    return .failure(keeperError)
                }
            }

            return .success(usage)
        }.value

        // A read that finishes after stop() must not bring the chip back.
        guard !Task.isCancelled else { return }
        apply(result)
    }

    func apply(
        _ result: Result<TodayTokenUsage, any Error>,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        switch result {
        case let .success(usage):
            self.usage = usage
            lastErrorMessage = nil
        case let .failure(error):
            if (error as? CCSwitchUsageError) == .databaseMissing || (error as? KeeperUsageError) == .databaseMissing {
                usage = nil
                lastErrorMessage = nil
                return
            }
            // A busy database is usually free again by the next round, so keep
            // today's totals and only drop ones left over from an earlier day.
            if let usage, !calendar.isDate(usage.dayStart, inSameDayAs: now) {
                self.usage = nil
            }
            lastErrorMessage = error.localizedDescription
        }
    }
}
