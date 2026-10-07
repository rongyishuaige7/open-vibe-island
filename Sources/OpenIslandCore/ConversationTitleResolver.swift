import Foundation

/// Where to read one session's conversation title.
public struct ConversationTitleRequest: Equatable, Hashable, Sendable {
    public enum Source: Equatable, Hashable, Sendable {
        /// Codex: `thread_name` in `<codexHome>/session_index.jsonl`.
        case codexIndex(codexHome: String)
        /// Claude Code: `custom-title` / `ai-title` lines in the transcript.
        case claudeTranscript(path: String)
        /// Antigravity / Gemini: `title` in `<appDataDir>/conversation_summaries.db`.
        case agyDatabase(databasePath: String)
    }

    public var sessionID: String
    public var source: Source

    public init(sessionID: String, source: Source) {
        self.sessionID = sessionID
        self.source = source
    }

    /// Requests for the sessions whose agent records a conversation title.
    public static func requests(
        for sessions: [AgentSession],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [ConversationTitleRequest] {
        sessions.compactMap { session in
            guard !session.isDemoSession else { return nil }
            switch session.tool {
            case .codex:
                let home = codexHomePath(
                    transcriptPath: session.codexMetadata?.transcriptPath,
                    environment: environment
                )
                return ConversationTitleRequest(sessionID: session.id, source: .codexIndex(codexHome: home))
            case .claudeCode:
                guard let path = session.claudeMetadata?.transcriptPath, !path.isEmpty else { return nil }
                return ConversationTitleRequest(sessionID: session.id, source: .claudeTranscript(path: path))
            case .geminiCLI:
                guard let transcriptPath = session.geminiMetadata?.transcriptPath, !transcriptPath.isEmpty,
                      let dbPath = AgySessionReader.databasePath(forTranscriptPath: transcriptPath) else {
                    return nil
                }
                return ConversationTitleRequest(sessionID: session.id, source: .agyDatabase(databasePath: dbPath))
            default:
                return nil
            }
        }
    }

    /// The Codex home that owns a rollout (`<home>/sessions/…` or
    /// `<home>/archived_sessions/…`), else `CODEX_HOME`, else `~/.codex`.
    public static func codexHomePath(
        transcriptPath: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let transcriptPath, !transcriptPath.isEmpty {
            let parents = (transcriptPath as NSString).pathComponents.dropLast()
            if let index = parents.lastIndex(where: { $0 == "sessions" || $0 == "archived_sessions" }),
               index > parents.startIndex {
                return NSString.path(withComponents: Array(parents[..<index]))
            }
        }
        if let home = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !home.isEmpty {
            return home
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
    }
}

/// Reads the conversation titles agents record for their sessions: Codex's
/// `thread_name` in `session_index.jsonl`, and Claude Code's `custom-title`
/// (set with /rename) or `ai-title` transcript lines. Results are cached per
/// file by size and modification date, so polling unchanged sessions costs
/// one `stat` each.
public final class ConversationTitleResolver: @unchecked Sendable {
    struct FileStamp: Equatable {
        var size: UInt64
        var modifiedAt: Date
    }

    private struct CodexIndexEntry {
        var stamp: FileStamp
        var titles: [String: String]
    }

    private struct ClaudeEntry {
        var stamp: FileStamp
        var customTitle: String?
        var aiTitle: String?
    }

    private struct AgyDbEntry {
        /// The database file and its `-wal`: in WAL mode new writes land in
        /// the `-wal` file, and the main file only changes on a checkpoint.
        var stamp: [FileStamp?]
        /// Every session ID read at this stamp; nil means no title yet.
        var titles: [String: String?]
    }

    static let maxTitleLength = 200
    private static let maxCodexIndexBytes = 8 * 1_024 * 1_024
    private static let customTitleMarker = Data(#""type":"custom-title""#.utf8)
    private static let aiTitleMarker = Data(#""type":"ai-title""#.utf8)

    private let claudeTailWindows: [Int]
    private let lock = NSLock()
    private var codexIndexes: [String: CodexIndexEntry] = [:]
    private var claudeTranscripts: [String: ClaudeEntry] = [:]
    private var agyDatabases: [String: AgyDbEntry] = [:]

    /// `claudeTailWindows`: byte windows read from the end of a transcript,
    /// smallest first; a larger one is tried only when no title line is found.
    public init(claudeTailWindows: [Int] = [256 * 1_024, 2 * 1_024 * 1_024]) {
        self.claudeTailWindows = claudeTailWindows
    }

    /// Title per session ID, for the requests whose agent recorded one.
    public func titles(for requests: [ConversationTitleRequest]) -> [String: String] {
        var result: [String: String] = [:]
        var codexByHome: [String: [String: String]] = [:]
        for request in requests {
            let title: String?
            switch request.source {
            case let .codexIndex(codexHome):
                if codexByHome[codexHome] == nil {
                    codexByHome[codexHome] = codexIndexTitles(codexHome: codexHome)
                }
                title = codexByHome[codexHome]?[request.sessionID]
            case let .claudeTranscript(path):
                title = claudeTitle(transcriptPath: path)
            case let .agyDatabase(databasePath):
                title = agyTitle(sessionID: request.sessionID, databasePath: databasePath)
            }
            if let title {
                result[request.sessionID] = title
            }
        }
        return result
    }

    // MARK: - Codex

    private func codexIndexTitles(codexHome: String) -> [String: String] {
        let path = (codexHome as NSString).appendingPathComponent("session_index.jsonl")
        guard let stamp = Self.stamp(path) else { return [:] }
        if let cached = lock.withLock({ codexIndexes[path] }), cached.stamp == stamp {
            return cached.titles
        }
        let titles = Self.readTail(path: path, maxBytes: Self.maxCodexIndexBytes)
            .map(Self.parseCodexIndex) ?? [:]
        lock.withLock { codexIndexes[path] = CodexIndexEntry(stamp: stamp, titles: titles) }
        return titles
    }

    /// Latest `thread_name` per `id`. Codex appends a line on every rename, so
    /// the newest `updated_at` wins; file order breaks ties.
    static func parseCodexIndex(_ data: Data) -> [String: String] {
        var latest: [String: (title: String, updatedAt: String)] = [:]
        for line in lines(of: data) {
            guard let object = jsonObject(line),
                  let id = object["id"] as? String, !id.isEmpty,
                  let title = sanitizedTitle(object["thread_name"] as? String) else {
                continue
            }
            let updatedAt = object["updated_at"] as? String ?? ""
            if let existing = latest[id], existing.updatedAt > updatedAt {
                continue
            }
            latest[id] = (title, updatedAt)
        }
        return latest.mapValues { $0.title }
    }

    // MARK: - Claude Code

    private func claudeTitle(transcriptPath path: String) -> String? {
        guard let stamp = Self.stamp(path) else { return nil }
        let cached = lock.withLock { claudeTranscripts[path] }
        if let cached, cached.stamp == stamp {
            return cached.customTitle ?? cached.aiTitle
        }

        var found: (custom: String?, ai: String?) = (nil, nil)
        for window in claudeTailWindows {
            if let data = Self.readTail(path: path, maxBytes: window) {
                found = Self.latestClaudeTitles(in: data)
            }
            if found.custom != nil || found.ai != nil || UInt64(window) >= stamp.size {
                break
            }
        }

        // Title lines are appended, so when the file only grew, a title that
        // scrolled out of every window is still the latest one; keep it.
        let grew = cached.map { stamp.size >= $0.stamp.size } ?? false
        let entry = ClaudeEntry(
            stamp: stamp,
            customTitle: found.custom ?? (grew ? cached?.customTitle : nil),
            aiTitle: found.ai ?? (grew ? cached?.aiTitle : nil)
        )
        lock.withLock { claudeTranscripts[path] = entry }
        return entry.customTitle ?? entry.aiTitle
    }

    /// Latest `custom-title` and `ai-title` in a chunk of transcript JSONL.
    static func latestClaudeTitles(in data: Data) -> (custom: String?, ai: String?) {
        var custom: String?
        var ai: String?
        var sawCustom = false
        var sawAI = false
        for line in lines(of: data).reversed() {
            if sawCustom && sawAI { break }
            if !sawCustom, line.range(of: customTitleMarker) != nil,
               let object = jsonObject(line), object["type"] as? String == "custom-title" {
                sawCustom = true
                custom = sanitizedTitle(object["customTitle"] as? String)
            } else if !sawAI, line.range(of: aiTitleMarker) != nil,
                      let object = jsonObject(line), object["type"] as? String == "ai-title" {
                sawAI = true
                ai = sanitizedTitle(object["aiTitle"] as? String)
            }
        }
        return (custom, ai)
    }

    // MARK: - Antigravity / Gemini

    private func agyTitle(sessionID: String, databasePath: String) -> String? {
        guard let databaseStamp = Self.stamp(databasePath) else { return nil }
        let stamp = [databaseStamp, Self.stamp(databasePath + "-wal")]
        // Each session is read once per stamp; another session in the same
        // database is not covered by a cached entry until it has been read.
        if let cached = lock.withLock({ agyDatabases[databasePath] }), cached.stamp == stamp,
           let title = cached.titles[sessionID] {
            return title
        }

        let title = AgySessionReader.fetchTitle(sessionID: sessionID, databasePath: databasePath)
            .flatMap(Self.sanitizedTitle)
        lock.withLock {
            var entry = agyDatabases[databasePath]
            if entry?.stamp != stamp {
                entry = AgyDbEntry(stamp: stamp, titles: [:])
            }
            entry?.titles.updateValue(title, forKey: sessionID)
            agyDatabases[databasePath] = entry
        }
        return title
    }

    // MARK: - Helpers

    static func lines(of data: Data) -> [Data] {
        data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).map { Data($0) }
    }

    static func jsonObject(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    /// The last `maxBytes` of a file, starting at a line boundary.
    static func readTail(path: String, maxBytes: Int) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              var data = try? handle.readToEnd() else {
            return nil
        }
        if start > 0 {
            guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { return Data() }
            data = Data(data[data.index(after: newline)...])
        }
        return data
    }

    private static func stamp(_ path: String) -> FileStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modifiedAt = attributes[.modificationDate] as? Date else {
            return nil
        }
        return FileStamp(size: size, modifiedAt: modifiedAt)
    }

    /// One line of at most `maxTitleLength` characters, or nil when blank.
    static func sanitizedTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count > maxTitleLength ? String(collapsed.prefix(maxTitleLength)) : collapsed
    }
}
