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

// cmux-rbf #cm-73.43: every `.43` test that reads a panel's or a tab's title sits in this one
// `.serialized` suite, so no test sees another's `FigmaTabTitleSetting.current`. A test that needs
// the setting off installs its own holder and puts the app's back in a `defer`. Under the unit-test
// host the app's holder has no store and holds the default, on, so no test reads Tom's `cmux.json`.
@MainActor @Suite("FigmaTabTitle", .serialized)
struct FigmaTabTitleTests {

    // MARK: fixtures

    /// `cm-73 - figma native pane`, linked as Figma links it.
    static let file = "https://www.figma.com/design/MVdKSLWiPvKNyWab361uJ2/cm-73-figma-native-pane"
    /// The page title Figma's editor gives that file.
    static let fileTitle = "cm-73 - figma native pane – Figma"

    /// A Figma pane's panel: no address bar, as `cmux figma open` makes it.
    static func panel(bar: Bool = false) -> BrowserPanel {
        BrowserPanel(
            workspaceId: UUID(),
            chromeVisibility: bar ? .visible : .hidden,
            websiteDataStore: .nonPersistent()
        )
    }

    /// cmux's preview of a frame of a file (the page carrying the embed).
    static func preview(of link: String = file, node: String = "12-2") -> URL {
        let pasted = URL(string: link + "?node-id=" + node)!
        return (try? FigmaPaneURL.destination(for: pasted).url) ?? pasted
    }

    // MARK: Scenario 351, written against the panel's public seams only

    // (a) the preview, its page titled `Figma`: the link's name
    @Test func previewReadsLinkName() {
        let panel = Self.panel()
        panel.publishObservedDocumentURL(Self.preview())
        panel.publishObservedDocumentTitle("Figma")
        #expect(panel.displayTitle == "Figma (cm 73 figma native pane)")
    }

    // (b) the editor: Figma's own name for the file
    @Test func editorReadsFigmasOwnName() {
        let panel = Self.panel()
        panel.publishObservedDocumentURL(URL(string: Self.file)!)
        panel.publishObservedDocumentTitle(Self.fileTitle)
        #expect(panel.displayTitle == "Figma (cm-73 - figma native pane)")
    }

    // (c), (d) another file's address, then its own title: never the old file's name
    @Test func movedFileNeverReadsThePreviousFilesName() {
        let panel = Self.panel()
        panel.publishObservedDocumentURL(URL(string: Self.file)!)
        panel.publishObservedDocumentTitle(Self.fileTitle)
        panel.publishObservedDocumentURL(URL(string: "https://www.figma.com/design/OTHERKEY456/Other-file")!)
        #expect(panel.displayTitle == "Figma (Other file)", "the moved file read the previous file's name")
        panel.publishObservedDocumentTitle("Other file – Figma")
        #expect(panel.displayTitle == "Figma (Other file)")
    }

    // (e) a FigJam board
    @Test func figjamTitleNamesTheFile() {
        let panel = Self.panel()
        panel.publishObservedDocumentURL(URL(string: "https://www.figma.com/board/BOARDKEY789/Board-link")!)
        panel.publishObservedDocumentTitle("Retro board – FigJam")
        #expect(panel.displayTitle == "Figma (Retro board)")
    }

    // (f) an ordinary browser tab on a Figma file: the page's title, as today
    @Test func addressBarShowingKeepsPageTitle() {
        let editor = Self.panel(bar: true)
        editor.publishObservedDocumentURL(URL(string: Self.file)!)
        editor.publishObservedDocumentTitle(Self.fileTitle)
        #expect(editor.displayTitle == Self.fileTitle)
        let read = Self.panel(bar: true)
        read.publishObservedDocumentURL(Self.preview())
        read.publishObservedDocumentTitle("Figma")
        #expect(read.displayTitle == "Figma")
    }

    // (g) a failed load writes the address into the title: the name it had stays
    @Test func failedLoadKeepsTheNameItHad() {
        let panel = Self.panel()
        panel.publishObservedDocumentURL(URL(string: Self.file)!)
        panel.publishObservedDocumentTitle(Self.fileTitle)
        panel.publishObservedDocumentTitle(Self.file)
        #expect(panel.displayTitle == "Figma (cm-73 - figma native pane)", "a failed load's address became the name")
    }

    // (h) a fresh panel whose only title is its address: the link's name, never the address
    @Test func freshPanelWithOnlyAnAddressReadsLinkNameNotAddress() {
        let panel = Self.panel()
        panel.publishObservedDocumentURL(URL(string: Self.file)!)
        panel.publishObservedDocumentTitle(Self.file)
        #expect(panel.displayTitle == "Figma (cm 73 figma native pane)", "the address was shown as the name")
    }

    // MARK: step 2's own seams: the kept title, the holder, the Agent Pane

    // The switch writes the preview's `Figma` title: the kept Figma title must survive it.
    @Test func previewSwitchKeepsTheKeptFigmaTitle() {
        let panel = Self.panel()
        panel.publishObservedDocumentURL(URL(string: Self.file)!)
        panel.publishObservedDocumentTitle(Self.fileTitle)
        panel.publishObservedDocumentURL(Self.preview())
        panel.publishObservedDocumentTitle("Figma")
        #expect(panel.figmaPageTitle?.title == Self.fileTitle, "the preview's own title erased what Figma's editor named")
        #expect(panel.figmaPageTitle?.key == "MVdKSLWiPvKNyWab361uJ2")
        // The preview's header reads the link's name here (no workspace to hold Figma's), never the page title.
        #expect(panel.displayTitle == "Figma (cm 73 figma native pane)")
    }

    // The workspace's known name beats the link's in the preview, and only for its own file.
    @Test func knownNameIsReadOnlyForItsOwnFile() {
        let panel = Self.panel()
        panel.publishObservedDocumentURL(Self.preview())
        panel.publishObservedDocumentTitle("Figma")
        panel.figmaKnownFileName = (key: "MVdKSLWiPvKNyWab361uJ2", name: "cm-73 - figma native pane")
        #expect(panel.displayTitle == "Figma (cm-73 - figma native pane)")
        panel.figmaKnownFileName = (key: "SOMEOTHERKEY", name: "other")
        #expect(panel.displayTitle == "Figma (cm 73 figma native pane)", "a name for another file was read")
    }

    // The setting off reads `Figma`, on a live panel, in the preview and the editor.
    @Test func settingOffReadsFigmaOnALivePanel() {
        let app = FigmaTabTitleSetting.current
        defer { FigmaTabTitleSetting.current = app }
        FigmaTabTitleSetting.current = FigmaTabTitleSetting(showsFileName: false)
        let editor = Self.panel()
        editor.publishObservedDocumentURL(URL(string: Self.file)!)
        editor.publishObservedDocumentTitle(Self.fileTitle)
        #expect(editor.displayTitle == "Figma")
        let read = Self.panel()
        read.publishObservedDocumentURL(Self.preview())
        read.publishObservedDocumentTitle("Figma")
        #expect(read.displayTitle == "Figma")
        FigmaTabTitleSetting.current = FigmaTabTitleSetting(showsFileName: true)
        #expect(editor.displayTitle == "Figma (cm-73 - figma native pane)")
    }

    // cm-126: an Agent Pane's panel keeps the page's title, whatever Figma named the file.
    @Test func agentPanePanelKeepsThePageTitle() {
        let panel = Self.panel()
        panel.ownerTerminalSurfaceId = UUID()
        panel.ownedKind = .agentPane
        panel.publishObservedDocumentURL(URL(string: Self.file)!)
        panel.publishObservedDocumentTitle(Self.fileTitle)
        #expect(panel.displayTitle == Self.fileTitle)
    }

    // MARK: step 3, a workspace: the known name, the recorder, the refresh, the split

    static let fileKey = "MVdKSLWiPvKNyWab361uJ2"
    static let figmasName = "Figma (cm-73 - figma native pane)"
    static let linksName = "Figma (cm 73 figma native pane)"

    /// A delivery barrier on the exact queue the browser subscription uses, not a delay.
    private func drain() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func newFigmaTab(_ w: Workspace) throws -> BrowserPanel {
        let pane = try #require(w.bonsplitController.allPaneIds.first)
        return try #require(w.newFigmaSurface(inPane: pane))
    }

    private func tabTitle(_ w: Workspace, _ panel: BrowserPanel) -> String? {
        w.surfaceIdFromPanelId(panel.id).flatMap { w.bonsplitController.tab($0)?.title }
    }

    private func menuName(_ w: Workspace, key: String = Self.fileKey) -> String? {
        w.figmaFiles.entries.first { $0.key == key }?.name
    }

    /// What the tab does when the pane shows the preview: its address, then its page's own title.
    private func showPreview(_ panel: BrowserPanel, link: String = Self.file, node: String = "12-2") {
        panel.publishObservedDocumentURL(Self.preview(of: link, node: node))
        panel.publishObservedDocumentTitle("Figma")
    }

    /// What the tab does when the pane shows Figma's editor: its address, then Figma's title.
    private func showEditor(_ panel: BrowserPanel, link: String = Self.file, title: String = Self.fileTitle) {
        panel.publishObservedDocumentURL(URL(string: link)!)
        panel.publishObservedDocumentTitle(title)
    }

    /// Ten other files shown in the workspace: the cap of the menu's list, so the first file falls off.
    private func evictFromTheList(_ w: Workspace) {
        for i in 0..<10 {
            w.figmaFiles.show(URL(string: "https://www.figma.com/design/EVICT\(i)/Evict-\(i)")!)
        }
    }

    // 352: the header follows the menu, in every tab on the file
    @Test func bothPreviewsFollowTheEditorsName() async throws {
        let w = Workspace(); defer { w.teardownAllPanels() }
        let a = try newFigmaTab(w), b = try newFigmaTab(w)
        await drain()
        showPreview(a); showPreview(b)
        await drain()
        #expect(tabTitle(w, a) == Self.linksName)
        #expect(tabTitle(w, b) == Self.linksName)
        showEditor(a)
        await drain()
        #expect(tabTitle(w, a) == Self.figmasName)
        #expect(tabTitle(w, b) == Self.figmasName, "tab B kept the link's name after the editor named the file")
        #expect(w.panelTitles[b.id] == Self.figmasName, "panelTitles (every other reader) kept the link's name")
        #expect(menuName(w) == "cm-73 - figma native pane")
        // a goto to another node of the same file leaves both as they are
        showPreview(a, node: "34-5")
        await drain()
        #expect(tabTitle(w, a) == Self.figmasName, "the preview reads the menu's name after the switch")
        #expect(tabTitle(w, b) == Self.figmasName)
    }

    // 353 (a): a preview whose address moves to another file reads that file's name, never the old one's
    @Test func previewMovedToAnotherFileNeverReadsTheOldName() async throws {
        let w = Workspace(); defer { w.teardownAllPanels() }
        let a = try newFigmaTab(w), b = try newFigmaTab(w)
        await drain()
        showEditor(b)
        showPreview(a)
        await drain()
        #expect(tabTitle(w, a) == Self.figmasName)
        showPreview(a, link: "https://www.figma.com/design/OTHERKEY456/Other-file")
        await drain()
        #expect(tabTitle(w, a) == "Figma (Other file)", "the moved tab read the previous file's name")
    }

    // 353 (b): a link with no name part reads `Figma` in the header, `Untitled` in the menu
    @Test func noNamePartKeepsUntitledInTheMenu() async throws {
        let w = Workspace(); defer { w.teardownAllPanels() }
        let a = try newFigmaTab(w)
        await drain()
        showPreview(a, link: "https://www.figma.com/design/" + Self.fileKey)
        await drain()
        #expect(tabTitle(w, a) == "Figma")
        #expect(menuName(w) == "Untitled")
    }

    // 358: Rename Tab wins over the file's name, and clearing it gives the file's name back
    @Test func renamedTabKeepsHisNameAndClearingGivesTheFilesBack() async throws {
        let w = Workspace(); defer { w.teardownAllPanels() }
        let a = try newFigmaTab(w), b = try newFigmaTab(w)
        await drain()
        showPreview(a)
        await drain()
        #expect(w.setPanelCustomTitle(panelId: a.id, title: "design review"))
        showEditor(b)
        await drain()
        #expect(tabTitle(w, a) == "design review")
        showPreview(a, link: "https://www.figma.com/design/OTHERKEY456/Other-file")
        await drain()
        #expect(tabTitle(w, a) == "design review", "the file's name replaced his")
        showPreview(a)
        await drain()
        #expect(w.setPanelCustomTitle(panelId: a.id, title: nil))
        #expect(tabTitle(w, a) == Self.figmasName, "clearing his name did not give the file's name back")
    }

    // 364 (1): an editor tab keeps Figma's name after its file leaves the list
    @Test func editorKeepsFigmasNameAfterItsFileFallsOffTheList() async throws {
        let w = Workspace(); defer { w.teardownAllPanels() }
        let a = try newFigmaTab(w)
        await drain()
        showEditor(a)
        await drain()
        #expect(tabTitle(w, a) == Self.figmasName)
        evictFromTheList(w)
        #expect(menuName(w) == nil)
        a.isLoading = true; await drain()
        a.isLoading = false; await drain()
        #expect(tabTitle(w, a) == Self.figmasName)
    }

    // 364 (2): a preview opened after the eviction gets Figma's name from the editor tab, and so does the menu
    @Test func previewOpenedAfterEvictionReadsFigmasNameFromAnotherTab() async throws {
        let w = Workspace(); defer { w.teardownAllPanels() }
        let a = try newFigmaTab(w)
        await drain()
        showEditor(a)
        await drain()
        evictFromTheList(w)
        let b = try newFigmaTab(w)
        await drain()
        showPreview(b)
        await drain()
        #expect(tabTitle(w, b) == Self.figmasName, "B read the link's name")
        #expect(menuName(w) == "cm-73 - figma native pane", "the menu did not take Figma's name from A")
    }

    // 364 (3): the switch to the preview keeps Figma's name, in the header and the menu, and so does the way back
    @Test func switchToPreviewKeepsFigmasName() async throws {
        let w = Workspace(); defer { w.teardownAllPanels() }
        let a = try newFigmaTab(w)
        await drain()
        showEditor(a)
        await drain()
        evictFromTheList(w)
        showPreview(a)   // the address, then the title, with no drain between, as the switch writes them
        await drain()
        #expect(tabTitle(w, a) == Self.figmasName, "the switch to the preview read the link's name")
        #expect(menuName(w) == "cm-73 - figma native pane")
        showEditor(a)
        await drain()
        #expect(tabTitle(w, a) == Self.figmasName)
    }

    // 364 (4): a failed load, whose title is the address, leaves the header and the menu as they were
    @Test func failedLoadKeepsMenuRow() async throws {
        let w = Workspace(); defer { w.teardownAllPanels() }
        let a = try newFigmaTab(w)
        await drain()
        showEditor(a)
        await drain()
        a.publishObservedDocumentTitle(Self.file)
        await drain()
        #expect(tabTitle(w, a) == Self.figmasName)
        #expect(menuName(w) == "cm-73 - figma native pane", "a failed load renamed the menu row to the address")
    }

    // 364 (5): a tab made by a split reads the menu's name from its first moment, before any drain
    @Test func splitReadsMenuNameBeforeFirstTitle() async throws {
        let w = Workspace(); defer { w.teardownAllPanels() }
        let a = try newFigmaTab(w)
        await drain()
        showEditor(a)
        await drain()
        #expect(menuName(w) == "cm-73 - figma native pane")
        let terminal = try #require(w.panels.first { $0.value is TerminalPanel }?.key)
        let c = try #require(w.newBrowserSplit(
            from: terminal,
            orientation: .horizontal,
            url: Self.preview(),
            focus: false,
            allowsExternalBrowserFallback: false,
            chromeVisibility: BrowserChromeVisibility(omnibarVisible: false),
            transparentBackground: true
        ))
        // Read at once, before the subscription's first turn.
        #expect(w.panelTitles[c.id] == Self.figmasName, "panelTitles read the link's name")
        #expect(tabTitle(w, c) == Self.figmasName, "the tab read the link's name")
    }

    // A tab made in a pane (not by a split) reads the menu's name from its first moment too.
    @Test func tabMadeInAPaneReadsMenuNameBeforeFirstTitle() async throws {
        let w = Workspace(); defer { w.teardownAllPanels() }
        let a = try newFigmaTab(w)
        await drain()
        showEditor(a)
        await drain()
        let pane = try #require(w.bonsplitController.allPaneIds.first)
        let c = try #require(w.newBrowserSurface(
            inPane: pane,
            url: Self.preview(),
            focus: false,
            allowsExternalBrowserFallback: false,
            chromeVisibility: BrowserChromeVisibility(omnibarVisible: false),
            transparentBackground: true
        ))
        #expect(w.panelTitles[c.id] == Self.figmasName, "panelTitles read the link's name")
        #expect(tabTitle(w, c) == Self.figmasName, "the tab read the link's name")
    }

    // A file whose real name is "Untitled" (Figma's own title for a new file) still reads
    // `Figma (Untitled)` in every tab on it: the rule tests where the name came from, not its text.
    @Test func figmasUntitledNameStillReadsUntitled() async throws {
        let w = Workspace(); defer { w.teardownAllPanels() }
        let a = try newFigmaTab(w), b = try newFigmaTab(w)
        await drain()
        let link = "https://www.figma.com/design/" + Self.fileKey   // no name part
        showEditor(a, link: link, title: "Untitled – Figma")
        showPreview(b, link: link)
        await drain()
        #expect(tabTitle(w, a) == "Figma (Untitled)")
        #expect(tabTitle(w, b) == "Figma (Untitled)", "a name from Figma that reads Untitled was taken for the placeholder")
        #expect(menuName(w) == "Untitled")
    }

    // Row 17, through the real detach and attach a move between workspaces runs.
    private func move(_ panel: BrowserPanel, from source: Workspace, to destination: Workspace) throws {
        #expect(panel.figmaKnownFileName != nil, "the first workspace held no name for the file")
        let detached = try #require(source.detachSurface(panelId: panel.id))
        // Between the two workspaces the panel holds no name: the clear on leaving is observable here
        // (the second workspace's attach would set its own at once, hiding a missing clear after it).
        #expect(panel.figmaKnownFileName == nil, "the old workspace's name stayed on the detached panel")
        let pane = try #require(destination.bonsplitController.allPaneIds.first)
        #expect(destination.attachDetachedSurface(detached, inPane: pane, focus: false) != nil)
    }

    // A preview moved to another workspace reads that workspace's name for the file, not the old one's.
    @Test func movedPreviewTakesTheNewWorkspacesKnownName() async throws {
        let w1 = Workspace(), w2 = Workspace()
        defer { w1.teardownAllPanels(); w2.teardownAllPanels() }
        let a = try newFigmaTab(w1), b = try newFigmaTab(w1)
        await drain()
        showPreview(a); showEditor(b)
        await drain()
        #expect(tabTitle(w1, a) == Self.figmasName)
        try move(a, from: w1, to: w2)
        await drain()
        #expect(tabTitle(w2, a) == Self.linksName, "the preview kept the first workspace's name for the file")
        #expect(a.figmaKnownFileName?.name == "cm 73 figma native pane", "the second workspace's menu holds the link's name")
    }

    // An editor moved to a workspace that never knew the file names it in that workspace's menu, and
    // the preview there keeps that name.
    @Test func movedEditorHandsItsNameToTheNewMenu() async throws {
        let w1 = Workspace(), w2 = Workspace()
        defer { w1.teardownAllPanels(); w2.teardownAllPanels() }
        let a = try newFigmaTab(w1)
        await drain()
        showEditor(a)
        await drain()
        try move(a, from: w1, to: w2)
        await drain()
        #expect(tabTitle(w2, a) == Self.figmasName)
        #expect(menuName(w2) == "cm-73 - figma native pane", "the new workspace's menu did not take Figma's name")
        showPreview(a)
        await drain()
        #expect(tabTitle(w2, a) == Self.figmasName, "the switch to the preview there read the link's name")
    }

    // MARK: step 4, restore: a tab not shown yet is named in every reader

    /// A workspace restored from a saved session holding one Figma tab, left a placeholder (not shown).
    /// The saved record is built by hand: `editRecord` rewrites it to what an older build, or the page,
    /// would have saved, and `listEntries` is the saved menu list.
    private func restoredWorkspace(
        link: String = Self.file,
        preview: Bool = true,
        savedTitle: String = "Figma",
        listEntries: [SessionFigmaFileSnapshot] = [],
        customTitle: String? = nil,
        editRecord: (inout SessionBrowserPanelSnapshot) -> Void = { _ in }
    ) throws -> (workspace: Workspace, panelId: UUID) {
        let source = Workspace()
        defer { source.retireFromOwningTabManager() }
        let terminal = try #require(source.focusedPanelId)
        let address = preview ? Self.preview(of: link) : URL(string: link)!
        let made = try #require(source.newBrowserSplit(
            from: terminal,
            orientation: .horizontal,
            url: address,
            focus: false,
            allowsExternalBrowserFallback: false,
            chromeVisibility: BrowserChromeVisibility(omnibarVisible: false)
        ))
        var snapshot = source.sessionSnapshot(includeScrollback: false)
        for index in snapshot.panels.indices where snapshot.panels[index].id == made.id {
            snapshot.panels[index].title = savedTitle
            snapshot.panels[index].customTitle = customTitle
            if var browser = snapshot.panels[index].browser {
                editRecord(&browser)
                snapshot.panels[index].browser = browser
            }
        }
        snapshot.figmaFiles = listEntries
        let restored = Workspace()
        let remap = restored.restoreSessionSnapshot(snapshot, deferBrowserPanels: true)
        let panelId = try #require(remap[made.id])
        #expect(restored.panels[panelId] is DeferredBrowserPanel, "the restored tab was shown, so this test would prove nothing")
        return (restored, panelId)
    }

    // 356 (1a): a session from before `.43` (saved title `Figma`): the tab is named before it is shown,
    // in `panelTitle(panelId:)` (the socket's list reads it) and in the Bonsplit tab
    @Test func restoredFigmaTabIsNamedBeforeItIsShown() throws {
        let (w, id) = try restoredWorkspace()
        defer { w.teardownAllPanels() }
        let tab = try #require(w.surfaceIdFromPanelId(id).flatMap { w.bonsplitController.tab($0)?.title })
        #expect(w.panelTitle(panelId: id) == Self.linksName, "panelTitle kept the saved title")
        #expect(tab == Self.linksName, "the Bonsplit tab kept the saved title")
    }

    // the saved menu list is back by then, so the restored tab reads Figma's name from it
    @Test func restoredTabReadsTheSavedMenuName() throws {
        let entry = SessionFigmaFileSnapshot(link: Self.file, view: "editor", name: "cm-73 - figma native pane")
        let (w, id) = try restoredWorkspace(listEntries: [entry])
        defer { w.teardownAllPanels() }
        #expect(w.panelTitle(panelId: id) == Self.figmasName)
    }

    // the rule is `DeferredBrowserPanel.displayTitle`'s own answer, read directly
    @Test func restoredDeferredTabReadsTheRule() throws {
        let (w, id) = try restoredWorkspace()
        defer { w.teardownAllPanels() }
        let deferred = try #require(w.panels[id] as? DeferredBrowserPanel)
        #expect(deferred.displayTitle == Self.linksName)
    }

    // the design's cost, pinned: an editor tab whose file fell off the list reads its link's name until shown
    @Test func restoredEditorWhoseFileFellOffReadsLinkName() throws {
        let (w, id) = try restoredWorkspace(preview: false, savedTitle: Self.fileTitle)
        defer { w.teardownAllPanels() }
        #expect(w.panelTitle(panelId: id) == Self.linksName)
    }

    // the setting, off, before the tab is shown: `Figma`
    @Test func restoredTabReadsFigmaWhenTheSettingIsOff() throws {
        let app = FigmaTabTitleSetting.current
        defer { FigmaTabTitleSetting.current = app }
        FigmaTabTitleSetting.current = FigmaTabTitleSetting(showsFileName: false)
        let (w, id) = try restoredWorkspace(savedTitle: Self.figmasName)
        defer { w.teardownAllPanels() }
        #expect(w.panelTitle(panelId: id) == "Figma")
    }

    // Rename Tab's name wins in a restored tab too
    @Test func restoredRenamedTabKeepsHisName() throws {
        let (w, id) = try restoredWorkspace()
        defer { w.teardownAllPanels() }
        #expect(w.setPanelCustomTitle(panelId: id, title: "design review"))
        w.refreshFigmaTabTitles()
        #expect(w.panelTitle(panelId: id) == "design review")
        let tab = try #require(w.surfaceIdFromPanelId(id).flatMap { w.bonsplitController.tab($0)?.title })
        #expect(tab == "design review")
    }

    // 357 (3), the restore leg: an Agent Pane keeps "Agent Pane" and its page's title, in a live panel
    // and in a restored tab not shown yet. The restored one's record is built by hand, and its saved
    // title is the page's title, so the wrap shows.
    private func agentPaneRecord(_ browser: inout SessionBrowserPanelSnapshot) {
        browser.ownerTerminalSurfaceId = UUID()
        browser.ownedKind = BrowserOwnedKind.agentPane.rawValue
        browser.chromeVisibility = BrowserChromeVisibility(omnibarVisible: false)
    }

    @Test func restoredAgentPaneKeepsAgentPaneAndThePageTitle() throws {
        let (w, id) = try restoredWorkspace(preview: false, savedTitle: Self.fileTitle, editRecord: { agentPaneRecord(&$0) })
        defer { w.teardownAllPanels() }
        let deferred = try #require(w.panels[id] as? DeferredBrowserPanel)
        #expect(deferred.displayTitle == Self.fileTitle, "the rule named an Agent Pane")
        #expect(w.panelTitle(panelId: id) == "Agent Pane", "the restore refresh replaced the Agent Pane's caption")
        let tab = try #require(w.surfaceIdFromPanelId(id).flatMap { w.bonsplitController.tab($0)?.title })
        #expect(tab == "Agent Pane", "the Bonsplit tab lost the Agent Pane's caption")
    }

    @Test func liveAgentPaneKeepsAgentPaneThroughARefreshAndAListRename() async throws {
        let w = Workspace(); defer { w.teardownAllPanels() }
        let a = try newFigmaTab(w)
        await drain()
        a.ownerTerminalSurfaceId = UUID()
        a.ownedKind = .agentPane
        showEditor(a)
        await drain()
        w.refreshFigmaTabTitles()
        #expect(w.panelTitles[a.id] == "Agent Pane", "a re-title replaced the Agent Pane's caption")
        #expect(tabTitle(w, a) == "Agent Pane")
        #expect(a.displayTitle == Self.fileTitle)
        // another tab on the file renames it in the list: the refresh visits the Agent Pane too
        let b = try newFigmaTab(w)
        await drain()
        showEditor(b, title: "renamed – Figma")
        await drain()
        #expect(tabTitle(w, a) == "Agent Pane", "a list rename replaced the Agent Pane's caption")
    }

    // 357 (3), the list-rename leg for a restored Agent Pane: another tab on the file renames it in the
    // list, and the refresh visits the placeholder too, still wrapped.
    @Test func restoredAgentPaneKeepsAgentPaneThroughAListRename() async throws {
        let (w, id) = try restoredWorkspace(preview: false, savedTitle: Self.fileTitle, editRecord: { agentPaneRecord(&$0) })
        defer { w.teardownAllPanels() }
        let b = try newFigmaTab(w)
        await drain()
        showEditor(b, title: "renamed – Figma")
        await drain()
        #expect(w.figmaFiles.entries.first { $0.key == Self.fileKey }?.name == "renamed")
        #expect(w.panelTitle(panelId: id) == "Agent Pane", "a list rename replaced the restored Agent Pane's caption")
        let tab = try #require(w.surfaceIdFromPanelId(id).flatMap { w.bonsplitController.tab($0)?.title })
        #expect(tab == "Agent Pane")
    }

    // Pages that name no file keep the page's title, today's.
    @Test func recentsAndNewFileKeepThePageTitle() {
        let recents = Self.panel()
        recents.publishObservedDocumentURL(URL(string: "https://www.figma.com/files/recent")!)
        recents.publishObservedDocumentTitle("Recents – Figma")
        #expect(recents.displayTitle == "Recents – Figma")
        let new = Self.panel()
        new.publishObservedDocumentURL(URL(string: "https://www.figma.com/design/new?folder_id=1")!)
        new.publishObservedDocumentTitle("Figma")
        #expect(new.displayTitle == "Figma")
    }

    // MARK: step 5, setting end to end

    @Test func showFileNameInHeaderIsRegisteredInSupportedPaths() {
        #expect(CmuxSettingsFileStore.supportedSettingsJSONPaths.contains("figma.showFileNameInHeader"))
    }

    // 357 (3), the setting-flip legs: live and restored Agent Panes stay `Agent Pane` when the
    // setting flips off and back on.
    @Test func agentPanesKeepAgentPaneThroughSettingFlip() async throws {
        let (w, restoredId) = try restoredWorkspace(preview: false, savedTitle: Self.fileTitle, editRecord: { agentPaneRecord(&$0) })
        defer { w.teardownAllPanels() }
        let live = try newFigmaTab(w)
        await drain()
        live.ownerTerminalSurfaceId = UUID()
        live.ownedKind = .agentPane
        showEditor(live)
        await drain()

        let saved = FigmaTabTitleSetting.current
        defer { FigmaTabTitleSetting.current = saved }

        for shows in [false, true] {
            FigmaTabTitleSetting.current = FigmaTabTitleSetting(showsFileName: shows)
            w.refreshFigmaTabTitles()
            #expect(w.panelTitles[live.id] == "Agent Pane")
            #expect(tabTitle(w, live) == "Agent Pane")
            #expect(live.displayTitle == Self.fileTitle)
            #expect(w.panelTitle(panelId: restoredId) == "Agent Pane")
            let restoredTab = try #require(w.surfaceIdFromPanelId(restoredId).flatMap { w.bonsplitController.tab($0)?.title })
            #expect(restoredTab == "Agent Pane")
            let deferred = try #require(w.panels[restoredId] as? DeferredBrowserPanel)
            #expect(deferred.displayTitle == Self.fileTitle)
        }
    }

    private func makeScratchConfigFile() throws -> URL {
        let dir = URL(fileURLWithPath: "/Volumes/tom-ssd/tmp/cm-73.43/scratch-cfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cmux.json")
    }

    private func waitForCondition(timeout: Duration = .seconds(2), _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    @Test func holderFollowsTheFile() async throws {
        let file = try makeScratchConfigFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try Data("{}".utf8).write(to: file, options: .atomic)

        // Every wait here is bounded (`waitForCondition`, 2 s): a holder that ignores the file turns
        // this test red and ends the run; an unbounded wait on the change stream hung the test host.
        var changes = 0
        let holder = FigmaTabTitleSetting(
            store: JSONConfigStore(fileURL: file),
            onChange: { changes += 1 }
        )
        #expect(holder.showsFileName == true)

        try Data(#"{"figma":{"showFileNameInHeader":false}}"#.utf8).write(to: file, options: .atomic)
        let sawFalse = await waitForCondition { !holder.showsFileName }
        #expect(sawFalse, "holder did not turn false within 2 s")
        let sawChange = await waitForCondition { changes >= 1 }
        #expect(sawChange, "the holder's onChange did not run within 2 s")

        try Data(#"{"figma":{"showFileNameInHeader":true}}"#.utf8).write(to: file, options: .atomic)
        let sawTrue = await waitForCondition { holder.showsFileName }
        #expect(sawTrue, "holder did not turn true within 2 s")

        try Data(#"{"figma":{"defaultFolder":"https://www.figma.com/files/team/1/project/2"}}"#.utf8).write(to: file, options: .atomic)
        let defaultOnlyHolder = FigmaTabTitleSetting(store: JSONConfigStore(fileURL: file))
        #expect(defaultOnlyHolder.showsFileName == true)
    }

    // 357 (1): writing `figma.showFileNameInHeader` in a scratch cmux.json flips every tab in the
    // workspace (preview, editor, restored-not-made) to `Figma` and back within 2 s.
    @Test func settingFlipRetitlesEveryTab() async throws {
        let file = try makeScratchConfigFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try Data("{}".utf8).write(to: file, options: .atomic)

        let (w, restoredId) = try restoredWorkspace(
            link: "https://www.figma.com/design/abcRestored123/restored-file",
            preview: true,
            savedTitle: "Figma"
        )
        defer { w.teardownAllPanels() }

        let previewTab = try newFigmaTab(w)
        await drain()
        showPreview(previewTab)
        let editorTab = try newFigmaTab(w)
        await drain()
        showEditor(editorTab, link: "https://www.figma.com/design/xyzEditor456/editor-file", title: "Editor Own Name – Figma")
        await drain()

        let saved = FigmaTabTitleSetting.current
        defer { FigmaTabTitleSetting.current = saved }

        let holder = FigmaTabTitleSetting(
            store: JSONConfigStore(fileURL: file),
            onChange: { w.refreshFigmaTabTitles() }
        )
        FigmaTabTitleSetting.current = holder
        w.refreshFigmaTabTitles()

        #expect(tabTitle(w, previewTab) == "Figma (cm 73 figma native pane)")
        #expect(tabTitle(w, editorTab) == "Figma (Editor Own Name)")
        #expect(w.surfaceIdFromPanelId(restoredId).flatMap { w.bonsplitController.tab($0)?.title } == "Figma (restored file)")

        try Data(#"{"figma":{"showFileNameInHeader":false}}"#.utf8).write(to: file, options: .atomic)
        let allPlain = await waitForCondition {
            tabTitle(w, previewTab) == "Figma"
                && tabTitle(w, editorTab) == "Figma"
                && w.surfaceIdFromPanelId(restoredId).flatMap { w.bonsplitController.tab($0)?.title } == "Figma"
        }
        #expect(allPlain, "not all tabs flipped to Figma within 2 s")

        try Data(#"{"figma":{"showFileNameInHeader":true}}"#.utf8).write(to: file, options: .atomic)
        let allNamed = await waitForCondition {
            tabTitle(w, previewTab) == "Figma (cm 73 figma native pane)"
                && tabTitle(w, editorTab) == "Figma (Editor Own Name)"
                && w.surfaceIdFromPanelId(restoredId).flatMap { w.bonsplitController.tab($0)?.title } == "Figma (restored file)"
        }
        #expect(allNamed, "not all tabs returned to their file names within 2 s")

        try Data(#"{"figma":{"defaultFolder":"https://www.figma.com/files/team/1/project/2"}}"#.utf8).write(to: file, options: .atomic)
        let defaultOnly = FigmaTabTitleSetting(store: JSONConfigStore(fileURL: file), onChange: { w.refreshFigmaTabTitles() })
        FigmaTabTitleSetting.current = defaultOnly
        w.refreshFigmaTabTitles()
        #expect(tabTitle(w, previewTab) == "Figma (cm 73 figma native pane)")
        #expect(tabTitle(w, editorTab) == "Figma (Editor Own Name)")
    }

    @Test func settingRouteReachesEveryWorkspaceInEveryWindow() async throws {
        let previousApp = AppDelegate.shared
        let app = AppDelegate()
        AppDelegate.shared = previousApp  // AppDelegate.init assigns shared; this test calls `app` directly
        let firstManager = TabManager()
        let secondManager = TabManager()
        let firstWindowId = app.registerMainWindowContextForTesting(tabManager: firstManager)
        let secondWindowId = app.registerMainWindowContextForTesting(tabManager: secondManager)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: firstWindowId)
            app.unregisterMainWindowContextForTesting(windowId: secondWindowId)
        }

        let w1 = try #require(firstManager.selectedWorkspace)
        let w2 = try #require(secondManager.selectedWorkspace)
        let t1 = try newFigmaTab(w1)
        let t2 = try newFigmaTab(w2)
        await drain()
        showPreview(t1)
        showPreview(t2)
        await drain()

        let saved = FigmaTabTitleSetting.current
        defer { FigmaTabTitleSetting.current = saved }

        #expect(tabTitle(w1, t1) == "Figma (cm 73 figma native pane)")
        #expect(tabTitle(w2, t2) == "Figma (cm 73 figma native pane)")

        FigmaTabTitleSetting.current = FigmaTabTitleSetting(showsFileName: false)
        app.refreshFigmaTabTitles()
        #expect(tabTitle(w1, t1) == "Figma")
        #expect(tabTitle(w2, t2) == "Figma")

        FigmaTabTitleSetting.current = FigmaTabTitleSetting(showsFileName: true)
        app.refreshFigmaTabTitles()
        #expect(tabTitle(w1, t1) == "Figma (cm 73 figma native pane)")
        #expect(tabTitle(w2, t2) == "Figma (cm 73 figma native pane)")
    }

    /// What `cmux tree` reads is a published copy, refreshed only on its own events; a title change
    /// alone is not one. A flip of the setting while a terminal holds the focus changes no workspace
    /// title, so the route itself must ask for the copy to be published again (Scenario 363's finding,
    /// 2026-11-17: `tree` read `Figma` after the names came back).
    @Test func settingRoutePublishesWhatTreeReads() async throws {
        let previousApp = AppDelegate.shared
        let app = AppDelegate()
        AppDelegate.shared = previousApp  // AppDelegate.init assigns shared; this test calls `app` directly
        let manager = TabManager()
        let windowId = app.registerMainWindowContextForTesting(tabManager: manager)
        defer { app.unregisterMainWindowContextForTesting(windowId: windowId) }
        let w = try #require(manager.selectedWorkspace)
        let tab = try newFigmaTab(w)
        await drain()
        showPreview(tab)
        await drain()
        // A terminal holds the focus, as in Tom's run: the workspace title can't follow the Figma tab,
        // so no workspace-title event refreshes the copy for the route.
        let terminalId = try #require(w.panels.first { $0.value is TerminalPanel }?.key)
        w.focusPanel(terminalId)
        await drain()
        try #require(w.focusedPanelId == terminalId)

        let saved = FigmaTabTitleSetting.current
        defer { FigmaTabTitleSetting.current = saved }

        // Let every refresh the setup asked for land, then hold still, so only the route can move it.
        let controller = TerminalController.shared
        let store = controller.socketReadSnapshotStore
        #expect(await waitForCondition { controller.socketReadSnapshotRefreshTask == nil })
        var generation = store.read().generation
        var quiet = 0
        let settleBy = ContinuousClock.now + .seconds(3)
        while quiet < 5, ContinuousClock.now < settleBy {
            try? await Task.sleep(for: .milliseconds(40))
            let now = store.read().generation
            if now == generation { quiet += 1 } else { generation = now; quiet = 0 }
        }
        try #require(quiet >= 5, "the copy never held still for 200 ms, so a change can't be pinned on the route")

        for shows in [false, true] {
            let before = store.read().generation
            FigmaTabTitleSetting.current = FigmaTabTitleSetting(showsFileName: shows)
            app.refreshFigmaTabTitles()
            #expect(await waitForCondition { store.read().generation != before }, "showsFileName: \(shows)")
        }
    }
    // MARK: step 6, the Dock and every reader

    private func makeDock() throws -> (dock: DockSplitStore, pane: PaneID) {
        let dock = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil },
            browserAvailabilityProvider: { true }
        )
        dock.hasLoadedConfiguration = true
        let pane = try #require(dock.bonsplitController.allPaneIds.first)
        return (dock, pane)
    }

    /// `persistent` gives the tab the profile's own store: a tab on a non-persistent store is left out
    /// of a session snapshot (`BrowserPanel.shouldPersistSessionSnapshot`), so a test that saves the
    /// Dock needs one.
    private func newDockFigma(_ dock: DockSplitStore, _ pane: PaneID, persistent: Bool = false) throws -> BrowserPanel {
        let id = try #require(dock.newSurface(
            kind: .browser,
            inPane: pane,
            focus: false,
            chromeVisibility: .hidden,
            websiteDataStore: persistent ? nil : .nonPersistent()
        ))
        return try #require(dock.browserPanel(for: id))
    }

    private func dockTabTitle(_ dock: DockSplitStore, _ panelId: UUID) -> String? {
        dock.surfaceId(forPanelId: panelId).flatMap { dock.bonsplitController.tab($0)?.title }
    }

    /// A Dock saved with one Figma tab whose saved title is `Figma` (a session from before `.43`),
    /// restored into a fresh Dock with its browser tab deferred.
    private func restoredDock(
        preview: Bool = true,
        agentPane: Bool = false
    ) throws -> (dock: DockSplitStore, panelId: UUID) {
        let (source, sourcePane) = try makeDock()
        defer { source.closeAllPanels() }
        let panel = try newDockFigma(source, sourcePane, persistent: true)
        if agentPane {
            panel.ownerTerminalSurfaceId = UUID()
            panel.ownedKind = .agentPane
        }
        if preview { showPreview(panel) } else { showEditor(panel) }
        var snapshot = source.sessionSnapshot(includeScrollback: false)
        for index in snapshot.panels.indices where snapshot.panels[index].id == panel.id {
            snapshot.panels[index].title = preview ? "Figma" : Self.fileTitle
        }
        let (restored, _) = try makeDock()
        let remap = restored.restoreSessionSnapshot(snapshot, deferBrowserPanels: true)
        let panelId = try #require(remap[panel.id])
        #expect(restored.panels[panelId] is DeferredBrowserPanel, "the restored Dock tab was shown, so this test would prove nothing")
        return (restored, panelId)
    }

    // 359, the Dock leg: an editor in the Dock reads Figma's name from its page, a preview its link's
    // name (the Dock holds no file list); switched to the preview it reads the link's name, back in the
    // editor Figma's again
    @Test func dockEditorReadsFigmasNamePreviewReadsLink() async throws {
        let (dock, pane) = try makeDock()
        defer { dock.closeAllPanels() }
        let editor = try newDockFigma(dock, pane)
        let preview = try newDockFigma(dock, pane)
        showEditor(editor)
        showPreview(preview)
        await drain()
        #expect(dockTabTitle(dock, editor.id) == Self.figmasName)
        #expect(dockTabTitle(dock, preview.id) == Self.linksName)
        showPreview(editor)
        await drain()
        #expect(dockTabTitle(dock, editor.id) == Self.linksName, "the Dock exception: a switched editor reads the link's name there")
        showEditor(editor)
        await drain()
        #expect(dockTabTitle(dock, editor.id) == Self.figmasName)
    }

    // 357 (2), the Dock leg: the setting's flip re-titles a live editor and a live preview in the Dock
    @Test func dockTabsFollowTheSettingFlip() async throws {
        let (dock, pane) = try makeDock()
        defer { dock.closeAllPanels() }
        let editor = try newDockFigma(dock, pane)
        let preview = try newDockFigma(dock, pane)
        showEditor(editor)
        showPreview(preview)
        await drain()

        let saved = FigmaTabTitleSetting.current
        defer { FigmaTabTitleSetting.current = saved }
        FigmaTabTitleSetting.current = FigmaTabTitleSetting(showsFileName: false)
        dock.refreshFigmaTabTitles()
        #expect(dockTabTitle(dock, editor.id) == "Figma")
        #expect(dockTabTitle(dock, preview.id) == "Figma")
        FigmaTabTitleSetting.current = FigmaTabTitleSetting(showsFileName: true)
        dock.refreshFigmaTabTitles()
        #expect(dockTabTitle(dock, editor.id) == Self.figmasName)
        #expect(dockTabTitle(dock, preview.id) == Self.linksName)
    }

    // Tom's kept exception: the Dock has no Agent Pane rule, so an Agent Pane there reads its page's
    // title, never `Agent Pane`, through a flip and back
    @Test func dockAgentPaneReadsPageTitleUnwrapped() async throws {
        let (dock, pane) = try makeDock()
        defer { dock.closeAllPanels() }
        let agentPane = try newDockFigma(dock, pane)
        agentPane.ownerTerminalSurfaceId = UUID()
        agentPane.ownedKind = .agentPane
        showEditor(agentPane)
        await drain()
        #expect(dockTabTitle(dock, agentPane.id) == Self.fileTitle)

        let saved = FigmaTabTitleSetting.current
        defer { FigmaTabTitleSetting.current = saved }
        for shows in [false, true] {
            FigmaTabTitleSetting.current = FigmaTabTitleSetting(showsFileName: shows)
            dock.refreshFigmaTabTitles()
            #expect(dockTabTitle(dock, agentPane.id) == Self.fileTitle, "the Dock wrapped an Agent Pane (setting \(shows))")
        }

        // The refresh writes only when a tab's title differs from the panel's (the guard), so the
        // loop above never reaches the writer: an Agent Pane there already reads its page title. A
        // tab that arrives from a workspace carries `Agent Pane`: the Dock's writer replaces it with
        // the page title, unwrapped. This is the leg a wrapping writer fails.
        let tabId = try #require(dock.surfaceId(forPanelId: agentPane.id))
        dock.bonsplitController.updateTab(tabId, title: "Agent Pane")
        dock.refreshFigmaTabTitles()
        #expect(dockTabTitle(dock, agentPane.id) == Self.fileTitle, "the Dock's writer wrapped the Agent Pane's title")
    }

    // a Dock tab with a Rename Tab name keeps it through a flip
    @Test func dockRenamedTabKeepsItsNameThroughAFlip() async throws {
        let (dock, pane) = try makeDock()
        defer { dock.closeAllPanels() }
        let editor = try newDockFigma(dock, pane)
        showEditor(editor)
        await drain()
        let tabId = try #require(dock.surfaceId(forPanelId: editor.id))
        dock.bonsplitController.updateTab(tabId, title: "design review", hasCustomTitle: true)

        let saved = FigmaTabTitleSetting.current
        defer { FigmaTabTitleSetting.current = saved }
        FigmaTabTitleSetting.current = FigmaTabTitleSetting(showsFileName: false)
        dock.refreshFigmaTabTitles()
        #expect(dockTabTitle(dock, editor.id) == "design review")
        FigmaTabTitleSetting.current = FigmaTabTitleSetting(showsFileName: true)
        dock.refreshFigmaTabTitles()
        #expect(dockTabTitle(dock, editor.id) == "design review")
    }

    // a Dock session from before `.43` (saved title `Figma`): the restored, not-shown tab is named by
    // the rule when the restore ends, and follows a flip while still not shown
    @Test func restoredDockTabIsNamedAndFollowsTheFlip() throws {
        let (dock, id) = try restoredDock()
        defer { dock.closeAllPanels() }
        #expect(dockTabTitle(dock, id) == Self.linksName, "the restored Dock tab kept its saved title")

        let saved = FigmaTabTitleSetting.current
        defer { FigmaTabTitleSetting.current = saved }
        FigmaTabTitleSetting.current = FigmaTabTitleSetting(showsFileName: false)
        dock.refreshFigmaTabTitles()
        #expect(dockTabTitle(dock, id) == "Figma", "the Dock's refresh skipped the restored, not-shown tab")
        #expect(dock.panels[id] is DeferredBrowserPanel)
        FigmaTabTitleSetting.current = FigmaTabTitleSetting(showsFileName: true)
        dock.refreshFigmaTabTitles()
        #expect(dockTabTitle(dock, id) == Self.linksName)
    }

    @Test func restoredDockAgentPaneReadsItsSavedPageTitleUnwrapped() throws {
        let (dock, id) = try restoredDock(preview: false, agentPane: true)
        defer { dock.closeAllPanels() }
        #expect(dockTabTitle(dock, id) == Self.fileTitle)
        let saved = FigmaTabTitleSetting.current
        defer { FigmaTabTitleSetting.current = saved }
        FigmaTabTitleSetting.current = FigmaTabTitleSetting(showsFileName: false)
        dock.refreshFigmaTabTitles()
        #expect(dockTabTitle(dock, id) == Self.fileTitle)
    }

    // the route reaches the Dock in a window and the workspace's own Dock, not only the workspaces
    @Test func settingRouteReachesTheDockInTheWindowAndTheWorkspace() async throws {
        let previousApp = AppDelegate.shared
        let app = AppDelegate()
        AppDelegate.shared = previousApp  // AppDelegate.init assigns shared; this test calls `app` directly
        let manager = TabManager()
        let windowId = app.registerMainWindowContextForTesting(tabManager: manager)
        defer { app.unregisterMainWindowContextForTesting(windowId: windowId) }
        let workspace = try #require(manager.selectedWorkspace)
        let workspaceDock = try #require(workspace.dockSplit)
        workspaceDock.hasLoadedConfiguration = true
        let windowDock = manager.makeWindowDockStore(windowId: windowId)
        windowDock.hasLoadedConfiguration = true
        defer { workspaceDock.closeAllPanels(); windowDock.closeAllPanels() }
        let inWorkspaceDock = try newDockFigma(workspaceDock, try #require(workspaceDock.bonsplitController.allPaneIds.first))
        let inWindowDock = try newDockFigma(windowDock, try #require(windowDock.bonsplitController.allPaneIds.first))
        showEditor(inWorkspaceDock)
        showEditor(inWindowDock)
        await drain()
        #expect(dockTabTitle(workspaceDock, inWorkspaceDock.id) == Self.figmasName)
        #expect(dockTabTitle(windowDock, inWindowDock.id) == Self.figmasName)

        let saved = FigmaTabTitleSetting.current
        defer { FigmaTabTitleSetting.current = saved }
        FigmaTabTitleSetting.current = FigmaTabTitleSetting(showsFileName: false)
        app.refreshFigmaTabTitles()
        #expect(dockTabTitle(workspaceDock, inWorkspaceDock.id) == "Figma", "the route skipped the workspace's Dock")
        #expect(dockTabTitle(windowDock, inWindowDock.id) == "Figma", "the route skipped the window's Dock")
        FigmaTabTitleSetting.current = FigmaTabTitleSetting(showsFileName: true)
        app.refreshFigmaTabTitles()
        #expect(dockTabTitle(workspaceDock, inWorkspaceDock.id) == Self.figmasName)
        #expect(dockTabTitle(windowDock, inWindowDock.id) == Self.figmasName)
    }

    // 359: every reader of a workspace's Figma tab reads the same name. Each reader is read at the
    // expression it uses; the ones that open a dialog or a view are read at their source.
    @Test func everyWorkspaceReaderReadsTheFilesName() async throws {
        let previousApp = AppDelegate.shared
        let app = AppDelegate()
        AppDelegate.shared = previousApp  // AppDelegate.init assigns shared; this test calls `app` directly
        let manager = TabManager()
        let windowId = app.registerMainWindowContextForTesting(tabManager: manager)
        defer { app.unregisterMainWindowContextForTesting(windowId: windowId) }
        let w = try #require(manager.selectedWorkspace)
        let preview = try newFigmaTab(w)
        let editor = try newFigmaTab(w)
        await drain()
        showEditor(editor)
        await drain()
        showPreview(preview)
        await drain()

        // socket surface lists (`list-panels`: `panelTitle(panelId:) ?? displayTitle`) and the command
        // palette's panel name (`panelDisplayName`: `workspace.panelTitle(panelId:)`)
        #expect(w.panelTitle(panelId: preview.id) == Self.figmasName)
        #expect(w.panelTitle(panelId: editor.id) == Self.figmasName)
        // Rename Tab's field (`panelCustomTitles ?? panelTitles ?? displayTitle`) and the close-tab
        // dialog (`panelCustomTitles`, then `panelTitles`)
        #expect(w.panelCustomTitles[preview.id] == nil)
        #expect(w.panelTitles[preview.id] == Self.figmasName)
        #expect(w.panelTitles[editor.id] == Self.figmasName)
        // Global Search's document title (`panel.displayTitle`, `AppDelegate+GlobalSearch.swift`)
        let contexts = app.globalSearchPanelContexts()
        #expect(contexts.first { $0.panelID == preview.id }?.panelTitle == Self.figmasName)
        #expect(contexts.first { $0.panelID == editor.id }?.panelTitle == Self.figmasName)
        // the tab itself
        #expect(tabTitle(w, preview) == Self.figmasName)
    }
    // MARK: fix round (cold review): rename cleared on a restored tab; a deferred tab moved

    // A saved session whose Figma tab was renamed `design review`, restored not shown: the rename shows;
    // clearing it before the tab is shown gives the file's name back, not the saved name.
    @Test func clearedRenameOnARestoredTabGivesTheFilesNameBack() throws {
        let (w, id) = try restoredWorkspace(customTitle: "design review")
        defer { w.teardownAllPanels() }
        #expect(w.panelTitle(panelId: id) == "design review", "the saved rename did not show")
        #expect(w.setPanelCustomTitle(panelId: id, title: nil))
        #expect(w.panelTitle(panelId: id) == Self.linksName, "the cleared rename stuck on the restored tab")
        let tab = try #require(w.surfaceIdFromPanelId(id).flatMap { w.bonsplitController.tab($0)?.title })
        #expect(tab == Self.linksName, "the Bonsplit tab kept the cleared rename")
    }

    // A restored tab, not shown, that held Figma's name in its workspace, moved to a workspace whose menu
    // never knew the file: it reads that workspace's name, not the one it left with.
    @Test func movedDeferredTabTakesTheNewWorkspacesName() throws {
        let entry = SessionFigmaFileSnapshot(link: Self.file, view: "editor", name: "cm-73 - figma native pane")
        let (w1, id) = try restoredWorkspace(listEntries: [entry])
        let w2 = Workspace()
        defer { w1.teardownAllPanels(); w2.teardownAllPanels() }
        #expect(w1.panelTitle(panelId: id) == Self.figmasName)
        let detached = try #require(w1.detachSurface(panelId: id))
        let pane = try #require(w2.bonsplitController.allPaneIds.first)
        #expect(w2.attachDetachedSurface(detached, inPane: pane, focus: false) != nil)
        #expect(w2.panels[id] is DeferredBrowserPanel)
        #expect(w2.panelTitle(panelId: id) == Self.linksName, "panelTitle kept the first workspace's name")
        let tab = try #require(w2.surfaceIdFromPanelId(id).flatMap { w2.bonsplitController.tab($0)?.title })
        #expect(tab == Self.linksName, "the Bonsplit tab kept the first workspace's name")
    }

    // The same into a Dock, which holds no file list: the link's name.
    @Test func movedDeferredTabInTheDockReadsTheLinksName() throws {
        let entry = SessionFigmaFileSnapshot(link: Self.file, view: "editor", name: "cm-73 - figma native pane")
        let (w1, id) = try restoredWorkspace(listEntries: [entry])
        let (dock, dockPane) = try makeDock()
        defer { w1.teardownAllPanels(); dock.closeAllPanels() }
        #expect(w1.panelTitle(panelId: id) == Self.figmasName)
        let detached = try #require(w1.detachSurface(panelId: id))
        #expect(dock.attachDetachedSurface(detached, inPane: dockPane, focus: false) != nil)
        #expect(dock.panels[id] is DeferredBrowserPanel)
        #expect(dockTabTitle(dock, id) == Self.linksName, "the Dock tab kept the workspace's name")
    }
    // The same, split into a new Dock pane (the other Dock attach).
    @Test func movedDeferredTabSplitIntoTheDockReadsTheLinksName() throws {
        let entry = SessionFigmaFileSnapshot(link: Self.file, view: "editor", name: "cm-73 - figma native pane")
        let (w1, id) = try restoredWorkspace(listEntries: [entry])
        let (dock, dockPane) = try makeDock()
        defer { w1.teardownAllPanels(); dock.closeAllPanels() }
        #expect(w1.panelTitle(panelId: id) == Self.figmasName)
        let detached = try #require(w1.detachSurface(panelId: id))
        #expect(dock.attachDetachedSurface(detached, bySplitting: dockPane, orientation: .horizontal, insertFirst: false, focus: false) != nil)
        #expect(dock.panels[id] is DeferredBrowserPanel)
        #expect(dockTabTitle(dock, id) == Self.linksName, "the split Dock tab kept the workspace's name")
    }

    // The production wiring: the holder the app builds (`makeAppSetting`), over a scratch `cmux.json`,
    // with its own re-title closure (`AppDelegate.shared?.refreshFigmaTabTitles()`): one write flips a
    // Figma tab in each of two windows. Under the test host the app's holder has no store, so this builds
    // it the way the app does, with no test-host variable.
    @Test func appHolderOverTheFileRetitlesEveryWindow() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let file = try makeScratchConfigFile()
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            try Data("{}".utf8).write(to: file, options: .atomic)

            let previousApp = AppDelegate.shared
            let app = AppDelegate()
            defer { AppDelegate.shared = previousApp }   // `app` is the app's `shared` for this test only
            let firstManager = TabManager()
            let secondManager = TabManager()
            let firstWindowId = app.registerMainWindowContextForTesting(tabManager: firstManager)
            let secondWindowId = app.registerMainWindowContextForTesting(tabManager: secondManager)
            defer {
                app.unregisterMainWindowContextForTesting(windowId: firstWindowId)
                app.unregisterMainWindowContextForTesting(windowId: secondWindowId)
            }
            let w1 = try #require(firstManager.selectedWorkspace)
            let w2 = try #require(secondManager.selectedWorkspace)
            let t1 = try newFigmaTab(w1)
            let t2 = try newFigmaTab(w2)
            await drain()
            showPreview(t1)
            showPreview(t2)
            await drain()

            let saved = FigmaTabTitleSetting.current
            defer { FigmaTabTitleSetting.current = saved }
            FigmaTabTitleSetting.current = FigmaTabTitleSetting.makeAppSetting(environment: [:], configFile: file)
            #expect(AppDelegate.shared === app)
            #expect(tabTitle(w1, t1) == Self.linksName)
            #expect(tabTitle(w2, t2) == Self.linksName)

            try Data(#"{"figma":{"showFileNameInHeader":false}}"#.utf8).write(to: file, options: .atomic)
            let bothPlain = await waitForCondition { tabTitle(w1, t1) == "Figma" && tabTitle(w2, t2) == "Figma" }
            #expect(bothPlain, "the app's holder did not re-title both windows within 2 s: \(tabTitle(w1, t1) ?? "nil"), \(tabTitle(w2, t2) ?? "nil")")

            try Data(#"{"figma":{"showFileNameInHeader":true}}"#.utf8).write(to: file, options: .atomic)
            let bothNamed = await waitForCondition { tabTitle(w1, t1) == Self.linksName && tabTitle(w2, t2) == Self.linksName }
            #expect(bothNamed, "the names did not come back in both windows within 2 s")
        }
    }
}
