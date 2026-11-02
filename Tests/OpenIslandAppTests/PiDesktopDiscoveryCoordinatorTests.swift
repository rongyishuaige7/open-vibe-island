import Foundation
import OpenIslandCore
import Testing
@testable import OpenIslandApp

@MainActor
struct PiDesktopDiscoveryCoordinatorTests {
    /// Applies every event to a state the coordinator reads back, the way
    /// AppModel does, so start/activity decisions see real session state.
    @MainActor
    private final class Harness {
        var state = SessionState()
        var events: [AgentEvent] = []
        let coordinator = PiDesktopDiscoveryCoordinator()

        init() {
            coordinator.stateAccessor = { [weak self] in self?.state ?? SessionState() }
            coordinator.onEvent = { [weak self] event in
                guard let self else { return }
                events.append(event)
                state.apply(event)
            }
        }

        func publish(_ snapshots: [PiDesktopSessionSnapshot]) {
            coordinator.publish(snapshots, at: Date(timeIntervalSince1970: 1))
        }

        func sessionIDs() -> [String] {
            state.sessions.map(\.id).sorted()
        }
    }

    private func snapshot(
        id: String,
        title: String = "会话",
        phase: SessionPhase = .running,
        summary: String? = nil,
        currentTool: String? = "Bash"
    ) -> PiDesktopSessionSnapshot {
        PiDesktopSessionSnapshot(
            sessionID: id,
            title: title,
            projectPath: "/Users/u/repo",
            workspaceName: "repo",
            phase: phase,
            summary: summary,
            currentTool: currentTool,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
    }

    @Test
    func startsSessionsAndKeepsThemAlive() {
        let harness = Harness()
        harness.publish([snapshot(id: "s1"), snapshot(id: "s2", phase: .completed, summary: "完成")])

        #expect(harness.sessionIDs() == ["s1", "s2"])
        #expect(harness.state.session(id: "s1")?.tool == .piDesktop)
        #expect(harness.state.session(id: "s1")?.phase == .running)
        #expect(harness.state.session(id: "s2")?.phase == .completed)
        #expect(harness.events.contains { if case .sessionHeartbeat = $0 { true } else { false } })
    }

    @Test
    func secondPublishUpdatesPhaseInsteadOfRestarting() {
        let harness = Harness()
        harness.publish([snapshot(id: "s1", phase: .running)])
        let startedCount = harness.events.filter { if case .sessionStarted = $0 { true } else { false } }.count

        harness.publish([snapshot(id: "s1", phase: .completed, summary: "已完成")])

        let updatedStartCount = harness.events.filter { if case .sessionStarted = $0 { true } else { false } }.count
        #expect(startedCount == 1)
        #expect(updatedStartCount == 1, "retitling or phase changes must not restart an existing session")
        #expect(harness.state.session(id: "s1")?.phase == .completed)
        #expect(harness.state.session(id: "s1")?.summary == "已完成")
    }

    @Test
    func sessionsMissingFromTheNextSnapshotAreEnded() {
        let harness = Harness()
        harness.publish([snapshot(id: "s1"), snapshot(id: "s2")])

        harness.publish([snapshot(id: "s1")])

        // The reducer keeps ended sessions in state (flagged) so the UI can
        // show a completed row; it must not silently restart them either.
        #expect(harness.state.session(id: "s1")?.isSessionEnded == false)
        #expect(harness.state.session(id: "s2")?.isSessionEnded == true)
        #expect(harness.state.session(id: "s2")?.phase == .completed)
    }

    @Test
    func emptySnapshotEndsEverything() {
        let harness = Harness()
        harness.publish([snapshot(id: "s1")])

        harness.publish([])

        #expect(harness.state.session(id: "s1")?.isSessionEnded == true)
        #expect(harness.events.contains { event in
            if case let .sessionCompleted(payload) = event { return payload.isSessionEnd == true }
            return false
        })
    }
}
