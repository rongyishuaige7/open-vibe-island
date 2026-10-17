import Foundation
import Testing
@testable import OpenIslandCore

struct ClaudeSessionRegistryTests {
    @Test
    func claudeSessionRegistryRoundTripsTrackedSessions() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-island-claude-registry-\(UUID().uuidString)", isDirectory: true)
        let fileURL = rootURL.appendingPathComponent("claude-session-registry.json")
        let registry = ClaudeSessionRegistry(fileURL: fileURL)

        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let records = [
            ClaudeTrackedSessionRecord(
                sessionID: "claude-session-1",
                title: "Claude · open-island",
                origin: .live,
                attachmentState: .attached,
                summary: "Working on the registry.",
                phase: .running,
                updatedAt: Date(timeIntervalSince1970: 1_000),
                jumpTarget: JumpTarget(
                    terminalApp: "Ghostty",
                    workspaceName: "open-island",
                    paneTitle: "claude ~/Personal/open-island",
                    workingDirectory: "/tmp/open-island",
                    terminalSessionID: "ghostty-claude",
                    terminalTTY: "/dev/ttys002"
                ),
                claudeMetadata: ClaudeSessionMetadata(
                    transcriptPath: "/tmp/claude.jsonl",
                    initialUserPrompt: "Start with Claude recovery.",
                    lastUserPrompt: "Tighten Claude restart recovery.",
                    lastAssistantMessage: "Implementing the registry.",
                    currentTool: "Task",
                    currentToolInputPreview: "Implement ClaudeSessionRegistry",
                    model: "sonnet"
                )
            ),
        ]

        try registry.save(records)
        let reloaded = try registry.load()

        #expect(reloaded == records)
        #expect(reloaded.first?.session.claudeMetadata?.transcriptPath == "/tmp/claude.jsonl")
        #expect(reloaded.first?.session.jumpTarget?.terminalTTY == "/dev/ttys002")
    }

    @Test
    func claudeTrackedSessionRecordRestoresAsStale() {
        let record = ClaudeTrackedSessionRecord(
            sessionID: "claude-session-1",
            title: "Claude · open-island",
            origin: .live,
            attachmentState: .attached,
            summary: "Working on the registry.",
            phase: .running,
            updatedAt: .now,
            jumpTarget: JumpTarget(
                terminalApp: "Ghostty",
                workspaceName: "open-island",
                paneTitle: "claude ~/Personal/open-island",
                workingDirectory: "/tmp/open-island",
                terminalSessionID: "ghostty-claude",
                terminalTTY: "/dev/ttys002"
            )
        )

        #expect(record.session.attachmentState == .attached)
        #expect(record.restorableSession.attachmentState == .stale)
        #expect(record.restorableSession.jumpTarget?.terminalSessionID == "ghostty-claude")
    }
}

struct ClaudeSessionMetadataCompatibilityTests {
    @Test
    func legacyMetadataWithoutNewArraysStillDecodes() throws {
        let json = Data(#"""
        {
          "transcriptPath": "/tmp/claude.jsonl",
          "lastAssistantMessage": "Still here",
          "model": "sonnet"
        }
        """#.utf8)

        let metadata = try JSONDecoder().decode(ClaudeSessionMetadata.self, from: json)

        #expect(metadata.transcriptPath == "/tmp/claude.jsonl")
        #expect(metadata.activeSubagents.isEmpty)
        #expect(metadata.activeTasks.isEmpty)
    }

    @Test
    func registryRecordWithLegacyMetadataIsNotDropped() throws {
        let json = Data(#"""
        [{
          "sessionID": "claude-legacy",
          "title": "Claude · repo",
          "origin": "live",
          "attachmentState": "stale",
          "summary": "Older record",
          "phase": "completed",
          "updatedAt": 0,
          "claudeMetadata": {
            "transcriptPath": "/tmp/legacy.jsonl"
          }
        }]
        """#.utf8)

        let records = try JSONDecoder().decode([ClaudeTrackedSessionRecord].self, from: json)
        let record = try #require(records.first)

        #expect(record.sessionID == "claude-legacy")
        #expect(record.claudeMetadata?.transcriptPath == "/tmp/legacy.jsonl")
        #expect(record.claudeMetadata?.activeTasks.isEmpty == true)
    }
}
