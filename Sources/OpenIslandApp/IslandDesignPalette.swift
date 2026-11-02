import SwiftUI
import OpenIslandCore

enum IslandDesignPalette {
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
