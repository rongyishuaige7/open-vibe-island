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
        #expect(!PixelMascotMotion.cursorVisible(state: .running, time: 1.0))
        #expect(PixelMascotMotion.cursorVisible(state: .waiting, time: 1.0))
    }

    @Test
    func idleMascotsRestDim() {
        #expect(PixelMascotMotion.opacity(for: .idle) == PixelMascotMotion.idleOpacity)
        #expect(PixelMascotMotion.opacity(for: .running) == 1)
        #expect(PixelMascotMotion.opacity(for: .waiting) == 1)
        #expect(PixelMascotMotion.breathMinOpacity < 1)
    }

    /// Each running keyframe samples a different step of the cycle, so the
    /// four frames cover both walk poses with the cursor on and off.
    @Test
    func runningKeyframesCoverEveryWalkAndCursorPose() {
        let poses = PixelMascotMotion.keyframeTimes.map { time in
            "\(PixelMascotMotion.walkFrame(state: .running, time: time))-\(PixelMascotMotion.cursorVisible(state: .running, time: time))"
        }
        #expect(Set(poses).count == 4)
        #expect(PixelMascotMotion.keyframeTimes.allSatisfy { $0 < PixelMascotMotion.cycleDuration })
    }

    @Test
    func onlyRunningMascotsGetMoreThanOneFrame() {
        let running = PixelMascotRenderer.frames(for: PixelMascotSlot(tool: .claudeCode, state: .running), scale: 2, animated: true)
        #expect(running.count == 4)
        #expect(running.first?.width == 32)
        #expect(running.first?.height == 22)

        #expect(PixelMascotRenderer.frames(for: PixelMascotSlot(tool: .codex, state: .waiting), scale: 2, animated: true).count == 1)
        #expect(PixelMascotRenderer.frames(for: PixelMascotSlot(tool: .codex, state: .idle), scale: 2, animated: true).count == 1)
        #expect(PixelMascotRenderer.frames(for: PixelMascotSlot(tool: .codex, state: .running), scale: 2, animated: false).count == 1)
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
        #expect(slots == [PixelMascotSlot(tool: .codex, state: .waiting, mark: .answer)])
    }

    @Test
    func marksKeepTheMostUrgentPerTool() {
        let slots = AppModel.mascotSlots(
            for: [
                makeSession(id: "g-done", tool: .geminiCLI, phase: .completed),
                makeSession(id: "g-ask", tool: .geminiCLI, phase: .waitingForAnswer),
                makeSession(id: "x-ask", tool: .codex, phase: .waitingForAnswer),
                makeSession(id: "x-approve", tool: .codex, phase: .waitingForApproval),
                makeSession(id: "x-done", tool: .codex, phase: .completed),
                makeSession(id: "c-run", tool: .claudeCode, phase: .running),
                makeSession(id: "c-done", tool: .claudeCode, phase: .completed),
            ],
            unseenCompletedIDs: ["g-done", "x-done", "c-done"]
        )
        #expect(slots == [
            PixelMascotSlot(tool: .geminiCLI, state: .waiting, mark: .answer),
            PixelMascotSlot(tool: .codex, state: .waiting, mark: .approval),
            PixelMascotSlot(tool: .claudeCode, state: .running, mark: .unseenDone),
        ])
    }

    @Test
    func seenCompletionsCarryNoMark() {
        let slots = AppModel.mascotSlots(
            for: [makeSession(id: "done", tool: .codex, phase: .completed)],
            unseenCompletedIDs: ["another-session"]
        )
        #expect(slots == [PixelMascotSlot(tool: .codex, state: .idle)])
    }

    @Test
    func markedIdleMascotsStayLit() {
        #expect(PixelMascotMotion.opacity(for: .idle, mark: .unseenDone) == 1)
        #expect(PixelMascotMotion.opacity(for: .idle, mark: nil) == PixelMascotMotion.idleOpacity)
        #expect(PixelMascotMotion.opacity(for: .running, mark: .unseenDone) == 1)
    }

    @Test
    func markBitmapsAreRectangularAndNarrowerThanEverySprite() {
        let narrowestSprite = [PixelSprite.claude, .codex, .blob].map { PixelMascotRenderer.width(of: $0) }.min() ?? 0
        for mark in PixelMascotMark.allCases {
            let rows = mark.rows
            #expect(!rows.isEmpty)
            #expect(Set(rows.map(\.count)).count == 1)
            #expect(rows.joined().contains("#"))
            #expect(PixelMascotRenderer.markSize(of: mark).width < narrowestSprite)
            #expect(PixelMascotRenderer.markImage(for: mark, scale: 2) != nil)
        }
    }

    /// The row sits centered in the pill, and the island draws nothing above
    /// the pill: a mark has to land between the pill's top edge and the
    /// sprite's bob, inside the headroom the layer view reserves.
    @Test
    func marksFitAboveTheSpritesInsideThePill() {
        let layouts: [[AgentTool]] = [[.claudeCode], [.codex], [.geminiCLI], [.codex, .claudeCode], [.geminiCLI, .codex, .claudeCode]]
        // External menu bar, MacBook notch, taller MacBook notch.
        let pillHeights: [CGFloat] = [24, 32, 37]
        for tools in layouts {
            let slots = tools.map { PixelMascotSlot(tool: $0, state: .running) }
            let rowHeight = PixelMascotRow.height(of: slots)
            let spriteFrames = PixelMascotRenderer.spriteFrames(for: tools)
            for scale: CGFloat in [1, 2] {
                for mark in PixelMascotMark.allCases {
                    for spriteFrame in spriteFrames {
                        let markFrame = PixelMascotRenderer.markFrame(for: mark, above: spriteFrame, scale: scale)
                        #expect(markFrame.minY >= spriteFrame.maxY)
                        #expect(markFrame.minX >= spriteFrame.minX)
                        #expect(markFrame.maxX <= spriteFrame.maxX)
                        #expect(markFrame.maxY <= rowHeight + PixelMascotMark.headroom)
                        for pillHeight in pillHeights {
                            // Worst case: layout snaps the row's top down to the pixel grid.
                            let rowTop = (((pillHeight - rowHeight) / 2) * scale).rounded(.down) / scale
                            #expect(markFrame.maxY - rowHeight <= rowTop, "\(tools) \(mark) @\(scale)x in \(pillHeight)pt")
                        }
                    }
                }
            }
        }
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
