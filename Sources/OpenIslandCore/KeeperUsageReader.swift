import Foundation
import SQLite3

/// Per-account token consumption detail.
public struct AccountTokenUsage: Equatable, Sendable, Identifiable {
    public var id: String { account }
    public var account: String
    public var totals: AgentTokenTotals

    public init(account: String, totals: AgentTokenTotals) {
        self.account = account
        self.totals = totals
    }
}

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
    public var agyAccountBreakdown: [AccountTokenUsage]

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
        otherAccounts: [String] = [],
        agyAccountBreakdown: [AccountTokenUsage] = []
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
        self.agyAccountBreakdown = agyAccountBreakdown
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

        let db = try openDatabase(databaseURL)
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

    /// KEEPER writes in WAL mode; see SQLiteReadOnly for why the read
    /// survives KEEPER stopping and removing its -wal file.
    private static func openDatabase(_ databaseURL: URL) throws -> OpaquePointer {
        switch SQLiteReadOnly.open(path: databaseURL.path, busyTimeoutMilliseconds: 200) {
        case let .success(db):
            return db
        case let .failure(error):
            throw KeeperUsageError.sqlite(error.message)
        }
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

    /// Reads the latest Codex Plus 5h and 7d rate limit windows recorded by KEEPER
    /// from CPA's observed response headers.
    public static func loadCodexRateLimits(
        databaseURL: URL = defaultDatabaseURL,
        now: Date = Date()
    ) throws -> CodexUsageSnapshot? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw KeeperUsageError.databaseMissing
        }

        let db = try openDatabase(databaseURL)
        defer { sqlite3_close(db) }

        // Verify tables exist
        let cycleColumns = columns(db: db, table: "quota_cycles")
        let segmentColumns = columns(db: db, table: "quota_percent_segments")
        guard !cycleColumns.isEmpty, !segmentColumns.isEmpty else {
            return nil
        }

        let identityColumns = columns(db: db, table: "usage_identities")
        let hasName = identityColumns.contains("name")
        let hasPlan = identityColumns.contains("plan_type")

        let sql = """
            WITH latest_account AS (
                SELECT qc.auth_index
                FROM quota_cycles qc
                JOIN quota_percent_segments qps ON qps.cycle_id = qc.id
                WHERE qc.provider = 'codex'
                ORDER BY qps.last_observed_at DESC, qps.id DESC
                LIMIT 1
            ),
            -- Newest observation per window. The 5h window is observed far
            -- more often than the 7d one, so a plain LIMIT over both could
            -- crowd the 7d row out.
            observations AS (
                SELECT qc.quota_key,
                       qc.window_seconds,
                       qc.reset_at,
                       qps.remaining_percent,
                       qps.last_observed_at,
                       qps.id AS segment_id,
                       qc.auth_index,
                       ROW_NUMBER() OVER (
                           PARTITION BY qc.quota_key
                           ORDER BY qps.last_observed_at DESC, qps.id DESC
                       ) AS recency
                FROM quota_cycles qc
                JOIN quota_percent_segments qps ON qps.cycle_id = qc.id
                JOIN latest_account la ON qc.auth_index = la.auth_index
                WHERE qc.provider = 'codex'
                  AND qc.quota_key IN ('rate_limit.primary_window', 'rate_limit.secondary_window')
            )
            SELECT o.quota_key,
                   o.window_seconds,
                   o.reset_at,
                   o.remaining_percent,
                   o.last_observed_at,
                   \(hasName ? "COALESCE(ui.name, '')" : "''"),
                   \(hasPlan ? "COALESCE(ui.plan_type, '')" : "''")
            FROM observations o
            LEFT JOIN usage_identities ui ON ui.identity = o.auth_index
            WHERE o.recency = 1
            ORDER BY o.last_observed_at DESC, o.segment_id DESC;
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw KeeperUsageError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        var windowsByKey: [String: CodexUsageWindow] = [:]
        var latestCapturedAt: Date?
        var planType: String?

        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ col: Int32) -> String {
                sqlite3_column_text(statement, col).map { String(cString: $0) } ?? ""
            }

            let quotaKey = text(0)
            let windowSeconds = Int(sqlite3_column_int64(statement, 1))
            let resetAtString = text(2)
            let remainingPercent = Int(sqlite3_column_int64(statement, 3))
            let lastObservedString = text(4)
            let observedPlan = text(6)

            let windowKey: String
            if quotaKey == "rate_limit.primary_window" {
                windowKey = "primary"
            } else if quotaKey == "rate_limit.secondary_window" {
                windowKey = "secondary"
            } else {
                continue
            }

            if planType == nil && !observedPlan.isEmpty {
                planType = observedPlan
            }

            if let observedDate = parseISO8601Date(lastObservedString) {
                if latestCapturedAt == nil || observedDate > latestCapturedAt! {
                    latestCapturedAt = observedDate
                }
            }

            // Only keep the most recent observation for each window key
            if windowsByKey[windowKey] == nil {
                let windowMinutes = max(1, windowSeconds / 60)
                let label = formatWindowLabel(minutes: windowMinutes)
                let resetsAt = parseISO8601Date(resetAtString)
                let isWindowExpired = resetsAt.map { $0 <= now } ?? false

                let leftPercentage = isWindowExpired ? 100.0 : Double(remainingPercent)
                let usedPercentage = isWindowExpired ? 0.0 : max(0, 100.0 - Double(remainingPercent))

                windowsByKey[windowKey] = CodexUsageWindow(
                    key: windowKey,
                    label: label,
                    usedPercentage: usedPercentage,
                    leftPercentage: leftPercentage,
                    windowMinutes: windowMinutes,
                    resetsAt: resetsAt
                )
            }
        }

        let windows = ["primary", "secondary"].compactMap { windowsByKey[$0] }
        guard !windows.isEmpty else {
            return nil
        }

        return CodexUsageSnapshot(
            sourceFilePath: databaseURL.path,
            capturedAt: latestCapturedAt ?? now,
            planType: planType ?? "plus",
            limitID: "codex",
            windows: windows
        )
    }

    private static func formatWindowLabel(minutes: Int) -> String {
        let days = minutes / 1_440
        let remainingMinutesAfterDays = minutes % 1_440
        let hours = remainingMinutesAfterDays / 60
        let remainingMinutes = remainingMinutesAfterDays % 60

        if days > 0, hours == 0, remainingMinutes == 0 {
            return "\(days)d"
        }
        if days > 0, hours > 0 {
            return "\(days)d \(hours)h"
        }
        if hours > 0, remainingMinutes == 0 {
            return "\(hours)h"
        }
        if hours > 0 {
            return "\(hours)h \(remainingMinutes)m"
        }
        return "\(minutes)m"
    }

    private static func parseISO8601Date(_ string: String) -> Date? {
        guard !string.isEmpty else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) {
            return date
        }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: string)
    }
}

extension KeeperTodayUsage {
    mutating func add(_ totals: AgentTokenTotals, account: String, to channel: KeeperUsageReader.Channel) {
        func append(_ accounts: inout [String]) {
            if !account.isEmpty && !accounts.contains(account) {
                accounts.append(account)
            }
        }
        func appendBreakdown(_ list: inout [AccountTokenUsage], totals: AgentTokenTotals) {
            guard !account.isEmpty else { return }
            if let idx = list.firstIndex(where: { $0.account.caseInsensitiveCompare(account) == .orderedSame }) {
                list[idx].totals += totals
            } else {
                list.append(AccountTokenUsage(account: account, totals: totals))
            }
        }
        switch channel {
        case .agy:
            var adjustedTotals = totals
            if adjustedTotals.totalTokens < adjustedTotals.cacheReadTokens {
                adjustedTotals.totalTokens += adjustedTotals.cacheReadTokens
            }
            agy += adjustedTotals
            append(&agyAccounts)
            appendBreakdown(&agyAccountBreakdown, totals: adjustedTotals)
        case .agyPro:
            var adjustedTotals = totals
            if adjustedTotals.totalTokens < adjustedTotals.cacheReadTokens {
                adjustedTotals.totalTokens += adjustedTotals.cacheReadTokens
            }
            agyPro += adjustedTotals
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
