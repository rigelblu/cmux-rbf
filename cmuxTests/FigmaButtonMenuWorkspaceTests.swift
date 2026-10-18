import AppKit
import Bonsplit
import CmuxBrowser
import CmuxSettings
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor @Suite(.serialized) struct FigmaButtonMenuWorkspaceTests {
    private let folder = "https://www.figma.com/files/team/764866853003674551/folder/643299150"
    private func select(_ title: String, in menu: NSMenu) throws {
        let index = try #require(menu.items.firstIndex { $0.title == title })
        menu.performActionForItem(at: index)
    }
    private func panelAddress(_ panel: BrowserPanel) -> String? {
        (panel.navigationDelegate?.lastAttemptedURL ?? panel.currentURL)?.absoluteString
    }
    // cmux-rbf #cm-73.16: kind is recovered from the saved URL, including legacy /file/ links.
    @Test func kindImagesOnNewAndSavedRows() throws {
        let w = Workspace(); defer { w.teardownAllPanels() }
        let pane = try #require(w.bonsplitController.allPaneIds.first)
        for path in ["design/D/Design", "file/F/Legacy", "board/B/Board", "slides/S/Slides"] {
            w.figmaFiles.show(URL(string: "https://www.figma.com/\(path)")!)
        }
        let menu = w.figmaButtonMenu(inPane: pane, folder: folder)
        var data: [String: Data] = [:]
        for title in ["Design", "Legacy", "Board", "Slides", "New Design File", "New FigJam Board", "New Slide Deck"] {
            let item = try #require(menu.items.first { $0.title == title })
            let image = try #require(item.image, "kind image missing for \(title)")
            #expect(image.size == NSSize(width: 16, height: 16))
            #expect(!image.isTemplate)
            data[title] = try #require(image.tiffRepresentation)
            let picture = try #require(data[title])
            let rep = try #require(NSBitmapImageRep(data: picture))
            let rgb = title.contains("Board") ? [136, 72, 240] : title.contains("Slides") || title.contains("Slide Deck") ? [232, 96, 48] : [64, 144, 240]
            // colorAt returns calibrated NSColor values; pin the stored sRGB bytes, as FigmaMarkAsset does.
            try #require(rep.bitsPerSample == 8 && rep.samplesPerPixel == 4)
            let bytes = try #require(rep.bitmapData)
            var tilePixels = 0
            var whitePixels = 0
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    let pixel = bytes + y * rep.bytesPerRow + x * 4
                    guard pixel[3] > 242 else { continue }
                    if (0..<3).allSatisfy({ abs(Int(pixel[$0]) - rgb[$0]) < 3 }) { tilePixels += 1 }
                    if (0..<3).allSatisfy({ pixel[$0] > 242 }) { whitePixels += 1 }
                }
            }
            #expect(tilePixels > 20, "wrong kind tile colour for \(title)")
            #expect(whitePixels > 2, "missing white glyph for \(title)")
            #expect(bytes[3] < 128, "tile corners should be rounded")
        }
        #expect(data["Design"] == data["New Design File"])
        #expect(data["Legacy"] == data["Design"])
        #expect(data["Board"] == data["New FigJam Board"])
        #expect(data["Slides"] == data["New Slide Deck"])
        #expect(data["Design"] != data["Board"])
        #expect(data["Board"] != data["Slides"])
        #expect(menu.items.first { $0.title == "Recents…" }?.image == nil)
    }
    // cmux-rbf #cm-73.16: non-file pages have no kind image; decoding is reused across menu builds.
    @Test func kindImageFallbackAndCache() throws {
        #expect(FigmaKindIcon.kind(for: URL(string: "https://www.figma.com/files/recent")!) == nil)
        let w = Workspace(); defer { w.teardownAllPanels() }
        let pane = try #require(w.bonsplitController.allPaneIds.first)
        let menu = w.figmaButtonMenu(inPane: pane, folder: "invalid")
        for title in ["Choose Figma Folder…", "Recents…", "Enter Design Focus"] {
            let item = try #require(menu.items.first { $0.title == title })
            #expect(item.image == nil)
        }
        for kind in FigmaNewFileLink.Kind.allCases {
            let first = try #require(FigmaKindIcon.image(for: kind))
            #expect(first === FigmaKindIcon.image(for: kind))
        }
        #expect(Workspace.currentSplitButtonTooltips().pairExit == KeyboardShortcutSettings.Action.toggleDesignFocus.tooltip(
            String(localized: "workspace.tooltip.pairExit", defaultValue: "Exit Design Focus")
        ))
    }

    @Test func recentsAndNewFileActionsUseClickedPaneAndFocus() throws {
        let w = Workspace(); defer { w.teardownAllPanels() }
        let first = try #require(w.bonsplitController.allPaneIds.first)
        let terminal = try #require(w.focusedPanelId)
        _ = try #require(w.newTerminalSplit(from: terminal, orientation: .horizontal))
        let clicked = w.bonsplitController.allPaneIds[1]
        w.focusPanel(terminal)
        let beforeFirst = w.bonsplitController.tabs(inPane: first).count
        let beforeClicked = w.bonsplitController.tabs(inPane: clicked).count
        let menu = w.figmaButtonMenu(inPane: clicked, folder: folder)
        try select("Recents…", in: menu)
        #expect(w.bonsplitController.tabs(inPane: clicked).count == beforeClicked + 1)
        #expect(w.bonsplitController.tabs(inPane: first).count == beforeFirst)
        for (kind, title) in [("design", "New Design File"), ("board", "New FigJam Board"), ("slides", "New Slide Deck")] {
            try select(title, in: menu)
            let panel = try #require(w.panels[w.focusedPanelId ?? UUID()] as? BrowserPanel)
            #expect(w.paneId(forPanelId: panel.id) == clicked)
            #expect(panelAddress(panel) == "https://www.figma.com/\(kind)/new?folder_id=643299150&team_id=764866853003674551")
            #expect(!panel.isOmnibarVisible)
        }
    }
    @Test func picksFirstOpenTabWithoutNavigationOrReordering() throws {
        let w = Workspace(); defer { w.teardownAllPanels() }
        let first = try #require(w.bonsplitController.allPaneIds.first)
        let a = try #require(w.newFigmaSurface(inPane: first))
        let url = URL(string: "https://www.figma.com/design/A/Name?node-id=9-8")!
        a.publishObservedDocumentURL(url)
        let terminal = try #require(w.panels.values.first { $0 is TerminalPanel })
        _ = try #require(w.newTerminalSplit(from: terminal.id, orientation: .horizontal))
        let clicked = w.bonsplitController.allPaneIds[1]
        let b = try #require(w.newFigmaSurface(inPane: clicked))
        b.publishObservedDocumentURL(url)
        w.figmaFiles.show(URL(string: "https://www.figma.com/design/A/Name?node-id=2-3")!, title: "Saved – Figma")
        let before = w.figmaFiles.entries
        let attemptedBefore = a.navigationDelegate?.lastAttemptedURL
        let tabCount = w.bonsplitController.allTabIds.count
        let menu = w.figmaButtonMenu(inPane: clicked)
        try select("Saved", in: menu)
        #expect(w.focusedPanelId == a.id)
        #expect(w.bonsplitController.allTabIds.count == tabCount)
        #expect(a.navigationDelegate?.lastAttemptedURL == attemptedBefore)
        #expect(w.figmaFiles.entries == before)
    }
    @Test func closedEditorAndReadRowsReopenTheirViewAndFrame() throws {
        let w = Workspace(); defer { w.teardownAllPanels() }
        let pane = try #require(w.bonsplitController.allPaneIds.first)
        let page = FileManager.default.temporaryDirectory.appendingPathComponent("figma-menu-\(UUID()).html")
        defer { try? FileManager.default.removeItem(at: page) }
        let editor = URL(string: "https://www.figma.com/design/A/Editor?node-id=2-3&mode=dev")!
        w.figmaFiles.show(editor, title: "Editor – Figma")
        let readLink = URL(string: "https://www.figma.com/design/B/Read?node-id=8-7")!
        let read = try FigmaPaneURL.destination(for: readLink).url
        w.figmaFiles.show(read, title: "Figma")
        let menu = w.figmaButtonMenu(inPane: pane, page: page)
        try select("Editor", in: menu)
        let editorPanel = try #require(w.panels[w.focusedPanelId ?? UUID()] as? BrowserPanel)
        #expect(panelAddress(editorPanel) == editor.absoluteString)
        try select("Read", in: menu)
        let readPanel = try #require(w.panels[w.focusedPanelId ?? UUID()] as? BrowserPanel)
        let address = try #require(panelAddress(readPanel).flatMap(URL.init(string:)))
        #expect(FigmaPaneURL.isWrapperPage(address, wrapper: page))
        #expect(FigmaPaneURL.node(fromPaneURL: address, wrapper: page) == "8-7")
    }
    @Test func newSurfaceChecksRequestedAddressAllowlist() throws {
        let w = Workspace(); defer { w.teardownAllPanels() }
        let pane = try #require(w.bonsplitController.allPaneIds.first)
        let name = "figma-menu-\(UUID())"; let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: BrowserAvailabilitySettings.disabledKey)
        defaults.set("www.figma.com", forKey: BrowserURLAllowlistPolicy.userDefaultsKey)
        let requested = URL(string: "https://figma.com/design/new?folder_id=1&team_id=2")!
        var handedOff: [URL] = []
        let panel = w.newFigmaSurface(inPane: pane, address: requested, defaults: defaults, openExternally: { handedOff.append($0) })
        #expect(panel == nil)
        #expect(handedOff == [requested])
    }
    @Test func choosesFolderWithSettingsAnchorAndHighlight() throws {
        let w = Workspace(); defer { w.teardownAllPanels() }
        let pane = try #require(w.bonsplitController.allPaneIds.first)
        var destination: SettingsNavigationDestination?
        let menu = w.figmaButtonMenu(inPane: pane, folder: "invalid", showSettings: { target, anchor, highlight in
            destination = SettingsNavigationDestination(target: target, anchorID: anchor, shouldHighlight: highlight)
        })
        try select("Choose Figma Folder…", in: menu)
        #expect(destination?.target == .automation)
        #expect(destination?.anchorID == "setting:automation:figma-default-folder")
        #expect(destination?.shouldHighlight == true)
    }
    @Test func focusEligibilityUsesTheSameGuardsAndMenuEnters() throws {
        let w = Workspace(); defer { w.teardownAllPanels() }
        let pane = try #require(w.bonsplitController.allPaneIds.first)
        #expect(!w.canEnterDesignFocusFromFigmaMenu) // no Figma
        let terminal = try #require(w.focusedPanelId)
        let figma = try #require(w.newFigmaSurface(inPane: pane))
        #expect(w.canEnterDesignFocusFromFigmaMenu)
        w.layoutMode = .canvas
        #expect(!w.canEnterDesignFocusFromFigmaMenu)
        w.layoutMode = .splits
        _ = w.closePanel(terminal, force: true)
        #expect(!w.canEnterDesignFocusFromFigmaMenu) // no terminal
        _ = w.newTerminalSurface(inPane: pane)
        w.focusPanel(figma.id)
        let menu = w.figmaButtonMenu(inPane: pane)
        let item = try #require(menu.items.first { $0.title == "Enter Design Focus" })
        #expect(item.isEnabled)
        #expect(item.keyEquivalent == (KeyboardShortcutSettings.menuShortcut(for: .toggleDesignFocus).menuItemKeyEquivalent ?? ""))
        try select("Enter Design Focus", in: menu)
        #expect(w.isDesignFocusActive)
    }
    // cmux-rbf #cm-73.16: R6, a refused local read view hands out only Figma's own link.
    @Test func refusedReadViewOpensFigmaLinkExternally() throws {
        let w = Workspace(); defer { w.teardownAllPanels() }
        let pane = try #require(w.bonsplitController.allPaneIds.first)
        let name = "figma-read-refusal-\(UUID())"
        let defaults = try #require(LocalFileRefusingDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: BrowserAvailabilitySettings.disabledKey)
        let link = URL(string: "https://www.figma.com/design/A/Read?node-id=8-7")!
        w.figmaFiles.show(try FigmaPaneURL.destination(for: link).url)
        let entry = try #require(w.figmaFiles.entries.first)
        var handedOff: [URL] = []
        let before = w.bonsplitController.allTabIds.count
        let menu = w.figmaButtonMenu(inPane: pane, defaults: defaults, openExternally: { handedOff.append($0) })
        try select("Read", in: menu)
        #expect(handedOff == [entry.link])
        #expect(!handedOff.contains { $0.isFileURL })
        #expect(w.bonsplitController.allTabIds.count == before)
    }

    // Immutable overrides over Foundation's thread-safe preference store; no extra mutable state.
    private final class LocalFileRefusingDefaults: UserDefaults, @unchecked Sendable {
        override func objectIsForced(forKey key: String) -> Bool {
            key == "BrowserAllowLocalFiles" || super.objectIsForced(forKey: key)
        }
        override func object(forKey key: String) -> Any? {
            key == "BrowserAllowLocalFiles" ? false : super.object(forKey: key)
        }
    }

}
