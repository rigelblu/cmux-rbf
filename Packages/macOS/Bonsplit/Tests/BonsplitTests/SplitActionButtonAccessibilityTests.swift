import XCTest
@testable import Bonsplit

/// cmux-rbf `#cm-73.9`: a header button whose icon is a picture has no name of its own for assistive tech
/// (an SF Symbol names itself, "Globe"), so it falls back to its identifier. The tooltip is its name.
/// The view applies this value as the button's accessibility label; that the label reaches the running app's
/// accessibility tree is the app check of Scenario 60, since a hosted SwiftUI view exposes no tree in a test.
final class SplitActionButtonAccessibilityTests: XCTestCase {

    func testPictureButtonIsNamedByItsTooltip() {
        XCTAssertEqual(
            TabBarStyling.splitActionAccessibilityName(for: .imageData(Data([1, 2, 3])), tooltip: "New Tab (Figma)"),
            "New Tab (Figma)"
        )
    }

    func testTooltipIsTrimmedAndAnEmptyOneNamesNothing() {
        XCTAssertEqual(
            TabBarStyling.splitActionAccessibilityName(for: .imageData(Data()), tooltip: "  New Tab (Figma)\n"),
            "New Tab (Figma)"
        )
        XCTAssertNil(TabBarStyling.splitActionAccessibilityName(for: .imageData(Data()), tooltip: "   "))
    }

    func testSymbolAndEmojiButtonsKeepTheirOwnName() {
        XCTAssertNil(TabBarStyling.splitActionAccessibilityName(for: .systemImage("globe"), tooltip: "New Tab (Browser)"))
        XCTAssertNil(TabBarStyling.splitActionAccessibilityName(for: .emoji("x", scale: 1), tooltip: "x"))
    }
}
