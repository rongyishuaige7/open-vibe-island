import Foundation
import Testing
@testable import OpenIslandCore

struct ClaudeProUsageReaderTests {
    @Test
    func readsEmptySnapshotWhenDirectoryDoesNotExist() throws {
        let nonexistent = URL(fileURLWithPath: "/tmp/nonexistent-sessions-\(UUID().uuidString)")
        let snapshot = try ClaudeProUsageReader.loadToday(
            sessionsDirectoryURL: nonexistent,
            projectsDirectoryURL: nonexistent
        )
        #expect(snapshot == .zero)
    }

    @Test
    func readsSessionStatusLineAndTranscript() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessionsDir = tempDir.appendingPathComponent("sessions")
        let projectsDir = tempDir.appendingPathComponent("projects")
        let projSubdir = projectsDir.appendingPathComponent("my-project")
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projSubdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let calendar = Calendar.current
        let now = Date()
        let dayStart = calendar.startOfDay(for: now)
        let todayTS = dayStart.timeIntervalSince1970 + 3600
        let yesterdayTS = dayStart.timeIntervalSince1970 - 7200

        let sessionID = "12345678-1234-1234-1234-123456789abc"
        let sessionContent = """
        {
          "session_id": "\(sessionID)",
          "samples": [
            {"t": \(yesterdayTS), "cost": 1.5, "rl5h": 10, "rl7d": 20},
            {"t": \(todayTS), "cost": 4.25, "rl5h": 35, "rl7d": 45}
          ]
        }
        """
        try sessionContent.write(
            to: sessionsDir.appendingPathComponent("\(sessionID).json"),
            atomically: true,
            encoding: .utf8
        )

        let isoDate = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: todayTS))
        let transcriptContent = """
        {"type":"message","timestamp":"\(isoDate)","message":{"usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200}}}
        {"type":"message","timestamp":"\(isoDate)","message":{"usage":{"input_tokens":50,"output_tokens":25,"cache_read_input_tokens":500,"cache_creation_input_tokens":0}}}
        """
        try transcriptContent.write(
            to: projSubdir.appendingPathComponent("\(sessionID).jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let snapshot = try ClaudeProUsageReader.loadToday(
            sessionsDirectoryURL: sessionsDir,
            projectsDirectoryURL: projectsDir,
            now: now,
            calendar: calendar
        )

        #expect(snapshot.activeSessionsCount == 1)
        #expect(snapshot.estimatedCostUSD == 2.75) // 4.25 - 1.5 = 2.75
        #expect(snapshot.rateLimit5hPercent == 35)
        #expect(snapshot.rateLimit7dPercent == 45)
        #expect(snapshot.totals.requestCount == 2)
        #expect(snapshot.inputTokens == 150)
        #expect(snapshot.outputTokens == 75)
        #expect(snapshot.totals.cacheReadTokens == 1500)
        #expect(snapshot.cacheCreationTokens == 200)
        #expect(snapshot.totals.totalTokens == 150 + 75 + 1500 + 200)
    }

    @Test
    func fallsBackToStatusLineSamplesWhenTranscriptMissing() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessionsDir = tempDir.appendingPathComponent("sessions")
        let projectsDir = tempDir.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let now = Date()
        let todayTS = Calendar.current.startOfDay(for: now).timeIntervalSince1970 + 1000

        let sessionID = "87654321-4321-4321-4321-cba987654321"
        let sessionContent = """
        {
          "session_id": "\(sessionID)",
          "samples": [
            {"t": \(todayTS), "cost": 0.85, "in": 5000, "out": 120, "rl5h": 20, "rl7d": 30},
            {"t": \(todayTS + 60), "cost": 1.20, "in": 5500, "out": 80, "rl5h": 22, "rl7d": 30}
          ]
        }
        """
        try sessionContent.write(
            to: sessionsDir.appendingPathComponent("\(sessionID).json"),
            atomically: true,
            encoding: .utf8
        )

        let snapshot = try ClaudeProUsageReader.loadToday(
            sessionsDirectoryURL: sessionsDir,
            projectsDirectoryURL: projectsDir,
            now: now
        )

        #expect(snapshot.activeSessionsCount == 1)
        #expect(snapshot.estimatedCostUSD == 1.20)
        #expect(snapshot.totals.requestCount == 2)
        #expect(snapshot.outputTokens == 200) // 120 + 80
        #expect(snapshot.inputTokens == 5500)
        #expect(snapshot.totals.totalTokens == 5700)
    }

    @Test
    func countsAppendedTranscriptLinesWithoutRereadingAndStartsOverOnReplace() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessionsDir = tempDir.appendingPathComponent("sessions")
        let projSubdir = tempDir.appendingPathComponent("projects").appendingPathComponent("my-project")
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projSubdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let calendar = Calendar.current
        let now = Date()
        let todayTS = calendar.startOfDay(for: now).timeIntervalSince1970 + 60
        let yesterdayTS = todayTS - 86_400
        let sessionID = "abcdef01-1234-1234-1234-123456789abc"
        try """
        {"session_id": "\(sessionID)", "samples": [{"t": \(todayTS), "cost": 1.0}]}
        """.write(to: sessionsDir.appendingPathComponent("\(sessionID).json"), atomically: true, encoding: .utf8)

        func line(_ ts: TimeInterval, output: Int) -> String {
            let iso = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: ts))
            return #"{"timestamp":"\#(iso)","message":{"usage":{"input_tokens":1,"output_tokens":\#(output)}}}"#
        }
        let transcriptURL = projSubdir.appendingPathComponent("\(sessionID).jsonl")
        func append(_ text: String) throws {
            let handle = try FileHandle(forWritingTo: transcriptURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        }
        func load() throws -> ClaudeProUsageSnapshot {
            try ClaudeProUsageReader.loadToday(
                sessionsDirectoryURL: sessionsDir,
                projectsDirectoryURL: tempDir.appendingPathComponent("projects"),
                now: now,
                calendar: calendar
            )
        }

        try (line(yesterdayTS, output: 1000) + "\n" + line(todayTS, output: 10) + "\n")
            .write(to: transcriptURL, atomically: true, encoding: .utf8)
        #expect(try load().outputTokens == 10)

        // A complete last line without a newline counts.
        try append(line(todayTS, output: 20))
        #expect(try load().outputTokens == 30)

        // A line the writer is still appending waits until it is complete.
        let pending = "\n" + line(todayTS, output: 40)
        let splitIndex = pending.index(pending.startIndex, offsetBy: 30)
        try append(String(pending[..<splitIndex]))
        #expect(try load().outputTokens == 30)
        try append(String(pending[splitIndex...]) + "\n")
        let grown = try load()
        #expect(grown.outputTokens == 70)
        #expect(grown.totals.requestCount == 3)

        // A rewritten transcript is a new file and is counted from scratch.
        try (line(todayTS, output: 5) + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        let replaced = try load()
        #expect(replaced.outputTokens == 5)
        #expect(replaced.totals.requestCount == 1)
    }

    @Test
    func deduplicatesStreamingAndToolSnapshotLinesByMessageId() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessionsDir = tempDir.appendingPathComponent("sessions")
        let projSubdir = tempDir.appendingPathComponent("projects").appendingPathComponent("my-project")
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projSubdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let calendar = Calendar.current
        let now = Date()
        let todayTS = calendar.startOfDay(for: now).timeIntervalSince1970 + 60
        let sessionID = "dedup-test-1234-1234-123456789abc"
        try """
        {"session_id": "\(sessionID)", "samples": [{"t": \(todayTS), "cost": 1.0}]}
        """.write(to: sessionsDir.appendingPathComponent("\(sessionID).json"), atomically: true, encoding: .utf8)

        let iso = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: todayTS))
        func msgLine(msgId: String, out: Int, cacheRead: Int) -> String {
            #"{"timestamp":"\#(iso)","type":"assistant","message":{"id":"\#(msgId)","usage":{"input_tokens":10,"output_tokens":\#(out),"cache_read_input_tokens":\#(cacheRead)}}}\#n"#
        }

        let transcriptURL = projSubdir.appendingPathComponent("\(sessionID).jsonl")
        // Write the same message ID 3 times (simulating parallel tool usage / streaming snapshots) + msg_2 once
        let content = msgLine(msgId: "msg_1", out: 100, cacheRead: 500)
            + msgLine(msgId: "msg_1", out: 100, cacheRead: 500)
            + msgLine(msgId: "msg_1", out: 100, cacheRead: 500)
            + msgLine(msgId: "msg_2", out: 200, cacheRead: 1000)
        try content.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let snapshot = try ClaudeProUsageReader.loadToday(
            sessionsDirectoryURL: sessionsDir,
            projectsDirectoryURL: tempDir.appendingPathComponent("projects"),
            now: now,
            calendar: calendar
        )

        // Only 2 distinct requests should be counted, not 4
        #expect(snapshot.totals.requestCount == 2)
        #expect(snapshot.outputTokens == 300) // 100 + 200
        #expect(snapshot.totals.cacheReadTokens == 1500) // 500 + 1000
        #expect(snapshot.totals.totalTokens == 20 + 300 + 1500)

        // Appending another snapshot of msg_2 should not increase tokens
        let handle = try FileHandle(forWritingTo: transcriptURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(msgLine(msgId: "msg_2", out: 200, cacheRead: 1000).utf8))

        let secondSnapshot = try ClaudeProUsageReader.loadToday(
            sessionsDirectoryURL: sessionsDir,
            projectsDirectoryURL: tempDir.appendingPathComponent("projects"),
            now: now,
            calendar: calendar
        )
        #expect(secondSnapshot.totals.requestCount == 2)
        #expect(secondSnapshot.outputTokens == 300)
    }

    @Test
    func readsEachInstanceIndependently() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let calendar = Calendar.current
        let now = Date()
        let todayTS = calendar.startOfDay(for: now).timeIntervalSince1970 + 600

        let pro = try makeFixture(
            under: root,
            name: "pro",
            sessionID: "11111111-1111-1111-1111-111111111111",
            todayTS: todayTS,
            outputTokens: 100,
            cacheReadTokens: 1_000,
            costDelta: 2.75,
            rateLimit5h: 35,
            rateLimit7d: 45,
            displayName: "rongyi"
        )
        let pro2 = try makeFixture(
            under: root,
            name: "pro2",
            sessionID: "22222222-2222-2222-2222-222222222222",
            todayTS: todayTS,
            outputTokens: 20,
            cacheReadTokens: 300,
            costDelta: 0.5,
            rateLimit5h: 12,
            rateLimit7d: 7,
            displayName: "yirong"
        )

        let proSnapshot = try ClaudeProUsageReader.loadToday(instance: pro, now: now, calendar: calendar)
        let pro2Snapshot = try ClaudeProUsageReader.loadToday(instance: pro2, now: now, calendar: calendar)

        #expect(proSnapshot.outputTokens == 100)
        #expect(pro2Snapshot.outputTokens == 20)
        #expect(proSnapshot.estimatedCostUSD == 2.75)
        #expect(pro2Snapshot.estimatedCostUSD == 0.5)
        #expect(proSnapshot.rateLimit5hPercent == 35)
        #expect(pro2Snapshot.rateLimit5hPercent == 12)
        #expect(proSnapshot.rateLimit7dPercent == 45)
        #expect(pro2Snapshot.rateLimit7dPercent == 7)
        #expect(proSnapshot.accountHint == "rongyi")
        #expect(pro2Snapshot.accountHint == "yirong")
    }

    @Test
    func labelsAnInstanceWithItsFallbackWhenNoProfileWasWritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let calendar = Calendar.current
        let now = Date()
        let todayTS = calendar.startOfDay(for: now).timeIntervalSince1970 + 600

        let instance = try makeFixture(
            under: root,
            name: "pro2",
            sessionID: "33333333-3333-3333-3333-333333333333",
            todayTS: todayTS,
            outputTokens: 5,
            cacheReadTokens: 10,
            costDelta: 0.1,
            rateLimit5h: 3,
            rateLimit7d: 4,
            displayName: nil
        )

        let snapshot = try ClaudeProUsageReader.loadToday(instance: instance, now: now, calendar: calendar)
        #expect(snapshot.accountHint == "Pro2")
    }

    /// Claude Code rewrites `.claude.json` while it runs, so a read can land on
    /// a half-written file. The row must keep the name it already showed
    /// instead of flickering back to the generic hint.
    @Test
    func keepsTheLastProfileNameWhenTheProfileBecomesUnreadable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let calendar = Calendar.current
        let now = Date()
        let todayTS = calendar.startOfDay(for: now).timeIntervalSince1970 + 600

        let instance = try makeFixture(
            under: root,
            name: "pro2",
            sessionID: "44444444-4444-4444-4444-444444444444",
            todayTS: todayTS,
            outputTokens: 1,
            cacheReadTokens: 1,
            costDelta: 0.01,
            rateLimit5h: 1,
            rateLimit7d: 2,
            displayName: "yirong"
        )

        let first = try ClaudeProUsageReader.loadToday(instance: instance, now: now, calendar: calendar)
        #expect(first.accountHint == "yirong")

        try "{\"oauthAccount\":"
            .write(
                to: instance.configDirectoryURL.appendingPathComponent(".claude.json"),
                atomically: true,
                encoding: .utf8
            )

        let second = try ClaudeProUsageReader.loadToday(instance: instance, now: now, calendar: calendar)
        #expect(second.accountHint == "yirong")
    }

    /// Writes a sandbox laid out the way a hardened install is: a status line
    /// state store, one workspace of transcripts, and optionally the profile
    /// Claude Code caches.
    private func makeFixture(
        under root: URL,
        name: String,
        sessionID: String,
        todayTS: TimeInterval,
        outputTokens: Int,
        cacheReadTokens: Int,
        costDelta: Double,
        rateLimit5h: Int,
        rateLimit7d: Int,
        displayName: String?
    ) throws -> ClaudeProInstance {
        let instance = ClaudeProInstance(
            id: name,
            fallbackAccountHint: name == "pro" ? "Pro" : "Pro2",
            configDirectoryURL: root.appendingPathComponent(name, isDirectory: true)
        )
        let sessionsDirectory = instance.sessionsDirectoryURL
        let projectDirectory = instance.projectsDirectoryURL
            .appendingPathComponent("my-project", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)

        try """
        {"session_id": "\(sessionID)", "samples": [
          {"t": \(todayTS - 86_400), "cost": 1.5},
          {"t": \(todayTS), "cost": \(1.5 + costDelta), "rl5h": \(rateLimit5h), "rl7d": \(rateLimit7d)}
        ]}
        """.write(
            to: sessionsDirectory.appendingPathComponent("\(sessionID).json"),
            atomically: true,
            encoding: .utf8
        )

        let iso = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: todayTS))
        try """
        {"type":"assistant","timestamp":"\(iso)","message":{"usage":{"input_tokens":10,"output_tokens":\(outputTokens),"cache_read_input_tokens":\(cacheReadTokens),"cache_creation_input_tokens":0}}}
        """.write(
            to: projectDirectory.appendingPathComponent("\(sessionID).jsonl"),
            atomically: true,
            encoding: .utf8
        )

        if let displayName {
            try """
            {"oauthAccount":{"displayName":"\(displayName)"}}
            """.write(
                to: instance.configDirectoryURL.appendingPathComponent(".claude.json"),
                atomically: true,
                encoding: .utf8
            )
        }

        return instance
    }
}
