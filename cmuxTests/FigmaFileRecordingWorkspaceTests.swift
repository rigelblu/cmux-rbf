import AppKit
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor @Suite(.serialized) struct FigmaFileRecordingWorkspaceTests {
    private func url(_ path: String) -> URL { URL(string: "https://www.figma.com/" + path)! }
    @Test func recordsAllKindsAndOnlyFigmaTabs() {
        let w = Workspace(); defer { w.teardownAllPanels() }
        let p = UUID()
        w.recordFigmaFile(panelID: p, address: url("design/A/First"), title: "", showsAddressBar: false)
        w.recordFigmaFile(panelID: p, address: url("board/B/Second"), title: "", showsAddressBar: false)
        w.recordFigmaFile(panelID: p, address: url("slides/C/Third"), title: "", showsAddressBar: false)
        w.recordFigmaFile(panelID: UUID(), address: url("design/D/Ordinary"), title: "", showsAddressBar: true)
        for kind in ["design", "board", "slides"] {
            w.recordFigmaFile(panelID: p, address: url("\(kind)/new?folder_id=1"), title: "", showsAddressBar: false)
        }
        w.recordFigmaFile(panelID: p, address: url("files/recent"), title: "", showsAddressBar: false)
        #expect(w.figmaFiles.entries.map(\.key) == ["C", "B", "A"])
    }
    @Test func staleTitleAndLateRenameAndSelectionDoNotReorder() throws {
        let w = Workspace(); defer { w.teardownAllPanels() }
        let p = UUID(), q = UUID()
        w.recordFigmaFile(panelID: p, address: url("design/A/First"), title: "Previous – Figma", showsAddressBar: false)
        #expect(w.figmaFiles.entries.first?.name == "First")
        w.recordFigmaFile(panelID: p, address: url("design/A/First"), title: "Real A – Figma", showsAddressBar: false)
        w.recordFigmaFile(panelID: p, address: url("design/B/Second"), title: "Real A – Figma", showsAddressBar: false)
        #expect(w.figmaFiles.entries.first?.name == "Second")
        w.recordFigmaFile(panelID: q, address: url("board/C/Third"), title: "", showsAddressBar: false)
        w.recordFigmaFile(panelID: p, address: url("design/B/Second"), title: "Real B – Figma", showsAddressBar: false)
        #expect(w.figmaFiles.entries.map(\.key) == ["C", "B", "A"])
        let named = try #require(w.figmaFiles.entries.first { $0.key == "B" })
        #expect(named.name == "Real B")
        // Selection/loading/favicon/mute emissions carry the same address and title.
        w.recordFigmaFile(panelID: p, address: url("design/B/Second"), title: "Real B – Figma", showsAddressBar: false)
        #expect(w.figmaFiles.entries.map(\.key) == ["C", "B", "A"])
    }
    @Test func restoresOnlyBaselineThenRecordsChangedView() throws {
        let w = Workspace(); defer { w.teardownAllPanels() }
        let p = UUID()
        w.figmaFiles.show(url("design/A/First"))
        w.figmaFiles.show(url("board/B/Second"))
        let saved = w.figmaFiles.entries
        w.beginFigmaFileRestore(panelID: p, address: url("design/A/First"))
        w.recordFigmaFile(panelID: p, address: nil, title: "", showsAddressBar: false)
        w.recordFigmaFile(panelID: p, address: url("design/A/First"), title: "Figma", showsAddressBar: false)
        #expect(w.figmaFiles.entries == saved)
        w.recordFigmaFile(panelID: p, address: url("design/A/First?node-id=2-3"), title: "Figma", showsAddressBar: false)
        #expect(w.figmaFiles.entries == saved)
        let read = try FigmaPaneURL.destination(for: url("design/A/First?node-id=2-3")).url
        w.recordFigmaFile(panelID: p, address: read, title: "Figma", showsAddressBar: false)
        #expect(w.figmaFiles.entries.map(\.key) == ["A", "B"])
        #expect(w.figmaFiles.entries.first?.view == .read)
    }
    // cmux-rbf #cm-73.16: R1, a non-file restore must not consume the first real showing.
    @Test(arguments: ["files/recent", "login", "design/new"])
    func restoredNonFileThenFirstFileIsRecorded(path: String) {
        let w = Workspace(); defer { w.teardownAllPanels() }
        let p = UUID()
        w.beginFigmaFileRestore(panelID: p, address: url(path))
        w.recordFigmaFile(panelID: p, address: url(path), title: "Figma", showsAddressBar: false)
        w.recordFigmaFile(panelID: p, address: url("design/A/First"), title: "Figma", showsAddressBar: false)
        #expect(w.figmaFiles.entries.map(\.key) == ["A"])
    }

    // cmux-rbf #cm-73.16: M6, non-file pages do not erase the tab's last recorded file.
    @Test func returningFromRecentsDoesNotCountAsAnotherShowing() {
        let w = Workspace(); defer { w.teardownAllPanels() }
        let p = UUID()
        w.recordFigmaFile(panelID: p, address: url("design/A/First"), title: "Figma", showsAddressBar: false)
        w.recordFigmaFile(panelID: UUID(), address: url("design/B/Second"), title: "Figma", showsAddressBar: false)
        w.recordFigmaFile(panelID: p, address: url("files/recent"), title: "Recent files", showsAddressBar: false)
        w.recordFigmaFile(panelID: p, address: url("design/A/First"), title: "Recent files", showsAddressBar: false)
        #expect(w.figmaFiles.entries.map(\.key) == ["B", "A"])
        #expect(w.figmaFiles.entries.last?.name == "First")
    }

}
