import Foundation
import Testing
@testable import CmuxSettings

/// `cm-11.1` — the rows the workspace color chooser shows, and their state.
@Suite("WorkspaceColorMenuModel")
struct WorkspaceColorMenuModelTests {
    private static let palette: [String: String] = [
        "Teal": "#006B6B",
        "Red": "#C0392B",
        "Blue": "#1565C0",
    ]
    private static let order = ["Teal", "Red", "Blue"]

    private func candidates(
        labels: [String: String] = [:],
        targets: [String?],
        palette: [String: String] = WorkspaceColorMenuModelTests.palette,
        order: [String] = WorkspaceColorMenuModelTests.order
    ) -> [WorkspaceColorMenuCandidate] {
        WorkspaceColorMenuModel.candidates(
            orderedNames: order,
            palette: palette,
            labels: labels,
            targetHexes: targets
        )
    }

    // MARK: - Shape

    @Test("No Color is always present and always first")
    func noColorIsAlwaysFirst() {
        for targets in [[nil], [String?.some("#006B6B")], [nil, "#C0392B"], []] {
            let rows = candidates(targets: targets)
            #expect(rows.first?.kind == .noColor)
            #expect(rows.first?.hex == nil)
        }
    }

    @Test("Palette entries follow in display order")
    func paletteEntriesFollowInOrder() {
        let rows = candidates(targets: [nil])
        let names = rows.compactMap { row -> String? in
            guard case let .paletteEntry(entry) = row.kind else { return nil }
            return entry.name
        }
        #expect(names == ["Teal", "Red", "Blue"])
    }

    @Test("Entries carry their labels so the menu can show meaning first")
    func entriesCarryLabels() {
        let rows = candidates(labels: ["Teal": "GOAL: Primary"], targets: [nil])
        let displays = rows.compactMap { row -> String? in
            guard case let .paletteEntry(entry) = row.kind else { return nil }
            return entry.displayName
        }
        #expect(displays == ["GOAL: Primary (Teal)", "Red", "Blue"])
    }

    // MARK: - State

    @Test("A single uncolored workspace checks No Color only")
    func singleUncoloredChecksNoColor() {
        let rows = candidates(targets: [nil])
        #expect(rows.first?.state == .on)
        #expect(rows.dropFirst().allSatisfy { $0.state == .off })
    }

    @Test("A single colored workspace checks its own entry")
    func singleColoredChecksItsEntry() {
        let rows = candidates(targets: ["#006B6B"])
        #expect(rows.first?.state == .off)
        let teal = rows.first { $0.hex == "#006B6B" }
        #expect(teal?.state == .on)
        #expect(rows.first { $0.hex == "#C0392B" }?.state == .off)
    }

    @Test("A mixed selection marks each matching subset mixed")
    func mixedSelection() {
        let rows = candidates(targets: ["#006B6B", "#C0392B"])
        #expect(rows.first { $0.hex == "#006B6B" }?.state == .mixed)
        #expect(rows.first { $0.hex == "#C0392B" }?.state == .mixed)
        #expect(rows.first { $0.hex == "#1565C0" }?.state == .off)
        #expect(rows.first?.state == .off, "no target is uncolored")
    }

    @Test("No Color is mixed when only some targets are uncolored")
    func noColorMixed() {
        let rows = candidates(targets: [nil, "#006B6B"])
        #expect(rows.first?.state == .mixed)
        #expect(rows.first { $0.hex == "#006B6B" }?.state == .mixed)
    }

    @Test("Target hexes are normalized before comparison")
    func targetsAreNormalized() {
        let rows = candidates(targets: ["006b6b"])
        #expect(rows.first { $0.hex == "#006B6B" }?.state == .on)
    }

    // MARK: - Duplicate hexes

    @Test("Every entry resolving to the assigned hex is checked")
    func duplicateHexEntriesAreAllChecked() {
        var palette = Self.palette
        palette["Primary Teal"] = "#006B6B"
        let rows = candidates(
            targets: ["#006B6B"],
            palette: palette,
            order: ["Teal", "Red", "Blue", "Primary Teal"]
        )
        let checked = rows.filter { $0.state == .on }.compactMap { row -> String? in
            guard case let .paletteEntry(entry) = row.kind else { return nil }
            return entry.name
        }
        #expect(checked.sorted() == ["Primary Teal", "Teal"], "the stored truth is a color, not a slot")
    }

    // MARK: - Colors the palette no longer lists

    @Test("An assigned color absent from the palette appears as an unlisted row")
    func unlistedAssignedHexAppears() {
        let rows = candidates(targets: ["#ABCDEF"])
        let unlisted = rows.filter { if case .unlisted = $0.kind { return true } else { return false } }
        #expect(unlisted.count == 1)
        #expect(unlisted.first?.hex == "#ABCDEF")
        #expect(unlisted.first?.state == .on, "it is the current color of every target")
    }

    @Test("Unlisted rows are deduplicated and come last")
    func unlistedRowsAreDedupedAndLast() {
        let rows = candidates(targets: ["#ABCDEF", "#abcdef", "#FEDCBA"])
        let unlistedHexes = rows.compactMap { row -> String? in
            guard case let .unlisted(hex) = row.kind else { return nil }
            return hex
        }
        #expect(unlistedHexes == ["#ABCDEF", "#FEDCBA"], "case variants are one color")
        let firstUnlisted = rows.firstIndex { if case .unlisted = $0.kind { return true } else { return false } }
        let lastPalette = rows.lastIndex { if case .paletteEntry = $0.kind { return true } else { return false } }
        #expect(firstUnlisted.map { idx in lastPalette.map { $0 < idx } ?? true } == true)
    }

    @Test("A color still in the palette never becomes an unlisted row")
    func listedColorIsNotDuplicated() {
        let rows = candidates(targets: ["#006B6B"])
        #expect(!rows.contains { if case .unlisted = $0.kind { return true } else { return false } })
    }

    @Test("Unlisted rows report mixed state like any other candidate")
    func unlistedRowsReportMixed() {
        let rows = candidates(targets: ["#ABCDEF", nil])
        let unlisted = rows.first { if case .unlisted = $0.kind { return true } else { return false } }
        #expect(unlisted?.state == .mixed)
    }

    // MARK: - Degenerate input

    @Test("An empty selection still renders the palette, all off")
    func emptySelectionRendersPaletteOff() {
        let rows = candidates(targets: [])
        #expect(rows.count == 4, "No Color plus three entries")
        #expect(rows.allSatisfy { $0.state == .off })
    }

    @Test("An unparseable stored color does not masquerade as No Color")
    func unparseableTargetIsNotNoColor() {
        let rows = candidates(targets: ["not-a-hex"])
        #expect(rows.first?.state == .off)
        #expect(!rows.contains { if case .unlisted = $0.kind { return true } else { return false } })
    }
}
