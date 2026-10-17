import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// The sentences the footer pill shows for a problem in his status list (#cm-109.3, `unknown_icon`). Each sentence
/// names a value from his file, so a test pins that the place, the id and the value reach it, and that the line is the
/// catalog's sentence and not its key.
@Suite("Workspace status problem words")
struct WorkspaceStatusProblemWordsTests {
    @Test func anUnknownIconNamesThePlaceTheIdTheValueAndTheSevenNames() {
        let line = WorkspaceStatusProblemWords.line(.unknownIcon(entry: 7, id: "parked", value: " Half "))
        #expect(line.contains("7"), "\(line)")
        #expect(line.contains("“parked”"), "\(line)")
        #expect(line.contains("“ Half ”"), "\(line)")
        // The id comes before the value, as the three arguments are in the format: a swap keeps both in the line.
        if let idAt = line.range(of: "“parked”"), let valueAt = line.range(of: "“ Half ”") {
            #expect(idAt.lowerBound < valueAt.lowerBound, "\(line)")
        }
        for name in WorkspaceStatusIcon.allCases.map(\.rawValue) {
            #expect(line.contains(name), "\(name) is missing from \(line)")
        }
        #expect(!line.contains("sidebar.statusFile.problem.unknownIcon"), "\(line)")
    }

    @Test func anUnknownIconHasItsOwnSentence() {
        let icon = WorkspaceStatusProblemWords.line(.unknownIcon(entry: 2, id: "a", value: "x"))
        let extends = WorkspaceStatusProblemWords.line(.unknownExtends(entry: 2, id: "a", value: "x"))
        #expect(icon != extends)
    }
}
