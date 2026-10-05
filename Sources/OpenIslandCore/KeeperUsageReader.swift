import Foundation
import SQLite3

/// Antigravity token totals (both regular pool and Pro) loaded from KEEPER.
public struct AntigravityTodayUsage: Equatable, Sendable {
    public var agy: AgentTokenTotals
    public var agyPro: AgentTokenTotals

    public init(agy: AgentTokenTotals = .zero, agyPro: AgentTokenTotals = .zero) {
        self.agy = agy
        self.agyPro = agyPro
    }

    public static let zero = AntigravityTodayUsage()
}

public enum KeeperUsageError: Error, Equatable, LocalizedError {
    /// KEEPER database is not installed or missing.
    case databaseMissing
    /// Database read or query failed.
    case sqlite(String)

    public var errorDescription: String? {
        switch self {
        case .databaseMissing:
            "KEEPER database not found"
        case let .sqlite(message):
            message
        }
    }
}

/// Read-only access to KEEPER's SQLite database (/opt/homebrew/var/cpa-usage-keeper/app.db),
/// which records token usage for Antigravity requests routed through CPA or synced from transcripts.
public enum KeeperUsageReader {
    public static var defaultDatabaseURL: URL {
        URL(fileURLWithPath: "/opt/homebrew/var/cpa-usage-keeper/app.db")
    }

    /// Sums today's Antigravity token usage (pool vs pro) since local midnight of `now`.
    public static func loadToday(
        databaseURL: URL = defaultDatabaseURL,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> AntigravityTodayUsage {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw KeeperUsageError.databaseMissing
        }

        var handle: OpaquePointer?
        let flags: Int32 = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK, let db = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw KeeperUsageError.sqlite(message)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)

        // Today's bucket prefix in business timezone, e.g. "2026-10-05%"
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let datePrefix = formatter.string(from: now) + "%"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, totalsQuery, -1, &statement, nil) == SQLITE_OK else {
            throw KeeperUsageError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, (datePrefix as NSString).utf8String, -1, nil)

        var agyTotals = AgentTokenTotals.zero
        var agyProTotals = AgentTokenTotals.zero

        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw KeeperUsageError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            let name = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
            let reqCount = Int(sqlite3_column_int64(statement, 1))
            let totalTokens = Int(sqlite3_column_int64(statement, 2))
            let cacheReadTokens = Int(sqlite3_column_int64(statement, 3))

            let totals = AgentTokenTotals(
                requestCount: reqCount,
                totalTokens: totalTokens,
                cacheReadTokens: cacheReadTokens
            )

            if name.localizedCaseInsensitiveContains("wisnumandala") || name.localizedCaseInsensitiveContains("pro") {
                agyProTotals.requestCount += totals.requestCount
                agyProTotals.totalTokens += totals.totalTokens
                agyProTotals.cacheReadTokens += totals.cacheReadTokens
            } else {
                agyTotals.requestCount += totals.requestCount
                agyTotals.totalTokens += totals.totalTokens
                agyTotals.cacheReadTokens += totals.cacheReadTokens
            }
        }

        return AntigravityTodayUsage(agy: agyTotals, agyPro: agyProTotals)
    }

    static let totalsQuery = """
        SELECT ui.name,
               COALESCE(SUM(uds.request_count), 0),
               COALESCE(SUM(uds.total_tokens), 0),
               COALESCE(SUM(uds.cache_read_tokens), 0)
        FROM usage_overview_daily_stats uds
        JOIN usage_identities ui ON uds.auth_index = ui.identity
        WHERE uds.bucket_start LIKE ?1
        GROUP BY ui.name
        """
}
