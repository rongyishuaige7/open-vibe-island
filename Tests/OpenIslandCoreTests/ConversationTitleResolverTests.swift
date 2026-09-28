import Foundation
import Testing
@testable import OpenIslandCore

struct ConversationTitleResolverTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-island-titles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ lines: [String], to url: URL) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    @Test
    func codexIndexUsesLatestThreadNamePerSession() throws {
        let home = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        try write([
            #"{"id":"a","thread_name":"First name","updated_at":"2026-01-10T08:00:00.000000Z"}"#,
            #"{"id":"b","thread_name":"Other","updated_at":"2026-01-10T09:00:00.000000Z"}"#,
            #"{"id":"a","thread_name":"Renamed thread","updated_at":"2026-01-11T08:00:00.000000Z"}"#,
            #"{"id":"a","thread_name":"Stale older entry","updated_at":"2026-01-09T08:00:00.000000Z"}"#,
            #"{"id":"c","thread_name":"   ","updated_at":"2026-01-12T08:00:00.000000Z"}"#,
            "not json",
        ], to: home.appendingPathComponent("session_index.jsonl"))

        let titles = ConversationTitleResolver().titles(for: ["a", "b", "c", "missing"].map {
            ConversationTitleRequest(sessionID: $0, source: .codexIndex(codexHome: home.path))
        })

        #expect(titles == ["a": "Renamed thread", "b": "Other"])
    }

    @Test
    func codexHomeComesFromTheRolloutPath() {
        #expect(ConversationTitleRequest.codexHomePath(
            transcriptPath: "/Users/me/.codex-yi/sessions/2026/09/28/rollout-2026-09-28T10-00-00-x.jsonl",
            environment: [:]) == "/Users/me/.codex-yi")
        #expect(ConversationTitleRequest.codexHomePath(
            transcriptPath: "/Users/me/.codex/archived_sessions/rollout-2026-09-01T10-00-00-x.jsonl",
            environment: [:]) == "/Users/me/.codex")
        #expect(ConversationTitleRequest.codexHomePath(transcriptPath: nil, environment: ["CODEX_HOME": "/opt/codex"])
            == "/opt/codex")
        #expect(ConversationTitleRequest.codexHomePath(transcriptPath: nil, environment: [:])
            == (NSHomeDirectory() as NSString).appendingPathComponent(".codex"))
    }

    @Test
    func claudeCustomTitleBeatsAITitleAndLatestAITitleWins() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let aiOnly = dir.appendingPathComponent("s1.jsonl")
        try write([
            #"{"type":"user","message":{"role":"user","content":"hi"}}"#,
            #"{"type":"ai-title","aiTitle":"Early title","sessionId":"s1"}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":"ok"}}"#,
            #"{"type":"ai-title","aiTitle":"Refined title","sessionId":"s1"}"#,
        ], to: aiOnly)
        let renamed = dir.appendingPathComponent("s2.jsonl")
        try write([
            #"{"type":"custom-title","customTitle":"我的重命名","sessionId":"s2"}"#,
            #"{"type":"ai-title","aiTitle":"Newer AI title","sessionId":"s2"}"#,
        ], to: renamed)

        let titles = ConversationTitleResolver().titles(for: [
            ConversationTitleRequest(sessionID: "s1", source: .claudeTranscript(path: aiOnly.path)),
            ConversationTitleRequest(sessionID: "s2", source: .claudeTranscript(path: renamed.path)),
        ])

        #expect(titles == ["s1": "Refined title", "s2": "我的重命名"])
    }

    @Test
    func claudeTitleOutsideTheFirstWindowIsFound() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("s.jsonl")
        let filler = #"{"type":"assistant","message":{"content":""# + String(repeating: "x", count: 200) + #""}}"#
        try write([#"{"type":"ai-title","aiTitle":"Deep title","sessionId":"s"}"#]
            + Array(repeating: filler, count: 50), to: url)
        let request = [ConversationTitleRequest(sessionID: "s", source: .claudeTranscript(path: url.path))]

        #expect(ConversationTitleResolver(claudeTailWindows: [1_024]).titles(for: request).isEmpty)
        #expect(ConversationTitleResolver(claudeTailWindows: [1_024, 1_024 * 1_024]).titles(for: request)
            == ["s": "Deep title"])
    }

    @Test
    func claudeTitleRefreshesWhenTheTranscriptGrows() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("s.jsonl")
        try write([#"{"type":"ai-title","aiTitle":"Draft","sessionId":"s"}"#], to: url)
        let resolver = ConversationTitleResolver()
        let request = [ConversationTitleRequest(sessionID: "s", source: .claudeTranscript(path: url.path))]
        #expect(resolver.titles(for: request) == ["s": "Draft"])

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((#"{"type":"ai-title","aiTitle":"Final","sessionId":"s"}"# + "\n").utf8))
        try handle.close()

        #expect(resolver.titles(for: request) == ["s": "Final"])
    }

    @Test
    func titlesAreSanitizedToOneLine() {
        #expect(ConversationTitleResolver.sanitizedTitle("  修复\n  刘海\t显示  ") == "修复 刘海 显示")
        #expect(ConversationTitleResolver.sanitizedTitle(" \n ") == nil)
        #expect(ConversationTitleResolver.sanitizedTitle(nil) == nil)
        #expect(ConversationTitleResolver.sanitizedTitle(String(repeating: "长", count: 300))?.count
            == ConversationTitleResolver.maxTitleLength)
    }

    @Test
    func requestsCoverCodexAndClaudeSessionsOnly() {
        let at = Date(timeIntervalSince1970: 10_000)
        let rollout = "/Users/me/.codex-yi/sessions/2026/09/28/rollout-2026-09-28T10-00-00-cx.jsonl"
        let sessions = [
            AgentSession(id: "cx", title: "Codex · a", tool: .codex, phase: .completed, summary: "", updatedAt: at,
                         codexMetadata: CodexSessionMetadata(transcriptPath: rollout)),
            AgentSession(id: "cl", title: "Claude · b", tool: .claudeCode, phase: .completed, summary: "", updatedAt: at,
                         claudeMetadata: ClaudeSessionMetadata(transcriptPath: "/tmp/cl.jsonl")),
            AgentSession(id: "cl-synthetic", title: "Claude · c", tool: .claudeCode, phase: .completed, summary: "",
                         updatedAt: at),
            AgentSession(id: "gm", title: "Gemini · d", tool: .geminiCLI, phase: .completed, summary: "", updatedAt: at),
            AgentSession(id: "demo", title: "Codex · e", tool: .codex, origin: .demo, phase: .completed, summary: "",
                         updatedAt: at),
        ]

        #expect(ConversationTitleRequest.requests(for: sessions, environment: [:]) == [
            ConversationTitleRequest(sessionID: "cx", source: .codexIndex(codexHome: "/Users/me/.codex-yi")),
            ConversationTitleRequest(sessionID: "cl", source: .claudeTranscript(path: "/tmp/cl.jsonl")),
        ])
    }
}
