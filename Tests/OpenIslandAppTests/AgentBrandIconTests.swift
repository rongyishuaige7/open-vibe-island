import AppKit
import Testing
@testable import OpenIslandApp
@testable import OpenIslandCore

@MainActor
struct AgentBrandIconTests {
    @Test
    func claudeAndCodexLoadBundledTemplateIcons() {
        for tool in [AgentTool.claudeCode, .codex] {
            let image = AgentBrandIcon.image(for: tool)
            #expect(image != nil, "\(tool) icon should load from the resource bundle")
            #expect(image?.isTemplate == true)
            #expect(image?.size == NSSize(width: 24, height: 24))
        }
    }

    @Test
    func agentsWithoutAMarkKeepTextOnlyBadge() {
        #expect(AgentBrandIcon.resourceName(for: .geminiCLI) == nil)
        #expect(AgentBrandIcon.image(for: .cursor) == nil)
    }
}
