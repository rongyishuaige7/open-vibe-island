import Foundation
import Testing
@testable import OpenIslandCore

struct DSHHooksTests {
    @Test
    func dshHookPayloadRoundTripsThroughBridgeCodec() throws {
        let payload = DSHHookPayload(
            event: .snapshot,
            sessions: [
                DSHSessionSnapshot(
                    sessionID: "session-1",
                    title: "Fix login",
                    cwd: "/tmp/project",
                    workspaceName: "project",
                    summary: "Running bash",
                    phase: .running,
                    createdAt: Date(timeIntervalSince1970: 1_000),
                    isSubagent: false
                ),
            ],
            todayTokens: DSHTodayTokens(totalTokens: 1_234, cacheReadTokens: 300, sessionCount: 1),
            timestamp: Date(timeIntervalSince1970: 2_000)
        )
        let envelope = BridgeEnvelope.command(.processDSHHook(payload))
        var buffer = try BridgeCodec.encodeLine(envelope)
        let decoded = try BridgeCodec.decodeLines(from: &buffer)

        #expect(decoded == [envelope])
        #expect(buffer.isEmpty)
    }


    @Test
    func rawPluginJSONDecodesWithBridgeDateStrategy() throws {
        let json = """
        {"type":"command","command":{"type":"processDSHHook","dshHook":{"event":"snapshot","sessions":[{"sessionID":"session-ui-test","title":"DSH · Open Island","cwd":"/Users/rongyi/Developer/open-vibe-island","workspaceName":"open-vibe-island","summary":"Implemented the DeepSeek Harness bridge","phase":"running","createdAt":1792244300000,"updatedAt":1792244366004}],"todayTokens":{"totalTokens":123456,"cacheReadTokens":23456,"sessionCount":1},"timestamp":1792244366004}}}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let envelope = try decoder.decode(BridgeEnvelope.self, from: Data(json.utf8))

        guard case let .command(.processDSHHook(payload)) = envelope else {
            Issue.record("Expected processDSHHook, got \(envelope)")
            return
        }
        #expect(payload.event == .snapshot)
        #expect(payload.todayTokens?.totalTokens == 123_456)
        #expect(payload.sessions?.first?.title == "DSH · Open Island")
        #expect(payload.sessions?.first?.phase == .running)
        #expect(payload.sessions?.first?.isSubagent == nil)
    }

    @Test
    func dshSnapshotCreatesSessionEmitsTodayTotalsAndHeartbeat() async throws {
        let socketURL = BridgeSocketLocation.uniqueTestURL()
        let server = BridgeServer(socketURL: socketURL)
        try server.start()
        defer { server.stop() }

        let observer = LocalBridgeClient(socketURL: socketURL)
        let stream = try observer.connect()
        defer { observer.disconnect() }
        try await observer.send(.registerClient(role: .observer))

        let now = Date(timeIntervalSince1970: 2_000)
        let snapshot = DSHSessionSnapshot(
            sessionID: "session-1",
            title: "Fix login",
            cwd: "/tmp/project",
            workspaceName: "project",
            summary: "Thinking…",
            phase: .running,
            createdAt: now
        )
        let response = try BridgeCommandClient(socketURL: socketURL).send(
            .processDSHHook(
                DSHHookPayload(
                    event: .snapshot,
                    sessions: [snapshot],
                    todayTokens: DSHTodayTokens(totalTokens: 1_200, cacheReadTokens: 300, sessionCount: 1),
                    timestamp: now
                )
            )
        )
        #expect(response == .acknowledged)

        var iterator = stream.makeAsyncIterator()
        let todayEvent = try await nextDSHEvent(from: &iterator)
        let startedEvent = try await nextDSHEvent(from: &iterator)
        let heartbeatEvent = try await nextDSHEvent(from: &iterator)

        guard case let .dshTodayTokensUpdated(today) = todayEvent else {
            Issue.record("Expected DSH today totals, got \(todayEvent)")
            return
        }
        #expect(today.usage.totalTokens == 1_200)
        #expect(today.usage.cacheReadTokens == 300)
        #expect(today.usage.sessionCount == 1)

        guard case let .sessionStarted(started) = startedEvent else {
            Issue.record("Expected DSH session start, got \(startedEvent)")
            return
        }
        #expect(started.sessionID == "dsh:session-1")
        #expect(started.tool == .deepSeekHarness)
        #expect(started.title == "Fix login")
        #expect(started.conversationTitle == "Fix login")
        #expect(started.initialPhase == .running)
        #expect(started.jumpTarget?.terminalApp == "DeepSeek Harness")
        #expect(started.jumpTarget?.workingDirectory == "/tmp/project")

        guard case let .sessionHeartbeat(heartbeat) = heartbeatEvent else {
            Issue.record("Expected DSH heartbeat, got \(heartbeatEvent)")
            return
        }
        #expect(heartbeat.sessionID == "dsh:session-1")
    }

    @Test
    func dshSessionEndMarksTheSessionEnded() async throws {
        let socketURL = BridgeSocketLocation.uniqueTestURL()
        let server = BridgeServer(socketURL: socketURL)
        try server.start()
        defer { server.stop() }

        let observer = LocalBridgeClient(socketURL: socketURL)
        let stream = try observer.connect()
        defer { observer.disconnect() }
        try await observer.send(.registerClient(role: .observer))

        let client = BridgeCommandClient(socketURL: socketURL)
        let snapshot = DSHSessionSnapshot(sessionID: "session-1", title: "Fix login", phase: .running)
        _ = try client.send(.processDSHHook(DSHHookPayload(event: .sessionStart, session: snapshot)))

        var iterator = stream.makeAsyncIterator()
        _ = try await nextDSHEvent(from: &iterator) // today totals
        _ = try await nextDSHEvent(from: &iterator) // session start
        _ = try await nextDSHEvent(from: &iterator) // heartbeat

        var completed = snapshot
        completed.phase = .completed
        _ = try client.send(
            .processDSHHook(
                DSHHookPayload(event: .sessionEnd, session: completed, todayTokens: .zero)
            )
        )

        _ = try await nextDSHEvent(from: &iterator) // today totals
        let completedEvent = try await nextDSHEvent(from: &iterator)
        guard case let .sessionCompleted(payload) = completedEvent else {
            Issue.record("Expected DSH session completion, got \(completedEvent)")
            return
        }
        #expect(payload.sessionID == "dsh:session-1")
        #expect(payload.isSessionEnd == true)
    }
}

private func nextDSHEvent(
    from iterator: inout AsyncThrowingStream<AgentEvent, Error>.AsyncIterator
) async throws -> AgentEvent {
    guard let event = try await iterator.next() else {
        throw CancellationError()
    }
    return event
}
