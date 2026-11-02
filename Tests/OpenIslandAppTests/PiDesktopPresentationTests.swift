import Foundation
import OpenIslandCore
import Testing
@testable import OpenIslandApp

@MainActor
struct PiDesktopPresentationTests {
    private func snapshot(title: String) -> PiDesktopSessionSnapshot {
        PiDesktopSessionSnapshot(
            sessionID: "s1",
            title: title,
            projectPath: "/Users/u/repo",
            workspaceName: "repo",
            phase: .completed,
            summary: "完成",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
    }

    @Test
    func islandHeadlineShowsTheConversationTitleNotNewSession() throws {
        var state = SessionState()
        for event in PiDesktopEventMapper.events(for: snapshot(title: "主对话"), existing: nil, timestamp: .now) {
            state.apply(event)
        }

        let session = try #require(state.session(id: "s1"))
        #expect(session.spotlightHeadlinePromptText == "主对话")
        #expect(session.spotlightHeadlinePromptText != "新会话")
    }

    @Test
    func placeholderTitleStillFallsBackToNewSession() throws {
        var state = SessionState()
        for event in PiDesktopEventMapper.events(for: snapshot(title: "新会话"), existing: nil, timestamp: .now) {
            state.apply(event)
        }

        let session = try #require(state.session(id: "s1"))
        #expect(session.spotlightHeadlinePromptText == "新会话")
    }
}
