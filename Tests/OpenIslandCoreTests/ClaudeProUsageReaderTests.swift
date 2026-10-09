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
}
