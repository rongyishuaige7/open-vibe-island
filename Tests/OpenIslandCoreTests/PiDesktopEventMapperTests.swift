import Foundation
import Testing
@testable import OpenIslandCore

struct PiDesktopEventMapperTests {
    private func snapshot(
        id: String = "s1",
        title: String = "看看搜索走哪个 API",
        phase: SessionPhase = .running,
        summary: String? = "正在检查搜索结果",
        currentTool: String? = "Bash",
        workspace: String? = "open-island",
        projectPath: String? = "/Users/u/open-island"
    ) -> PiDesktopSessionSnapshot {
        PiDesktopSessionSnapshot(
            sessionID: id,
            title: title,
            projectPath: projectPath,
            workspaceName: workspace,
            providerID: "p1",
            modelID: "cn:deepseek-v4.1-flash",
            mode: "agent",
            permissionMode: "auto",
            phase: phase,
            summary: summary,
            currentTool: currentTool,
            todoCompleted: 1,
            todoTotal: 3,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
    }

    @Test
    func newSnapshotStartsASessionWithPiDesktopToolAndJumpTarget() throws {
        let events = PiDesktopEventMapper.events(for: snapshot(), existing: nil, timestamp: .now)
        let started = try #require(events.compactMap { event -> SessionStarted? in
            if case let .sessionStarted(payload) = event { return payload }
            return nil
        }.first)

        #expect(started.sessionID == "s1")
        #expect(started.title == "看看搜索走哪个 API")
        #expect(started.tool == .piDesktop)
        #expect(started.initialPhase == .running)
        #expect(started.summary == "Running Bash")
        #expect(started.jumpTarget?.terminalApp == "PI Desktop")
        #expect(started.jumpTarget?.workspaceName == "open-island")
        #expect(started.jumpTarget?.terminalSessionID == "s1")

        // Every snapshot also refreshes liveness.
        #expect(events.contains { if case .sessionHeartbeat = $0 { true } else { false } })
    }

    @Test
    func existingSessionOnlyGetsActivityPlusHeartbeat() throws {
        let initial = snapshot(phase: .running, summary: "正在检查搜索结果", currentTool: "Bash")
        var mutableState = SessionState()
        for event in PiDesktopEventMapper.events(for: initial, existing: nil, timestamp: .now) {
            mutableState.apply(event)
        }
        let existing = try #require(mutableState.session(id: "s1"))

        let updated = snapshot(phase: .completed, summary: "已完成", currentTool: "Bash")
        let events = PiDesktopEventMapper.events(for: updated, existing: existing, timestamp: .now)

        #expect(events.contains { if case .sessionStarted = $0 { true } else { false } } == false)
        let activity = try #require(events.compactMap { event -> SessionActivityUpdated? in
            if case let .activityUpdated(payload) = event { return payload }
            return nil
        }.first)
        #expect(activity.phase == .completed)
        #expect(activity.summary == "已完成")
        #expect(events.contains { if case .sessionHeartbeat = $0 { true } else { false } })
    }

    @Test
    func unchangedSnapshotOnlySendsAHeartbeat() throws {
        let initial = snapshot(phase: .running, summary: nil, currentTool: "Bash")
        var state = SessionState()
        for event in PiDesktopEventMapper.events(for: initial, existing: nil, timestamp: .now) {
            state.apply(event)
        }
        let existing = try #require(state.session(id: "s1"))

        let events = PiDesktopEventMapper.events(for: initial, existing: existing, timestamp: .now)
        #expect(events.count == 1)
        #expect(events.contains { if case .sessionHeartbeat = $0 { true } else { false } })
    }

    @Test
    func retitledSessionStartsAgainWithTheNewTitle() throws {
        var state = SessionState()
        for event in PiDesktopEventMapper.events(for: snapshot(title: "新会话"), existing: nil, timestamp: .now) {
            state.apply(event)
        }
        let existing = try #require(state.session(id: "s1"))

        let events = PiDesktopEventMapper.events(for: snapshot(title: "看看搜索走哪个 API"), existing: existing, timestamp: .now)
        let started = try #require(events.compactMap { event -> SessionStarted? in
            if case let .sessionStarted(payload) = event { return payload }
            return nil
        }.first)
        #expect(started.title == "看看搜索走哪个 API")
    }

    @Test
    func summaryFallsBackByPhase() {
        #expect(PiDesktopEventMapper.summary(for: snapshot(phase: .running, summary: nil, currentTool: "Read")) == "Running Read")
        #expect(PiDesktopEventMapper.summary(for: snapshot(phase: .running, summary: nil, currentTool: nil)) == "PI Desktop is working.")
        #expect(PiDesktopEventMapper.summary(for: snapshot(phase: .waitingForApproval, summary: nil, currentTool: nil)) == "PI Desktop is waiting for approval.")
        #expect(PiDesktopEventMapper.summary(for: snapshot(phase: .waitingForAnswer, summary: "要不要继续？", currentTool: nil)) == "要不要继续？")
        #expect(PiDesktopEventMapper.summary(for: snapshot(phase: .completed, summary: nil, currentTool: nil)) == "PI Desktop finished the turn.")
    }

    @Test
    func titleFallsBackToWorkspaceThenDisplayName() {
        #expect(PiDesktopEventMapper.title(for: snapshot(title: "  ")) == "PI Desktop · open-island")
        #expect(
            PiDesktopEventMapper.title(
                for: snapshot(title: "", workspace: nil, projectPath: "/Users/u/repo")
            ) == "PI Desktop · repo"
        )
        #expect(
            PiDesktopEventMapper.title(
                for: snapshot(title: "", workspace: nil, projectPath: nil)
            ) == "PI Desktop"
        )
    }

    @Test
    func endedSessionRestartsWhenTheAppReportsItAgain() throws {
        var state = SessionState()
        for event in PiDesktopEventMapper.events(for: snapshot(), existing: nil, timestamp: .now) {
            state.apply(event)
        }
        state.apply(PiDesktopEventMapper.sessionEnded(sessionID: "s1", timestamp: .now))
        let ended = try #require(state.session(id: "s1"))
        #expect(ended.isSessionEnded)

        let events = PiDesktopEventMapper.events(for: snapshot(), existing: ended, timestamp: .now)
        #expect(events.contains { if case .sessionStarted = $0 { true } else { false } })
    }

    @Test
    func sessionEndCarriesTheSessionEndFlag() throws {
        guard case let .sessionCompleted(completed) = PiDesktopEventMapper.sessionEnded(
            sessionID: "s1",
            timestamp: Date(timeIntervalSince1970: 5)
        ) else {
            Issue.record("expected sessionCompleted")
            return
        }
        #expect(completed.sessionID == "s1")
        #expect(completed.isSessionEnd == true)
        #expect(completed.summary == "PI Desktop closed the session.")
    }

    @Test
    func todayTokensSumTurnsAndDeduplicateSessions() {
        let turns = [
            PiDesktopTurnUsage(id: "t1", sessionID: "a", status: "completed", inputTokens: 100, outputTokens: 50, cacheReadTokens: 10, startedAt: .now),
            PiDesktopTurnUsage(id: "t2", sessionID: "a", status: "completed", inputTokens: 200, outputTokens: 25, cacheReadTokens: 5, startedAt: .now),
            PiDesktopTurnUsage(id: "t3", sessionID: "b", status: "error", inputTokens: 1, outputTokens: 2, cacheReadTokens: 0, startedAt: .now)
        ]
        let tokens = PiDesktopTodayTokens(turns: turns)
        #expect(tokens.inputTokens == 301)
        #expect(tokens.outputTokens == 77)
        #expect(tokens.totalTokens == 378)
        #expect(tokens.cacheReadTokens == 15)
        #expect(tokens.sessionCount == 2)
    }

    @Test
    func todayTokensIgnoreDuplicateTurnIDs() {
        let turn = PiDesktopTurnUsage(id: "t1", sessionID: "a", status: "completed", inputTokens: 100, outputTokens: 50, cacheReadTokens: 7, startedAt: .now)
        let tokens = PiDesktopTodayTokens(turns: [turn, turn])
        #expect(tokens.totalTokens == 150)
        #expect(tokens.cacheReadTokens == 7)
        #expect(tokens.sessionCount == 1)
    }

    @Test
    func todayTokensEventRoundTripsThroughJSON() throws {
        let event = AgentEvent.piDesktopTodayTokensUpdated(
            PiDesktopTodayTokensUpdated(
                usage: PiDesktopTodayTokens(totalTokens: 42, inputTokens: 20, outputTokens: 22, cacheReadTokens: 3, sessionCount: 2),
                timestamp: Date(timeIntervalSince1970: 77)
            )
        )
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(AgentEvent.self, from: data)
        #expect(decoded == event)
    }

    @Test
    func bridgeRoundTripsThePiDesktopCommand() throws {
        let payload = PiDesktopHookPayload(
            event: .activity,
            session: snapshot(),
            sessions: nil,
            todayTokens: PiDesktopTodayTokens(totalTokens: 10, inputTokens: 4, outputTokens: 6, cacheReadTokens: 0, sessionCount: 1),
            timestamp: Date(timeIntervalSince1970: 1_000)
        )
        let command = BridgeCommand.processPiDesktopHook(payload)
        var buffer = try BridgeCodec.encodeLine(.command(command))
        let decoded = try BridgeCodec.decodeLines(from: &buffer)
        guard case let .command(decodedCommand)? = decoded.first,
              case let .processPiDesktopHook(roundTripped) = decodedCommand else {
            Issue.record("expected a processPiDesktopHook command")
            return
        }
        #expect(roundTripped == payload)
    }
}
