import Foundation
import Testing
@testable import OpenIslandCore

struct ConversationTitleSessionStateTests {
    @Test
    func reconcileSetsTitlesAndKeepsMissingOnes() {
        var state = SessionState(sessions: [
            AgentSession(id: "a", title: "Codex · repo", tool: .codex, phase: .completed, summary: "",
                         updatedAt: Date(timeIntervalSince1970: 10_000)),
        ])

        // `#expect` evaluates its operand on an immutable copy, so mutate first.
        let firstChanged = state.reconcileConversationTitles(["a": "整理刘海显示", "unknown": "x"])
        #expect(firstChanged)
        #expect(state.session(id: "a")?.conversationTitle == "整理刘海显示")

        let sameChanged = state.reconcileConversationTitles(["a": "整理刘海显示"])
        let emptyChanged = state.reconcileConversationTitles([:])
        #expect(!sameChanged)
        #expect(!emptyChanged)
        #expect(state.session(id: "a")?.conversationTitle == "整理刘海显示")
    }
}
