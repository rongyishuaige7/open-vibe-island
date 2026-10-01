// Pixel mascots for the closed island's right slot and the pixel checkmark
// used by the `.pixel` session-state style.
//
// The Claude critter frames, the per-cell shimmer and the checkmark bitmap are
// adapted from agent-notch (https://github.com/realfishsam/agent-notch),
// which carries this license:
//
// MIT License
//
// Copyright (c) 2026 realfishsam
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
// The Codex and generic mascots are original to this fork.

import Foundation
import OpenIslandCore

/// One mascot in the right slot: an agent tool, the most urgent state among
/// its surfaced sessions and the most urgent mark to float above it.
struct PixelMascotSlot: Equatable {
    let tool: AgentTool
    let state: AgentGridCellState
    var mark: PixelMascotMark? = nil
}

/// A small glyph above a mascot. Raw values rank urgency: a pending approval
/// outranks a question, which outranks a finished turn the user hasn't seen.
enum PixelMascotMark: Int, CaseIterable, Comparable {
    case unseenDone
    case answer
    case approval

    static func < (lhs: PixelMascotMark, rhs: PixelMascotMark) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Square cells, `#` lit, row 0 on top.
    var rows: [String] {
        switch self {
        case .unseenDone: PixelCheckmarkBitmap.rows
        case .answer: [".##.", "#..#", "..#.", "....", "..#."]
        case .approval: ["##", "##", "##", "..", "##"]
        }
    }

    static let cell: CGFloat = 1
    /// Clearance between the sprite's bob headroom and the mark.
    static let gap: CGFloat = 0.5
    /// Room the row reserves above the sprites so marks never clip.
    static let headroom: CGFloat = (gap + CGFloat(allCases.map { $0.rows.count }.max() ?? 0) * cell).rounded(.up)
}

/// A two-frame walking sprite; `#` marks a lit cell. Cells are twice as tall
/// as they are wide, the aspect of the terminal block characters the Claude
/// critter comes from.
struct PixelSprite {
    let frames: [[String]]
    /// Replacement row shown while a blinking cursor is off.
    var cursorOff: (row: Int, line: String)?

    var columns: Int { frames[0][0].count }
    var rowCount: Int { frames[0].count }

    func rows(frame: Int, cursorVisible: Bool) -> [String] {
        var rows = frames[frame % frames.count]
        if !cursorVisible, let cursorOff {
            rows[cursorOff.row] = cursorOff.line
        }
        return rows
    }

    static func sprite(for tool: AgentTool) -> PixelSprite {
        switch tool {
        case .claudeCode: claude
        case .codex: codex
        default: blob
        }
    }

    /// Claude Code's launch-banner critter; the feet alternate as it walks.
    static let claude = PixelSprite(frames: [
        ["..############..", "..##.######.##..", "################", "..############..", "...#.#....#.#..."],
        ["..############..", "..##.######.##..", "################", "..############..", "....#.#..#.#...."],
    ])

    /// A terminal-window critter with a `>_` face whose cursor blinks.
    static let codex = PixelSprite(
        frames: [
            [".########.", "#.########", "##.#######", "#.##....##", ".########.", ".##....##."],
            [".########.", "#.########", "##.#######", "#.##....##", ".########.", "..##..##.."],
        ],
        cursorOff: (row: 3, line: "#.########")
    )

    /// A small blob in the tool's brand color for every other agent.
    static let blob = PixelSprite(frames: [
        ["..####..", ".######.", "##.##.##", ".######.", ".#....#."],
        ["..####..", ".######.", "##.##.##", ".######.", "..#..#.."],
    ])
}

/// Frame timing shared by the mascot row, kept pure so tests can pin it.
enum PixelMascotMotion {
    static let stepDuration: TimeInterval = 0.4
    static let cursorBlinkDuration: TimeInterval = 0.8
    static let bobHeight: CGFloat = 1
    /// One walk-and-blink cycle: two steps with the cursor on, two with it off.
    static let cycleDuration: TimeInterval = 1.6
    /// Sample times for the running keyframes, one inside each step.
    static let keyframeTimes: [TimeInterval] = [0.2, 0.6, 1.0, 1.4]
    static let idleOpacity: Float = 0.3
    static let breathMinOpacity: Float = 0.35
    static let breathDuration: TimeInterval = 0.7

    /// Keeps the time small so the frame math stays exact.
    private static func phase(_ time: TimeInterval) -> TimeInterval {
        time.truncatingRemainder(dividingBy: 3_600)
    }

    /// Only running mascots walk; everything else holds frame 0.
    static func walkFrame(state: AgentGridCellState, time: TimeInterval?) -> Int {
        guard state == .running, let time else { return 0 }
        return Int(phase(time) / stepDuration) % 2
    }

    static func cursorVisible(state: AgentGridCellState, time: TimeInterval?) -> Bool {
        guard state == .running, let time else { return true }
        return Int(phase(time) / cursorBlinkDuration) % 2 == 0
    }

    /// Resting layer opacity: idle mascots stay dim unless a mark floats above
    /// them, so an unseen finish lights the critter back up. Waiting ones
    /// breathe from `breathMinOpacity` up to full, like the grid's waiting tile.
    static func opacity(for state: AgentGridCellState, mark: PixelMascotMark? = nil) -> Float {
        state == .idle && mark == nil ? idleOpacity : 1
    }

    /// Stable per-cell noise in 0..<1 that re-rolls three times a second,
    /// for the running body's shimmer.
    static func shimmer(column: Int, row: Int, time: TimeInterval) -> Double {
        let step = Int(phase(time) * 3)
        let n = sin(Double(column * 374_761 + row * 668_265 + step * 982_451) * 0.0001) * 43_758.5453
        return n - n.rounded(.down)
    }
}

/// The completed-row checkmark, drawn with square cells.
enum PixelCheckmarkBitmap {
    static let rows = ["......#", ".....#.", "#...#..", ".#.#...", "..#...."]
}
