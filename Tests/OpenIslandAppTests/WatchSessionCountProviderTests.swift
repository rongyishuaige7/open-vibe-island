import Foundation
import Testing
@testable import OpenIslandApp
import OpenIslandCore

@MainActor
struct WatchSessionCountProviderTests {
    /// The Watch HTTP endpoint calls the provider on its own network queue,
    /// so it must not assume main-actor isolation.
    @Test
    func providerReadsSessionCountOffMainActor() async {
        let model = AppModel()
        let now = Date(timeIntervalSince1970: 2_000)
        model.state = SessionState(sessions: ["a", "b"].map { id in
            AgentSession(
                id: id,
                title: id,
                tool: .claudeCode,
                origin: .live,
                attachmentState: .attached,
                phase: .running,
                summary: "Running",
                updatedAt: now
            )
        })

        let provider = model.activeSessionCountProvider
        let count = await Task.detached { provider() }.value
        #expect(count == 2)
    }
}
