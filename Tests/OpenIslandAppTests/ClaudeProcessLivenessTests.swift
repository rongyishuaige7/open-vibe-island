import Foundation
import Testing
@testable import OpenIslandApp
@testable import OpenIslandCore

@MainActor
struct ClaudeProcessLivenessTests {
    private static let workspace = "/tmp/claude-liveness-demo"

    private func claudeSession(
        id: String,
        tty: String?,
        updatedAt: Date = Date(timeIntervalSince1970: 1_000),
        transcriptPath: String? = nil
    ) -> AgentSession {
        AgentSession(
            id: id,
            title: "Claude · demo",
            tool: .claudeCode,
            origin: .live,
            attachmentState: .stale,
            phase: .completed,
            summary: "Ready",
            updatedAt: updatedAt,
            jumpTarget: JumpTarget(
                terminalApp: "Ghostty",
                workspaceName: "claude-liveness-demo",
                paneTitle: "Claude \(id)",
                workingDirectory: Self.workspace,
                terminalTTY: tty
            ),
            claudeMetadata: transcriptPath.map { ClaudeSessionMetadata(transcriptPath: $0) }
        )
    }

    private func claudeProcess(
        sessionID: String? = nil,
        tty: String?,
        transcriptPath: String? = nil
    ) -> ActiveAgentProcessDiscovery.ProcessSnapshot {
        .init(
            tool: .claudeCode,
            sessionID: sessionID,
            workingDirectory: Self.workspace,
            terminalTTY: tty,
            terminalApp: "Ghostty",
            transcriptPath: transcriptPath
        )
    }

    /// Matches AppModel; the coordinator's empty default would make every
    /// Claude session look synthetic.
    private func makeCoordinator() -> ProcessMonitoringCoordinator {
        let coordinator = ProcessMonitoringCoordinator()
        coordinator.syntheticClaudeSessionPrefix = "claude-process:"
        return coordinator
    }

    private func coordinator(with sessions: [AgentSession]) -> (ProcessMonitoringCoordinator, () -> SessionState) {
        var state = SessionState(sessions: sessions)
        let coordinator = makeCoordinator()
        coordinator.stateAccessor = { state }
        coordinator.stateUpdater = { state = $0 }
        return (coordinator, { state })
    }

    private func alive(
        _ coordinator: ProcessMonitoringCoordinator,
        _ processes: [ActiveAgentProcessDiscovery.ProcessSnapshot]
    ) -> Set<String> {
        coordinator.sessionIDsWithAliveProcesses(activeProcesses: processes, isCodexAppRunning: false)
    }

    @Test
    func staleResumeArgumentDoesNotKeepAnEndedSessionAlive() {
        // Tab A was launched with `--resume session-old`, then switched to
        // session-a in-process. Tab B runs session-b. session-old ended long
        // ago on tab B's old TTY and has no process of its own.
        let (coordinator, _) = coordinator(with: [
            claudeSession(id: "session-a", tty: "/dev/ttys101"),
            claudeSession(id: "session-b", tty: "/dev/ttys102"),
            claudeSession(id: "session-old", tty: "/dev/ttys102", updatedAt: Date(timeIntervalSince1970: 10)),
        ])

        let aliveIDs = alive(coordinator, [
            claudeProcess(sessionID: "session-old", tty: "/dev/ttys101"),
            claudeProcess(tty: "/dev/ttys102"),
        ])

        #expect(aliveIDs == ["session-a", "session-b"])
    }

    @Test
    func oneProcessKeepsAtMostOneSessionAlive() {
        let (coordinator, _) = coordinator(with: [
            claudeSession(id: "session-current", tty: "/dev/ttys101"),
            claudeSession(id: "session-no-tty", tty: nil),
        ])

        let aliveIDs = alive(coordinator, [
            claudeProcess(sessionID: "session-current", tty: "/dev/ttys101"),
        ])

        #expect(aliveIDs == ["session-current"])
    }

    @Test
    func resumeArgumentStillMatchesWhenTTYAgrees() {
        let (coordinator, _) = coordinator(with: [
            claudeSession(id: "session-a", tty: "/dev/ttys101"),
            claudeSession(id: "session-b", tty: "/dev/ttys101", updatedAt: Date(timeIntervalSince1970: 2_000)),
        ])

        let aliveIDs = alive(coordinator, [
            claudeProcess(sessionID: "session-a", tty: "/dev/ttys101"),
        ])

        #expect(aliveIDs == ["session-a"])
    }

    @Test
    func resumeInANewTabStillMatchesWhenTheOldTTYIsGone() {
        let (coordinator, _) = coordinator(with: [
            claudeSession(id: "session-moved", tty: "/dev/ttys102"),
        ])

        let aliveIDs = alive(coordinator, [
            claudeProcess(sessionID: "session-moved", tty: "/dev/ttys101"),
        ])

        #expect(aliveIDs == ["session-moved"])
    }

    @Test
    func sessionWithoutTTYStaysAliveWhileAnUnmatchedProcessRunsInItsFolder() {
        let (coordinator, _) = coordinator(with: [
            claudeSession(id: "session-discovered", tty: nil),
        ])

        let aliveIDs = alive(coordinator, [claudeProcess(tty: "/dev/ttys101")])

        #expect(aliveIDs == ["session-discovered"])
    }

    @Test
    func staleResumeProcessIsStillRepresentedAndGetsNoSyntheticRow() {
        let merged = makeCoordinator().mergedWithSyntheticClaudeSessions(
            existingSessions: [
                claudeSession(id: "session-a", tty: "/dev/ttys101"),
                claudeSession(id: "session-old", tty: "/dev/ttys102"),
            ],
            activeProcesses: [claudeProcess(sessionID: "session-old", tty: "/dev/ttys101")]
        )

        #expect(merged.map(\.id).sorted() == ["session-a", "session-old"])
    }

    @Test
    func sharedFolderDoesNotRewriteAnotherSessionsTTY() {
        // session-old sorts first, so it used to be the one that took the new
        // process's TTY even though session-target is the row missing one.
        let oldUpdatedAt = Date(timeIntervalSince1970: 500)
        let (coordinator, currentState) = coordinator(with: [
            claudeSession(id: "session-old", tty: "/dev/ttys102", updatedAt: oldUpdatedAt),
            claudeSession(id: "session-target", tty: nil, updatedAt: Date(timeIntervalSince1970: 100)),
        ])

        reconcile(coordinator, [claudeProcess(tty: "/dev/ttys101")])

        let old = currentState().session(id: "session-old")
        #expect(old?.jumpTarget?.terminalTTY == "/dev/ttys102")
        #expect(old?.updatedAt == oldUpdatedAt)
        #expect(currentState().session(id: "session-target")?.jumpTarget?.terminalTTY == "/dev/ttys101")
    }

    @Test
    func missingTTYIsFilledInWithoutRefreshingActivity() {
        let oldUpdatedAt = Date(timeIntervalSince1970: 10)
        let (coordinator, currentState) = coordinator(with: [
            claudeSession(id: "session-discovered", tty: nil, updatedAt: oldUpdatedAt),
        ])

        reconcile(coordinator, [claudeProcess(tty: "/dev/ttys101")])

        let session = currentState().session(id: "session-discovered")
        #expect(session?.jumpTarget?.terminalTTY == "/dev/ttys101")
        #expect(session?.updatedAt == oldUpdatedAt)
    }

    @Test
    func processThatIdentifiesTheSessionMovesItsTTY() {
        let (coordinator, currentState) = coordinator(with: [
            claudeSession(id: "session-moved", tty: "/dev/ttys102"),
        ])

        reconcile(coordinator, [claudeProcess(sessionID: "session-moved", tty: "/dev/ttys101")])

        #expect(currentState().session(id: "session-moved")?.jumpTarget?.terminalTTY == "/dev/ttys101")
    }

    @Test
    func runningClaudeSessionReconcilesToCompletedWhenTranscriptIsInterrupted() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-island-reconcile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let transcriptFile = root.appendingPathComponent("session-run.jsonl")
        let lines = [
            #"{"type":"user","sessionId":"session-run","cwd":"/Users/test/project","timestamp":"2026-07-22T18:00:00Z","message":{"role":"user","content":[{"type":"text","text":"Do work"}]}}"#,
            #"{"type":"user","sessionId":"session-run","cwd":"/Users/test/project","timestamp":"2026-07-22T18:00:02Z","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"interruptedMessageId":"msg_123"}"#,
        ]
        try lines.joined(separator: "\n").write(to: transcriptFile, atomically: true, encoding: .utf8)

        var session = claudeSession(id: "session-run", tty: "/dev/ttys101", transcriptPath: transcriptFile.path)
        session.phase = .running
        let (coordinator, currentState) = coordinator(with: [session])

        reconcile(coordinator, [claudeProcess(sessionID: "session-run", tty: "/dev/ttys101")])

        #expect(currentState().session(id: "session-run")?.phase == .completed)
    }

    @Test
    func runningClaudeSessionReconcilesToCompletedWhenProcessIsDetached() {
        var session = claudeSession(id: "session-detached", tty: "/dev/ttys101")
        session.phase = .running
        session.attachmentState = .detached
        let (coordinator, currentState) = coordinator(with: [session])

        reconcile(coordinator, [])

        #expect(currentState().session(id: "session-detached")?.phase == .completed)
    }

    @Test
    func runningSessionReconcilesToCompletedWhenProcessIsDeadEvenIfAttached() {
        var session = claudeSession(id: "session-dead-process", tty: "/dev/ttys101")
        session.phase = .running
        session.attachmentState = .attached
        let (coordinator, currentState) = coordinator(with: [session])

        // First reconcile: not seen count becomes 1
        reconcile(coordinator, [])
        // Second reconcile: not seen count becomes 2, isProcessAlive becomes false
        reconcile(coordinator, [])

        // When process is confirmed dead (2 missed cycles), invisible sessions are pruned.
        #expect(currentState().session(id: "session-dead-process") == nil)
    }

    @Test
    func runningSessionKeepsRunningPhaseWhenProcessIsAliveEvenIfDetached() {
        var session = claudeSession(id: "session-running-detached", tty: "/dev/ttys101")
        session.phase = .running
        session.attachmentState = .detached
        let (coordinator, currentState) = coordinator(with: [session])

        reconcile(coordinator, [claudeProcess(sessionID: "session-running-detached", tty: "/dev/ttys101")])

        #expect(currentState().session(id: "session-running-detached")?.phase == .running)
    }

    private func reconcile(
        _ coordinator: ProcessMonitoringCoordinator,
        _ processes: [ActiveAgentProcessDiscovery.ProcessSnapshot]
    ) {
        coordinator.reconcileSessionAttachments(
            activeProcesses: processes,
            ghosttyAvailability: .unavailable(appIsRunning: false),
            terminalAvailability: .available([], appIsRunning: false),
            preResolvedJumpTargets: [:],
            observedCodexAppRunning: false
        )
    }
}
