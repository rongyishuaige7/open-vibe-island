import Foundation
import Testing
@testable import OpenIslandApp
import OpenIslandCore

@MainActor
struct PixelMascotTests {
    @Test
    func spritesAreRectangularAndFramesMatch() {
        for sprite in [PixelSprite.claude, .codex, .blob] {
            for frame in sprite.frames {
                #expect(frame.count == sprite.rowCount)
                #expect(frame.allSatisfy { $0.count == sprite.columns })
            }
            if let cursorOff = sprite.cursorOff {
                #expect(cursorOff.row < sprite.rowCount)
                #expect(cursorOff.line.count == sprite.columns)
            }
        }
    }

    /// The MacBook pill's right wing is 44pt minus half the pill height as
    /// edge padding: 28pt at the 32pt notch height.
    @Test
    func claudeAndCodexFitTheMacBookWing() {
        let slots = [PixelMascotSlot(tool: .codex, state: .running), PixelMascotSlot(tool: .claudeCode, state: .running)]
        #expect(PixelMascotRow.intrinsicWidth(of: slots) <= 28)
        #expect(PixelMascotRow.height(of: slots) <= 20)
        #expect(PixelMascotRow.intrinsicWidth(of: []) == 0)
    }

    @Test
    func onlyRunningMascotsWalkAndBlink() {
        #expect(PixelMascotMotion.walkFrame(state: .running, time: 0.1) == 0)
        #expect(PixelMascotMotion.walkFrame(state: .running, time: 0.5) == 1)
        #expect(PixelMascotMotion.walkFrame(state: .running, time: 0.9) == 0)
        #expect(PixelMascotMotion.walkFrame(state: .waiting, time: 0.5) == 0)
        #expect(PixelMascotMotion.walkFrame(state: .idle, time: 0.5) == 0)
        #expect(PixelMascotMotion.walkFrame(state: .running, time: nil) == 0)

        #expect(PixelMascotMotion.cursorVisible(state: .running, time: 0.2))
        #expect(!PixelMascotMotion.cursorVisible(state: .running, time: 0.7))
        #expect(PixelMascotMotion.cursorVisible(state: .waiting, time: 0.7))
    }

    @Test
    func idleMascotsStayDimAndWaitingOnesBreathe() {
        #expect(PixelMascotMotion.alpha(state: .idle, time: 1) == 0.3)
        #expect(PixelMascotMotion.alpha(state: .running, time: 1) == 1)
        let samples = stride(from: 0.0, through: 1.4, by: 0.1).map {
            PixelMascotMotion.alpha(state: .waiting, time: $0)
        }
        #expect(samples.allSatisfy { $0 >= 0.35 && $0 <= 1 })
        #expect((samples.max() ?? 0) - (samples.min() ?? 0) > 0.5)
    }

    @Test
    func codexCursorBlinkOnlyChangesTheUnderscore() {
        let on = PixelSprite.codex.rows(frame: 0, cursorVisible: true)
        let off = PixelSprite.codex.rows(frame: 0, cursorVisible: false)
        let changed = zip(on, off).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        #expect(changed == [3])
    }

    @Test
    func pixelStyleAnimatesLikeTheDot() {
        for presence in [IslandSessionPresence.running, .active, .inactive] {
            for actionable in [false, true] {
                #expect(
                    IslandSessionStateIndicator.pixel.timelineInterval(presence: presence, isActionable: actionable)
                        == IslandSessionStateIndicator.animatedDot.timelineInterval(presence: presence, isActionable: actionable)
                )
            }
        }
    }

    @Test
    func mascotSlotsKeepOnePerToolWithClaudeOutermost() {
        let slots = AppModel.mascotSlots(for: [
            makeSession(id: "c1", tool: .claudeCode, phase: .completed),
            makeSession(id: "x1", tool: .codex, phase: .running),
            makeSession(id: "c2", tool: .claudeCode, phase: .running),
            makeSession(id: "x2", tool: .codex, phase: .completed),
        ])
        #expect(slots == [
            PixelMascotSlot(tool: .codex, state: .running),
            PixelMascotSlot(tool: .claudeCode, state: .running),
        ])
    }

    @Test
    func waitingOutranksRunningWithinATool() {
        let slots = AppModel.mascotSlots(for: [
            makeSession(id: "r", tool: .codex, phase: .running),
            makeSession(id: "w", tool: .codex, phase: .waitingForAnswer),
        ])
        #expect(slots == [PixelMascotSlot(tool: .codex, state: .waiting)])
    }

    @Test
    func showsAtMostThreeTools() {
        let slots = AppModel.mascotSlots(for: [
            makeSession(id: "a", tool: .openCode, phase: .running),
            makeSession(id: "b", tool: .geminiCLI, phase: .running),
            makeSession(id: "c", tool: .codex, phase: .running),
            makeSession(id: "d", tool: .claudeCode, phase: .running),
        ])
        #expect(slots.map(\.tool) == [.geminiCLI, .codex, .claudeCode])
    }

    /// Writes the preference to both profiles, like the agents-grid tests,
    /// because the active profile follows the machine's real screen.
    @Test
    func mascotsSlotFollowsSurfacedSessions() {
        let model = AppModel()
        model.updateAppearancePreferences(for: .topBar) { $0.rightSlot = .mascots }
        model.updateAppearancePreferences(for: .notch) { $0.rightSlot = .mascots }

        model.state = SessionState(sessions: [])
        #expect(model.islandClosedRightSlotContent() == nil)

        model.state = SessionState(sessions: [makeSession(id: "c", tool: .claudeCode, phase: .running)])
        #expect(model.islandClosedRightSlotContent() == .mascots([PixelMascotSlot(tool: .claudeCode, state: .running)]))
    }

    private func makeSession(id: String, tool: AgentTool, phase: SessionPhase) -> AgentSession {
        let now = Date(timeIntervalSince1970: 400_000)
        var session = AgentSession(
            id: id,
            title: "\(tool.displayName) · \(id)",
            tool: tool,
            origin: .live,
            attachmentState: .attached,
            phase: phase,
            summary: "",
            updatedAt: now,
            firstSeenAt: now,
            jumpTarget: JumpTarget(
                terminalApp: "Ghostty",
                workspaceName: id,
                paneTitle: "\(id) ~/\(id)",
                workingDirectory: "/tmp/\(id)",
                terminalSessionID: "ghostty-\(id)"
            )
        )
        session.isProcessAlive = true
        session.isHookManaged = true
        return session
    }
}
