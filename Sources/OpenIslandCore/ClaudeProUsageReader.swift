import Foundation

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
                    parseTranscript(
                        at: candidateTranscriptURL,
                        startTS: startTS,
                        endTS: endTS,
                        isoFormatter: isoFormatter,
                        fallbackFormatter: fallbackISOFormatter,
                        totalRequests: &totalRequests,
                        totalInputTokens: &totalInputTokens,
                        totalOutputTokens: &totalOutputTokens,
                        totalCacheReadTokens: &totalCacheReadTokens,
                        totalCacheCreationTokens: &totalCacheCreationTokens
                    )
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

    private static func parseTranscript(
        at url: URL,
        startTS: TimeInterval,
        endTS: TimeInterval,
        isoFormatter: ISO8601DateFormatter,
        fallbackFormatter: ISO8601DateFormatter,
        totalRequests: inout Int,
        totalInputTokens: inout Int,
        totalOutputTokens: inout Int,
        totalCacheReadTokens: inout Int,
        totalCacheCreationTokens: inout Int
    ) {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in content.split(separator: "\n") {
            guard line.contains("\"usage\""),
                  let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else {
                continue
            }

            // Check timestamp if present
            if let tsString = obj["timestamp"] as? String {
                let date = isoFormatter.date(from: tsString) ?? fallbackFormatter.date(from: tsString)
                if let date {
                    let ts = date.timeIntervalSince1970
                    if ts < startTS || ts >= endTS {
                        continue
                    }
                }
            }

            totalRequests += 1
            totalInputTokens += intValue(from: usage["input_tokens"]) ?? 0
            totalOutputTokens += intValue(from: usage["output_tokens"]) ?? 0
            totalCacheReadTokens += intValue(from: usage["cache_read_input_tokens"]) ?? 0
            totalCacheCreationTokens += intValue(from: usage["cache_creation_input_tokens"]) ?? 0
        }
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
