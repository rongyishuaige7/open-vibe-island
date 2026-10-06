import Foundation
import SQLite3

/// Antigravity, Codex, and Claude token totals loaded from KEEPER.
public struct KeeperTodayUsage: Equatable, Sendable {
    public var agy: AgentTokenTotals
    public var agyPro: AgentTokenTotals
    public var codex: AgentTokenTotals
    public var claude: AgentTokenTotals

    public init(
        agy: AgentTokenTotals = .zero,
        agyPro: AgentTokenTotals = .zero,
        codex: AgentTokenTotals = .zero,
        claude: AgentTokenTotals = .zero
    ) {
        self.agy = agy
        self.agyPro = agyPro
        self.codex = codex
        self.claude = claude
    }

    public static let zero = KeeperTodayUsage()
}

public typealias AntigravityTodayUsage = KeeperTodayUsage

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
/// which records token usage for requests routed through CPA or synced from transcripts.
public enum KeeperUsageReader {
    public static var defaultDatabaseURL: URL {
        URL(fileURLWithPath: "/opt/homebrew/var/cpa-usage-keeper/app.db")
    }

    /// Sums today's token usage (Antigravity pool vs pro, Codex, Claude) since local midnight of `now`.
    public static func loadToday(
        databaseURL: URL = defaultDatabaseURL,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> KeeperTodayUsage {
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

        let hasExtendedColumns = tableHasColumns(db: db, table: "usage_identities", requiredColumns: ["type", "provider"])
        let sql = hasExtendedColumns ? enhancedTotalsQuery : legacyTotalsQuery

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw KeeperUsageError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, (datePrefix as NSString).utf8String, -1, nil)

        var agyTotals = AgentTokenTotals.zero
        var agyProTotals = AgentTokenTotals.zero
        var codexTotals = AgentTokenTotals.zero
        var claudeTotals = AgentTokenTotals.zero

        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw KeeperUsageError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            let name = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
            let type = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let provider = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
            let planType = sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? ""
            let reqCount = Int(sqlite3_column_int64(statement, 4))
            let totalTokens = Int(sqlite3_column_int64(statement, 5))
            let cacheReadTokens = Int(sqlite3_column_int64(statement, 6))

            let totals = AgentTokenTotals(
                requestCount: reqCount,
                totalTokens: totalTokens,
                cacheReadTokens: cacheReadTokens
            )

            let lowerType = type.lowercased()
            let lowerProvider = provider.lowercased()
            let lowerName = name.lowercased()
            let lowerPlan = planType.lowercased()

            if lowerType.contains("codex") || lowerProvider.contains("codex") || lowerName.contains("codex") {
                codexTotals += totals
            } else if lowerType.contains("claude") || lowerProvider.contains("claude") || lowerType.contains("anthropic") || lowerProvider.contains("anthropic") || lowerName.contains("claude") {
                claudeTotals += totals
            } else if lowerType.contains("antigravity") || lowerProvider.contains("antigravity") || (lowerType.isEmpty && lowerProvider.isEmpty) || lowerName.contains("antigravity") || lowerName.contains("agy") {
                if lowerName.contains("wisnumandala") || lowerName.contains("pro") || lowerPlan.contains("pro") {
                    agyProTotals += totals
                } else {
                    agyTotals += totals
                }
            }
        }

        return KeeperTodayUsage(
            agy: agyTotals,
            agyPro: agyProTotals,
            codex: codexTotals,
            claude: claudeTotals
        )
    }

    private static func tableHasColumns(db: OpaquePointer, table: String, requiredColumns: [String]) -> Bool {
        var statement: OpaquePointer?
        let query = "PRAGMA table_info(\(table));"
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(statement) }

        var foundColumns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let namePtr = sqlite3_column_text(statement, 1) {
                foundColumns.insert(String(cString: namePtr).lowercased())
            }
        }
        return requiredColumns.allSatisfy { foundColumns.contains($0.lowercased()) }
    }

    static let enhancedTotalsQuery = """
        SELECT ui.name,
               COALESCE(ui.type, ''),
               COALESCE(ui.provider, ''),
               COALESCE(ui.plan_type, ''),
               COALESCE(SUM(uds.request_count), 0),
               COALESCE(SUM(uds.total_tokens), 0),
               COALESCE(SUM(uds.cache_read_tokens), 0)
        FROM usage_overview_daily_stats uds
        JOIN usage_identities ui ON uds.auth_index = ui.identity
        WHERE uds.bucket_start LIKE ?1
        GROUP BY ui.name, ui.type, ui.provider, ui.plan_type
        """

    static let legacyTotalsQuery = """
        SELECT ui.name,
               '',
               '',
               '',
               COALESCE(SUM(uds.request_count), 0),
               COALESCE(SUM(uds.total_tokens), 0),
               COALESCE(SUM(uds.cache_read_tokens), 0)
        FROM usage_overview_daily_stats uds
        JOIN usage_identities ui ON uds.auth_index = ui.identity
        WHERE uds.bucket_start LIKE ?1
        GROUP BY ui.name
        """
}
