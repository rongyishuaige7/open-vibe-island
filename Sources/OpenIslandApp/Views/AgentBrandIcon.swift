import AppKit
import OpenIslandCore

/// Monochrome brand marks for agents that ship one (LobeHub icons, MIT —
/// see Resources/agent-icons-LICENSE.txt). Loaded as template images so
/// callers tint them with the agent's brand color; agents without a mark
/// keep the text-only badge.
@MainActor
enum AgentBrandIcon {
    private static var cache: [AgentTool: NSImage] = [:]

    nonisolated static func resourceName(for tool: AgentTool) -> String? {
        switch tool {
        case .claudeCode: "agent-icon-claude"
        case .codex: "agent-icon-codex"
        default: nil
        }
    }

    static func image(for tool: AgentTool) -> NSImage? {
        if let cached = cache[tool] {
            return cached
        }
        guard let name = resourceName(for: tool),
              let url = Bundle.appResources.url(forResource: name, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        // SVG reps report a 1×1 intrinsic size; give it the viewBox size.
        image.size = NSSize(width: 24, height: 24)
        image.isTemplate = true
        cache[tool] = image
        return image
    }
}
