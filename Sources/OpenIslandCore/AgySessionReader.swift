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
    public var model: String?

    public init(
        sessionID: String,
        title: String,
        preview: String,
        isRunning: Bool,
        lastModifiedTime: Date,
        workspaceURIs: [String],
        stepCount: Int,
        appDataDir: String,
        model: String? = nil
    ) {
        self.sessionID = sessionID
        self.title = title
        self.preview = preview
        self.isRunning = isRunning
        self.lastModifiedTime = lastModifiedTime
        self.workspaceURIs = workspaceURIs
        self.stepCount = stepCount
        self.appDataDir = appDataDir
        self.model = model
    }
}

public final class AgySessionReader: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedDatabasePaths: (date: Date, paths: [String])?
    nonisolated(unsafe) private static var cachedDefaultModels: [String: (date: Date, model: String?)] = [:]

    private static let modelPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"The user changed setting `Model Selection` from (?:None|.*?) to (.+?)\.\s*(?:No need|</USER_SETTINGS_CHANGE>|\\n|\n|\r)"#,
            options: []
        )
    }()

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

    public static func fetchRecord(
        sessionID: String,
        transcriptPath: String?
    ) -> AgySessionRecord? {
        let dbPath = databasePath(forTranscriptPath: transcriptPath)
        return fetchRecord(sessionID: sessionID, databasePath: dbPath)
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

    private static func openDatabase(databasePath: String) -> OpaquePointer? {
        var db: OpaquePointer?
        // First try READWRITE so WAL shared-memory (-shm) and locks coordinate seamlessly with agy.
        var rc = sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil)
        if rc == SQLITE_OK {
            sqlite3_busy_timeout(db, 200)
            return db
        }
        sqlite3_close(db)
        db = nil

        // If READWRITE fails, try immutable URI (read-only without requiring WAL/SHM file creation).
        let uri = "file://\(databasePath)?immutable=1"
        rc = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil)
        if rc == SQLITE_OK {
            sqlite3_busy_timeout(db, 200)
            return db
        }
        sqlite3_close(db)
        return nil
    }

    private static func queryRecord(sessionID: String, databasePath: String) -> AgySessionRecord? {
        guard let db = openDatabase(databasePath: databasePath) else {
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

        let resolvedAppDataDir: String
        if appDataDir.hasPrefix("/") {
            resolvedAppDataDir = appDataDir
        } else {
            resolvedAppDataDir = URL(fileURLWithPath: databasePath).deletingLastPathComponent().path
        }

        let isRunning = (notFullyIdle == 1) || (status == "CASCADE_RUN_STATUS_RUNNING")
        let lastModifiedTime = parseDate(lastModifiedStr) ?? .now
        let workspaceURIs = parseWorkspaceURIs(workspaceURIsStr)
        let model = resolveModel(sessionID: sessionID, appDataDir: resolvedAppDataDir)

        return AgySessionRecord(
            sessionID: sessionID,
            title: title,
            preview: preview,
            isRunning: isRunning,
            lastModifiedTime: lastModifiedTime,
            workspaceURIs: workspaceURIs,
            stepCount: stepCount,
            appDataDir: resolvedAppDataDir,
            model: model
        )
    }

    /// Discovers recent sessions from all candidate databases updated on or after cutoff.
    public static func fetchRecentRecords(
        cutoff: Date = Date.now.addingTimeInterval(-86_400),
        limit: Int = 50
    ) -> [AgySessionRecord] {
        var records: [AgySessionRecord] = []
        var seenIDs = Set<String>()

        for dbPath in candidateDatabasePaths() {
            let dbRecords = queryRecentRecords(databasePath: dbPath, limit: limit)
            for record in dbRecords {
                guard record.lastModifiedTime >= cutoff else { continue }
                if seenIDs.insert(record.sessionID).inserted {
                    records.append(record)
                }
            }
        }

        return records.sorted(by: { $0.lastModifiedTime > $1.lastModifiedTime })
    }

    private static func queryRecentRecords(databasePath: String, limit: Int) -> [AgySessionRecord] {
        guard let db = openDatabase(databasePath: databasePath) else {
            return []
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT conversation_id, title, preview, not_fully_idle, status, last_modified_time, workspace_uris, step_count, app_data_dir 
        FROM conversation_summaries 
        ORDER BY last_modified_time DESC 
        LIMIT ?;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(limit))

        var results: [AgySessionRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let sessionID = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            guard !sessionID.isEmpty else { continue }
            let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let preview = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let notFullyIdle = sqlite3_column_int(stmt, 3)
            let status = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            let lastModifiedStr = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
            let workspaceURIsStr = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
            let stepCount = Int(sqlite3_column_int(stmt, 7))
            let appDataDir = sqlite3_column_text(stmt, 8).map { String(cString: $0) } ?? ""

            let resolvedAppDataDir: String
            if appDataDir.hasPrefix("/") {
                resolvedAppDataDir = appDataDir
            } else {
                resolvedAppDataDir = URL(fileURLWithPath: databasePath).deletingLastPathComponent().path
            }

            let isRunning = (notFullyIdle == 1) || (status == "CASCADE_RUN_STATUS_RUNNING")
            let lastModifiedTime = parseDate(lastModifiedStr) ?? .now
            let workspaceURIs = parseWorkspaceURIs(workspaceURIsStr)
            let model = resolveModel(sessionID: sessionID, appDataDir: resolvedAppDataDir)

            results.append(AgySessionRecord(
                sessionID: sessionID,
                title: title,
                preview: preview,
                isRunning: isRunning,
                lastModifiedTime: lastModifiedTime,
                workspaceURIs: workspaceURIs,
                stepCount: stepCount,
                appDataDir: resolvedAppDataDir,
                model: model
            ))
        }

        return results
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

    public static func resolveModel(sessionID: String, appDataDir: String) -> String? {
        guard !sessionID.isEmpty, !appDataDir.isEmpty else { return nil }

        // 1. Try reading the first chunk of the session transcript for model setting change
        let transcriptPath = (appDataDir as NSString).appendingPathComponent("brain/\(sessionID)/.system_generated/logs/transcript.jsonl")
        if let fileHandle = FileHandle(forReadingAtPath: transcriptPath) {
            defer { try? fileHandle.close() }
            let initialData = fileHandle.readData(ofLength: 8192)
            if let content = String(data: initialData, encoding: .utf8),
               let pattern = modelPattern,
               let match = pattern.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
               let range = Range(match.range(at: 1), in: content) {
                let model = String(content[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !model.isEmpty {
                    return model
                }
            }
        }

        // 2. Fall back to settings.json in appDataDir
        lock.lock()
        if let cached = cachedDefaultModels[appDataDir], Date.now.timeIntervalSince(cached.date) < 10 {
            lock.unlock()
            return cached.model
        }
        lock.unlock()

        let settingsPath = (appDataDir as NSString).appendingPathComponent("settings.json")
        var defaultModel: String?
        if let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let model = json["model"] as? String {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                defaultModel = trimmed
            }
        }

        if let defaultModel {
            lock.lock()
            cachedDefaultModels[appDataDir] = (date: .now, model: defaultModel)
            lock.unlock()
        }

        if let defaultModel {
            return defaultModel
        }

        // 3. Fall back to profile default based on appDataDir
        if appDataDir.lowercased().contains("pro") {
            return "Gemini 3.8 Pro"
        }
        return "Gemini 3.8 Flash"
    }
}

public extension AgySessionRecord {
    func asAgentSession() -> AgentSession {
        let firstWorkspace = workspaceURIs.first.flatMap { uri -> String? in
            if uri.hasPrefix("file://") {
                return URL(string: uri)?.path
            }
            return uri
        }
        let workspaceName = firstWorkspace.map { WorkspaceNameResolver.workspaceName(for: $0) } ?? "Workspace"
        let displayTitle = !title.isEmpty ? title : "Gemini · \(workspaceName)"
        let displayPreview = !preview.isEmpty ? preview : "Antigravity session in \(workspaceName)"
        let transcriptPath = (appDataDir as NSString).appendingPathComponent("brain/\(sessionID)/.system_generated/logs/transcript.jsonl")

        var session = AgentSession(
            id: sessionID,
            title: displayTitle,
            tool: .geminiCLI,
            origin: .live,
            attachmentState: .attached,
            phase: isRunning ? .running : .completed,
            summary: displayPreview,
            updatedAt: lastModifiedTime,
            jumpTarget: firstWorkspace.map { cwd in
                JumpTarget(
                    terminalApp: "Antigravity",
                    workspaceName: workspaceName,
                    paneTitle: "Gemini \(sessionID.prefix(8))",
                    workingDirectory: cwd
                )
            },
            geminiMetadata: GeminiSessionMetadata(
                transcriptPath: transcriptPath,
                initialUserPrompt: displayPreview,
                lastUserPrompt: displayPreview,
                model: model
            )
        )
        if !title.isEmpty {
            session.conversationTitle = title
        }
        return session
    }
}
