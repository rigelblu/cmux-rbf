import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct FigmaFileListTests {
    private func url(_ path: String) -> URL { URL(string: "https://www.figma.com/" + path)! }

    @Test func ordersByKeyAndCapsTen() {
        var list = FigmaFileList()
        for i in 0..<11 { list.show(url("design/K\(i)/Name-\(i)")) }
        #expect(list.entries.count == 10)
        #expect(list.entries.first?.key == "K10")
        #expect(!list.entries.contains { $0.key == "K0" })
        list.show(url("board/K3/Renamed?node-id=12-2&t=secret&mode=dev"))
        #expect(list.entries.count == 10)
        #expect(list.entries.first?.key == "K3")
        #expect(list.entries.first?.view == .editor)
        #expect(list.entries.first?.link.absoluteString == "https://www.figma.com/board/K3/Renamed?node-id=12-2&mode=dev")
    }

    @Test func kindsAndNonFiles() {
        var list = FigmaFileList()
        for kind in ["design", "board", "slides"] {
            list.show(url("\(kind)/new?folder_id=123"))
            list.show(url("\(kind)/\(kind)/A-name"))
        }
        list.show(url("files/recent"))
        list.show(URL(string: "https://example.com/design/OTHER/No")!)
        #expect(list.entries.map(\.key) == ["slides", "board", "design"])
    }

    @Test func titlesWinAndLateTitleDoesNotReorder() {
        var list = FigmaFileList()
        list.show(url("design/A/Old-slug"), title: "Onboarding – Figma")
        list.show(url("board/B/Board"), title: "Ideas – FigJam")
        list.rename(key: "A", title: "Renamed – Figma Slides")
        #expect(list.entries.map(\.key) == ["B", "A"])
        #expect(list.entries.last?.name == "Renamed")
        list.show(url("design/A/Older-address"), title: "Figma")
        #expect(list.entries.first?.name == "Renamed")
    }

    @Test func readViewKeepsLinkAndFrameAndTitleName() throws {
        var list = FigmaFileList()
        let source = url("design/A/Read%20view-name?node-id=12-2&t=secret")
        list.show(source, title: "A title – Figma")
        let read = try FigmaPaneURL.destination(for: source).url
        list.show(read, title: "Figma")
        let entry = try #require(list.entries.first)
        #expect(entry.view == .read)
        #expect(entry.name == "A title")
        #expect(entry.link.absoluteString == "https://www.figma.com/design/A/Read%20view-name?node-id=12-2")
        #expect(list.entries.count == 1)
    }

    @Test func addressNamesAndMiddleCut() {
        var list = FigmaFileList()
        list.show(url("design/A/A%20decoded-name"), title: "Figma")
        #expect(list.entries.first?.name == "A decoded name")
        list.show(url("design/B"), title: "Figma")
        #expect(list.entries.first?.name == "Untitled")
        let name = String(repeating: "a", count: 35) + String(repeating: "z", count: 35)
        list.show(url("slides/C/Deck"), title: name + " – Figma Slides")
        #expect(list.entries.first?.name == name)
        #expect(list.entries.first?.displayName.count == 50)
        #expect(list.entries.first?.displayName == String(name.prefix(25)) + "…" + String(name.suffix(24)))
    }
}
