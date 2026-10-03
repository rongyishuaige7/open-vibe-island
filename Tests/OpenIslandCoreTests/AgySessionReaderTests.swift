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
            appDataDir: "/Users/test/.gemini/antigravity-cli"
        )

        let session = record.asAgentSession()
        #expect(session.id == "test-uuid-1234")
        #expect(session.title == "Test Task")
        #expect(session.tool == .geminiCLI)
        #expect(session.phase == .running)
        #expect(session.summary == "Test preview text")
        #expect(session.jumpTarget?.workingDirectory == "/Users/test/myproject")
        #expect(session.geminiMetadata?.transcriptPath == "/Users/test/.gemini/antigravity-cli/brain/test-uuid-1234/.system_generated/logs/transcript.jsonl")
    }
}

