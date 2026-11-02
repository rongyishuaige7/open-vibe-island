import Foundation
import SQLite3
import Testing
@testable import OpenIslandCore

/// Builds throwaway PI Desktop databases with the subset of schema v24 that
/// `PiDesktopSessionStore` reads.
enum PiDesktopFixture {
    struct SessionSeed {
        var id: String
        var title: String
        var projectID: Int64?
        var providerID: String?
        var modelID: String?
        var mode: String
        var permissionMode: String
        var createdAt: Int64
        var updatedAt: Int64
        var deletedAt: Int64?
        var messages: [MessageSeed] = []
        var todos: [(content: String, status: String)] = []
        var turns: [TurnSeed] = []
    }

    struct MessageSeed {
        var seq: Int64
        var role: String
        var toolName: String?
        var text: String?
    }

    struct TurnSeed {
        var id: String
        var status: String
        var modelID: String?
        var inputTokens: Int64
        var outputTokens: Int64
        var usageJSON: String?
        var startedAt: Int64
        var endedAt: Int64?
    }

    static func databasePath() -> String {
        NSTemporaryDirectory() + "pi-desktop-fixture-\(UUID().uuidString).sqlite"
    }

    @discardableResult
    static func write(
        to path: String,
        schemaVersion: Int32 = 24,
        journalModeWAL: Bool = false,
        projects: [(id: Int64, path: String, name: String)] = [],
        sessions: [SessionSeed] = []
    ) throws -> String {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let db else {
            throw FixtureError.openFailed
        }
        defer { sqlite3_close(db) }

        if journalModeWAL {
            try exec(db, "PRAGMA journal_mode=WAL;")
        }
        try exec(db, "PRAGMA user_version=\(schemaVersion);")
        try exec(db, schema)

        for project in projects {
            var statement: OpaquePointer?
            try prepare(db, "INSERT INTO projects (id, path, name, created_at, last_opened_at) VALUES (?, ?, ?, 0, 0);", &statement)
            sqlite3_bind_int64(statement, 1, project.id)
            bind(statement, 2, project.path)
            bind(statement, 3, project.name)
            try step(db, statement)
        }

        for session in sessions {
            var statement: OpaquePointer?
            try prepare(
                db,
                """
                INSERT INTO sessions (id, title, project_id, provider_id, model_id, mode, permission_mode,
                                      created_at, updated_at, deleted_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """,
                &statement
            )
            bind(statement, 1, session.id)
            bind(statement, 2, session.title)
            if let projectID = session.projectID {
                sqlite3_bind_int64(statement, 3, projectID)
            } else {
                sqlite3_bind_null(statement, 3)
            }
            bind(statement, 4, session.providerID)
            bind(statement, 5, session.modelID)
            bind(statement, 6, session.mode)
            bind(statement, 7, session.permissionMode)
            sqlite3_bind_int64(statement, 8, session.createdAt)
            sqlite3_bind_int64(statement, 9, session.updatedAt)
            if let deletedAt = session.deletedAt {
                sqlite3_bind_int64(statement, 10, deletedAt)
            } else {
                sqlite3_bind_null(statement, 10)
            }
            try step(db, statement)

            for message in session.messages {
                var messageStatement: OpaquePointer?
                try prepare(
                    db,
                    "INSERT INTO messages (id, session_id, seq, role, tool_name, text, created_at) VALUES (?, ?, ?, ?, ?, ?, 0);",
                    &messageStatement
                )
                bind(messageStatement, 1, "\(session.id)-\(message.seq)")
                bind(messageStatement, 2, session.id)
                sqlite3_bind_int64(messageStatement, 3, message.seq)
                bind(messageStatement, 4, message.role)
                bind(messageStatement, 5, message.toolName)
                bind(messageStatement, 6, message.text)
                try step(db, messageStatement)
            }

            for (index, todo) in session.todos.enumerated() {
                var todoStatement: OpaquePointer?
                try prepare(
                    db,
                    "INSERT INTO session_todo (session_id, position, content, status, updated_at) VALUES (?, ?, ?, ?, 0);",
                    &todoStatement
                )
                bind(todoStatement, 1, session.id)
                sqlite3_bind_int64(todoStatement, 2, Int64(index))
                bind(todoStatement, 3, todo.content)
                bind(todoStatement, 4, todo.status)
                try step(db, todoStatement)
            }

            for turn in session.turns {
                var turnStatement: OpaquePointer?
                try prepare(
                    db,
                    """
                    INSERT INTO turns (id, session_id, status, model_id, input_tokens, output_tokens,
                                       usage_json, started_at, ended_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """,
                    &turnStatement
                )
                bind(turnStatement, 1, turn.id)
                bind(turnStatement, 2, session.id)
                bind(turnStatement, 3, turn.status)
                bind(turnStatement, 4, turn.modelID)
                sqlite3_bind_int64(turnStatement, 5, turn.inputTokens)
                sqlite3_bind_int64(turnStatement, 6, turn.outputTokens)
                bind(turnStatement, 7, turn.usageJSON)
                sqlite3_bind_int64(turnStatement, 8, turn.startedAt)
                if let endedAt = turn.endedAt {
                    sqlite3_bind_int64(turnStatement, 9, endedAt)
                } else {
                    sqlite3_bind_null(turnStatement, 9)
                }
                try step(db, turnStatement)
            }
        }

        return path
    }

    private static let schema = """
        CREATE TABLE projects (
            id INTEGER PRIMARY KEY,
            path TEXT NOT NULL UNIQUE,
            name TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            last_opened_at INTEGER NOT NULL
        );
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL DEFAULT '',
            project_id INTEGER REFERENCES projects(id) ON DELETE SET NULL,
            provider_id TEXT,
            model_id TEXT,
            mode TEXT NOT NULL DEFAULT 'agent',
            permission_mode TEXT NOT NULL DEFAULT 'inherit',
            source TEXT,
            deleted_at INTEGER,
            pinned INTEGER NOT NULL DEFAULT 0,
            last_seq INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        );
        CREATE TABLE turns (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            status TEXT NOT NULL DEFAULT 'running',
            model_id TEXT,
            input_tokens INTEGER NOT NULL DEFAULT 0,
            output_tokens INTEGER NOT NULL DEFAULT 0,
            usage_json TEXT,
            started_at INTEGER NOT NULL,
            ended_at INTEGER
        );
        CREATE TABLE messages (
            mid INTEGER PRIMARY KEY,
            id TEXT NOT NULL UNIQUE,
            session_id TEXT NOT NULL,
            seq INTEGER NOT NULL,
            role TEXT NOT NULL,
            tool_name TEXT,
            text TEXT,
            created_at INTEGER NOT NULL,
            UNIQUE (session_id, seq)
        );
        CREATE TABLE session_todo (
            session_id TEXT NOT NULL,
            position INTEGER NOT NULL,
            content TEXT NOT NULL,
            status TEXT NOT NULL,
            updated_at INTEGER NOT NULL,
            PRIMARY KEY (session_id, position)
        );
        """

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(error)
            throw FixtureError.sqlite(message)
        }
    }

    private static func prepare(_ db: OpaquePointer, _ sql: String, _ statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw FixtureError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, transient)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private static func step(_ db: OpaquePointer, _ statement: OpaquePointer?) throws {
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw FixtureError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    enum FixtureError: Error {
        case openFailed
        case sqlite(String)
    }
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct PiDesktopSessionStoreTests {
    @Test
    func loadsSessionsWithDerivedActivity() throws {
        let path = PiDesktopFixture.databasePath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try PiDesktopFixture.write(
            to: path,
            projects: [(1, "/Users/u/open-island", "open-island")],
            sessions: [
                .init(
                    id: "s1",
                    title: "修复跳转",
                    projectID: 1,
                    providerID: "p1",
                    modelID: "cn:deepseek-v4.1-flash",
                    mode: "agent",
                    permissionMode: "auto",
                    createdAt: 1_000,
                    updatedAt: 2_000,
                    messages: [
                        .init(seq: 1, role: "user", toolName: nil, text: "跑一下测试"),
                        .init(seq: 2, role: "tool", toolName: "Bash", text: nil),
                        .init(seq: 3, role: "assistant", toolName: nil, text: "测试通过。\n另外还有一段说明。")
                    ],
                    todos: [
                        ("先跑测试", "completed"),
                        ("再改文档", "pending")
                    ],
                    turns: [
                        .init(id: "t1", status: "running", modelID: "cn:deepseek", inputTokens: 10, outputTokens: 20, usageJSON: nil, startedAt: 2_000, endedAt: nil)
                    ]
                )
            ]
        )

        let store = PiDesktopSessionStore(databasePath: path)
        let records = try sessions(from: store)

        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(record.id == "s1")
        #expect(record.title == "修复跳转")
        #expect(record.projectPath == "/Users/u/open-island")
        #expect(record.workspaceName == "open-island")
        #expect(record.currentTool == "Bash")
        #expect(record.lastAssistantLine == "测试通过。")
        #expect(record.phase == .running)
        #expect(record.activeTurnID == "t1")
        #expect(record.todoCompleted == 1)
        #expect(record.todoTotal == 2)
        #expect(record.messageCount == 3)
        #expect(record.createdAt == Date(timeIntervalSince1970: 1))
        #expect(record.updatedAt == Date(timeIntervalSince1970: 2))
    }

    @Test
    func hidesDeletedSessionsAndReportsIdlePhase() throws {
        let path = PiDesktopFixture.databasePath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try PiDesktopFixture.write(
            to: path,
            sessions: [
                .init(id: "gone", title: "已删除", projectID: nil, providerID: nil, modelID: nil, mode: "agent", permissionMode: "auto", createdAt: 1, updatedAt: 2, deletedAt: 3),
                .init(id: "idle", title: "闲聊", projectID: nil, providerID: nil, modelID: nil, mode: "chat", permissionMode: "inherit", createdAt: 1, updatedAt: 2, deletedAt: nil)
            ]
        )

        let records = try sessions(from: PiDesktopSessionStore(databasePath: path))
        #expect(records.map(\.id) == ["idle"])
        #expect(records.first?.phase == .completed)
        #expect(records.first?.activeTurnID == nil)
    }

    @Test
    func ordersByRecencyAndRespectsLimit() throws {
        let path = PiDesktopFixture.databasePath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try PiDesktopFixture.write(
            to: path,
            sessions: [
                .init(id: "old", title: "旧", projectID: nil, providerID: nil, modelID: nil, mode: "agent", permissionMode: "auto", createdAt: 1, updatedAt: 10, deletedAt: nil),
                .init(id: "new", title: "新", projectID: nil, providerID: nil, modelID: nil, mode: "agent", permissionMode: "auto", createdAt: 1, updatedAt: 30, deletedAt: nil),
                .init(id: "mid", title: "中", projectID: nil, providerID: nil, modelID: nil, mode: "agent", permissionMode: "auto", createdAt: 1, updatedAt: 20, deletedAt: nil)
            ]
        )

        let store = PiDesktopSessionStore(databasePath: path)
        #expect(try sessions(from: store).map(\.id) == ["new", "mid", "old"])
        #expect(try sessions(from: store, limit: 2).map(\.id) == ["new", "mid"])
    }

    @Test
    func reportsUnsupportedSchema() throws {
        let path = PiDesktopFixture.databasePath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try PiDesktopFixture.write(to: path, schemaVersion: 23)

        let store = PiDesktopSessionStore(databasePath: path)
        switch store.loadSessions() {
        case let .failure(error):
            #expect(error == .unsupportedSchema(found: 23, expected: 24))
        case .success:
            Issue.record("expected an unsupported-schema failure")
        }
        #expect(store.schemaVersion() == 23)
    }

    @Test
    func reportsMissingDatabase() {
        let store = PiDesktopSessionStore(databasePath: "/nonexistent/pi-desktop-\(UUID().uuidString).sqlite")
        switch store.loadSessions() {
        case let .failure(error):
            if case .databaseMissing = error {} else {
                Issue.record("expected databaseMissing, got \(error)")
            }
        case .success:
            Issue.record("expected a missing-database failure")
        }
    }

    @Test
    func readsAggregateUsageWithoutDoubleCountingOperations() throws {
        let path = PiDesktopFixture.databasePath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let usage = """
            {"aggregation":"aggregate","inputTokens":6521,"outputTokens":9104,
             "cacheReadTokens":630400,"reasoningTokens":1009,
             "operations":[{"inputTokens":6521,"outputTokens":9104}]}
            """
        try PiDesktopFixture.write(
            to: path,
            sessions: [
                .init(
                    id: "s1", title: "会话", projectID: nil, providerID: nil, modelID: nil,
                    mode: "agent", permissionMode: "auto", createdAt: 0, updatedAt: 0, deletedAt: nil,
                    turns: [
                        .init(id: "t1", status: "completed", modelID: "cn:deepseek", inputTokens: 0, outputTokens: 0, usageJSON: usage, startedAt: 1_000, endedAt: 2_000)
                    ]
                )
            ]
        )

        let turns = try turnUsage(from: PiDesktopSessionStore(databasePath: path))
        let turn = try #require(turns.first)
        #expect(turn.inputTokens == 6521)
        #expect(turn.outputTokens == 9104)
        #expect(turn.cacheReadTokens == 630_400)
        #expect(turn.reasoningTokens == 1009)
        #expect(turn.totalTokens == 15_625)
        #expect(turn.startedAt == Date(timeIntervalSince1970: 1))
        #expect(turn.endedAt == Date(timeIntervalSince1970: 2))
    }

    @Test
    func fallsBackToColumnsWhenUsageJSONIsUnusable() throws {
        let path = PiDesktopFixture.databasePath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try PiDesktopFixture.write(
            to: path,
            sessions: [
                .init(
                    id: "s1", title: "会话", projectID: nil, providerID: nil, modelID: nil,
                    mode: "agent", permissionMode: "auto", createdAt: 0, updatedAt: 0, deletedAt: nil,
                    turns: [
                        .init(id: "t1", status: "completed", modelID: nil, inputTokens: 11, outputTokens: 22, usageJSON: nil, startedAt: 1_000, endedAt: 2_000),
                        .init(id: "t2", status: "error", modelID: nil, inputTokens: 33, outputTokens: 44, usageJSON: "{not json", startedAt: 3_000, endedAt: 4_000)
                    ]
                )
            ]
        )

        let turns = try turnUsage(from: PiDesktopSessionStore(databasePath: path))
        #expect(turns.map(\.id) == ["t1", "t2"])
        #expect(turns.map(\.inputTokens) == [11, 33])
        #expect(turns.map(\.cacheReadTokens) == [0, 0])
    }

    @Test
    func filtersTurnsByStartWindow() throws {
        let path = PiDesktopFixture.databasePath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try PiDesktopFixture.write(
            to: path,
            sessions: [
                .init(
                    id: "s1", title: "会话", projectID: nil, providerID: nil, modelID: nil,
                    mode: "agent", permissionMode: "auto", createdAt: 0, updatedAt: 0, deletedAt: nil,
                    turns: [
                        .init(id: "before", status: "completed", modelID: nil, inputTokens: 1, outputTokens: 1, usageJSON: nil, startedAt: 1_000, endedAt: nil),
                        .init(id: "inside", status: "completed", modelID: nil, inputTokens: 1, outputTokens: 1, usageJSON: nil, startedAt: 5_000, endedAt: nil),
                        .init(id: "after", status: "completed", modelID: nil, inputTokens: 1, outputTokens: 1, usageJSON: nil, startedAt: 9_000, endedAt: nil)
                    ]
                )
            ]
        )

        let turns = try turnUsage(
            from: PiDesktopSessionStore(databasePath: path),
            from: Date(timeIntervalSince1970: 2),
            to: Date(timeIntervalSince1970: 8)
        )
        #expect(turns.map(\.id) == ["inside"])
    }

    @Test
    func seesRowsCommittedByAnOpenWriter() throws {
        let path = PiDesktopFixture.databasePath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try PiDesktopFixture.write(to: path, journalModeWAL: true)

        // Hold a writer open the way PI Desktop does, then insert a session.
        var writer: OpaquePointer?
        #expect(sqlite3_open_v2(path, &writer, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        defer { sqlite3_close(writer) }
        #expect(sqlite3_exec(writer, "INSERT INTO sessions (id, title, created_at, updated_at) VALUES ('live', '实时', 1, 2);", nil, nil, nil) == SQLITE_OK)

        let records = try sessions(from: PiDesktopSessionStore(databasePath: path))
        #expect(records.map(\.id) == ["live"])
    }

    @Test
    func clipsLongAssistantRepliesToASingleLine() {
        #expect(PiDesktopSessionStore.clipFirstLine(nil) == nil)
        #expect(PiDesktopSessionStore.clipFirstLine("   ") == nil)
        #expect(PiDesktopSessionStore.clipFirstLine("第一行\n第二行") == "第一行")
        let long = String(repeating: "a", count: 200)
        let clipped = PiDesktopSessionStore.clipFirstLine(long)
        #expect(clipped?.count == 121)
        #expect(clipped?.hasSuffix("…") == true)
    }

    // MARK: - Helpers

    private func sessions(
        from store: PiDesktopSessionStore,
        limit: Int = PiDesktopSessionStore.sessionLimit
    ) throws -> [PiDesktopSessionRecord] {
        switch store.loadSessions(limit: limit) {
        case let .success(records):
            return records
        case let .failure(error):
            throw error
        }
    }

    private func turnUsage(
        from store: PiDesktopSessionStore,
        from start: Date = Date(timeIntervalSince1970: 0),
        to end: Date = Date(timeIntervalSince1970: 100_000)
    ) throws -> [PiDesktopTurnUsage] {
        switch store.loadTurns(from: start, to: end) {
        case let .success(turns):
            return turns
        case let .failure(error):
            throw error
        }
    }
}
