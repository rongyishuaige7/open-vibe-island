import Foundation
import Testing
@testable import OpenIslandCore

struct SessionModelLabelTests {
    @Test
    func claudeIdsBecomeFamilyAndVersion() {
        #expect(SessionModelLabel.display(for: "claude-opus-5-5") == "Opus 5.5")
        #expect(SessionModelLabel.display(for: "claude-haiku-4-5-20251001") == "Haiku 4.5")
        #expect(SessionModelLabel.display(for: "claude-3-5-sonnet-20241022") == "Sonnet 3.5")
        #expect(SessionModelLabel.display(for: "claude-3-opus-20240229") == "Opus 3")
        #expect(SessionModelLabel.display(for: "claude-sonnet-5") == "Sonnet 5")
        #expect(SessionModelLabel.display(for: "claude-opus-5.5") == "Opus 5.5")
        #expect(SessionModelLabel.display(for: "claude-sonnet-4.5-20250929") == "Sonnet 4.5")
    }

    @Test
    func claudeProviderVariantsAreNormalized() {
        #expect(SessionModelLabel.display(for: "anthropic.claude-sonnet-4-5-20250929-v1:0") == "Sonnet 4.5")
        #expect(SessionModelLabel.display(for: "claude-opus-4-1@20250805") == "Opus 4.1")
        #expect(SessionModelLabel.display(for: "claude-opus-5-5[1m]") == "Opus 5.5")
        #expect(SessionModelLabel.display(for: "anthropic/claude-sonnet-5") == "Sonnet 5")
    }

    @Test
    func unknownClaudeFamilyKeepsTheRawId() {
        #expect(SessionModelLabel.display(for: "claude-fable-5-1") == "claude-fable-5-1")
    }

    @Test
    func otherProvidersKeepTheirIds() {
        #expect(SessionModelLabel.display(for: "gpt-5-codex") == "gpt-5-codex")
        #expect(SessionModelLabel.display(for: "gemini-2.5-pro") == "gemini-2.5-pro")
        #expect(SessionModelLabel.display(for: "openrouter/example-model") == "example-model")
    }

    @Test
    func longIdsAreClipped() {
        let label = SessionModelLabel.display(for: "example-provider-model-with-long-name")
        #expect(label == "example-provider-…")
        #expect(label?.count == SessionModelLabel.maximumLength)
    }

    @Test
    func emptyAndSyntheticModelsHaveNoLabel() {
        #expect(SessionModelLabel.display(for: nil) == nil)
        #expect(SessionModelLabel.display(for: "  ") == nil)
        #expect(SessionModelLabel.display(for: "<synthetic>") == nil)
    }

    @Test
    func sessionPrefersTheAgentsOwnMetadata() {
        var session = AgentSession(
            id: "model-session",
            title: "Claude · demo",
            tool: .claudeCode,
            phase: .running,
            summary: "Working",
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        #expect(session.currentModelIdentifier == nil)

        session.claudeMetadata = ClaudeSessionMetadata(model: " claude-sonnet-5 ")
        #expect(session.currentModelIdentifier == "claude-sonnet-5")

        session.claudeMetadata = nil
        session.codexMetadata = CodexSessionMetadata(model: "gpt-5-codex")
        #expect(session.currentModelIdentifier == "gpt-5-codex")
    }

    @Test
    func rolloutTurnContextTracksTheLatestModel() {
        let lines = [
            rolloutLine(type: "turn_context", payload: ["model": "gpt-5-codex", "cwd": "/tmp/demo"]),
            rolloutLine(type: "event_msg", payload: ["type": "user_message", "message": "Check the build."]),
            rolloutLine(type: "turn_context", payload: ["model": "gpt-5-mini", "cwd": "/tmp/demo"]),
            rolloutLine(type: "turn_context", payload: ["model": "", "cwd": "/tmp/demo"]),
        ]

        let snapshot = CodexRolloutReducer.snapshot(for: lines)
        #expect(snapshot.model == "gpt-5-mini")
        #expect(snapshot.metadata.model == "gpt-5-mini")

        let events = CodexRolloutReducer.events(
            from: CodexRolloutReducer.snapshot(for: Array(lines.prefix(2))),
            to: snapshot,
            sessionID: "codex-model-session",
            transcriptPath: "/tmp/rollout.jsonl"
        )
        let update = events.compactMap { event -> SessionMetadataUpdated? in
            if case let .sessionMetadataUpdated(payload) = event { return payload }
            return nil
        }.first
        #expect(update?.codexMetadata.model == "gpt-5-mini")
    }

    @Test
    func codexMetadataUpdateWithoutModelKeepsTheKnownModel() {
        var session = AgentSession(
            id: "codex-model-session",
            title: "Codex · demo",
            tool: .codex,
            phase: .running,
            summary: "Working",
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        session.codexMetadata = CodexSessionMetadata(lastUserPrompt: "Check the build.", model: "gpt-5-codex")
        var state = SessionState(sessions: [session])

        state.apply(
            .sessionMetadataUpdated(
                SessionMetadataUpdated(
                    sessionID: "codex-model-session",
                    codexMetadata: CodexSessionMetadata(lastAssistantMessage: "Build is green."),
                    timestamp: Date(timeIntervalSince1970: 1_010)
                )
            )
        )
        #expect(state.session(id: "codex-model-session")?.codexMetadata?.model == "gpt-5-codex")
        #expect(state.session(id: "codex-model-session")?.codexMetadata?.lastAssistantMessage == "Build is green.")

        state.apply(
            .sessionMetadataUpdated(
                SessionMetadataUpdated(
                    sessionID: "codex-model-session",
                    codexMetadata: CodexSessionMetadata(model: "gpt-5-mini"),
                    timestamp: Date(timeIntervalSince1970: 1_020)
                )
            )
        )
        #expect(state.session(id: "codex-model-session")?.codexMetadata?.model == "gpt-5-mini")
    }

    @Test
    func codexHookPayloadCarriesItsModelIntoMetadata() {
        let payload = CodexHookPayload(
            cwd: "/tmp/demo",
            hookEventName: .userPromptSubmit,
            model: "gpt-5-codex",
            permissionMode: .default,
            sessionID: "codex-model-session",
            transcriptPath: nil
        )
        #expect(payload.defaultCodexMetadata.model == "gpt-5-codex")

        let blank = CodexHookPayload(
            cwd: "/tmp/demo",
            hookEventName: .userPromptSubmit,
            model: " ",
            permissionMode: .default,
            sessionID: "codex-model-session",
            transcriptPath: nil
        )
        #expect(blank.defaultCodexMetadata.model == nil)
    }

    @Test
    func legacyCodexMetadataDecodesWithoutModel() throws {
        let json = #"{"transcriptPath":"/tmp/rollout.jsonl","lastUserPrompt":"Check the build."}"#
        let metadata = try JSONDecoder().decode(CodexSessionMetadata.self, from: Data(json.utf8))
        #expect(metadata.model == nil)
        #expect(metadata.lastUserPrompt == "Check the build.")
    }

    private func rolloutLine(type: String, payload: [String: Any]) -> String {
        let object: [String: Any] = [
            "timestamp": "2026-04-02T04:03:44.000Z",
            "type": type,
            "payload": payload,
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
