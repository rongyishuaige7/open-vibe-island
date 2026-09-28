import Testing
@testable import OpenIslandCore

struct CodexTranscriptPathTests {
    @Test
    func recognizesRolloutsUnderDefaultAndCustomHomes() {
        #expect(CodexTranscriptPath.isRolloutTranscript(
            "/Users/me/.codex/sessions/2026/09/28/rollout-2026-09-28T10-00-00-0199aaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl"))
        #expect(CodexTranscriptPath.isRolloutTranscript(
            "/Users/me/.codex-yi/sessions/2026/09/28/rollout-2026-09-28T10-00-00-0199aaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl"))
        #expect(CodexTranscriptPath.isRolloutTranscript(
            "/opt/codex-home/archived_sessions/rollout-2026-09-01T10-00-00-x.jsonl"))
    }

    @Test
    func rejectsNonRolloutFiles() {
        #expect(!CodexTranscriptPath.isRolloutTranscript("/Users/me/.codex/sessions/2026/09/28/other.jsonl"))
        #expect(!CodexTranscriptPath.isRolloutTranscript("/Users/me/.codex/log/rollout-x.jsonl"))
        #expect(!CodexTranscriptPath.isRolloutTranscript("/Users/me/.codex/sessions/rollout-x.json"))
        #expect(!CodexTranscriptPath.isRolloutTranscript("/Users/me/.claude/projects/p/abc.jsonl"))
        #expect(!CodexTranscriptPath.isRolloutTranscript(""))
    }

    @Test
    func archivedDetectionWorksForAnyHome() {
        #expect(CodexTranscriptPath.isArchivedRolloutTranscript(
            "/Users/me/.codex/archived_sessions/rollout-2026-09-01T10-00-00-x.jsonl"))
        #expect(CodexTranscriptPath.isArchivedRolloutTranscript(
            "/Users/me/.codex-yi/archived_sessions/rollout-2026-09-01T10-00-00-x.jsonl"))
        #expect(!CodexTranscriptPath.isArchivedRolloutTranscript(
            "/Users/me/.codex-yi/sessions/2026/09/28/rollout-2026-09-28T10-00-00-x.jsonl"))
        #expect(!CodexTranscriptPath.isArchivedRolloutTranscript(
            "/Users/me/.codex/archived_sessions/notes.txt"))
    }
}
