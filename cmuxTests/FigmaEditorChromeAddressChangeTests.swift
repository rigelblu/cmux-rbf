import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// When an address changes with no page load (Figma opening a file from its file
/// list, in the same tab), does the pane collapse Figma's side panels? One pure
/// decision, held row by row. Whether the app's observer fires for Figma's own
/// change, and whether Figma's control is there to click, is not held here.
@Suite("FigmaEditorChromeAddressChange")
struct FigmaEditorChromeAddressChangeTests {

    private static let fileList = "https://www.figma.com/files/team/1/recents-and-sharing/recently-viewed"
    private static let fileA = "https://www.figma.com/design/KEY/a"

    private func collapses(
        from before: String?,
        to after: String?,
        addressBarShown: Bool = false,
        loadInProgress: Bool = false
    ) -> Bool {
        FigmaEditorChrome.shouldMinimizeUI(
            afterAddressChangeFrom: before.flatMap { URL(string: $0) },
            to: after.flatMap { URL(string: $0) },
            isOmnibarVisible: addressBarShown,
            loadInProgress: loadInProgress
        )
    }

    @Test("from the file list to a file, no address bar: collapse")
    func fileListToFile() {
        #expect(collapses(from: Self.fileList, to: Self.fileA))
    }

    @Test("from no address to a file, no address bar: collapse")
    func noAddressToFile() {
        #expect(collapses(from: nil, to: Self.fileA))
    }

    @Test("the same file with a frame added: no collapse, the panels are already as they were left")
    func sameFileDifferentFrame() {
        #expect(!collapses(from: Self.fileA, to: "\(Self.fileA)?node-id=1-2"))
        // The same file under a different name in the path is still the same file.
        #expect(!collapses(from: Self.fileA, to: "https://www.figma.com/design/KEY/renamed?node-id=3-4"))
    }

    @Test("from one file to another: collapse")
    func fileToOtherFile() {
        #expect(collapses(from: Self.fileA, to: "https://www.figma.com/design/OTHER/b"))
    }

    @Test("with the address bar showing, an ordinary browser tab: no collapse")
    func addressBarShown() {
        #expect(!collapses(from: Self.fileList, to: Self.fileA, addressBarShown: true))
    }

    @Test("from a file back to the file list: no collapse, the list is not a file")
    func fileToFileList() {
        #expect(!collapses(from: Self.fileA, to: Self.fileList))
    }

    @Test("a load in progress: no collapse, the finished load collapses once")
    func loadInProgress() {
        #expect(!collapses(from: Self.fileList, to: Self.fileA, loadInProgress: true))
    }

    @Test("another site's file-shaped address: no collapse")
    func otherSite() {
        #expect(!collapses(from: Self.fileList, to: "https://www.figma.com.example.com/design/KEY/a"))
        #expect(!collapses(from: Self.fileList, to: "http://www.figma.com/design/KEY/a"))
    }
}
