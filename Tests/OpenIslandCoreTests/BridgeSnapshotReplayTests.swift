import Foundation
import Testing
@testable import OpenIslandCore

/// AppModel pushes its state to the bridge after applying each observed
/// event, so a snapshot can lag events the bridge already emitted.
struct BridgeSnapshotReplayTests {
    private func startPayload(_ sessionID: String) -> CodexHookPayload {
        CodexHookPayload(
            cwd: "/tmp/worktree",
            hookEventName: .sessionStart,
            model: "gpt-5-codex",
            permissionMode: .default,
            sessionID: sessionID,
            transcriptPath: nil
        )
    }

    private func promptPayload(_ sessionID: String) -> CodexHookPayload {
        CodexHookPayload(
            cwd: "/tmp/worktree",
            hookEventName: .userPromptSubmit,
            model: "gpt-5-codex",
            permissionMode: .default,
            sessionID: sessionID,
            transcriptPath: nil,
            prompt: "Keep going"
        )
    }

    private func next(
        _ iterator: inout AsyncThrowingStream<AgentEvent, Error>.AsyncIterator
    ) async throws -> AgentEvent? {
        try await iterator.next()
    }

    @Test
    func staleSnapshotKeepsEventsTheObserverHasNotApplied() async throws {
        let socketURL = BridgeSocketLocation.uniqueTestURL()
        let server = BridgeServer(socketURL: socketURL)
        try server.start()
        defer { server.stop() }

        let observer = LocalBridgeClient(socketURL: socketURL)
        let stream = try observer.connect()
        defer { observer.disconnect() }
        try await observer.send(.registerClient(role: .observer))

        _ = try BridgeCommandClient(socketURL: socketURL).send(.processCodexHook(startPayload("replay-1")))
        let counts = server.observerEventCountsForTests()
        #expect(counts.sent == 1)
        #expect(counts.unacknowledged == 1)

        // A snapshot taken before AppModel applied sessionStarted.
        server.updateStateSnapshot(SessionState(), appliedObserverEvents: 0)
        #expect(server.sessionStateSnapshotForTests().session(id: "replay-1") != nil)

        // The next hook must find the session instead of re-creating it.
        _ = try BridgeCommandClient(socketURL: socketURL).send(.processCodexHook(promptPayload("replay-1")))

        // The prompt hook may emit metadata updates before its activity
        // update; what must not appear is a second sessionStarted.
        var iterator = stream.makeAsyncIterator()
        var sessionStartedCount = 0
        var update: SessionActivityUpdated?
        for _ in 0..<6 {
            guard let event = try await next(&iterator) else { break }
            if case .sessionStarted = event {
                sessionStartedCount += 1
            }
            if case let .activityUpdated(payload) = event {
                update = payload
                break
            }
        }
        #expect(sessionStartedCount == 1)
        #expect(update?.phase == .running)
        #expect(server.sessionStateSnapshotForTests().session(id: "replay-1")?.phase == .running)
    }

    @Test
    func snapshotCoveringEveryEventIsAuthoritative() async throws {
        let socketURL = BridgeSocketLocation.uniqueTestURL()
        let server = BridgeServer(socketURL: socketURL)
        try server.start()
        defer { server.stop() }

        let observer = LocalBridgeClient(socketURL: socketURL)
        // Dropping the stream terminates it, which disconnects the observer.
        let stream = try observer.connect()
        defer {
            withExtendedLifetime(stream) {}
            observer.disconnect()
        }
        try await observer.send(.registerClient(role: .observer))

        _ = try BridgeCommandClient(socketURL: socketURL).send(.processCodexHook(startPayload("replay-2")))

        // AppModel applied the event and then dropped the session itself.
        server.updateStateSnapshot(SessionState(), appliedObserverEvents: 1)
        #expect(server.sessionStateSnapshotForTests().session(id: "replay-2") == nil)
        let counts = server.observerEventCountsForTests()
        #expect(counts.sent == 1)
        #expect(counts.unacknowledged == 0)
    }

    @Test
    func countThatDoesNotMatchTheObserverReplacesStateOutright() async throws {
        let socketURL = BridgeSocketLocation.uniqueTestURL()
        let server = BridgeServer(socketURL: socketURL)
        try server.start()
        defer { server.stop() }

        let observer = LocalBridgeClient(socketURL: socketURL)
        // Dropping the stream terminates it, which disconnects the observer.
        let stream = try observer.connect()
        defer {
            withExtendedLifetime(stream) {}
            observer.disconnect()
        }
        try await observer.send(.registerClient(role: .observer))

        _ = try BridgeCommandClient(socketURL: socketURL).send(.processCodexHook(startPayload("replay-3")))
        #expect(server.observerEventCountsForTests().sent == 1)

        // A count from an earlier connection, beyond what this observer was sent.
        server.updateStateSnapshot(SessionState(), appliedObserverEvents: 99)
        #expect(server.sessionStateSnapshotForTests().session(id: "replay-3") == nil)
        #expect(server.observerEventCountsForTests().unacknowledged == 0)

        _ = try BridgeCommandClient(socketURL: socketURL).send(.processCodexHook(startPayload("replay-4")))
        server.updateStateSnapshot(SessionState())
        #expect(server.sessionStateSnapshotForTests().session(id: "replay-4") == nil)
        #expect(server.observerEventCountsForTests().unacknowledged == 0)
    }
}
