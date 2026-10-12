import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The one rule that says whether a browser pane's tab gets Figma's mark, and
/// the choice of picture built on it. A wrong yes puts Figma's mark on another
/// site's tab; a wrong no leaves a Figma pane's tab a globe.
@Suite("FigmaTabMark")
struct FigmaTabMarkTests {

    private static let wrapper = URL(fileURLWithPath: "/tmp/cmux-test/figma-embed.html")
    private static let readView = "file:///tmp/cmux-test/figma-embed.html?embed=https%3A%2F%2Fembed.figma.com%2Fdesign%2FKEY%2Fa"

    struct Row: CustomTestStringConvertible, Sendable {
        let address: String?
        let showsAddressBar: Bool
        let answer: Bool
        var testDescription: String {
            "\(address ?? "no address"), bar \(showsAddressBar ? "shown" : "hidden") -> \(answer ? "the mark" : "none")"
        }
    }

    static let rows: [Row] = [
        Row(address: readView, showsAddressBar: false, answer: true),
        Row(address: "https://www.figma.com/files/team/1/recents-and-sharing/recently-viewed", showsAddressBar: false, answer: true),
        Row(address: "https://www.figma.com/design/KEY/a", showsAddressBar: false, answer: true),
        Row(address: "https://figma.com/login", showsAddressBar: false, answer: true),
        Row(address: "https://www.figma.com/design/KEY/a", showsAddressBar: true, answer: false),
        Row(address: "https://accounts.google.com/", showsAddressBar: false, answer: false),
        Row(address: "http://www.figma.com/files/recent", showsAddressBar: false, answer: false),
        Row(address: "https://www.figma.com.example.com/", showsAddressBar: false, answer: false),
        Row(address: "https://embed.figma.com/design/KEY/a", showsAddressBar: false, answer: false),
        Row(address: "file:///tmp/cmux-test/other.html", showsAddressBar: false, answer: false),
        Row(address: nil, showsAddressBar: false, answer: false),
        Row(address: "https://user@www.figma.com/files/recent", showsAddressBar: false, answer: false),
        Row(address: "https://www.figma.com:8443/files/recent", showsAddressBar: false, answer: false),
    ]

    @Test("the rule, one row each", arguments: rows)
    func rule(row: Row) {
        let address = row.address.flatMap { URL(string: $0) }
        #expect(
            FigmaTabMark.applies(address: address, showsAddressBar: row.showsAddressBar, wrapper: Self.wrapper) == row.answer,
            "\(row.testDescription)"
        )
    }

    private static let own = Data([1, 2, 3])
    private static let figmaFile = URL(string: "https://www.figma.com/design/KEY/a")
    private static let elsewhere = URL(string: "https://example.com/")

    @Test("ownIconWins: the pane's own icon is returned, whatever the rule says")
    func ownIconWins() {
        #expect(FigmaTabMark.picture(own: Self.own, address: Self.figmaFile, showsAddressBar: false, wrapper: Self.wrapper) == Self.own)
        #expect(FigmaTabMark.picture(own: Self.own, address: Self.elsewhere, showsAddressBar: false, wrapper: Self.wrapper) == Self.own)
    }

    @Test("shippedWhenThereIsNoOwnIconAndTheRuleHolds")
    func shippedWhenThereIsNoOwnIconAndTheRuleHolds() {
        let picture = FigmaTabMark.picture(own: nil, address: Self.figmaFile, showsAddressBar: false, wrapper: Self.wrapper)
        #expect(picture == FigmaTabMark.shippedPicture)
        #expect(picture?.isEmpty == false)
    }

    @Test("noneWhenThereIsNoOwnIconAndTheRuleFails")
    func noneWhenThereIsNoOwnIconAndTheRuleFails() {
        #expect(FigmaTabMark.picture(own: nil, address: Self.elsewhere, showsAddressBar: false, wrapper: Self.wrapper) == nil)
        #expect(FigmaTabMark.picture(own: nil, address: Self.figmaFile, showsAddressBar: true, wrapper: Self.wrapper) == nil)
    }
}
