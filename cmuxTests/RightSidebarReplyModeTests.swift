import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Wiring for the Reply right-sidebar mode (`#cm-69.1`).
///
/// Adding a `RightSidebarMode` case makes the compiler name most of the sites
/// that must handle it, and those need no test — they cannot ship wrong. These
/// cover the paths where a miss is **silent**: a switch with a `default`, and
/// two functions whose `nil` is swallowed by a `compactMap`.
@Suite("Right sidebar Reply mode")
struct RightSidebarReplyModeTests {

    @Test("`cmux` can open Reply from the CLI")
    func cliArgumentResolvesReply() {
        // `from(cliArgument:)` ends in `default: return nil`, so the compiler
        // never forced this case. Without it the mode exists in the UI and is
        // unreachable from the CLI, with no error anywhere.
        #expect(RightSidebarMode.from(cliArgument: "reply") == .reply)
        #expect(RightSidebarMode.from(cliArgument: "  REPLY  ") == .reply)
        #expect(RightSidebarMode.from(cliArgument: "replies") == nil)
    }

    @Test("Reply is not beta-gated")
    func replyIsAvailableWithBetaFeaturesOff() {
        // An unavailable mode beeps instead of opening. Feed and Dock are the
        // gated pair; Reply ships on, like Files/Find/Vault.
        #expect(RightSidebarMode.reply.isAvailable(feedEnabled: false, dockEnabled: false, machinesEnabled: false))
        #expect(RightSidebarMode.availableModes(feedEnabled: false, dockEnabled: false, machinesEnabled: false).contains(.reply))
    }

    @Test("Reply promotes to a pane, and both palette descriptors exist for it")
    func replyOpensAsPaneAndHasPaletteDescriptors() {
        // `commandPaletteRightSidebarToolPaneCommandDescriptors()` compactMaps
        // over paneModes using a command id and a title. Either returning nil
        // drops the command with no compile error and no runtime complaint —
        // "Open Reply as Pane" would simply never appear.
        #expect(RightSidebarMode.reply.canOpenAsPane)

        let descriptors = ContentView.commandPaletteRightSidebarToolPaneCommandDescriptors()
        let reply = descriptors.first { $0.mode == .reply }

        #expect(reply != nil)
        #expect(reply?.commandId == "palette.openReplyPane")
        #expect(reply?.title == String(
            localized: "command.openReplyPane.title", defaultValue: "Open Reply as Pane"))
        #expect(descriptors.count == RightSidebarMode.paneModes.count)
    }

    @Test("Every mode's palette command id is distinct")
    func paletteCommandIDsAreUnique() {
        // A copy-pasted id would silently shadow another mode's command rather
        // than fail to build.
        let ids = RightSidebarMode.allCases.map(ContentView.commandPaletteRightSidebarModeCommandID)
        #expect(Set(ids).count == RightSidebarMode.allCases.count)
        #expect(ContentView.commandPaletteRightSidebarModeCommandID(.reply) == "palette.showRightSidebarReply")
    }

    @Test("Reply sits after Dock and before Custom in the mode bar")
    func replySitsBeforeCustomInModeBarOrder() {
        // The mode bar renders `allCases` in declaration order, and Custom is
        // required to stay last.
        let order = RightSidebarMode.allCases
        let dock = order.firstIndex(of: .dock)
        let reply = order.firstIndex(of: .reply)
        let custom = order.firstIndex(of: .customSidebar)

        #expect(dock != nil && reply != nil && custom != nil)
        #expect(dock! < reply!)
        #expect(reply! < custom!)
        #expect(custom == order.count - 1)
    }

    @Test("Reply does not drive the file explorer root")
    func replyDoesNotSyncFileExplorerRoot() {
        // Reply reads a transcript. Syncing the file tree from it would do
        // pointless disk work every time the mode is shown.
        #expect(
            FileExplorerRootSyncPolicy.shouldSyncFileExplorerStore(
                isRightSidebarVisible: true, mode: .reply) == false
        )
    }

    @Test("Reply carries a label and a symbol, and binds no shortcut yet")
    func replyPresentationDefaults() {
        #expect(RightSidebarMode.reply.label == String(
            localized: "rightSidebar.mode.reply", defaultValue: "Reply"))
        #expect(RightSidebarMode.reply.symbolName == "arrowshape.turn.up.left")
        // The six-surface shortcut fan-out is deferred to `cm-69.7`; the
        // palette falls back to `label`, as it already does for Custom.
        #expect(RightSidebarMode.reply.shortcutAction == nil)
    }

    @Test("Reply's symbol does not collide with another mode's")
    func modeSymbolsAreDistinct() {
        let symbols = RightSidebarMode.allCases.map(\.symbolName)
        #expect(Set(symbols).count == RightSidebarMode.allCases.count)
    }
}
