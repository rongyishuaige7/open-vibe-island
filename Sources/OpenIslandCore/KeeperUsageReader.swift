import Foundation
import SQLite3

/// Antigravity, Codex, and Claude token totals loaded from KEEPER.
public struct KeeperTodayUsage: Equatable, Sendable {
    public var agy: AgentTokenTotals
    public var agyPro: AgentTokenTotals
    public var codex: AgentTokenTotals
    public var claude: AgentTokenTotals
    /// Usage KEEPER logged for any other upstream, e.g. an OpenAI-compatible API key.
    public var other: AgentTokenTotals
    public var agyAccounts: [String]
    public var agyProAccounts: [String]
    public var codexAccounts: [String]
    public var claudeAccounts: [String]
    public var otherAccounts: [String]

    public init(
        agy: AgentTokenTotals = .zero,
        agyPro: AgentTokenTotals = .zero,
        codex: AgentTokenTotals = .zero,
        claude: AgentTokenTotals = .zero,
        other: AgentTokenTotals = .zero,
        agyAccounts: [String] = [],
        agyProAccounts: [String] = [],
        codexAccounts: [String] = [],
        claudeAccounts: [String] = [],
        otherAccounts: [String] = []
    ) {
        self.agy = agy
        self.agyPro = agyPro
        self.codex = codex
        self.claude = claude
        self.other = other
        self.agyAccounts = agyAccounts
        self.agyProAccounts = agyProAccounts
        self.codexAccounts = codexAccounts
        self.claudeAccounts = claudeAccounts
        self.otherAccounts = otherAccounts
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

    /// Antigravity accounts counted as AGY Pro. KEEPER records nothing that
    /// tells a Pro account apart (its `plan_type` is empty), so it is named here.
    public static let defaultAgyProAccounts: Set<String> = ["wisnumandala302"]

    enum Channel: Equatable {
        case agy, agyPro, codex, claude, other
    }

    /// Sums today's token usage per channel since local midnight of `now`.
    /// `agyProAccounts` are matched case-insensitively against the account
    /// name without its `@domain`.
    public static func loadToday(
        databaseURL: URL = defaultDatabaseURL,
        now: Date = Date(),
        calendar: Calendar = .current,
        agyProAccounts: Set<String> = defaultAgyProAccounts
    ) throws -> KeeperTodayUsage {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw KeeperUsageError.databaseMissing
        }

        // KEEPER writes in WAL mode; see SQLiteReadOnly for why the read
        // survives KEEPER stopping and removing its -wal file.
        let db: OpaquePointer
        switch SQLiteReadOnly.open(path: databaseURL.path, busyTimeoutMilliseconds: 200) {
        case let .success(handle):
            db = handle
        case let .failure(error):
            throw KeeperUsageError.sqlite(error.message)
        }
        defer { sqlite3_close(db) }

        // KEEPER buckets carry its own business time zone (e.g. +08:00), not
        // the user's. Hourly buckets can be cut at the user's local midnight;
        // daily ones only line up when the two zones match, so they are the
        // fallback for KEEPER versions without the hourly table.
        let dayStart = calendar.startOfDay(for: now)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(86_400)
        let identityColumns = columns(db: db, table: "usage_identities")
        let hourlyColumns = columns(db: db, table: "usage_overview_hourly_stats")
        let usesHourly = !hourlyColumns.isEmpty

        var statement: OpaquePointer?
        let sql = usesHourly
            ? totalsQuery(table: "usage_overview_hourly_stats", identityColumns: identityColumns,
                          statsColumns: hourlyColumns, dayFilter: .instantRange)
            : totalsQuery(table: "usage_overview_daily_stats", identityColumns: identityColumns,
                          statsColumns: columns(db: db, table: "usage_overview_daily_stats"), dayFilter: .datePrefix)
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw KeeperUsageError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        if usesHourly {
            let bounds = bucketStringBounds(dayStart: dayStart, dayEnd: dayEnd)
            sqlite3_bind_text(statement, 1, (bounds.lower as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (bounds.upper as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(statement, 3, Int64(dayStart.timeIntervalSince1970))
            sqlite3_bind_int64(statement, 4, Int64(dayEnd.timeIntervalSince1970))
        } else {
            sqlite3_bind_text(statement, 1, (bucketPrefix(for: now, calendar: calendar) as NSString).utf8String, -1, nil)
        }

        let proAccounts = Set(agyProAccounts.map { $0.lowercased() })
        var usage = KeeperTodayUsage()
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw KeeperUsageError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            func text(_ column: Int32) -> String {
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            }
            let name = text(0)
            let accountName = name.contains("@") ? String(name.split(separator: "@").first ?? "") : name
            let totals = AgentTokenTotals(
                requestCount: Int(sqlite3_column_int64(statement, 5)),
                totalTokens: Int(sqlite3_column_int64(statement, 6)),
                cacheReadTokens: Int(sqlite3_column_int64(statement, 7))
            )
            let channel = channel(
                name: name,
                type: text(1),
                provider: text(2),
                planType: text(3),
                executorType: text(4),
                isProAccount: proAccounts.contains(accountName.lowercased())
            )
            usage.add(totals, account: accountName, to: channel)
        }
        return usage
    }

    /// Prefers the executor CPA ran the request with; identity fields and
    /// the account name are only a fallback for rows or schemas without one.
    static func channel(
        name: String,
        type: String,
        provider: String,
        planType: String,
        executorType: String,
        isProAccount: Bool
    ) -> Channel {
        let executor = executorType.lowercased()
        let identity = [type.lowercased(), provider.lowercased()]
        let lowerName = name.lowercased()

        let base: Channel
        if executor.contains("codex") {
            base = .codex
        } else if executor.contains("claude") || executor.contains("anthropic") {
            base = .claude
        } else if executor.contains("antigravity") {
            base = .agy
        } else if !executor.isEmpty {
            base = .other
        } else if identity.contains(where: { $0.contains("codex") }) || lowerName.contains("codex") {
            base = .codex
        } else if identity.contains(where: { $0.contains("claude") || $0.contains("anthropic") })
                    || lowerName.contains("claude") {
            base = .claude
        } else if identity.contains(where: { $0.contains("antigravity") })
                    || lowerName.contains("antigravity") || lowerName.contains("agy")
                    // Legacy KEEPER identities had no type or provider and were all Antigravity.
                    || (identity.allSatisfy(\.isEmpty) && !name.isEmpty) {
            base = .agy
        } else {
            base = .other
        }

        guard base == .agy else { return base }
        return isProAccount || planType.lowercased() == "pro" ? .agyPro : .agy
    }

    /// Daily-table fallback: `bucket_start` holds KEEPER's day start, e.g.
    /// "2026-10-05T00:00:00+08:00", matched by the user's local date.
    static func bucketPrefix(for now: Date, calendar: Calendar) -> String {
        dayFormatter(timeZone: calendar.timeZone).string(from: now) + "%"
    }

    /// A coarse string range around the day for the `bucket_start` index.
    /// A bucket's own date is within a day of its UTC date whatever its
    /// offset, so a day of margin on each side keeps every candidate; the
    /// exact cut is the epoch comparison.
    static func bucketStringBounds(dayStart: Date, dayEnd: Date) -> (lower: String, upper: String) {
        let utc = dayFormatter(timeZone: TimeZone(identifier: "UTC")!)
        return (
            utc.string(from: dayStart.addingTimeInterval(-86_400)),
            utc.string(from: dayEnd.addingTimeInterval(2 * 86_400))
        )
    }

    private static func dayFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private static func columns(db: OpaquePointer, table: String) -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var found = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let namePtr = sqlite3_column_text(statement, 1) {
                found.insert(String(cString: namePtr).lowercased())
            }
        }
        return found
    }

    enum DayFilter {
        /// ?1 `LIKE` prefix on the bucket's date.
        case datePrefix
        /// ?1/?2 string bounds for the index, then ?3 <= bucket epoch < ?4.
        case instantRange
    }

    /// Older KEEPER schemas lack some columns; those read as ''. The LEFT
    /// JOIN keeps usage whose auth index no longer has an identity row.
    static func totalsQuery(
        table: String,
        identityColumns: Set<String>,
        statsColumns: Set<String>,
        dayFilter: DayFilter
    ) -> String {
        func identity(_ column: String) -> String {
            identityColumns.contains(column) ? "COALESCE(ui.\(column), '')" : "''"
        }
        let executor = statsColumns.contains("executor_type") ? "COALESCE(uds.executor_type, '')" : "''"
        let filter: String
        switch dayFilter {
        case .datePrefix:
            filter = "uds.bucket_start LIKE ?1"
        case .instantRange:
            // SQLite reads the "+08:00" offset, so strftime gives the real instant.
            filter = """
                uds.bucket_start >= ?1 AND uds.bucket_start < ?2
                  AND CAST(strftime('%s', uds.bucket_start) AS INTEGER) >= ?3
                  AND CAST(strftime('%s', uds.bucket_start) AS INTEGER) < ?4
                """
        }
        return """
            SELECT COALESCE(ui.name, ''),
                   \(identity("type")),
                   \(identity("provider")),
                   \(identity("plan_type")),
                   \(executor),
                   COALESCE(SUM(uds.request_count), 0),
                   COALESCE(SUM(uds.total_tokens), 0),
                   COALESCE(SUM(uds.cache_read_tokens), 0)
            FROM \(table) uds
            LEFT JOIN usage_identities ui ON uds.auth_index = ui.identity
            WHERE \(filter)
            GROUP BY 1, 2, 3, 4, 5
            """
    }
}

extension KeeperTodayUsage {
    mutating func add(_ totals: AgentTokenTotals, account: String, to channel: KeeperUsageReader.Channel) {
        func append(_ accounts: inout [String]) {
            if !account.isEmpty && !accounts.contains(account) {
                accounts.append(account)
            }
        }
        switch channel {
        case .agy:
            agy += totals
            append(&agyAccounts)
        case .agyPro:
            agyPro += totals
            append(&agyProAccounts)
        case .codex:
            codex += totals
            append(&codexAccounts)
        case .claude:
            claude += totals
            append(&claudeAccounts)
        case .other:
            other += totals
            append(&otherAccounts)
        }
    }
}
