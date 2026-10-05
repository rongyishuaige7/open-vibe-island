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
    }
}
