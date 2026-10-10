import Foundation
import SQLite3
import Testing
@testable import OpenIslandCore

struct KeeperUsageReaderTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()
    /// 2026-10-05 12:00 in Asia/Shanghai.
    private static let now = Date(timeIntervalSince1970: 1_791_172_800)

    @Test
    func defaultDatabasePathPointsToKeeper() {
        #expect(KeeperUsageReader.defaultDatabaseURL.path == "/opt/homebrew/var/cpa-usage-keeper/app.db")
    }

    @Test
    func missingDatabaseThrowsError() {
        let nonexistentURL = URL(fileURLWithPath: "/nonexistent/test-app.db")
        #expect(throws: KeeperUsageError.databaseMissing) {
            try KeeperUsageReader.loadToday(databaseURL: nonexistentURL, now: Self.now, calendar: Self.calendar)
        }
    }

    @Test
    func sumsTodayAntigravityPoolAndProTokens() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let dbURL = tempDir.appendingPathComponent("test-keeper-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        var handle: OpaquePointer?
        guard sqlite3_open(dbURL.path, &handle) == SQLITE_OK, let db = handle else {
            fatalError("Failed to open test db")
        }
        defer { sqlite3_close(db) }

        let schema = """
            CREATE TABLE usage_identities (
                id INTEGER PRIMARY KEY,
                name TEXT,
                identity TEXT
            );
            CREATE TABLE usage_overview_daily_stats (
                id INTEGER PRIMARY KEY,
                bucket_start TEXT,
                auth_index TEXT,
                request_count INTEGER,
                total_tokens INTEGER,
                cache_read_tokens INTEGER
            );
            INSERT INTO usage_identities (id, name, identity) VALUES
                (1, 'sk44989@gmail.com', 'idx-pool-1'),
                (2, 'victorcranston465@gmail.com', 'idx-pool-2'),
                (3, 'wisnumandala302@gmail.com', 'idx-pro');
            INSERT INTO usage_overview_daily_stats (bucket_start, auth_index, request_count, total_tokens, cache_read_tokens) VALUES
                ('2026-10-05T00:00:00+08:00', 'idx-pool-1', 10, 1000, 200),
                ('2026-10-05T00:00:00+08:00', 'idx-pool-2', 20, 2000, 300),
                ('2026-10-05T00:00:00+08:00', 'idx-pro', 5, 500, 50),
                ('2026-10-04T00:00:00+08:00', 'idx-pool-1', 99, 99999, 0);
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            fatalError("Failed to execute schema")
        }

        let usage = try KeeperUsageReader.loadToday(databaseURL: dbURL, now: Self.now, calendar: Self.calendar)

        #expect(usage.agy == AgentTokenTotals(requestCount: 30, totalTokens: 3000, cacheReadTokens: 500))
        #expect(usage.agyPro == AgentTokenTotals(requestCount: 5, totalTokens: 500, cacheReadTokens: 50))
        #expect(usage.codex == .zero)
        #expect(usage.claude == .zero)
    }

    @Test
    func readsWalModeDatabaseWhileKeeperRunsAndAfterItStops() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbURL = tempDir.appendingPathComponent("app.db")

        var handle: OpaquePointer?
        guard sqlite3_open(dbURL.path, &handle) == SQLITE_OK, let writer = handle else {
            fatalError("Failed to open test db")
        }
        // No auto-checkpoint, so the rows below live only in the -wal file
        // while the writer is open.
        let schema = """
            PRAGMA journal_mode=WAL;
            PRAGMA wal_autocheckpoint=0;
            CREATE TABLE usage_identities (
                id INTEGER PRIMARY KEY,
                name TEXT,
                identity TEXT
            );
            CREATE TABLE usage_overview_daily_stats (
                id INTEGER PRIMARY KEY,
                bucket_start TEXT,
                auth_index TEXT,
                request_count INTEGER,
                total_tokens INTEGER,
                cache_read_tokens INTEGER
            );
            INSERT INTO usage_identities (id, name, identity) VALUES (1, 'pool@gmail.com', 'idx-pool');
            INSERT INTO usage_overview_daily_stats (bucket_start, auth_index, request_count, total_tokens, cache_read_tokens) VALUES
                ('2026-10-05T00:00:00+08:00', 'idx-pool', 3, 300, 30);
        """
        guard sqlite3_exec(writer, schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(writer)
            fatalError("Failed to execute schema")
        }
        let expected = AgentTokenTotals(requestCount: 3, totalTokens: 300, cacheReadTokens: 30)

        let running = try KeeperUsageReader.loadToday(databaseURL: dbURL, now: Self.now, calendar: Self.calendar)
        #expect(running.agy == expected)

        // KEEPER stopped: its SQLite checkpoints and removes the WAL files,
        // and the header still says WAL mode.
        sqlite3_close(writer)
        try? FileManager.default.removeItem(atPath: dbURL.path + "-wal")
        try? FileManager.default.removeItem(atPath: dbURL.path + "-shm")

        let stopped = try KeeperUsageReader.loadToday(databaseURL: dbURL, now: Self.now, calendar: Self.calendar)
        #expect(stopped.agy == expected)
    }

    @Test
    func sumsTodayTokensWithExtendedIdentities() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let dbURL = tempDir.appendingPathComponent("test-keeper-extended-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        var handle: OpaquePointer?
        guard sqlite3_open(dbURL.path, &handle) == SQLITE_OK, let db = handle else {
            fatalError("Failed to open test db")
        }
        defer { sqlite3_close(db) }

        let schema = """
            CREATE TABLE usage_identities (
                id INTEGER PRIMARY KEY,
                name TEXT,
                identity TEXT,
                type TEXT,
                provider TEXT,
                plan_type TEXT
            );
            CREATE TABLE usage_overview_daily_stats (
                id INTEGER PRIMARY KEY,
                bucket_start TEXT,
                auth_index TEXT,
                request_count INTEGER,
                total_tokens INTEGER,
                cache_read_tokens INTEGER
            );
            INSERT INTO usage_identities (id, name, identity, type, provider, plan_type) VALUES
                (1, 'sk44989@gmail.com', 'idx-pool-1', 'antigravity', 'antigravity', ''),
                (2, 'wisnumandala302@gmail.com', 'idx-pro', 'antigravity', 'antigravity', 'pro'),
                (3, 'rongyiplus4@163.com', 'idx-codex', 'codex', 'codex', 'plus'),
                (4, 'claude-bot@anthropic.com', 'idx-claude', 'claude', 'claude', ''),
                (5, 'YI-API', 'idx-openai', 'openai', 'YI-API', '');
            INSERT INTO usage_overview_daily_stats (bucket_start, auth_index, request_count, total_tokens, cache_read_tokens) VALUES
                ('2026-10-05T00:00:00+08:00', 'idx-pool-1', 10, 1000, 200),
                ('2026-10-05T00:00:00+08:00', 'idx-pro', 5, 500, 50),
                ('2026-10-05T00:00:00+08:00', 'idx-codex', 77, 10138778, 9395456),
                ('2026-10-05T00:00:00+08:00', 'idx-claude', 8, 800, 80),
                ('2026-10-05T00:00:00+08:00', 'idx-openai', 99, 999999, 10000),
                ('2026-10-04T00:00:00+08:00', 'idx-codex', 50, 500000, 0);
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            fatalError("Failed to execute schema")
        }

        let usage = try KeeperUsageReader.loadToday(databaseURL: dbURL, now: Self.now, calendar: Self.calendar)

        #expect(usage.agy == AgentTokenTotals(requestCount: 10, totalTokens: 1000, cacheReadTokens: 200))
        #expect(usage.agyPro == AgentTokenTotals(requestCount: 5, totalTokens: 500, cacheReadTokens: 50))
        #expect(usage.codex == AgentTokenTotals(requestCount: 77, totalTokens: 10138778, cacheReadTokens: 9395456))
        #expect(usage.claude == AgentTokenTotals(requestCount: 8, totalTokens: 800, cacheReadTokens: 80))
        #expect(usage.agyAccounts == ["sk44989"])
        #expect(usage.agyProAccounts == ["wisnumandala302"])
        #expect(usage.codexAccounts == ["rongyiplus4"])
        #expect(usage.claudeAccounts == ["claude-bot"])
        #expect(usage.other == AgentTokenTotals(requestCount: 99, totalTokens: 999999, cacheReadTokens: 10000))
        #expect(usage.otherAccounts == ["YI-API"])
    }

    @Test
    func classifiesByExecutorAndKeepsUsageWithoutIdentity() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-keeper-executor-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        var handle: OpaquePointer?
        guard sqlite3_open(dbURL.path, &handle) == SQLITE_OK, let db = handle else {
            fatalError("Failed to open test db")
        }
        defer { sqlite3_close(db) }

        // Mirrors the live schema: Pro accounts have an empty plan_type, and
        // executor_type is what tells channels apart.
        let schema = """
            CREATE TABLE usage_identities (
                id INTEGER PRIMARY KEY, name TEXT, identity TEXT, type TEXT, provider TEXT, plan_type TEXT
            );
            CREATE TABLE usage_overview_daily_stats (
                id INTEGER PRIMARY KEY, bucket_start TEXT, auth_index TEXT, executor_type TEXT,
                request_count INTEGER, total_tokens INTEGER, cache_read_tokens INTEGER
            );
            INSERT INTO usage_identities (id, name, identity, type, provider, plan_type) VALUES
                (1, 'wisnumandala302@gmail.com', 'idx-pro', 'antigravity', 'antigravity', ''),
                (2, 'project-alpha@gmail.com', 'idx-pool', 'antigravity', 'antigravity', ''),
                (3, 'rongyiplus4@163.com', 'idx-codex', 'codex', 'codex', 'plus'),
                (4, 'YI-API', 'idx-openai', 'openai', 'YI-API', '');
            INSERT INTO usage_overview_daily_stats
                (bucket_start, auth_index, executor_type, request_count, total_tokens, cache_read_tokens) VALUES
                ('2026-10-05T00:00:00+08:00', 'idx-pro', 'AntigravityExecutor', 5, 500, 50),
                ('2026-10-05T00:00:00+08:00', 'idx-pool', 'AntigravityExecutor', 10, 1000, 100),
                ('2026-10-05T00:00:00+08:00', 'idx-codex', 'CodexExecutor', 7, 700, 70),
                ('2026-10-05T00:00:00+08:00', 'idx-openai', 'OpenAICompatExecutor', 1, 44, 0),
                ('2026-10-05T00:00:00+08:00', 'idx-gone', 'CodexExecutor', 2, 200, 20);
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            fatalError("Failed to execute schema")
        }

        let usage = try KeeperUsageReader.loadToday(databaseURL: dbURL, now: Self.now, calendar: Self.calendar)

        #expect(usage.agyPro == AgentTokenTotals(requestCount: 5, totalTokens: 500, cacheReadTokens: 50))
        // "project-alpha" contains "pro" but is not a configured Pro account.
        #expect(usage.agy == AgentTokenTotals(requestCount: 10, totalTokens: 1000, cacheReadTokens: 100))
        // The orphaned auth index still counts, classified by its executor.
        #expect(usage.codex == AgentTokenTotals(requestCount: 9, totalTokens: 900, cacheReadTokens: 90))
        #expect(usage.codexAccounts == ["rongyiplus4"])
        #expect(usage.other == AgentTokenTotals(requestCount: 1, totalTokens: 44, cacheReadTokens: 0))

        let noPro = try KeeperUsageReader.loadToday(
            databaseURL: dbURL, now: Self.now, calendar: Self.calendar, agyProAccounts: []
        )
        #expect(noPro.agyPro == .zero)
        #expect(noPro.agy.totalTokens == 1500)
    }

    /// KEEPER's buckets are in +08:00 while this user's day runs in New York:
    /// the +08:00 "2026-10-08" day is New York's Oct 7 noon to Oct 8 noon.
    @Test
    func hourlyBucketsAreCutAtTheUsersLocalMidnight() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-keeper-hourly-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        var handle: OpaquePointer?
        guard sqlite3_open(dbURL.path, &handle) == SQLITE_OK, let db = handle else {
            fatalError("Failed to open test db")
        }
        defer { sqlite3_close(db) }

        let schema = """
            CREATE TABLE usage_identities (id INTEGER PRIMARY KEY, name TEXT, identity TEXT);
            CREATE TABLE usage_overview_daily_stats (
                id INTEGER PRIMARY KEY, bucket_start TEXT, auth_index TEXT, executor_type TEXT,
                request_count INTEGER, total_tokens INTEGER, cache_read_tokens INTEGER
            );
            CREATE TABLE usage_overview_hourly_stats (
                id INTEGER PRIMARY KEY, bucket_start TEXT, auth_index TEXT, executor_type TEXT,
                request_count INTEGER, total_tokens INTEGER, cache_read_tokens INTEGER
            );
            INSERT INTO usage_identities (id, name, identity) VALUES (1, 'rongyiplus4@163.com', 'idx-codex');
            -- The daily table would give the misaligned +08:00 day.
            INSERT INTO usage_overview_daily_stats
                (bucket_start, auth_index, executor_type, request_count, total_tokens, cache_read_tokens) VALUES
                ('2026-10-08T00:00:00+08:00', 'idx-codex', 'CodexExecutor', 999, 999999, 0);
            INSERT INTO usage_overview_hourly_stats
                (bucket_start, auth_index, executor_type, request_count, total_tokens, cache_read_tokens) VALUES
                ('2026-10-08T11:00:00+08:00', 'idx-codex', 'CodexExecutor', 1, 1, 0),
                ('2026-10-08T12:00:00+08:00', 'idx-codex', 'CodexExecutor', 10, 100, 10),
                ('2026-10-09T11:00:00+08:00', 'idx-codex', 'CodexExecutor', 20, 200, 20),
                ('2026-10-09T12:00:00+08:00', 'idx-codex', 'CodexExecutor', 300, 3000, 0);
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            fatalError("Failed to execute schema")
        }

        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        // 2026-10-08 07:00 EDT.
        let now = Date(timeIntervalSince1970: 1_791_457_200)

        let usage = try KeeperUsageReader.loadToday(databaseURL: dbURL, now: now, calendar: newYork)

        // 12:00+08:00 is 00:00 EDT (in); 11:00+08:00 the next day is 23:00 EDT (in);
        // the buckets an hour either side belong to Oct 7 and Oct 9 in New York.
        #expect(usage.codex == AgentTokenTotals(requestCount: 30, totalTokens: 300, cacheReadTokens: 30))
        #expect(usage.codexAccounts == ["rongyiplus4"])
    }

    @Test
    func bucketPrefixIsGregorianWhateverTheUserCalendar() {
        var japanese = Calendar(identifier: .japanese)
        japanese.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        #expect(KeeperUsageReader.bucketPrefix(for: Self.now, calendar: japanese) == "2026-10-05%")
    }
}
