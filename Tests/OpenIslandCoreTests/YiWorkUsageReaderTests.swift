import Foundation
import Testing
@testable import OpenIslandCore

struct YiWorkUsageReaderTests {
    private let calendar = Calendar.current

    @Test
    func countsANewSessionInFull() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        try fixture.writeSession(
            id: "91820845",
            updatedAt: Date(),
            input: 1_000,
            output: 100,
            cacheRead: 800
        )

        let snapshot = YiWorkUsageReader.loadToday(
            dataDirectoryURL: fixture.dataDirectory,
            stateURL: fixture.stateURL,
            calendar: calendar
        )

        // The assistant's provider is OpenAI-shaped: `input_tokens` already
        // contains the cached ones.
        #expect(snapshot.totals.totalTokens == 1_100)
        #expect(snapshot.totals.cacheReadTokens == 800)
        #expect(snapshot.totals.requestCount == 1)
        #expect(snapshot.activeSessionsCount == 1)
        #expect(snapshot.dataDirectory == fixture.dataDirectory)
    }

    @Test
    func countsOnlyGrowthOnLaterReads() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let now = Date()
        try fixture.writeSession(id: "91820845", updatedAt: now, input: 1_000, output: 100, cacheRead: 800)

        let first = YiWorkUsageReader.loadToday(
            dataDirectoryURL: fixture.dataDirectory,
            stateURL: fixture.stateURL,
            calendar: calendar
        )
        #expect(first.totals.totalTokens == 1_100)

        // Same numbers read twice must not double count.
        let unchanged = YiWorkUsageReader.loadToday(
            dataDirectoryURL: fixture.dataDirectory,
            stateURL: fixture.stateURL,
            calendar: calendar
        )
        #expect(unchanged.totals.totalTokens == 1_100)

        try fixture.writeSession(id: "91820845", updatedAt: now, input: 1_500, output: 120, cacheRead: 1_200)
        let grown = YiWorkUsageReader.loadToday(
            dataDirectoryURL: fixture.dataDirectory,
            stateURL: fixture.stateURL,
            calendar: calendar
        )
        #expect(grown.totals.totalTokens == 1_620)
        #expect(grown.totals.cacheReadTokens == 1_200)
    }

    @Test
    func ignoresGrowthTheBackendWroteBeforeToday() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        try fixture.writeSession(
            id: "old-session",
            updatedAt: Date().addingTimeInterval(-86_400 * 2),
            input: 5_000,
            output: 500,
            cacheRead: 0
        )

        let snapshot = YiWorkUsageReader.loadToday(
            dataDirectoryURL: fixture.dataDirectory,
            stateURL: fixture.stateURL,
            calendar: calendar
        )

        #expect(snapshot.totals.totalTokens == 0)
        #expect(snapshot.activeSessionsCount == 0)
    }

    @Test
    func seedsWithoutCountingAConversationThatPredatesToday() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        // Started two days ago, still in use today: its counter already holds
        // earlier days, so the first read must not claim all of it.
        try fixture.writeSession(
            id: "long-running",
            createdAt: Date().addingTimeInterval(-86_400 * 2),
            updatedAt: Date(),
            input: 9_000,
            output: 900,
            cacheRead: 0
        )

        let snapshot = YiWorkUsageReader.loadToday(
            dataDirectoryURL: fixture.dataDirectory,
            stateURL: fixture.stateURL,
            calendar: calendar
        )
        #expect(snapshot.totals.totalTokens == 0)

        // Growth from here on is real and counts.
        try fixture.writeSession(
            id: "long-running",
            createdAt: Date().addingTimeInterval(-86_400 * 2),
            updatedAt: Date(),
            input: 9_500,
            output: 950,
            cacheRead: 0
        )
        let grown = YiWorkUsageReader.loadToday(
            dataDirectoryURL: fixture.dataDirectory,
            stateURL: fixture.stateURL,
            calendar: calendar
        )
        #expect(grown.totals.totalTokens == 550)
    }

    @Test
    func keepsBaselinesAcrossTheDayRollover() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let now = Date()
        try fixture.writeSession(id: "91820845", updatedAt: now, input: 1_000, output: 100, cacheRead: 0)

        _ = YiWorkUsageReader.loadToday(
            dataDirectoryURL: fixture.dataDirectory,
            stateURL: fixture.stateURL,
            now: now,
            calendar: calendar
        )

        let nextDay = calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
        let rolled = YiWorkUsageReader.loadToday(
            dataDirectoryURL: fixture.dataDirectory,
            stateURL: fixture.stateURL,
            now: nextDay,
            calendar: calendar
        )

        // A new day starts from zero, and yesterday's usage is not re-counted.
        #expect(rolled.totals.totalTokens == 0)
        #expect(rolled.activeSessionsCount == 0)
    }

    @Test
    func returnsEmptyWithoutADataDirectory() {
        let snapshot = YiWorkUsageReader.loadToday(
            dataDirectoryURL: URL(fileURLWithPath: "/nonexistent/yi-work-\(UUID().uuidString)"),
            stateURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("yi-work-state-\(UUID().uuidString).json"),
            calendar: calendar
        )
        #expect(snapshot == .empty)
    }

    @Test
    func resolvesTheMostRecentlyWrittenDataDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let stale = root.appendingPathComponent("YIWorkData", isDirectory: true)
        let active = root.appendingPathComponent(".yi-work-web-dev", isDirectory: true)
        for directory in [stale, active] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("db".utf8).write(to: directory.appendingPathComponent("aionui-backend.db"))
        }

        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let new = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: stale.path)
        try FileManager.default.setAttributes([.modificationDate: new], ofItemAtPath: active.path)

        let resolved = YiWorkUsageReader.resolveDataDirectory(from: [stale, active])
        #expect(resolved?.standardizedFileURL.path == active.standardizedFileURL.path)
    }

    @Test
    func parsesTheBackendMicrosecondTimestamps() {
        let micro = YiWorkUsageReader.parseTimestamp("2026-11-07T14:17:33.285543Z")
        let milli = YiWorkUsageReader.parseTimestamp("2026-11-07T14:17:33.285Z")
        let plain = YiWorkUsageReader.parseTimestamp("2026-11-07T14:17:33Z")

        #expect(micro != nil)
        #expect(milli != nil)
        #expect(plain != nil)
        #expect(abs((micro?.timeIntervalSince1970 ?? 0) - (milli?.timeIntervalSince1970 ?? 1)) < 0.01)
        #expect(YiWorkUsageReader.parseTimestamp(nil) == nil)
        #expect(YiWorkUsageReader.parseTimestamp("") == nil)
    }

    // MARK: - Fixture

    private struct Fixture {
        let root: URL
        let dataDirectory: URL
        let stateURL: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            dataDirectory = root.appendingPathComponent("YIWorkData", isDirectory: true)
            stateURL = root.appendingPathComponent("yi-work-usage.json")
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        }

        func writeSession(
            id: String,
            createdAt: Date? = nil,
            updatedAt: Date,
            input: Int,
            output: Int,
            cacheRead: Int
        ) throws {
            let directory = dataDirectory
                .appendingPathComponent("aionrs-sessions", isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
                .appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let stamp = formatter.string(from: updatedAt)
            let created = formatter.string(from: createdAt ?? updatedAt)

            let json = """
            {"id":"\(id)","created_at":"\(created)","updated_at":"\(stamp)","total_usage":{\
            "input_tokens":\(input),"output_tokens":\(output),\
            "cache_read_tokens":\(cacheRead),"cache_creation_tokens":0}}
            """
            try json.write(
                to: directory.appendingPathComponent("state.json"),
                atomically: true,
                encoding: .utf8
            )
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
