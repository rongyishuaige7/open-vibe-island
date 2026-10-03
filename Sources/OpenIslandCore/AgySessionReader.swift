import Foundation
import SQLite3

public struct AgySessionRecord: Equatable, Sendable {
    public var sessionID: String
    public var title: String
    public var preview: String
    public var isRunning: Bool
    public var lastModifiedTime: Date
    public var workspaceURIs: [String]
    public var stepCount: Int
    public var appDataDir: String

    public init(
        sessionID: String,
        title: String,
        preview: String,
        isRunning: Bool,
        lastModifiedTime: Date,
        workspaceURIs: [String],
        stepCount: Int,
        appDataDir: String
    ) {
        self.sessionID = sessionID
        self.title = title
        self.preview = preview
        self.isRunning = isRunning
        self.lastModifiedTime = lastModifiedTime
        self.workspaceURIs = workspaceURIs
        self.stepCount = stepCount
        self.appDataDir = appDataDir
    }
}

public final class AgySessionReader: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedDatabasePaths: (date: Date, paths: [String])?

    /// Returns candidate paths to `conversation_summaries.db` across all Antigravity profiles.
    public static func candidateDatabasePaths(fileManager: FileManager = .default) -> [String] {
        lock.lock()
        if let cached = cachedDatabasePaths, Date.now.timeIntervalSince(cached.date) < 5 {
            lock.unlock()
            return cached.paths
        }
        lock.unlock()

        var discovered: [String] = []
        let home = fileManager.homeDirectoryForCurrentUser
        let geminiDir = home.appendingPathComponent(".gemini", isDirectory: true)

        let standardPaths = [
            geminiDir.appendingPathComponent("antigravity-cli/conversation_summaries.db").path,
            geminiDir.appendingPathComponent("antigravity/conversation_summaries.db").path,
        ]
        for path in standardPaths {
            if fileManager.fileExists(atPath: path) && !discovered.contains(path) {
                discovered.append(path)
            }
        }

        // Check profiles like ~/.gemini/antigravity-cli-cpa/antigravity-cli/conversation_summaries.db
        if let subdirs = try? fileManager.contentsOfDirectory(at: geminiDir, includingPropertiesForKeys: [.isDirectoryKey]) {
            for subdir in subdirs {
                let name = subdir.lastPathComponent
                guard name.hasPrefix("antigravity") else { continue }

                let candidate1 = subdir.appendingPathComponent("conversation_summaries.db").path
                if fileManager.fileExists(atPath: candidate1) && !discovered.contains(candidate1) {
                    discovered.append(candidate1)
                }

                let candidate2 = subdir.appendingPathComponent("antigravity-cli/conversation_summaries.db").path
                if fileManager.fileExists(atPath: candidate2) && !discovered.contains(candidate2) {
                    discovered.append(candidate2)
                }
            }
        }

        lock.lock()
        cachedDatabasePaths = (date: .now, paths: discovered)
        lock.unlock()

        return discovered
    }

    /// Resolves the database path for a given appDataDir or transcript path.
    public static func databasePath(forAppDataDir appDataDir: String?) -> String? {
        guard let appDataDir, !appDataDir.isEmpty else { return nil }
        let candidate = (appDataDir as NSString).appendingPathComponent("conversation_summaries.db")
        if FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
        return nil
    }

    public static func databasePath(forTranscriptPath transcriptPath: String?) -> String? {
        guard let transcriptPath, !transcriptPath.isEmpty else { return nil }
        // Transcript format: <appDataDir>/brain/<sessionID>/.system_generated/logs/transcript.jsonl
        let pathComponents = (transcriptPath as NSString).pathComponents
        if let brainIndex = pathComponents.lastIndex(of: "brain"), brainIndex > 0 {
            let appDataDir = NSString.path(withComponents: Array(pathComponents[..<brainIndex]))
            return databasePath(forAppDataDir: appDataDir)
        }
        return nil
    }

    /// Fetches a record for a specific session ID, checking the specified database or all candidates.
    public static func fetchRecord(
        sessionID: String,
        databasePath: String? = nil,
        appDataDir: String? = nil
    ) -> AgySessionRecord? {
        if let databasePath, FileManager.default.fileExists(atPath: databasePath) {
            if let record = queryRecord(sessionID: sessionID, databasePath: databasePath) {
                return record
            }
        }

        if let inferredPath = Self.databasePath(forAppDataDir: appDataDir) {
            if let record = queryRecord(sessionID: sessionID, databasePath: inferredPath) {
                return record
            }
        }

        for path in candidateDatabasePaths() {
            if path == databasePath { continue }
            if let record = queryRecord(sessionID: sessionID, databasePath: path) {
                return record
            }
        }

        return nil
    }

    private static func queryRecord(sessionID: String, databasePath: String) -> AgySessionRecord? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT title, preview, not_fully_idle, status, last_modified_time, workspace_uris, step_count, app_data_dir 
        FROM conversation_summaries 
        WHERE conversation_id = ? 
        LIMIT 1;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (sessionID as NSString).utf8String, -1, nil)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }

        let title = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
        let preview = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
        let notFullyIdle = sqlite3_column_int(stmt, 2)
        let status = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
        let lastModifiedStr = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
        let workspaceURIsStr = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
        let stepCount = Int(sqlite3_column_int(stmt, 6))
        let appDataDir = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? ""

        let isRunning = (notFullyIdle == 1) || (status == "CASCADE_RUN_STATUS_RUNNING")
        let lastModifiedTime = parseDate(lastModifiedStr) ?? .now
        let workspaceURIs = parseWorkspaceURIs(workspaceURIsStr)

        return AgySessionRecord(
            sessionID: sessionID,
            title: title,
            preview: preview,
            isRunning: isRunning,
            lastModifiedTime: lastModifiedTime,
            workspaceURIs: workspaceURIs,
            stepCount: stepCount,
            appDataDir: appDataDir
        )
    }

    private static func parseWorkspaceURIs(_ jsonString: String) -> [String] {
        guard let data = jsonString.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return []
        }
        return array
    }

    private static func parseDate(_ dateString: String) -> Date? {
        guard !dateString.isEmpty, !dateString.hasPrefix("0001-01-01") else {
            return nil
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: dateString) {
            return date
        }

        // Antigravity SQLite uses space separator: "2026-10-03 11:21:07.123456+00:00"
        let tFormat = dateString.replacingOccurrences(of: " ", with: "T")
        if let date = isoFormatter.date(from: tFormat) {
            return date
        }

        let standardFormatter = ISO8601DateFormatter()
        if let date = standardFormatter.date(from: tFormat) {
            return date
        }

        return nil
    }
}
