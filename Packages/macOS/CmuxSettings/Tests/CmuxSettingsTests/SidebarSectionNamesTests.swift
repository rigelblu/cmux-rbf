import Foundation
import Testing
@testable import CmuxSettings

struct SidebarSectionNamesTests {
    @Test(arguments: ["pinned", "workspaces", "statuses"])
    func trimsEachKnownName(_ section: String) {
        #expect(SidebarSectionNames.normalized([section: " \n Board \t "]) == [section: "Board"])
    }

    @Test(arguments: ["", "   ", "\n\t"])
    func blankNamesLeaveOnlyTheirSectionAtItsDefault(_ value: String) {
        let names = SidebarSectionNames.normalized(["statuses": value, "workspaces": "Loose"])
        #expect(names["statuses"] == nil)
        #expect(names["workspaces"] == "Loose", "an invalid sibling does not discard a valid name")
    }

    enum Invalid: CaseIterable { case number, boolean, array, object, null }
    @Test(arguments: Invalid.allCases)
    func nonStringNamesLeaveOnlyTheirSectionAtItsDefault(_ kind: Invalid) {
        let value: Any
        switch kind {
        case .number: value = 7
        case .boolean: value = true
        case .array: value = ["Board"]
        case .object: value = ["name": "Board"]
        case .null: value = NSNull()
        }
        let names = SidebarSectionNames.normalized(["statuses": value, "pinned": "Favorites"])
        #expect(names["statuses"] == nil)
        #expect(names["pinned"] == "Favorites", "an invalid sibling does not discard a valid name")
    }

    @Test func unknownKeysAreIgnored() {
        #expect(SidebarSectionNames.normalized(["pins": "X", "workspaces ": "Y"]).isEmpty)
    }

    @Test func namesKeepTheirOwnCharactersAndMissingNamesUseDefaults() {
        #expect(SidebarSectionNames.normalized([:]).isEmpty)
        #expect(SidebarSectionNames.normalized(["statuses": "Board %@ • 作業", "pinned": "Favorites"]) == ["statuses": "Board %@ • 作業", "pinned": "Favorites"])
    }
}
