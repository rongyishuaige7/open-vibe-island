import Foundation
import SQLite3

/// One PI Desktop conversation as it exists in `~/.pi-desktop/pi.sqlite`.
///
/// PI Desktop hosts every conversation inside one Electron process, so there is
/// no per-session process to discover and no per-session hook to call. The
/// database is the only source that knows about all of them at once.
public struct PiDesktopSessionRecord: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var projectPath: String?
    public var workspaceName: String?
    public var providerID: String?
    public var modelID: String?
    /// `agent` or `chat`; PI Desktop stores the shell mode verbatim.
    public var mode: String
    /// `ask`, `accept-edits`, `auto`, or `inherit`.
    public var permissionMode: String
    /// PI Desktop's `title_source`: legacy | default | manual | generated.
    public var titleSource: String
    public var messageCount: Int
    /// Tool name of the most recent tool message, e.g. `Bash` or `Read`.
    public var currentTool: String?
    /// First line of the most recent assistant reply, clipped for the island.
    public var lastAssistantLine: String?
    public var phase: SessionPhase
    public var activeTurnID: String?
    public var todoCompleted: Int
    public var todoTotal: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        title: String,
        projectPath: String? = nil,
        workspaceName: String? = nil,
        providerID: String? = nil,
        modelID: String? = nil,
        mode: String = "agent",
        permissionMode: String = "inherit",
        titleSource: String = "legacy",
        messageCount: Int = 0,
        currentTool: String? = nil,
        lastAssistantLine: String? = nil,
        phase: SessionPhase = .completed,
        activeTurnID: String? = nil,
        todoCompleted: Int = 0,
        todoTotal: Int = 0,
        createdAt: Date = .distantPast,
        updatedAt: Date = .distantPast
    ) {
        self.id = id
        self.title = title
        self.projectPath = projectPath
        self.workspaceName = workspaceName
        self.providerID = providerID
        self.modelID = modelID
        self.mode = mode
        self.permissionMode = permissionMode
        self.titleSource = titleSource
        self.messageCount = messageCount
        self.currentTool = currentTool
        self.lastAssistantLine = lastAssistantLine
        self.phase = phase
        self.activeTurnID = activeTurnID
        self.todoCompleted = todoCompleted
        self.todoTotal = todoTotal
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// One PI Desktop turn and the counters it recorded.
///
/// `usage_json` carries an aggregate object whose top-level counters already
/// include every entry in `operations`; summing both would double count.
public struct PiDesktopTurnUsage: Equatable, Sendable, Identifiable {
    public var id: String
    public var sessionID: String
    public var status: String
    public var modelID: String?
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var reasoningTokens: Int
    public var startedAt: Date
    public var endedAt: Date?

    public var totalTokens: Int {
        inputTokens + outputTokens
    }

    public init(
        id: String,
        sessionID: String,
        status: String,
        modelID: String? = nil,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        reasoningTokens: Int = 0,
        startedAt: Date,
        endedAt: Date? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.status = status
        self.modelID = modelID
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.reasoningTokens = reasoningTokens
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

public enum PiDesktopStoreError: Error, Equatable, LocalizedError {
    case databaseMissing(String)
    /// PI Desktop migrates its schema with the app version. A different number
    /// means our SELECT list may no longer line up, so callers degrade to
    /// "app is running" instead of showing wrong sessions.
    case unsupportedSchema(found: Int32, expected: Int32)
    case sqlite(String)

    public var errorDescription: String? {
        switch self {
        case let .databaseMissing(path):
            "PI Desktop's database was not found at \(path)."
        case let .unsupportedSchema(found, expected):
            "PI Desktop schema \(found) is not supported (expected \(expected))."
        case let .sqlite(message):
            "PI Desktop database read failed: \(message)"
        }
    }
}

/// Read-only view of PI Desktop's SQLite store.
///
/// The app keeps the database in WAL mode and writes continuously; readers use
/// a plain READONLY connection so they see committed rows without blocking the
/// writer (see `SQLiteReadOnly` for why `immutable=1` is only a fallback).
public struct PiDesktopSessionStore: Sendable {
    /// Bump when PI Desktop ships a schema whose columns we have re-verified.
    public static let supportedSchemaVersion: Int32 = 24
    /// Upper bound for one poll so a pathological table cannot stall the app.
    public static let sessionLimit = 50

    public static var defaultDatabasePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi-desktop/pi.sqlite")
            .path
    }

    public var databasePath: String

    public init(databasePath: String = PiDesktopSessionStore.defaultDatabasePath) {
        self.databasePath = databasePath
    }

    public var databaseExists: Bool {
        FileManager.default.fileExists(atPath: databasePath)
    }

    public func loadSessions(limit: Int = PiDesktopSessionStore.sessionLimit) -> Result<[PiDesktopSessionRecord], PiDesktopStoreError> {
        guard databaseExists else {
            return .failure(.databaseMissing(databasePath))
        }

        return withDatabase { db in
            try Self.validateSchema(db)

            let sql = """
                SELECT
                    s.id,
                    s.title,
                    s.provider_id,
                    s.model_id,
                    s.mode,
                    s.permission_mode,
                    s.created_at,
                    s.updated_at,
                    p.path,
                    p.name,
                    (SELECT COUNT(*) FROM messages m WHERE m.session_id = s.id),
                    (SELECT m.tool_name FROM messages m
                        WHERE m.session_id = s.id AND m.role = 'tool' AND m.tool_name IS NOT NULL
                        ORDER BY m.seq DESC LIMIT 1),
                    (SELECT m.text FROM messages m
                        WHERE m.session_id = s.id AND m.role = 'assistant' AND m.text IS NOT NULL
                        ORDER BY m.seq DESC LIMIT 1),
                    (SELECT t.id FROM turns t
                        WHERE t.session_id = s.id AND t.status = 'running'
                        ORDER BY t.started_at DESC LIMIT 1),
                    (SELECT COUNT(*) FROM session_todo d WHERE d.session_id = s.id),
                    (SELECT COUNT(*) FROM session_todo d WHERE d.session_id = s.id AND d.status = 'completed'),
                    s.title_source
                FROM sessions s
                LEFT JOIN projects p ON p.id = s.project_id
                WHERE s.deleted_at IS NULL
                ORDER BY s.updated_at DESC
                LIMIT ?
                """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw PiDesktopStoreError.sqlite(Self.lastErrorMessage(db))
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(max(1, limit)))

            var records: [PiDesktopSessionRecord] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE {
                    break
                }
                guard step == SQLITE_ROW else {
                    throw PiDesktopStoreError.sqlite(Self.lastErrorMessage(db))
                }

                let activeTurnID = Self.string(statement, 13)
                records.append(
                    PiDesktopSessionRecord(
                        id: Self.string(statement, 0) ?? "",
                        title: Self.string(statement, 1) ?? "",
                        projectPath: Self.string(statement, 8),
                        workspaceName: Self.string(statement, 9),
                        providerID: Self.string(statement, 2),
                        modelID: Self.string(statement, 3),
                        mode: Self.string(statement, 4) ?? "agent",
                        permissionMode: Self.string(statement, 5) ?? "inherit",
                        titleSource: Self.string(statement, 16) ?? "legacy",
                        messageCount: Self.int(statement, 10),
                        currentTool: Self.string(statement, 11),
                        lastAssistantLine: Self.clipFirstLine(Self.string(statement, 12)),
                        phase: activeTurnID == nil ? .completed : .running,
                        activeTurnID: activeTurnID,
                        todoCompleted: Self.int(statement, 15),
                        todoTotal: Self.int(statement, 14),
                        createdAt: Self.date(statement, 6),
                        updatedAt: Self.date(statement, 7)
                    )
                )
            }
            return records
        }
    }

    /// Turns started inside `[from, to)`, using PI Desktop's millisecond epoch.
    public func loadTurns(from: Date, to: Date) -> Result<[PiDesktopTurnUsage], PiDesktopStoreError> {
        guard databaseExists else {
            return .failure(.databaseMissing(databasePath))
        }

        return withDatabase { db in
            try Self.validateSchema(db)

            let sql = """
                SELECT id, session_id, status, model_id, input_tokens, output_tokens,
                       usage_json, started_at, ended_at
                FROM turns
                WHERE started_at >= ? AND started_at < ?
                ORDER BY started_at ASC
                """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw PiDesktopStoreError.sqlite(Self.lastErrorMessage(db))
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, Self.milliseconds(from: from))
            sqlite3_bind_int64(statement, 2, Self.milliseconds(from: to))

            var turns: [PiDesktopTurnUsage] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE {
                    break
                }
                guard step == SQLITE_ROW else {
                    throw PiDesktopStoreError.sqlite(Self.lastErrorMessage(db))
                }

                let usage = Self.counterUsage(fromJSON: Self.string(statement, 6))
                turns.append(
                    PiDesktopTurnUsage(
                        id: Self.string(statement, 0) ?? "",
                        sessionID: Self.string(statement, 1) ?? "",
                        status: Self.string(statement, 2) ?? "unknown",
                        modelID: Self.string(statement, 3),
                        inputTokens: usage?.input ?? Self.int(statement, 4),
                        outputTokens: usage?.output ?? Self.int(statement, 5),
                        cacheReadTokens: usage?.cacheRead ?? 0,
                        reasoningTokens: usage?.reasoning ?? 0,
                        startedAt: Self.date(statement, 7),
                        endedAt: Self.optionalDate(statement, 8)
                    )
                )
            }
            return turns
        }
    }

    /// Current `PRAGMA user_version`, or nil when the file is missing/unreadable.
    public func schemaVersion() -> Int32? {
        guard databaseExists else {
            return nil
        }
        switch withDatabase({ db in try Self.validateSchema(db) }) {
        case .success:
            return Self.supportedSchemaVersion
        case let .failure(error):
            if case let .unsupportedSchema(found, _) = error {
                return found
            }
            return nil
        }
    }

    // MARK: - Database plumbing

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) -> Result<T, PiDesktopStoreError> {
        switch SQLiteReadOnly.open(path: databasePath, busyTimeoutMilliseconds: 200) {
        case let .failure(error):
            return .failure(.sqlite(error.message))
        case let .success(db):
            defer { sqlite3_close(db) }
            do {
                return .success(try body(db))
            } catch let error as PiDesktopStoreError {
                return .failure(error)
            } catch {
                return .failure(.sqlite(String(describing: error)))
            }
        }
    }

    private static func validateSchema(_ db: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw PiDesktopStoreError.sqlite(lastErrorMessage(db))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw PiDesktopStoreError.sqlite(lastErrorMessage(db))
        }
        let version = sqlite3_column_int(statement, 0)
        guard version == supportedSchemaVersion else {
            throw PiDesktopStoreError.unsupportedSchema(found: version, expected: supportedSchemaVersion)
        }
    }

    private static func lastErrorMessage(_ db: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(db))
    }

    // MARK: - Column helpers

    private static func string(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: text)
    }

    private static func int(_ statement: OpaquePointer, _ index: Int32) -> Int {
        Int(sqlite3_column_int64(statement, index))
    }

    private static func date(_ statement: OpaquePointer, _ index: Int32) -> Date {
        optionalDate(statement, index) ?? .distantPast
    }

    private static func optionalDate(_ statement: OpaquePointer, _ index: Int32) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        let milliseconds = sqlite3_column_int64(statement, index)
        guard milliseconds > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }

    private static func milliseconds(from date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// The island shows one line; replies can be long and may contain markdown.
    static func clipFirstLine(_ text: String?, limit: Int = 120) -> String? {
        guard let text else {
            return nil
        }
        let firstLine = text
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstLine, !firstLine.isEmpty else {
            return nil
        }
        return firstLine.count <= limit ? firstLine : String(firstLine.prefix(limit)) + "…"
    }

    struct CounterUsage {
        var input: Int
        var output: Int
        var cacheRead: Int
        var reasoning: Int
    }

    /// Reads the aggregate counters from `usage_json`.
    ///
    /// The object is `{"aggregation":"aggregate", "inputTokens":…, "operations":[…]}`;
    /// top-level counters already sum the operations, so only the top level is read.
    static func counterUsage(fromJSON json: String?) -> CounterUsage? {
        guard let json,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        func value(_ key: String) -> Int? {
            switch object[key] {
            case let number as NSNumber:
                return number.intValue
            case let string as String:
                return Int(string)
            default:
                return nil
            }
        }
        guard let input = value("inputTokens"), let output = value("outputTokens") else {
            return nil
        }
        return CounterUsage(
            input: input,
            output: output,
            cacheRead: value("cacheReadTokens") ?? 0,
            reasoning: value("reasoningTokens") ?? 0
        )
    }
}
