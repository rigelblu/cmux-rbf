import Bonsplit

extension BonsplitConfiguration {
    /// Workspace-derived policy for a nested remote-tmux split tree.
    var remoteTmuxEmbedded: BonsplitConfiguration {
        var configuration = self
        configuration.allowSplits = true
        configuration.allowCloseLastPane = false
        configuration.allowTabReordering = false
        configuration.allowCrossPaneTabMove = false
        configuration.allowsTabContextMenu = false
        configuration.autoCloseEmptyPanes = false
        configuration.contentViewLifecycle = .keepAllAlive
        configuration.newTabPosition = .end
        configuration.tabBarVisibility = .always
        configuration.dividerPositionRange = 0...1

        configuration.appearance.minimumPaneWidth = 1
        configuration.appearance.minimumPaneHeight = 1
        configuration.appearance.tabBarLeadingInset = 0
        configuration.appearance.enableAnimations = false
        // Keep configured Left/Up controls visible so the remote capability
        // boundary is discoverable, but disable them before the nested mirror
        // receives the configuration. Right/Down remain executable.
        configuration.appearance.splitButtons = configuration.appearance.splitButtons.compactMap {
            var button = $0
            switch button.action {
            case .splitRight, .splitDown,
                 .custom("cmux.splitRight"), .custom("cmux.splitDown"):
                return button
            case .custom("cmux.splitLeft"), .custom("cmux.splitUp"):
                button.isEnabled = false
                button.tooltip = TerminalSplitUnsupportedReason
                    .remoteMirrorCannotInsertBefore
                    .localizedHelp
                return button
            default:
                return nil
            }
        }
        return configuration
    }
}
