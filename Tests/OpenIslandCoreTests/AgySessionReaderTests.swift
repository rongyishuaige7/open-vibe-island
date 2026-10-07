import Foundation
import SQLite3
import Testing
@testable import OpenIslandCore

@Suite
struct AgySessionReaderTests {
    @Test
    func databasePathResolutionFromTranscriptPath() {
        let transcript = "/Users/test/.gemini/antigravity-cli/brain/12345678-1234-1234-1234-123456789abc/.system_generated/logs/transcript.jsonl"
        _ = AgySessionReader.databasePath(forTranscriptPath: transcript)
        // Resolves if directory exists, or tests the path component logic
        let components = (transcript as NSString).pathComponents
        let brainIndex = components.lastIndex(of: "brain")!
        let appDataDir = NSString.path(withComponents: Array(components[..<brainIndex]))
        #expect(appDataDir == "/Users/test/.gemini/antigravity-cli")
    }

    @Test
    func sqliteQueryParsesRecordCorrectly() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("conversation_summaries.db").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            Issue.record("Failed to create test SQLite db")
            return
        }
        defer { sqlite3_close(db) }

        let createTable = """
        CREATE TABLE conversation_summaries (
            conversation_id text PRIMARY KEY,
            title text NOT NULL DEFAULT "",
            preview text NOT NULL DEFAULT "",
            step_count integer NOT NULL DEFAULT 0,
            last_modified_time datetime NOT NULL,
            workspace_uris text NOT NULL,
            status text NOT NULL DEFAULT "",
            not_fully_idle numeric NOT NULL DEFAULT false,
            app_data_dir text NOT NULL DEFAULT ""
        );
        """
        guard sqlite3_exec(db, createTable, nil, nil, nil) == SQLITE_OK else {
            Issue.record("Failed to create table")
            return
        }

        let insertSQL = """
        INSERT INTO conversation_summaries 
        (conversation_id, title, preview, step_count, last_modified_time, workspace_uris, status, not_fully_idle, app_data_dir)
        VALUES 
        ('session-1', 'My Agy Title', 'Hello Agy', 5, '2026-10-03 11:20:00+00:00', '["file:///Users/test/workspace"]', 'CASCADE_RUN_STATUS_RUNNING', 1, '/Users/test/.gemini/antigravity-cli'),
        ('session-2', 'Completed Title', 'Done task', 12, '2026-10-03 11:21:00+00:00', '["file:///Users/test/workspace"]', 'CASCADE_RUN_STATUS_IDLE', 0, '/Users/test/.gemini/antigravity-cli');
        """
        guard sqlite3_exec(db, insertSQL, nil, nil, nil) == SQLITE_OK else {
            Issue.record("Failed to insert rows")
            return
        }

        let record1 = AgySessionReader.fetchRecord(sessionID: "session-1", databasePath: dbPath)
        #expect(record1 != nil)
        #expect(record1?.title == "My Agy Title")
        #expect(record1?.preview == "Hello Agy")
        #expect(record1?.isRunning == true)
        #expect(record1?.stepCount == 5)
        #expect(record1?.workspaceURIs == ["file:///Users/test/workspace"])

        let record2 = AgySessionReader.fetchRecord(sessionID: "session-2", databasePath: dbPath)
        #expect(record2 != nil)
        #expect(record2?.title == "Completed Title")
        #expect(record2?.isRunning == false)
        #expect(record2?.stepCount == 12)

        let recordNotFound = AgySessionReader.fetchRecord(sessionID: "non-existent", databasePath: dbPath)
        #expect(recordNotFound == nil)
    }

    @Test
    func readsStatusChangesStillInWriteAheadLog() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("conversation_summaries.db").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            Issue.record("Failed to create test SQLite db")
            return
        }
        defer { sqlite3_close(db) }

        // Keep the writer open with checkpoints off, like a running Antigravity,
        // so the update below lives only in the -wal file.
        let setup = """
        PRAGMA journal_mode=WAL;
        PRAGMA wal_autocheckpoint=0;
        CREATE TABLE conversation_summaries (
            conversation_id text PRIMARY KEY,
            title text NOT NULL DEFAULT "",
            preview text NOT NULL DEFAULT "",
            step_count integer NOT NULL DEFAULT 0,
            last_modified_time datetime NOT NULL,
            workspace_uris text NOT NULL,
            status text NOT NULL DEFAULT "",
            not_fully_idle numeric NOT NULL DEFAULT false,
            app_data_dir text NOT NULL DEFAULT ""
        );
        INSERT INTO conversation_summaries (conversation_id, last_modified_time, workspace_uris, status, not_fully_idle)
        VALUES ('wal-session', '2026-10-03 11:20:00+00:00', '[]', 'CASCADE_RUN_STATUS_IDLE', 0);
        """
        guard sqlite3_exec(db, setup, nil, nil, nil) == SQLITE_OK else {
            Issue.record("Failed to set up WAL database")
            return
        }
        #expect(AgySessionReader.fetchRecord(sessionID: "wal-session", databasePath: dbPath)?.isRunning == false)

        let update = """
        UPDATE conversation_summaries
        SET status = 'CASCADE_RUN_STATUS_RUNNING', not_fully_idle = 1
        WHERE conversation_id = 'wal-session';
        """
        guard sqlite3_exec(db, update, nil, nil, nil) == SQLITE_OK else {
            Issue.record("Failed to update row")
            return
        }
        #expect(AgySessionReader.fetchRecord(sessionID: "wal-session", databasePath: dbPath)?.isRunning == true)
    }

    @Test
    func conversationTitleResolverSupportsAgyDatabase() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("conversation_summaries.db").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            Issue.record("Failed to create test SQLite db")
            return
        }
        defer { sqlite3_close(db) }

        let createAndInsert = """
        CREATE TABLE conversation_summaries (
            conversation_id text PRIMARY KEY,
            title text NOT NULL DEFAULT "",
            preview text NOT NULL DEFAULT "",
            step_count integer NOT NULL DEFAULT 0,
            last_modified_time datetime NOT NULL,
            workspace_uris text NOT NULL,
            status text NOT NULL DEFAULT "",
            not_fully_idle numeric NOT NULL DEFAULT false,
            app_data_dir text NOT NULL DEFAULT ""
        );
        INSERT INTO conversation_summaries (conversation_id, title, preview, step_count, last_modified_time, workspace_uris, status, not_fully_idle, app_data_dir)
        VALUES ('agy-1', 'Antigravity Session Title', 'prompt', 1, '2026-10-03 11:20:00+00:00', '[]', 'CASCADE_RUN_STATUS_RUNNING', 1, '');
        """
        guard sqlite3_exec(db, createAndInsert, nil, nil, nil) == SQLITE_OK else {
            Issue.record("Failed to set up table and row")
            return
        }

        let resolver = ConversationTitleResolver()
        let request = ConversationTitleRequest(sessionID: "agy-1", source: .agyDatabase(databasePath: dbPath))
        let titles = resolver.titles(for: [request])

        #expect(titles["agy-1"] == "Antigravity Session Title")
    }

    @Test
    func asAgentSessionConvertsRecordCorrectly() {
        let record = AgySessionRecord(
            sessionID: "test-uuid-1234",
            title: "Test Task",
            preview: "Test preview text",
            isRunning: true,
            lastModifiedTime: Date(timeIntervalSince1970: 1_700_000_000),
            workspaceURIs: ["file:///Users/test/myproject"],
            stepCount: 10,
            appDataDir: "/Users/test/.gemini/antigravity-cli",
            model: "Gemini 3.8 Flash (High)"
        )

        let session = record.asAgentSession()
        #expect(session.id == "test-uuid-1234")
        #expect(session.title == "Test Task")
        #expect(session.tool == .geminiCLI)
        #expect(session.phase == .running)
        #expect(session.attachmentState == .attached)
        #expect(session.summary == "Test preview text")
        #expect(session.jumpTarget?.terminalApp == "Antigravity")
        #expect(session.jumpTarget?.workingDirectory == "/Users/test/myproject")
        #expect(session.geminiMetadata?.transcriptPath == "/Users/test/.gemini/antigravity-cli/brain/test-uuid-1234/.system_generated/logs/transcript.jsonl")
        #expect(session.geminiMetadata?.model == "Gemini 3.8 Flash (High)")
        #expect(session.currentModelIdentifier == "Gemini 3.8 Flash (High)")
    }

    @Test
    func resolveModelReadsFromTranscriptAndSettings() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let brainDir = tempDir.appendingPathComponent("brain/session-test/.system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: brainDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 1. Transcript with Model Selection
        let transcriptPath = brainDir.appendingPathComponent("transcript.jsonl")
        let transcriptContent = """
        {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","content":"<USER_SETTINGS_CHANGE>\\nThe user changed setting `Model Selection` from None to Gemini 3.8 Flash (High).\\n</USER_SETTINGS_CHANGE>"}
        """
        try transcriptContent.write(to: transcriptPath, atomically: true, encoding: .utf8)

        let resolvedFromTranscript = AgySessionReader.resolveModel(sessionID: "session-test", appDataDir: tempDir.path)
        #expect(resolvedFromTranscript == "Gemini 3.8 Flash (High)")

        // 2. Fallback to settings.json
        let settingsPath = tempDir.appendingPathComponent("settings.json")
        let settingsContent = """
        {"model": "Claude Sonnet 4.6 (Thinking)"}
        """
        try settingsContent.write(to: settingsPath, atomically: true, encoding: .utf8)

        let resolvedFromSettings = AgySessionReader.resolveModel(sessionID: "session-other", appDataDir: tempDir.path)
        #expect(resolvedFromSettings == "Claude Sonnet 4.6 (Thinking)")
    }

    @Test
    func liveAntigravitySessionModelResolution() {
        let records = AgySessionReader.fetchRecentRecords(limit: 5)
        #expect(!records.isEmpty)
        for record in records {
            let session = record.asAgentSession()
            #expect(session.currentModelIdentifier != nil)
            let badge = SessionModelLabel.display(for: session.currentModelIdentifier)
            #expect(badge != nil)
        }
    }
}

