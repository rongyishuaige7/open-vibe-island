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
    private let interval: Duration
    @ObservationIgnored private var task: Task<Void, Never>?

    init(databaseURL: URL = CCSwitchUsageReader.defaultDatabaseURL, interval: Duration = .seconds(30)) {
        self.databaseURL = databaseURL
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
        let result = await Task.detached(priority: .utility) {
            Result { try CCSwitchUsageReader.loadToday(databaseURL: databaseURL) }
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
            if (error as? CCSwitchUsageError) == .databaseMissing {
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
