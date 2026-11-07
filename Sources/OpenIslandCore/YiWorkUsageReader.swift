import Foundation
import os

/// Today's tokens YI-Work's built-in assistant spent, as recorded by the
/// backend that runs it.
public struct YiWorkUsageSnapshot: Equatable, Sendable {
    public var totals: AgentTokenTotals
    /// Conversations that consumed tokens today.
    public var activeSessionsCount: Int
    /// The data directory the numbers came from, for diagnostics.
    public var dataDirectory: URL?

    public init(
        totals: AgentTokenTotals = .zero,
        activeSessionsCount: Int = 0,
        dataDirectory: URL? = nil
    ) {
        self.totals = totals
        self.activeSessionsCount = activeSessionsCount
        self.dataDirectory = dataDirectory
    }

    public static let empty = YiWorkUsageSnapshot()

    public var isEmpty: Bool { totals.totalTokens == 0 }
}

/// Reads the token totals YI-Work's AionCore runtime keeps for its built-in
/// assistant ("管家").
///
/// That assistant is not one of the CLI backends the island already follows: it
/// writes no transcript, and the bundled backend never reports its usage to the
/// renderer. It does, however, keep one state file per conversation:
///
///     <dataDir>/aionrs-sessions/sessions/<id>/state.json
///
/// with a cumulative `total_usage` block and the time it was last written. A
/// day's numbers are therefore the deltas against the last reading, accumulated
/// over the local day — the same shape the DSH ledger uses, and the only
/// all-local source that covers this assistant.
public enum YiWorkUsageReader {
    /// Bindings the reader keeps between polls. Losing it costs at most the
    /// tokens spent since the last refresh, never a duplicate count.
    struct State: Codable, Equatable, Sendable {
        var version: Int
        var dayStart: Date
        var inputTokens: Int
        var outputTokens: Int
        var cacheReadTokens: Int
        var activeSessionIDs: [String]
        var sessions: [String: SessionTotals]
    }

    struct SessionTotals: Codable, Equatable, Sendable {
        var input: Int
        var output: Int
        var cacheRead: Int

        var total: Int { input + output }

        static func - (lhs: SessionTotals, rhs: SessionTotals) -> SessionTotals {
            SessionTotals(
                input: max(0, lhs.input - rhs.input),
                output: max(0, lhs.output - rhs.output),
                cacheRead: max(0, lhs.cacheRead - rhs.cacheRead)
            )
        }
    }

    /// The parts of `state.json` the reader needs.
    private struct SessionRecord: Decodable {
        struct Usage: Decodable {
            var inputTokens: Int?
            var outputTokens: Int?
            var cacheReadTokens: Int?
            var cacheCreationTokens: Int?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case cacheReadTokens = "cache_read_tokens"
                case cacheCreationTokens = "cache_creation_tokens"
            }
        }

        var id: String?
        var createdAt: String?
        var updatedAt: String?
        var totalUsage: Usage?

        enum CodingKeys: String, CodingKey {
            case id
            case createdAt = "created_at"
            case updatedAt = "updated_at"
            case totalUsage = "total_usage"
        }
    }

    public static var defaultStateURL: URL {
        CodexSessionStore.defaultDirectoryURL
            .appendingPathComponent("yi-work-usage.json", isDirectory: false)
    }

    /// The ledger YI-Work's frontend writes for the ACP agents it runs.
    public static var defaultLedgerURL: URL? {
        if let override = ProcessInfo.processInfo.environment["YI_WORK_USAGE_LEDGER"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: false)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".yi-work/usage/turns.jsonl", isDirectory: false)
    }

    /// Every directory YI-Work has been seen to keep its data in. The dev
    /// script and the packaged app disagree, and the user can move it with
    /// `--data-dir`, so the reader resolves rather than assumes.
    public static func candidateDataDirectories(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [
            home.appendingPathComponent("YIWorkData", isDirectory: true),
            home.appendingPathComponent(".yi-work-web-dev", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/YI-Work", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/yi-work", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/AionUi", isDirectory: true)
        ]
    }

    /// The candidate the backend wrote to most recently. A migrated install
    /// leaves its old directory behind, and the stale copy would otherwise
    /// answer with yesterday's totals.
    public static func resolveDataDirectory(
        from candidates: [URL] = candidateDataDirectories(),
        fileManager: FileManager = .default
    ) -> URL? {
        let existing = candidates.filter { fileManager.fileExists(atPath: $0.path) }
        guard existing.count > 1 else { return existing.first }

        func freshness(_ directory: URL) -> Date {
            let database = directory.appendingPathComponent("aionui-backend.db", isDirectory: false)
            if let attributes = try? fileManager.attributesOfItem(atPath: database.path),
               let modified = attributes[.modificationDate] as? Date {
                return modified
            }
            let sessions = directory.appendingPathComponent("aionrs-sessions", isDirectory: true)
            let attributes = try? fileManager.attributesOfItem(atPath: sessions.path)
            return (attributes?[.modificationDate] as? Date) ?? .distantPast
        }

        return existing.max { freshness($0) < freshness($1) }
    }

    public static var defaultDataDirectoryURL: URL? {
        if let override = ProcessInfo.processInfo.environment["YI_WORK_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return resolveDataDirectory()
    }

    /// Sums today's YI-Work usage from the two records it leaves behind: the
    /// assistant's per-conversation counters, and the ledger YI-Work's frontend
    /// writes for the ACP agents it runs (dsh, hermes, …).
    ///
    /// Best effort: a missing or half-written file only makes this round's
    /// numbers smaller, never throws.
    public static func loadToday(
        dataDirectoryURL: URL? = defaultDataDirectoryURL,
        ledgerURL: URL? = defaultLedgerURL,
        stateURL: URL = defaultStateURL,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> YiWorkUsageSnapshot {
        let assistant = loadAssistantToday(
            dataDirectoryURL: dataDirectoryURL,
            stateURL: stateURL,
            now: now,
            calendar: calendar
        )
        let ledger = loadLedgerToday(ledgerURL: ledgerURL, now: now, calendar: calendar)

        guard assistant.dataDirectory != nil || ledger.found else { return .empty }

        let conversations = assistant.sessionIDs.union(ledger.conversationIDs)
        return YiWorkUsageSnapshot(
            totals: AgentTokenTotals(
                requestCount: conversations.count,
                totalTokens: assistant.totalTokens + ledger.totalTokens,
                cacheReadTokens: assistant.cacheReadTokens + ledger.cacheReadTokens
            ),
            activeSessionsCount: conversations.count,
            dataDirectory: assistant.dataDirectory
        )
    }

    private struct AssistantToday {
        var totalTokens = 0
        var cacheReadTokens = 0
        var sessionIDs: Set<String> = []
        var dataDirectory: URL?
    }

    private struct LedgerToday: Sendable {
        var totalTokens = 0
        var cacheReadTokens = 0
        var conversationIDs: Set<String> = []
        var found = false

        static let missing = LedgerToday()
    }

    private static func loadAssistantToday(
        dataDirectoryURL: URL?,
        stateURL: URL,
        now: Date,
        calendar: Calendar
    ) -> AssistantToday {
        guard let dataDirectoryURL else { return AssistantToday() }

        let sessionsDirectory = dataDirectoryURL
            .appendingPathComponent("aionrs-sessions", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        guard let sessionDirectories = try? FileManager.default.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return AssistantToday()
        }

        return stateLock.withLock {
            let dayStart = calendar.startOfDay(for: now)
            var state = loadState(from: stateURL)
            if state.version != 1 || !calendar.isDate(state.dayStart, inSameDayAs: dayStart) {
                state = State(
                    version: 1,
                    dayStart: dayStart,
                    inputTokens: 0,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    activeSessionIDs: [],
                    sessions: state.version == 1 ? state.sessions : [:]
                )
            }

            var observed: Set<String> = []
            for directory in sessionDirectories {
                let fileURL = directory.appendingPathComponent("state.json", isDirectory: false)
                guard let data = try? Data(contentsOf: fileURL),
                      let record = try? JSONDecoder().decode(SessionRecord.self, from: data) else {
                    continue
                }

                let sessionID = record.id ?? directory.lastPathComponent
                guard !sessionID.isEmpty else { continue }
                observed.insert(sessionID)

                let current = SessionTotals(
                    input: record.totalUsage?.inputTokens ?? 0,
                    output: record.totalUsage?.outputTokens ?? 0,
                    cacheRead: record.totalUsage?.cacheReadTokens ?? 0
                )
                let known = state.sessions[sessionID]
                var delta = known.map { current - $0 } ?? current
                if known == nil,
                   let created = parseTimestamp(record.createdAt),
                   created < dayStart {
                    // A conversation that predates today: its counter already
                    // holds earlier days, so only seed the baseline.
                    delta = SessionTotals(input: 0, output: 0, cacheRead: 0)
                }
                state.sessions[sessionID] = current

                guard delta.total > 0 else { continue }
                // Only growth the backend wrote today counts toward today. A
                // restart after midnight otherwise dumps yesterday's sessions
                // into the new day.
                if let updated = parseTimestamp(record.updatedAt), updated < dayStart {
                    continue
                }

                state.inputTokens += delta.input
                state.outputTokens += delta.output
                state.cacheReadTokens += delta.cacheRead
                if !state.activeSessionIDs.contains(sessionID) {
                    state.activeSessionIDs.append(sessionID)
                }
            }

            // Drop conversations YI-Work deleted so the file cannot grow forever.
            state.sessions = state.sessions.filter { observed.contains($0.key) }
            saveState(state, to: stateURL)

            // The assistant's provider is OpenAI-shaped: `input_tokens` already
            // counts the cached ones, so adding cache again would double it.
            return AssistantToday(
                totalTokens: state.inputTokens + state.outputTokens,
                cacheReadTokens: state.cacheReadTokens,
                sessionIDs: Set(state.activeSessionIDs),
                dataDirectory: dataDirectoryURL
            )
        }
    }

    /// Sums the frontend ledger's lines for today.
    ///
    /// One line per finished turn, written by YI-Work for the ACP agents it
    /// runs. Its `semantics` field says whether `input` already counts the
    /// cached tokens: OpenAI-compatible backends include them, Anthropic-shaped
    /// ones report them separately.
    private static func loadLedgerToday(
        ledgerURL: URL?,
        now: Date,
        calendar: Calendar
    ) -> LedgerToday {
        guard let ledgerURL else { return .missing }

        let path = ledgerURL.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.intValue else {
            return .missing
        }

        let day = dayString(for: now, calendar: calendar)
        if let cached = ledgerCache.withLock({ $0[path] }),
           cached.modified == modified,
           cached.size == size,
           cached.day == day {
            return cached.totals
        }

        guard let data = try? Data(contentsOf: ledgerURL) else { return .missing }

        var totals = LedgerToday(found: true)
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let lineDay = object["day"] as? String,
                  lineDay == day else {
                continue
            }

            // The assistant's own counters already cover it; a ledger line for
            // it would count the same tokens twice.
            if let agent = object["agent"] as? [String: Any],
               let backend = (agent["backend"] as? String)?.lowercased(),
               backend == "aionrs" {
                continue
            }

            let tokens = object["tokens"] as? [String: Any] ?? [:]
            let input = intValue(tokens["input"])
            let output = intValue(tokens["output"])
            let cacheRead = intValue(tokens["cacheRead"])
            let cacheWrite = intValue(tokens["cacheWrite"])
            let semantics = (object["semantics"] as? String)?.lowercased() ?? "openai"

            totals.totalTokens += semantics == "anthropic"
                ? input + output + cacheRead + cacheWrite
                : input + output
            totals.cacheReadTokens += cacheRead

            if let conversationID = object["conversationId"] as? String, !conversationID.isEmpty {
                totals.conversationIDs.insert(conversationID)
            }
        }

        let entry = LedgerCacheEntry(modified: modified, size: size, day: day, totals: totals)
        ledgerCache.withLock { $0[path] = entry }
        return totals
    }

    static func dayString(for date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func intValue(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) ?? 0 }
        return 0
    }

    // MARK: - Persistence

    private static let stateLock = OSAllocatedUnfairLock()

    private struct LedgerCacheEntry: Sendable {
        var modified: Date
        var size: Int
        var day: String
        var totals: LedgerToday
    }

    /// Keyed by ledger path. The file is append-only, so an unchanged size and
    /// modification date means the same answer for the same day.
    private static let ledgerCache = OSAllocatedUnfairLock(initialState: [String: LedgerCacheEntry]())

    /// AionCore writes microsecond fractions ("…T14:17:33.285543Z"), which
    /// `ISO8601DateFormatter` rejects, so trim to milliseconds before parsing.
    ///
    /// The formatters are built per call: `ISO8601DateFormatter` is not
    /// `Sendable`, and a refresh parses a handful of timestamps at most.
    static func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }

        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]

        if let date = withFraction.date(from: raw) { return date }
        if let date = plain.date(from: raw) { return date }

        guard let dot = raw.firstIndex(of: "."),
              let end = raw[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }),
              dot < end else {
            return nil
        }
        let fraction = raw[raw.index(after: dot)..<end].prefix(3)
        let normalized = "\(raw[..<dot]).\(fraction)\(raw[end...])"
        return withFraction.date(from: normalized) ?? plain.date(from: normalized)
    }

    private static func loadState(from url: URL) -> State {
        guard let data = try? Data(contentsOf: url) else {
            return State(
                version: 0,
                dayStart: .distantPast,
                inputTokens: 0,
                outputTokens: 0,
                cacheReadTokens: 0,
                activeSessionIDs: [],
                sessions: [:]
            )
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let state = try? decoder.decode(State.self, from: data) else {
            return State(
                version: 0,
                dayStart: .distantPast,
                inputTokens: 0,
                outputTokens: 0,
                cacheReadTokens: 0,
                activeSessionIDs: [],
                sessions: [:]
            )
        }
        return state
    }

    private static func saveState(_ state: State, to url: URL) {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
