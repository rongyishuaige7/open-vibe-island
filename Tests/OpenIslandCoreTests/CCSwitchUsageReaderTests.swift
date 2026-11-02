import Foundation
import SQLite3
import Testing
@testable import OpenIslandCore

struct CCSwitchUsageReaderTests {
    /// A fixed zone and clock keep the day window independent of the host.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()
    /// 2026-01-15 12:00 in Asia/Shanghai.
    private static let now = Date(timeIntervalSince1970: 1_768_449_600)
    /// Local midnight of `now`, which is 16:00 UTC the previous day.
    private static let dayStart = 1_768_406_400

    @Test
    func defaultDatabaseLivesInCCSwitchHome() {
        #expect(CCSwitchUsageReader.defaultDatabaseURL.path == NSHomeDirectory() + "/.cc-switch/cc-switch.db")
    }

    @Test
    func sumsTodaysTokensPerAgentIncludingCache() throws {
        let url = try CCSwitchLogFixture.write([
            // Anthropic-style rows: cached tokens are not part of input_tokens.
            .init(app: "claude", input: 100, output: 50, cacheRead: 1_000, cacheCreation: 200, semantics: 2, createdAt: Self.dayStart + 1_800),
            .init(app: "claude", input: 10, output: 5, cacheRead: 0, cacheCreation: 0, semantics: 2, createdAt: Self.dayStart + 7_200),
            .init(app: "claude", input: 5, output: 2, cacheRead: 10, cacheCreation: 0, semantics: 0, createdAt: Self.dayStart + 9_000),
            // OpenAI-style rows: input_tokens already includes the cached share.
            .init(app: "codex", input: 700, output: 100, cacheRead: 600, cacheCreation: 0, semantics: 1, createdAt: Self.dayStart + 3_600),
            .init(app: "codex", input: 150, output: 10, cacheRead: 100, cacheCreation: 0, semantics: 0, createdAt: Self.dayStart + 5_400, source: "codex_session"),
            // Outside the local day, or another app.
            .init(app: "claude", input: 9_999, output: 9_999, cacheRead: 0, cacheCreation: 0, semantics: 2, createdAt: Self.dayStart - 1),
            .init(app: "codex", input: 9_999, output: 9_999, cacheRead: 0, cacheCreation: 0, semantics: 1, createdAt: Self.dayStart + 86_400),
            .init(app: "pi", input: 9_999, output: 9_999, cacheRead: 0, cacheCreation: 0, semantics: 2, createdAt: Self.dayStart + 60),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let usage = try CCSwitchUsageReader.loadToday(databaseURL: url, now: Self.now, calendar: Self.calendar)

        #expect(usage.dayStart == Date(timeIntervalSince1970: TimeInterval(Self.dayStart)))
        #expect(usage.claude == AgentTokenTotals(requestCount: 3, totalTokens: 1_382, cacheReadTokens: 1_010))
        #expect(usage.codex == AgentTokenTotals(requestCount: 2, totalTokens: 960, cacheReadTokens: 700))
    }

    @Test
    func agentWithoutRowsTodayReportsZero() throws {
        let url = try CCSwitchLogFixture.write([
            .init(app: "claude", input: 1, output: 1, cacheRead: 0, cacheCreation: 0, semantics: 2, createdAt: Self.dayStart + 60),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let usage = try CCSwitchUsageReader.loadToday(databaseURL: url, now: Self.now, calendar: Self.calendar)

        #expect(usage.claude.totalTokens == 2)
        #expect(usage.codex == .zero)
    }

    @Test
    func missingDatabaseIsReportedAsMissing() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-switch-missing-\(UUID().uuidString).db")

        #expect(throws: CCSwitchUsageError.databaseMissing) {
            try CCSwitchUsageReader.loadToday(databaseURL: url, now: Self.now, calendar: Self.calendar)
        }
    }

    @Test
    func unexpectedSchemaSurfacesTheSQLiteError() throws {
        let url = try CCSwitchLogFixture.write([], schema: "CREATE TABLE unrelated (id INTEGER PRIMARY KEY);")
        defer { try? FileManager.default.removeItem(at: url) }

        let error = #expect(throws: CCSwitchUsageError.self) {
            try CCSwitchUsageReader.loadToday(databaseURL: url, now: Self.now, calendar: Self.calendar)
        }
        guard case let .sqlite(message)? = error else {
            Issue.record("expected a SQLite error, got \(String(describing: error))")
            return
        }
        #expect(message.contains("no such table"))
    }
}

// MARK: - Fixture

/// Builds a synthetic cc-switch.db holding only the columns the reader queries.
enum CCSwitchLogFixture {
    struct Row {
        var app: String
        var input: Int
        var output: Int
        var cacheRead: Int
        var cacheCreation: Int
        var semantics: Int
        var createdAt: Int
        var source = "proxy"
    }

    static let requestLogSchema = """
        CREATE TABLE proxy_request_logs (
            id INTEGER PRIMARY KEY,
            app_type TEXT NOT NULL,
            input_tokens INTEGER NOT NULL DEFAULT 0,
            output_tokens INTEGER NOT NULL DEFAULT 0,
            cache_read_tokens INTEGER NOT NULL DEFAULT 0,
            cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL,
            data_source TEXT NOT NULL DEFAULT 'proxy',
            input_token_semantics INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX idx_request_logs_app_created_at ON proxy_request_logs (app_type, created_at DESC);
        """

    static func write(_ rows: [Row], schema: String = CCSwitchLogFixture.requestLogSchema) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-switch-fixture-\(UUID().uuidString).db")
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw NSError(domain: "CCSwitchLogFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "open failed"])
        }
        defer { sqlite3_close(db) }

        let inserts = rows.map { row in
            let values = "('\(row.app)', \(row.input), \(row.output), \(row.cacheRead), \(row.cacheCreation), \(row.createdAt), '\(row.source)', \(row.semantics))"
            return "INSERT INTO proxy_request_logs (app_type, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, created_at, data_source, input_token_semantics) VALUES \(values);"
        }
        for sql in [schema] + inserts {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "CCSwitchLogFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
            }
        }
        return url
    }
}
