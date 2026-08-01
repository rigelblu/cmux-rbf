import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `AppDelegate.presentPreferencesWindow` seam tests: the shared menu/⌘,
/// entrypoint must route through a result-reporting presenter and must not
/// activate the app when presentation fails
/// (https://github.com/manaflow-ai/cmux/issues/7777). Extracted from
/// `AppDelegateShortcutRoutingTests` to stay within the file-length budget.
@MainActor
@Suite
struct AppDelegatePresentPreferencesWindowTests {
    @Test func showsCustomSettingsWindowAndActivates() {
        var presentSettingsWindowCallCount = 0
        var activateApplicationCallCount = 0
        var receivedNavigationTargets: [SettingsNavigationTarget?] = []

        AppDelegate.presentPreferencesWindow(
            presentSettingsWindow: { navigationTarget in
                receivedNavigationTargets.append(navigationTarget)
                presentSettingsWindowCallCount += 1
                return .presented
            },
            activateApplication: {
                activateApplicationCallCount += 1
            }
        )

        #expect(presentSettingsWindowCallCount == 1)
        #expect(activateApplicationCallCount == 1)
        #expect(receivedNavigationTargets == [nil])
    }

    @Test func supportsRepeatedCalls() {
        var presentSettingsWindowCallCount = 0
        var activateApplicationCallCount = 0
        var receivedNavigationTargets: [SettingsNavigationTarget?] = []

        AppDelegate.presentPreferencesWindow(
            presentSettingsWindow: { navigationTarget in
                receivedNavigationTargets.append(navigationTarget)
                presentSettingsWindowCallCount += 1
                return .presented
            },
            activateApplication: {
                activateApplicationCallCount += 1
            }
        )

        AppDelegate.presentPreferencesWindow(
            presentSettingsWindow: { navigationTarget in
                receivedNavigationTargets.append(navigationTarget)
                presentSettingsWindowCallCount += 1
                return .presented
            },
            activateApplication: {
                activateApplicationCallCount += 1
            }
        )

        #expect(presentSettingsWindowCallCount == 2)
        #expect(activateApplicationCallCount == 2)
        #expect(receivedNavigationTargets == [nil, nil])
    }

    @Test func forwardsNavigationTarget() {
        var receivedNavigationTarget: SettingsNavigationTarget?
        var activateApplicationCallCount = 0

        AppDelegate.presentPreferencesWindow(
            navigationTarget: .keyboardShortcuts,
            presentSettingsWindow: { navigationTarget in
                receivedNavigationTarget = navigationTarget
                return .presented
            },
            activateApplication: {
                activateApplicationCallCount += 1
            }
        )

        #expect(receivedNavigationTarget == .keyboardShortcuts)
        #expect(activateApplicationCallCount == 1)
    }

    @Test func forwardsBrowserImportNavigationTarget() {
        var receivedNavigationTarget: SettingsNavigationTarget?
        var activateApplicationCallCount = 0

        AppDelegate.presentPreferencesWindow(
            navigationTarget: .browserImport,
            presentSettingsWindow: { navigationTarget in
                receivedNavigationTarget = navigationTarget
                return .presented
            },
            activateApplication: {
                activateApplicationCallCount += 1
            }
        )

        #expect(receivedNavigationTarget == .browserImport)
        #expect(activateApplicationCallCount == 1)
    }

    /// `#cm-11` — both color submenus' **Edit Color Labels…** row routes here, so the
    /// section it lands on is asserted once rather than in each builder.
    @Test func workspaceColorLabelEditorOpensWorkspaceColorsSection() {
        var receivedNavigationTarget: SettingsNavigationTarget?
        var activateApplicationCallCount = 0

        AppDelegate.presentWorkspaceColorLabelEditor(
            presentSettingsWindow: { navigationTarget in
                receivedNavigationTarget = navigationTarget
                return .presented
            },
            activateApplication: {
                activateApplicationCallCount += 1
            }
        )

        #expect(receivedNavigationTarget == .workspaceColors)
        #expect(activateApplicationCallCount == 1)
    }

    /// A menu row that silently does nothing is worse than one that beeps: the label
    /// editor inherits the same fail-loud contract as ⌘, rather than getting its own.
    @Test func workspaceColorLabelEditorDoesNotActivateWhenPresentationFails() {
        var activateApplicationCallCount = 0

        AppDelegate.presentWorkspaceColorLabelEditor(
            presentSettingsWindow: { _ in
                .failed(reason: "test-injected presentation failure")
            },
            activateApplication: {
                activateApplicationCallCount += 1
            }
        )

        #expect(activateApplicationCallCount == 0)
    }

    @Test func doesNotActivateWhenPresentationFails() {
        var activateApplicationCallCount = 0

        AppDelegate.presentPreferencesWindow(
            presentSettingsWindow: { _ in
                .failed(reason: "test-injected presentation failure")
            },
            activateApplication: {
                activateApplicationCallCount += 1
            }
        )

        // A failed presentation must not silently activate the app as if it
        // succeeded.
        #expect(activateApplicationCallCount == 0)
    }
}
