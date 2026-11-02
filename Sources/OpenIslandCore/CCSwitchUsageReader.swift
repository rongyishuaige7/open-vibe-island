import Foundation
import SQLite3

/// Read-only access to CC Switch's local proxy request log, which records
/// token usage for every Claude and Codex request routed through CC Switch.
///
/// This depends on CC Switch's internal schema and is not a supported API.
/// Failures surface as `CCSwitchUsageError` so the caller can say why the
/// numbers are missing instead of showing zeros.
public enum CCSwitchUsageReader {
    public static var defaultDatabaseURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".cc-switch/cc-switch.db")
    }

    /// Sums the tokens CC Switch logged per agent since local midnight of `now`.
    public static func loadToday(
        databaseURL: URL = defaultDatabaseURL,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> TodayTokenUsage {
        let dayStart = calendar.startOfDay(for: now)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(86_400)

        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw CCSwitchUsageError.databaseMissing
        }

        var handle: OpaquePointer?
        let flags: Int32 = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK, let db = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw CCSwitchUsageError.sqlite(message)
        }
        defer { sqlite3_close(db) }
        // CC Switch keeps a rollback journal, so this read and its writes
        // briefly block each other. Wait a moment, then skip this round.
        sqlite3_busy_timeout(db, 200)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, totalsQuery, -1, &statement, nil) == SQLITE_OK else {
            throw CCSwitchUsageError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(dayStart.timeIntervalSince1970))
        sqlite3_bind_int64(statement, 2, Int64(dayEnd.timeIntervalSince1970))

        var usage = TodayTokenUsage(dayStart: dayStart)
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw CCSwitchUsageError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            let totals = AgentTokenTotals(
                requestCount: Int(sqlite3_column_int64(statement, 1)),
                totalTokens: Int(sqlite3_column_int64(statement, 2)),
                cacheReadTokens: Int(sqlite3_column_int64(statement, 3))
            )
            switch sqlite3_column_text(statement, 0).map({ String(cString: $0) }) ?? "" {
            case "claude":
                usage.claude = totals
            case "codex":
                usage.codex = totals
            default:
                break
            }
        }
        return usage
    }

    /// `created_at` holds Unix seconds and `(app_type, created_at)` is
    /// indexed, so this is a short range scan. `input_token_semantics` says
    /// whether `input_tokens` already contains the cached tokens: 1 = yes
    /// (OpenAI style), 2 = no (Anthropic style), 0 = unset on older rows,
    /// treated as included for Codex and excluded otherwise.
    static let totalsQuery = """
        SELECT app_type,
               COUNT(*),
               COALESCE(SUM(CASE
                   WHEN input_token_semantics = 1
                        OR (input_token_semantics = 0 AND app_type = 'codex')
                   THEN input_tokens + output_tokens
                   ELSE input_tokens + cache_read_tokens + cache_creation_tokens + output_tokens
               END), 0),
               COALESCE(SUM(cache_read_tokens), 0)
        FROM proxy_request_logs
        WHERE app_type IN ('claude', 'codex')
          AND created_at >= ?1 AND created_at < ?2
        GROUP BY app_type
        """
}
