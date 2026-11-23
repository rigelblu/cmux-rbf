import Foundation
import CmuxSidebar
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension SidebarWorkspaceSnapshotTests {
    @MainActor
    @Test func workspaceAgentSpinnerFeatureFlagDefaultsOff() throws {
        let definition = try #require(CmuxFeatureFlags.allFlags.first {
            $0.key == "sidebar-workspace-agent-spinner-experiment"
        })
        let suiteName = "cmux.feature.flags.sidebar-workspace-agent-spinner.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let flags = CmuxFeatureFlags(defaults: defaults, remoteFlagValueProvider: { _ in nil })

        #expect(!flags.effectiveValue(for: definition))
    }

    @Test func presentationKeyChangesWhenAgentActivityVisibilityChanges() {
        let hidden = Self.presentationKey(showsAgentActivity: false)
        let visible = Self.presentationKey(showsAgentActivity: true)

        #expect(hidden != visible)
        #expect(!hidden.showsAgentActivity)
        #expect(visible.showsAgentActivity)
    }

    // cmux-rbf: changed on purpose (#cm-128.6): the laziness guard follows the lists builder, which is the code that ships.
    @Test func disabledMarksDoNotReadAgentLifecycleStates() {
        var didReadAgentLifecycleStates = false
        let paneStates: () -> WorkspaceAgentPaneStates = {
            didReadAgentLifecycleStates = true
            return WorkspaceAgentPaneStates(entries: [
                WorkspaceAgentPaneState(panelId: UUID(), agentKey: "codex", state: .running, usageLimit: false),
            ])
        }

        let lists = SidebarAgentActivitySummary.lists(
            showsNeedsYouMarks: false, showsAgentActivity: false, paneStates: paneStates())

        #expect(lists == SidebarAgentStateLists())
        #expect(!didReadAgentLifecycleStates)
    }
}
