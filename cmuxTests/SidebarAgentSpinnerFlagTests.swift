import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct SidebarAgentSpinnerFlagTests {
    @Test(arguments: [nil, false, true] as [Bool?])
    func spinnerStaysEnabledRegardlessOfRemoteAndLocalValues(remote: Bool?) throws {
        let suite = "cmux.sidebar.spinner.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let definition = try #require(CmuxFeatureFlags.allFlags.first {
            $0.key == "sidebar-workspace-agent-spinner-experiment"
        })
        defaults.set(false, forKey: "cmux.flags.override.\(definition.key)")
        let flags = CmuxFeatureFlags(defaults: defaults, remoteFlagValueProvider: { _ in remote })
        flags.applyLoadedFlags()

        #expect(flags.remoteValue(for: definition) == remote)
        #expect(flags.overrideValue(for: definition) == false)
        #expect(flags.isSidebarWorkspaceAgentSpinnerEnabled)
    }
}
