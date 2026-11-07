import SwiftUI
import OpenIslandCore

enum IslandDesignPalette {
    /// Per-agent brand tokens that are more than a single hex: surfaces that
    /// need a fill, a hairline or a glow read them here instead of guessing
    /// opacities at the call site.
    enum Agent {
        /// PI Desktop: gray-white ("paper") identity. Deliberately low
        /// saturation so it never competes with the island's body text.
        enum PiDesktop {
            static let accent = Color(red: 244.0 / 255.0, green: 241.0 / 255.0, blue: 234.0 / 255.0)
            static let accentStrong = Color.white
            static let accentMuted = Color(red: 207.0 / 255.0, green: 201.0 / 255.0, blue: 190.0 / 255.0)
            static let accentSubtle = Color(red: 148.0 / 255.0, green: 142.0 / 255.0, blue: 131.0 / 255.0)
            static let onAccent = Color(red: 27.0 / 255.0, green: 26.0 / 255.0, blue: 24.0 / 255.0)
            static let fill = accent.opacity(0.10)
            static let hairline = accent.opacity(0.28)
            static let glow = accent.opacity(0.20)
        }

        /// YI-Work: warm orange, leaning orange-yellow. Sits between Claude's
        /// yellow and a pure red so the row reads as its own thing rather than
        /// another Claude tint.
        enum YiWork {
            static let accent = Color(red: 255.0 / 255.0, green: 122.0 / 255.0, blue: 30.0 / 255.0)
            static let accentMuted = Color(red: 214.0 / 255.0, green: 98.0 / 255.0, blue: 26.0 / 255.0)
            static let glow = accent.opacity(0.22)
        }
    }

    enum Status {
        static let waitingAggregate = Color(red: 231.0 / 255.0, green: 167.0 / 255.0, blue: 98.0 / 255.0)
        static let waitingForApproval = Color(red: 244.0 / 255.0, green: 164.0 / 255.0, blue: 164.0 / 255.0)
        static let waitingForAnswer = Color(red: 255.0 / 255.0, green: 213.0 / 255.0, blue: 138.0 / 255.0)
        static let running = Color(red: 110.0 / 255.0, green: 167.0 / 255.0, blue: 255.0 / 255.0)
        static let completed = Color(red: 111.0 / 255.0, green: 185.0 / 255.0, blue: 130.0 / 255.0)
        static let inactive = V6Palette.paper.opacity(0.38)
        static let idle = V6Palette.paper.opacity(0.35)

        // Agent-specific running breathing light colors:
        /// AGY (Antigravity / Gemini CLI) 鲜绿色
        static let runningAgy = Color(red: 48.0 / 255.0, green: 209.0 / 255.0, blue: 88.0 / 255.0)
        /// Codex 经典蓝（当前原版蓝色）
        static let runningCodex = Color(red: 110.0 / 255.0, green: 167.0 / 255.0, blue: 255.0 / 255.0)
        /// Claude Code 鲜黄色
        static let runningClaude = Color(red: 255.0 / 255.0, green: 214.0 / 255.0, blue: 10.0 / 255.0)

        static func runningTint(for tool: AgentTool?) -> Color {
            guard let tool else { return running }
            switch tool {
            case .geminiCLI:
                return runningAgy
            case .codex:
                return runningCodex
            case .claudeCode:
                return runningClaude
            case .piDesktop:
                return Agent.PiDesktop.accent
            default:
                if let hex = Color(hex: tool.brandColorHex) {
                    return hex
                }
                return running
            }
        }

        static func tint(for phase: SessionPhase, tool: AgentTool? = nil) -> Color {
            switch phase {
            case .waitingForApproval:
                waitingForApproval
            case .waitingForAnswer:
                waitingForAnswer
            case .running:
                runningTint(for: tool)
            case .completed:
                completed
            }
        }

        static func tint(for phase: SessionPhase, presence: IslandSessionPresence, tool: AgentTool? = nil) -> Color {
            if phase == .waitingForApproval || phase == .waitingForAnswer {
                return tint(for: phase, tool: tool)
            }

            switch presence {
            case .running:
                return runningTint(for: tool)
            case .active:
                return completed
            case .inactive:
                return inactive
            }
        }
    }
}
