import Foundation
import Testing
@testable import OpenIslandCore

struct ClaudeTranscriptDiscoveryTests {
    /// Writes a single-line jsonl transcript into a throwaway root and returns
    /// the discovery instance pointed at it. Caller is responsible for cleanup
    /// via the returned root URL.
    private func makeDiscovery(
        line: String,
        fileName: String = "\(UUID().uuidString).jsonl"
    ) throws -> (discovery: ClaudeTranscriptDiscovery, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-island-transcript-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try line.write(
            to: root.appendingPathComponent(fileName),
            atomically: true,
            encoding: .utf8
        )
        return (ClaudeTranscriptDiscovery(rootURL: root), root)
    }

    @Test
    func desktopEntrypointTagsSessionAsClaudeApp() throws {
        let line = #"{"type":"attachment","sessionId":"abc12345","cwd":"/Users/test/project","entrypoint":"claude-desktop","timestamp":"2026-07-22T18:00:00Z"}"#
        let (discovery, root) = try makeDiscovery(line: line)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessions = discovery.discoverRecentSessions()

        #expect(sessions.count == 1)
        #expect(sessions.first?.jumpTarget?.terminalApp == "Claude.app")
    }

    @Test
    func cliEntrypointStaysUnknown() throws {
        // A terminal (`cli`) session has no claude-desktop entrypoint and must
        // keep the "Unknown" sentinel — the terminal resolver handles it later.
        let line = #"{"type":"attachment","sessionId":"def67890","cwd":"/Users/test/project","entrypoint":"cli","timestamp":"2026-07-22T18:00:00Z"}"#
        let (discovery, root) = try makeDiscovery(line: line)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessions = discovery.discoverRecentSessions()

        #expect(sessions.count == 1)
        #expect(sessions.first?.jumpTarget?.terminalApp == "Unknown")
    }

    @Test
    func absentEntrypointFieldStaysUnknown() throws {
        // Older transcripts predate the entrypoint field entirely; they must
        // still resolve to "Unknown" rather than crashing or misclassifying.
        let line = #"{"type":"attachment","sessionId":"aaa11111","cwd":"/Users/test/project","timestamp":"2026-07-22T18:00:00Z"}"#
        let (discovery, root) = try makeDiscovery(line: line)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessions = discovery.discoverRecentSessions()

        #expect(sessions.count == 1)
        #expect(sessions.first?.jumpTarget?.terminalApp == "Unknown")
    }

    @Test
    func syntheticAssistantReplyKeepsTheRealModel() throws {
        let lines = [
            #"{"type":"assistant","sessionId":"bbb22222","cwd":"/Users/test/project","timestamp":"2026-07-22T18:00:00Z","message":{"role":"assistant","model":"claude-sonnet-5","content":[{"type":"text","text":"Done."}]}}"#,
            #"{"type":"assistant","sessionId":"bbb22222","cwd":"/Users/test/project","timestamp":"2026-07-22T18:00:05Z","message":{"role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"API Error"}]}}"#,
        ]
        let (discovery, root) = try makeDiscovery(line: lines.joined(separator: "\n"))
        defer { try? FileManager.default.removeItem(at: root) }

        let sessions = discovery.discoverRecentSessions()

        #expect(sessions.first?.claudeMetadata?.model == "claude-sonnet-5")
    }

    @Test
    func firstNonEmptyEntrypointIsLatched() throws {
        // An empty earlier entrypoint is skipped, the first non-empty value is
        // latched ("claude-desktop"), and a later record ("cli") must not
        // overwrite it.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-island-transcript-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let lines = [
            #"{"type":"attachment","sessionId":"bbb22222","cwd":"/Users/test/project","entrypoint":"","timestamp":"2026-07-22T17:55:00Z"}"#,
            #"{"type":"attachment","sessionId":"bbb22222","entrypoint":"claude-desktop","timestamp":"2026-07-22T18:00:00Z"}"#,
            #"{"type":"attachment","sessionId":"bbb22222","entrypoint":"cli","timestamp":"2026-07-22T18:05:00Z"}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(
            to: root.appendingPathComponent("bbb22222.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let sessions = ClaudeTranscriptDiscovery(rootURL: root).discoverRecentSessions()

        #expect(sessions.count == 1)
        #expect(sessions.first?.jumpTarget?.terminalApp == "Claude.app")
    }

    @Test
    func inProgressUserPromptDiscoversAsRunning() throws {
        let lines = [
            #"{"type":"user","sessionId":"run11111","cwd":"/Users/test/project","timestamp":"2026-07-22T18:00:00Z","message":{"role":"user","content":[{"type":"text","text":"Build the project"}]}}"#,
        ]
        let (discovery, root) = try makeDiscovery(line: lines.joined(separator: "\n"), fileName: "run11111.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }

        let sessions = discovery.discoverRecentSessions()

        #expect(sessions.count == 1)
        #expect(sessions.first?.phase == .running)
        #expect(sessions.first?.summary == "Build the project")
    }

    @Test
    func toolUseTurnDiscoversAsRunning() throws {
        let lines = [
            #"{"type":"user","sessionId":"run22222","cwd":"/Users/test/project","timestamp":"2026-07-22T18:00:00Z","message":{"role":"user","content":[{"type":"text","text":"Run tests"}]}}"#,
            #"{"type":"assistant","sessionId":"run22222","cwd":"/Users/test/project","timestamp":"2026-07-22T18:00:05Z","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"tool_1","name":"Bash","input":{"command":"swift test"}}]}}"#,
        ]
        let (discovery, root) = try makeDiscovery(line: lines.joined(separator: "\n"), fileName: "run22222.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }

        let sessions = discovery.discoverRecentSessions()

        #expect(sessions.count == 1)
        #expect(sessions.first?.phase == .running)
        #expect(sessions.first?.summary.contains("Running Bash") == true)
    }

    @Test
    func completedTurnWithEndTurnDiscoversAsCompleted() throws {
        let lines = [
            #"{"type":"user","sessionId":"done1111","cwd":"/Users/test/project","timestamp":"2026-07-22T18:00:00Z","message":{"role":"user","content":[{"type":"text","text":"Hello"}]}}"#,
            #"{"type":"assistant","sessionId":"done1111","cwd":"/Users/test/project","timestamp":"2026-07-22T18:00:05Z","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Hello there!"}]}}"#,
        ]
        let (discovery, root) = try makeDiscovery(line: lines.joined(separator: "\n"), fileName: "done1111.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }

        let sessions = discovery.discoverRecentSessions()

        #expect(sessions.count == 1)
        #expect(sessions.first?.phase == .completed)
        #expect(sessions.first?.summary == "Hello there!")
    }

    @Test
    func completedTurnWithTurnDurationDiscoversAsCompleted() throws {
        let lines = [
            #"{"type":"user","sessionId":"done2222","cwd":"/Users/test/project","timestamp":"2026-07-22T18:00:00Z","message":{"role":"user","content":[{"type":"text","text":"Hello"}]}}"#,
            #"{"type":"assistant","sessionId":"done2222","cwd":"/Users/test/project","timestamp":"2026-07-22T18:00:05Z","message":{"role":"assistant","content":[{"type":"text","text":"Working on it"}]}}"#,
            #"{"type":"system","subtype":"turn_duration","durationMs":1234,"sessionId":"done2222","cwd":"/Users/test/project","timestamp":"2026-07-22T18:00:06Z"}"#,
        ]
        let (discovery, root) = try makeDiscovery(line: lines.joined(separator: "\n"), fileName: "done2222.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }

        let sessions = discovery.discoverRecentSessions()

        #expect(sessions.count == 1)
        #expect(sessions.first?.phase == .completed)
    }
}
