import Foundation
import Observation
import OpenIslandCore

/// Polls CC Switch's local request log for today's Claude and Codex token
/// totals, shown as the "Today" chip in the island header.
@MainActor
@Observable
final class TodayTokenUsageMonitor {
    private(set) var usage: TodayTokenUsage?
    /// DSH tokens reported by the host plugin's local-day ledger. Nil until
    /// the integration is installed and has seen a session.
    private(set) var dshTotals: AgentTokenTotals?
    /// Why the last refresh failed. Today's last good totals stay visible.
    private(set) var lastErrorMessage: String?

    private let databaseURL: URL
    private let keeperDatabaseURL: URL
    private let claudeProSessionsDirectoryURL: URL
    private let claudeProProjectsDirectoryURL: URL
    private let interval: Duration
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var dshTotalsDay: Date = .distantPast

    public var onDatabaseChanged: (@MainActor () -> Void)?

    @ObservationIgnored private var watcherSource: DispatchSourceFileSystemObject?
    @ObservationIgnored private var walWatcherSource: DispatchSourceFileSystemObject?
    /// File number of the -wal file `walWatcherSource` holds open.
    @ObservationIgnored private var walWatchedFileNumber: Int?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    init(
        databaseURL: URL = CCSwitchUsageReader.defaultDatabaseURL,
        keeperDatabaseURL: URL = KeeperUsageReader.defaultDatabaseURL,
        claudeProSessionsDirectoryURL: URL = ClaudeProUsageReader.defaultSessionsDirectoryURL,
        claudeProProjectsDirectoryURL: URL = ClaudeProUsageReader.defaultProjectsDirectoryURL,
        interval: Duration = .seconds(30)
    ) {
        self.databaseURL = databaseURL
        self.keeperDatabaseURL = keeperDatabaseURL
        self.claudeProSessionsDirectoryURL = claudeProSessionsDirectoryURL
        self.claudeProProjectsDirectoryURL = claudeProProjectsDirectoryURL
        self.interval = interval
    }

    func start() {
        guard task == nil else { return }
        startWatcher()
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
        stopWatcher()
        task?.cancel()
        task = nil
        usage = nil
        lastErrorMessage = nil
    }

    private func startWatcher() {
        stopWatcher()

        // The directory sees app.db-wal appear, vanish, or be replaced; writes
        // land in the -wal file itself. KEEPER may start after Open Island
        // (both launch at login) and recreates the file when it restarts, so
        // each directory event re-checks which -wal file is watched.
        let dirPath = keeperDatabaseURL.deletingLastPathComponent().path
        watcherSource = makeWatcher(path: dirPath, eventMask: [.write, .extend, .attrib, .link]) { [weak self] in
            self?.watchWALFileIfNeeded()
            self?.scheduleDebouncedRefresh()
        }
        watchWALFileIfNeeded()
    }

    private func watchWALFileIfNeeded() {
        let walPath = keeperDatabaseURL.path + "-wal"
        let fileNumber = (try? FileManager.default.attributesOfItem(atPath: walPath))
            .flatMap { ($0[.systemFileNumber] as? NSNumber)?.intValue }
        guard fileNumber != walWatchedFileNumber || (fileNumber != nil && walWatcherSource == nil) else {
            return
        }

        walWatcherSource?.cancel()
        walWatcherSource = nil
        walWatchedFileNumber = nil
        guard let fileNumber else { return }

        walWatcherSource = makeWatcher(path: walPath, eventMask: [.write, .extend, .attrib]) { [weak self] in
            self?.scheduleDebouncedRefresh()
        }
        if walWatcherSource != nil {
            walWatchedFileNumber = fileNumber
        }
    }

    /// Delivers events on the main queue, which the handlers' main-actor
    /// isolation requires.
    private func makeWatcher(
        path: String,
        eventMask: DispatchSource.FileSystemEvent,
        handler: @escaping () -> Void
    ) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: eventMask,
            queue: DispatchQueue.main
        )
        source.setEventHandler(handler: handler)
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        return source
    }

    private func scheduleDebouncedRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            await self.refresh()
            self.onDatabaseChanged?()
        }
    }

    private func stopWatcher() {
        debounceTask?.cancel()
        debounceTask = nil

        watcherSource?.cancel()
        watcherSource = nil
        walWatcherSource?.cancel()
        walWatcherSource = nil
        walWatchedFileNumber = nil
    }

    /// Merges the DSH plugin's today ledger into the chip. The ledger already
    /// resets at local midnight in the plugin; this also drops a total left
    /// over from an earlier day if the plugin has not reported since midnight.
    func updateDSHTotals(
        _ usage: DSHTodayTokens?,
        at date: Date = .now,
        calendar: Calendar = .current
    ) {
        guard let usage, usage.totalTokens > 0 || usage.sessionCount > 0 else {
            dshTotals = nil
            return
        }

        if dshTotals != nil, !calendar.isDate(dshTotalsDay, inSameDayAs: date) {
            dshTotals = nil
        }
        dshTotals = AgentTokenTotals(
            requestCount: usage.sessionCount,
            totalTokens: usage.totalTokens,
            cacheReadTokens: usage.cacheReadTokens
        )
        dshTotalsDay = calendar.startOfDay(for: date)
    }

    func refresh() async {
        let databaseURL = self.databaseURL
        let keeperDatabaseURL = self.keeperDatabaseURL
        let claudeProSessionsDirectoryURL = self.claudeProSessionsDirectoryURL
        let claudeProProjectsDirectoryURL = self.claudeProProjectsDirectoryURL
        let result = await Task.detached(priority: .utility) { () -> Result<TodayTokenUsage, any Error> in
            let calendar = Calendar.current
            let now = Date()
            let dayStart = calendar.startOfDay(for: now)

            var usage = TodayTokenUsage(dayStart: dayStart)
            var ccError: (any Error)?
            var keeperError: (any Error)?
            var hasAnyDatabase = false

            var ccClaude = AgentTokenTotals.zero
            var ccCodex = AgentTokenTotals.zero

            // 1. Try reading CC Switch for Claude and Codex
            do {
                let ccUsage = try CCSwitchUsageReader.loadToday(databaseURL: databaseURL, now: now, calendar: calendar)
                ccClaude = ccUsage.claude
                ccCodex = ccUsage.codex
                hasAnyDatabase = true
            } catch {
                ccError = error
            }

            // 2. Try reading KEEPER for Antigravity (Pool and Pro), Codex, Claude, and other upstreams
            do {
                let keeperUsage = try KeeperUsageReader.loadToday(databaseURL: keeperDatabaseURL, now: now, calendar: calendar)
                usage.agy = keeperUsage.agy
                usage.agyPro = keeperUsage.agyPro
                usage.other = keeperUsage.other
                usage.codex = ccCodex + keeperUsage.codex
                usage.claude = ccClaude + keeperUsage.claude
                usage.agyAccounts = keeperUsage.agyAccounts
                usage.agyProAccounts = keeperUsage.agyProAccounts
                usage.codexAccounts = keeperUsage.codexAccounts
                usage.claudeAccounts = keeperUsage.claudeAccounts
                usage.otherAccounts = keeperUsage.otherAccounts
                usage.agyAccountBreakdown = keeperUsage.agyAccountBreakdown
                hasAnyDatabase = true
            } catch {
                usage.codex = ccCodex
                usage.claude = ccClaude
                keeperError = error
            }

            // 3. Try reading Claude Pro (isolated CLI)
            do {
                let proUsage = try ClaudeProUsageReader.loadToday(
                    sessionsDirectoryURL: claudeProSessionsDirectoryURL,
                    projectsDirectoryURL: claudeProProjectsDirectoryURL,
                    now: now,
                    calendar: calendar
                )
                if proUsage.totals.totalTokens > 0 || proUsage.estimatedCostUSD > 0 {
                    usage.claudePro = proUsage.totals
                    usage.claudeProAccounts = [proUsage.accountHint]
                    usage.claudeProCostUSD = proUsage.estimatedCostUSD > 0 ? proUsage.estimatedCostUSD : nil
                    usage.claudeProRateLimit5h = proUsage.rateLimit5hPercent
                    usage.claudeProRateLimit7d = proUsage.rateLimit7dPercent
                    hasAnyDatabase = true
                }
            } catch {
                // Best-effort; Claude Pro is optional
            }

            let ccMissing = (ccError as? CCSwitchUsageError) == .databaseMissing
            let keeperMissing = (keeperError as? KeeperUsageError) == .databaseMissing

            // If both databases are missing and no Claude Pro usage found, return missing error
            if ccMissing && keeperMissing && usage.claudePro.totalTokens == 0 {
                return .failure(CCSwitchUsageError.databaseMissing)
            }

            // If databases failed with actual query/sqlite errors and no other sources succeeded
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
        // Assign only on change: every write invalidates the island header,
        // and most 30-second rounds read the same totals.
        switch result {
        case let .success(usage):
            setIfChanged(usage: usage, errorMessage: nil)
        case let .failure(error):
            if (error as? CCSwitchUsageError) == .databaseMissing || (error as? KeeperUsageError) == .databaseMissing {
                setIfChanged(usage: nil, errorMessage: nil)
                return
            }
            // A busy database is usually free again by the next round, so keep
            // today's totals and only drop ones left over from an earlier day.
            let kept = usage.flatMap { calendar.isDate($0.dayStart, inSameDayAs: now) ? $0 : nil }
            setIfChanged(usage: kept, errorMessage: error.localizedDescription)
        }
    }

    private func setIfChanged(usage newUsage: TodayTokenUsage?, errorMessage: String?) {
        if usage != newUsage {
            usage = newUsage
        }
        if lastErrorMessage != errorMessage {
            lastErrorMessage = errorMessage
        }
    }
}
