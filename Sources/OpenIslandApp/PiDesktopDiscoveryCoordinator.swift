import AppKit
import Foundation
import OpenIslandCore
import os

/// Polls PI Desktop's SQLite store and turns it into island session events.
///
/// PI Desktop keeps every conversation inside one Electron process, so there is
/// no per-session process to watch and its plugin events are too coarse for
/// activity. The store is cheap to read (measured p50 1.4 ms) but the poller
/// still gates on the write-ahead log's mtime so an idle app costs nothing.
@MainActor
final class PiDesktopDiscoveryCoordinator {
    /// Fires one event at a time so the app can apply them in order.
    var onEvent: (@MainActor (AgentEvent) -> Void)?
    /// Reads the current island state to decide start vs. activity.
    var stateAccessor: (@MainActor () -> SessionState)?

    private let store: PiDesktopSessionStore
    private var pollTask: Task<Void, Never>?
    private var knownSessionIDs: Set<String> = []
    private var lastSignature: DatabaseSignature?
    private var lastHeartbeatAt = Date.distantPast
    private var isAppRunning = false
    private var lastAppProbeAt = Date.distantPast

    private let logger = Logger(subsystem: "app.openisland.dev", category: "pi-desktop")

    private static let runningInterval: Duration = .seconds(1)
    private static let idleInterval: Duration = .seconds(3)
    private static let appProbeInterval: TimeInterval = 5
    private static let heartbeatInterval: TimeInterval = 15

    init(store: PiDesktopSessionStore = PiDesktopSessionStore()) {
        self.store = store
    }

    func start() {
        guard pollTask == nil else {
            return
        }
        logger.notice("starting PI Desktop polling")
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }
                let interval = self.tick()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// One poll cycle. Returns how long to wait before the next one.
    func tick(now: Date = .now) -> Duration {
        refreshAppRunningIfNeeded(now: now)

        guard isAppRunning else {
            endKnownSessions(summary: "PI Desktop closed.")
            return Self.idleInterval
        }

        guard store.databaseExists else {
            endKnownSessions(summary: "PI Desktop's database is unavailable.")
            return Self.idleInterval
        }

        let signature = DatabaseSignature(databasePath: store.databasePath)
        let signatureChanged = signature != lastSignature
        let heartbeatDue = now.timeIntervalSince(lastHeartbeatAt) >= Self.heartbeatInterval
        guard signatureChanged || heartbeatDue else {
            return Self.runningInterval
        }

        switch store.loadSessions() {
        case .failure:
            // Schema drift or a busy checkpoint: keep the last known rows and
            // try again next tick rather than tearing sessions down.
            return Self.runningInterval

        case let .success(records):
            publish(records.map(PiDesktopSessionSnapshot.init(record:)), at: now)
            lastSignature = signature
            lastHeartbeatAt = now
            return Self.runningInterval
        }
    }

    /// Exposed for tests: feed a snapshot list directly.
    func publish(_ snapshots: [PiDesktopSessionSnapshot], at timestamp: Date) {
        let state = stateAccessor?() ?? SessionState()
        var seen: Set<String> = []

        for snapshot in snapshots {
            seen.insert(snapshot.sessionID)
            let events = PiDesktopEventMapper.events(
                for: snapshot,
                existing: state.session(id: snapshot.sessionID),
                timestamp: timestamp
            )
            for event in events {
                onEvent?(event)
            }
        }

        let endedIDs = knownSessionIDs.subtracting(seen)
        for staleID in endedIDs {
            onEvent?(
                PiDesktopEventMapper.sessionEnded(sessionID: staleID, timestamp: timestamp)
            )
        }
        let sessionCount = snapshots.count
        let endedCount = endedIDs.count
        logger.notice(
            "published \(sessionCount, privacy: .public) PI Desktop session(s), ended \(endedCount, privacy: .public)"
        )
        knownSessionIDs = seen
    }

    private func refreshAppRunningIfNeeded(now: Date) {
        guard now.timeIntervalSince(lastAppProbeAt) >= Self.appProbeInterval else {
            return
        }
        lastAppProbeAt = now
        isAppRunning = !NSRunningApplication
            .runningApplications(withBundleIdentifier: PiDesktopEventMapper.bundleIdentifier)
            .isEmpty
    }

    private func endKnownSessions(summary: String) {
        guard !knownSessionIDs.isEmpty else {
            return
        }
        let now = Date.now
        for sessionID in knownSessionIDs {
            onEvent?(
                PiDesktopEventMapper.sessionEnded(sessionID: sessionID, summary: summary, timestamp: now)
            )
        }
        knownSessionIDs.removeAll()
        lastSignature = nil
    }

    /// WAL writes bump the `-wal` file, which is the cheap signal that anything
    /// changed. Sizes are included so a same-mtime rewrite still counts.
    private struct DatabaseSignature: Equatable {
        var databaseSize: Int64
        var databaseModified: TimeInterval
        var walSize: Int64
        var walModified: TimeInterval

        init(databasePath: String) {
            let database = Self.attributes(of: databasePath)
            let wal = Self.attributes(of: databasePath + "-wal")
            databaseSize = database.size
            databaseModified = database.modified
            walSize = wal.size
            walModified = wal.modified
        }

        private static func attributes(of path: String) -> (size: Int64, modified: TimeInterval) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
                return (0, 0)
            }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return (size, modified)
        }
    }
}
