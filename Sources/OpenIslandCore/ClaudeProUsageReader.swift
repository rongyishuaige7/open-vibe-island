import Foundation
import os

/// Token totals, estimated cost, and rate limits loaded from Claude Pro's
/// hardened sandbox session state and transcript records.
public struct ClaudeProUsageSnapshot: Equatable, Sendable {
    public var totals: AgentTokenTotals
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationTokens: Int
    public var estimatedCostUSD: Double
    public var rateLimit5hPercent: Int?
    public var rateLimit7dPercent: Int?
    public var activeSessionsCount: Int
    public var accountHint: String

    public init(
        totals: AgentTokenTotals = .zero,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        estimatedCostUSD: Double = 0.0,
        rateLimit5hPercent: Int? = nil,
        rateLimit7dPercent: Int? = nil,
        activeSessionsCount: Int = 0,
        accountHint: String = "Pro"
    ) {
        self.totals = totals
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.rateLimit5hPercent = rateLimit5hPercent
        self.rateLimit7dPercent = rateLimit7dPercent
        self.activeSessionsCount = activeSessionsCount
        self.accountHint = accountHint
    }

    public static let zero = ClaudeProUsageSnapshot()
}

/// Reads real-time token usage, cost, and rate limits for isolated Claude Pro instances
/// via claude-statusline state session stores and hardened transcripts.
public enum ClaudeProUsageReader {
    public static var defaultSessionsDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-pro-hardened/home/.local/state/claude-statusline/sessions", isDirectory: true)
    }

    public static var defaultProjectsDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-pro-hardened/projects", isDirectory: true)
    }

    /// Sums today's token usage, costs, and current rate limits for Claude Pro
    /// within [local midnight, next midnight).
    public static func loadToday(
        sessionsDirectoryURL: URL = defaultSessionsDirectoryURL,
        projectsDirectoryURL: URL = defaultProjectsDirectoryURL,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> ClaudeProUsageSnapshot {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionsDirectoryURL.path) else {
            return .zero
        }

        let dayStart = calendar.startOfDay(for: now)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let startTS = dayStart.timeIntervalSince1970
        let endTS = dayEnd.timeIntervalSince1970

        guard let sessionFileNames = try? fileManager.contentsOfDirectory(atPath: sessionsDirectoryURL.path) else {
            return .zero
        }

        // Cache project subdirectories under projectsDirectoryURL for fast transcript lookups
        let projectSubdirs: [URL] = {
            guard fileManager.fileExists(atPath: projectsDirectoryURL.path),
                  let entries = try? fileManager.contentsOfDirectory(at: projectsDirectoryURL, includingPropertiesForKeys: [.isDirectoryKey]) else {
                return []
            }
            return entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }()

        var activeSessionsCount = 0
        var totalCost: Double = 0.0
        var latestSampleTS: TimeInterval = 0
        var latestRL5h: Int?
        var latestRL7d: Int?

        var totalRequests = 0
        var totalInputTokens = 0
        var totalOutputTokens = 0
        var totalCacheReadTokens = 0
        var totalCacheCreationTokens = 0

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackISOFormatter = ISO8601DateFormatter()
        fallbackISOFormatter.formatOptions = [.withInternetDateTime]

        var readTranscriptPaths = Set<String>()
        for fileName in sessionFileNames where fileName.hasSuffix(".json") {
            let sessionFileURL = sessionsDirectoryURL.appendingPathComponent(fileName)
            guard let data = try? Data(contentsOf: sessionFileURL),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let sessionID = json["session_id"] as? String,
                  let samples = json["samples"] as? [[String: Any]],
                  !samples.isEmpty else {
                continue
            }

            let todaySamples = samples.filter { sample in
                guard let t = number(from: sample["t"]) else { return false }
                return t >= startTS && t < endTS
            }

            guard !todaySamples.isEmpty else { continue }
            activeSessionsCount += 1

            // Cost delta calculation
            let priorSamples = samples.filter { sample in
                guard let t = number(from: sample["t"]) else { return false }
                return t < startTS && sample["cost"] != nil
            }
            let baseCost = priorSamples.last.flatMap { number(from: $0["cost"]) } ?? 0.0
            if let lastTodayCost = todaySamples.reversed().compactMap({ number(from: $0["cost"]) }).first {
                totalCost += max(0.0, lastTodayCost - baseCost)
            }

            // Track latest rate limits
            if let latestTodaySample = todaySamples.last,
               let sampleT = number(from: latestTodaySample["t"]),
               sampleT >= latestSampleTS {
                latestSampleTS = sampleT
                if let rl5h = intValue(from: latestTodaySample["rl5h"]) { latestRL5h = rl5h }
                if let rl7d = intValue(from: latestTodaySample["rl7d"]) { latestRL7d = rl7d }
            }

            // Resolve transcript for exact token counts
            var foundTranscript = false
            for projectSubdir in projectSubdirs {
                let candidateTranscriptURL = projectSubdir.appendingPathComponent("\(sessionID).jsonl")
                if fileManager.fileExists(atPath: candidateTranscriptURL.path) {
                    foundTranscript = true
                    readTranscriptPaths.insert(candidateTranscriptURL.path)
                    let tally = transcriptTally(
                        at: candidateTranscriptURL,
                        startTS: startTS,
                        endTS: endTS,
                        isoFormatter: isoFormatter,
                        fallbackFormatter: fallbackISOFormatter
                    )
                    totalRequests += tally.requests
                    totalInputTokens += tally.inputTokens
                    totalOutputTokens += tally.outputTokens
                    totalCacheReadTokens += tally.cacheReadTokens
                    totalCacheCreationTokens += tally.cacheCreationTokens
                    break
                }
            }

            // Fallback to statusline samples if transcript is missing
            if !foundTranscript {
                var sessionOut = 0
                for sample in todaySamples {
                    if let out = intValue(from: sample["out"]), out > 0 {
                        sessionOut += out
                        totalRequests += 1
                    }
                }
                totalOutputTokens += sessionOut
                if let lastCtxIn = todaySamples.last.flatMap({ intValue(from: $0["in"]) }) {
                    totalInputTokens += lastCtxIn
                }
            }
        }

        // Forget transcripts under this directory that no session counts today.
        let projectsPrefix = projectsDirectoryURL.path + "/"
        let countedPaths = readTranscriptPaths
        transcriptProgress.withLock { progress in
            progress = progress.filter { path, _ in
                !path.hasPrefix(projectsPrefix) || countedPaths.contains(path)
            }
        }

        let totalTokens = totalInputTokens + totalOutputTokens + totalCacheReadTokens + totalCacheCreationTokens
        let totals = AgentTokenTotals(
            requestCount: totalRequests,
            totalTokens: totalTokens,
            cacheReadTokens: totalCacheReadTokens
        )

        return ClaudeProUsageSnapshot(
            totals: totals,
            inputTokens: totalInputTokens,
            outputTokens: totalOutputTokens,
            cacheCreationTokens: totalCacheCreationTokens,
            estimatedCostUSD: (totalCost * 100).rounded() / 100.0,
            rateLimit5hPercent: latestRL5h,
            rateLimit7dPercent: latestRL7d,
            activeSessionsCount: activeSessionsCount,
            accountHint: "Pro"
        )
    }

    /// Today's usage counted from one transcript.
    struct TranscriptTally: Equatable, Sendable {
        var requests = 0
        var inputTokens = 0
        var outputTokens = 0
        var cacheReadTokens = 0
        var cacheCreationTokens = 0
    }

    /// How far a transcript has been counted. Transcripts are append-only
    /// JSONL and a long session's runs to tens of megabytes, so each read
    /// resumes at `offset` instead of re-parsing the whole file.
    private struct TranscriptProgress: Sendable {
        var fileNumber: Int
        var offset: Int
        var dayStart: TimeInterval
        var tally: TranscriptTally
    }

    private static let transcriptProgress = OSAllocatedUnfairLock(initialState: [String: TranscriptProgress]())

    /// Counts the lines appended since the last read and returns the day's
    /// running total. Starts over when the file is replaced or shrinks, or
    /// when the day changes.
    static func transcriptTally(
        at url: URL,
        startTS: TimeInterval,
        endTS: TimeInterval,
        isoFormatter: ISO8601DateFormatter,
        fallbackFormatter: ISO8601DateFormatter
    ) -> TranscriptTally {
        let path = url.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.intValue else {
            return TranscriptTally()
        }

        let fresh = TranscriptProgress(fileNumber: fileNumber, offset: 0, dayStart: startTS, tally: TranscriptTally())
        var progress = transcriptProgress.withLock { $0[path] } ?? fresh
        if progress.fileNumber != fileNumber || progress.dayStart != startTS || progress.offset > size {
            progress = fresh
        }

        if progress.offset < size, let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if (try? handle.seek(toOffset: UInt64(progress.offset))) != nil,
               let data = try? handle.readToEnd() {
                progress.offset += countLines(
                    in: data,
                    startTS: startTS,
                    endTS: endTS,
                    isoFormatter: isoFormatter,
                    fallbackFormatter: fallbackFormatter,
                    into: &progress.tally
                )
            }
        }

        let stored = progress
        transcriptProgress.withLock { $0[path] = stored }
        return progress.tally
    }

    /// Counts the lines in `data` and returns how many bytes it consumed. A
    /// last line without a newline is consumed only if it parses; otherwise
    /// the writer is still appending it and the next read picks it up.
    private static func countLines(
        in data: Data,
        startTS: TimeInterval,
        endTS: TimeInterval,
        isoFormatter: ISO8601DateFormatter,
        fallbackFormatter: ISO8601DateFormatter,
        into tally: inout TranscriptTally
    ) -> Int {
        let marker = Array("\"usage\"".utf8)
        return data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            var consumed = 0
            while consumed < buffer.count {
                let remaining = buffer.count - consumed
                let newline = memchr(base + consumed, Int32(UInt8(ascii: "\n")), remaining)
                let lineLength = newline.map { base.distance(to: UnsafeRawPointer($0)) - consumed } ?? remaining
                let line = UnsafeRawBufferPointer(rebasing: buffer[consumed..<(consumed + lineLength)])
                let hasUsage = memmem(line.baseAddress, line.count, marker, marker.count) != nil

                if newline == nil {
                    guard let object = try? JSONSerialization.jsonObject(with: Data(line)) else { break }
                    if hasUsage {
                        count(object, startTS: startTS, endTS: endTS, isoFormatter: isoFormatter,
                              fallbackFormatter: fallbackFormatter, into: &tally)
                    }
                    consumed = buffer.count
                } else {
                    if hasUsage, let object = try? JSONSerialization.jsonObject(with: Data(line)) {
                        count(object, startTS: startTS, endTS: endTS, isoFormatter: isoFormatter,
                              fallbackFormatter: fallbackFormatter, into: &tally)
                    }
                    consumed += lineLength + 1
                }
            }
            return consumed
        }
    }

    private static func count(
        _ object: Any,
        startTS: TimeInterval,
        endTS: TimeInterval,
        isoFormatter: ISO8601DateFormatter,
        fallbackFormatter: ISO8601DateFormatter,
        into tally: inout TranscriptTally
    ) {
        guard let obj = object as? [String: Any],
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else {
            return
        }

        // Check timestamp if present
        if let tsString = obj["timestamp"] as? String {
            let date = isoFormatter.date(from: tsString) ?? fallbackFormatter.date(from: tsString)
            if let date {
                let ts = date.timeIntervalSince1970
                if ts < startTS || ts >= endTS {
                    return
                }
            }
        }

        tally.requests += 1
        tally.inputTokens += intValue(from: usage["input_tokens"]) ?? 0
        tally.outputTokens += intValue(from: usage["output_tokens"]) ?? 0
        tally.cacheReadTokens += intValue(from: usage["cache_read_input_tokens"]) ?? 0
        tally.cacheCreationTokens += intValue(from: usage["cache_creation_input_tokens"]) ?? 0
    }

    private static func number(from value: Any?) -> Double? {
        if let num = value as? NSNumber {
            return num.doubleValue
        }
        if let str = value as? String {
            return Double(str)
        }
        return nil
    }

    private static func intValue(from value: Any?) -> Int? {
        if let num = value as? NSNumber {
            return num.intValue
        }
        if let str = value as? String {
            return Int(str)
        }
        return nil
    }
}
