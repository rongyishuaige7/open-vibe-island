import Foundation

/// Recognizes Codex rollout transcripts by layout rather than by a fixed home.
///
/// Codex writes `<CODEX_HOME>/sessions/YYYY/MM/DD/rollout-*.jsonl` and moves
/// archived ones to `<CODEX_HOME>/archived_sessions/`. `CODEX_HOME` defaults to
/// `~/.codex` but launchers commonly point it elsewhere, so matching the literal
/// `/.codex/sessions/` misses every session from a non-default home.
public enum CodexTranscriptPath {
    /// True for a `rollout-*.jsonl` file under a `sessions` or `archived_sessions` directory.
    public static func isRolloutTranscript(_ path: String) -> Bool {
        let components = (path as NSString).pathComponents
        guard let fileName = components.last,
              fileName.hasPrefix("rollout-"),
              fileName.hasSuffix(".jsonl") else {
            return false
        }
        return components.dropLast().contains { $0 == "sessions" || $0 == "archived_sessions" }
    }

    /// True for a rollout transcript that sits under `archived_sessions`.
    public static func isArchivedRolloutTranscript(_ path: String) -> Bool {
        guard isRolloutTranscript(path) else {
            return false
        }
        return (path as NSString).pathComponents.dropLast().contains("archived_sessions")
    }
}
