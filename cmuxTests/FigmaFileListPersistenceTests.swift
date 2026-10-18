import AppKit
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor @Suite(.serialized) struct FigmaFileListPersistenceTests {
    private func snapshot() -> SessionWorkspaceSnapshot {
        SessionWorkspaceSnapshot(processTitle: "Terminal", isPinned: false, currentDirectory: "/tmp", layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)), panels: [], statusEntries: [], logEntries: [])
    }
    @Test func capturesAndRestoresLinkViewNameOrder() throws {
        let w = Workspace(), restored = Workspace()
        defer { w.teardownAllPanels(); restored.teardownAllPanels() }
        w.figmaFiles.show(URL(string: "https://www.figma.com/design/A/First?node-id=0-1&t=token&mode=dev&foo=bar")!, title: "First – Figma")
        let read = try FigmaPaneURL.destination(for: URL(string: "https://www.figma.com/board/B/Board?node-id=2-3&t=secret")!).url
        w.figmaFiles.show(read, title: "Figma")
        w.figmaFiles.show(URL(string: "https://www.figma.com/slides/C/Deck?t=token")!, title: "Deck – Figma Slides")
        let captured = w.sessionSnapshot(includeScrollback: false)
        let data = try JSONEncoder().encode(captured)
        let decoded = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: data)
        #expect(decoded.figmaFiles?.count == 3)
        #expect(decoded.figmaFiles?.map(\.view) == ["editor", "read", "editor"])
        #expect(decoded.figmaFiles?.map(\.name) == ["Deck", "Board", "First"])
        #expect(decoded.figmaFiles?.last?.link == "https://www.figma.com/design/A/First?node-id=0-1&mode=dev&foo=bar")
        #expect(decoded.figmaFiles?[1].link == "https://www.figma.com/board/B/Board?node-id=2-3")
        restored.restoreSessionSnapshot(decoded)
        #expect(restored.figmaFiles.entries.map(\.link) == w.figmaFiles.entries.map(\.link))
        #expect(restored.figmaFiles.entries.map(\.name) == w.figmaFiles.entries.map(\.name))
        #expect(restored.figmaFiles.entries.map(\.view) == w.figmaFiles.entries.map(\.view))
    }
    @Test func emptyCaptureOmitsKeyAndLegacyRestoresEmpty() throws {
        let w = Workspace(); defer { w.teardownAllPanels() }
        let data = try JSONEncoder().encode(w.sessionSnapshot(includeScrollback: false))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["figmaFiles"] == nil)
        let legacy = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: JSONEncoder().encode(snapshot()))
        w.figmaFiles.show(URL(string: "https://www.figma.com/design/A/First")!)
        w.restoreFigmaFiles(from: legacy)
        #expect(w.figmaFiles.entries.isEmpty)
    }
    @Test func restoreCapsAndRejectsInvalidRecords() {
        let w = Workspace(); defer { w.teardownAllPanels() }
        var s = snapshot()
        s.figmaFiles = (0..<12).map { SessionFigmaFileSnapshot(link: "https://www.figma.com/design/K\($0)/Name", view: "editor", name: "Name \($0)") }
        s.figmaFiles?.insert(SessionFigmaFileSnapshot(link: "https://evil.com/design/A", view: "editor", name: "Bad"), at: 0)
        s.figmaFiles?.insert(SessionFigmaFileSnapshot(link: "https://www.figma.com/design/new", view: "editor", name: "Not a file"), at: 0)
        w.restoreFigmaFiles(from: s)
        #expect(w.figmaFiles.entries.map(\.key) == (0..<10).map { "K\($0)" })
    }
    @Test func fingerprintChangesWithList() {
        let w = Workspace(); defer { w.teardownAllPanels() }
        var a = Hasher(); w.combineFigmaFilesIntoSessionAutosaveFingerprint(into: &a)
        w.figmaFiles.show(URL(string: "https://www.figma.com/design/A/First")!)
        var b = Hasher(); w.combineFigmaFilesIntoSessionAutosaveFingerprint(into: &b)
        #expect(a.finalize() != b.finalize())
    }
}
