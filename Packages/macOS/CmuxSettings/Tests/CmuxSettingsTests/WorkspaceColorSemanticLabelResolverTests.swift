import Foundation
import Testing
@testable import CmuxSettings

/// `cm-11.1` — semantic workspace color labels.
///
/// Covers the brief's pure seams: label validation, resolver ordering, display
/// formatting, and command identity. Assignment state lives in its own suite.
@Suite("WorkspaceColorSemanticLabelResolver")
struct WorkspaceColorSemanticLabelResolverTests {
    /// A slice of the shipped built-in palette.
    private static let palette: [String: String] = [
        "Teal": "#006B6B",
        "Red": "#C0392B",
        "Blue": "#1565C0",
    ]

    // MARK: - Display formatting

    @Test("A labelled entry reads meaning first, raw identity second")
    func labelledEntryPutsMeaningFirst() {
        let entry = WorkspaceColorPaletteEntry(name: "Teal", hex: "#006B6B", label: "GOAL: Primary")
        #expect(entry.displayName == "GOAL: Primary (Teal)")
    }

    @Test("An unlabelled entry shows the bare raw name")
    func unlabelledEntryShowsRawName() {
        let entry = WorkspaceColorPaletteEntry(name: "Teal", hex: "#006B6B", label: nil)
        #expect(entry.displayName == "Teal")
    }

    // MARK: - Label validation

    @Test("A well-formed label survives validation")
    func wellFormedLabelSurvives() {
        let valid = WorkspaceColorSemanticLabelResolver.validLabels(
            rawLabels: ["Teal": "GOAL: Primary"],
            palette: Self.palette
        )
        #expect(valid == ["Teal": "GOAL: Primary"])
    }

    @Test("Labels are trimmed, and one that is empty after trimming is dropped")
    func emptyAfterTrimIsDropped() {
        let valid = WorkspaceColorSemanticLabelResolver.validLabels(
            rawLabels: ["Teal": "   ", "Red": "  CUSTOMER: Urgent  "],
            palette: Self.palette
        )
        #expect(valid["Teal"] == nil)
        #expect(valid["Red"] == "CUSTOMER: Urgent")
    }

    @Test("A label longer than the limit is dropped")
    func oversizedLabelIsDropped() {
        let tooLong = String(repeating: "x", count: WorkspaceColorSemanticLabelResolver.maximumLabelLength + 1)
        let valid = WorkspaceColorSemanticLabelResolver.validLabels(
            rawLabels: ["Teal": tooLong],
            palette: Self.palette
        )
        #expect(valid["Teal"] == nil)
        #expect(
            WorkspaceColorSemanticLabelResolver.rejections(
                rawLabels: ["Teal": tooLong],
                palette: Self.palette
            )["Teal"] == .tooLong
        )
    }

    @Test("Two labels equal after case-folding both fail closed")
    func duplicateLabelsFailClosed() {
        let valid = WorkspaceColorSemanticLabelResolver.validLabels(
            rawLabels: ["Teal": "Primary", "Red": "PRIMARY"],
            palette: Self.palette
        )
        #expect(valid.isEmpty, "an ambiguous label must never resolve for either entry")
    }

    @Test("A label may not impersonate a raw palette name")
    func labelCollidingWithPaletteNameIsRejected() {
        let valid = WorkspaceColorSemanticLabelResolver.validLabels(
            rawLabels: ["Teal": "blue"],
            palette: Self.palette
        )
        #expect(valid["Teal"] == nil)
        #expect(
            WorkspaceColorSemanticLabelResolver.rejections(
                rawLabels: ["Teal": "blue"],
                palette: Self.palette
            )["Teal"] == .collidesWithPaletteName("Blue")
        )
    }

    @Test("Collision is symmetric — a palette entry added later invalidates the label, not the name")
    func paletteEntryAddedLaterInvalidatesTheLabel() {
        var palette = Self.palette
        palette["Primary"] = "#123456"
        let valid = WorkspaceColorSemanticLabelResolver.validLabels(
            rawLabels: ["Teal": "Primary"],
            palette: palette
        )
        #expect(valid["Teal"] == nil, "the raw name must keep resolving; the label yields")
        #expect(
            WorkspaceColorSemanticLabelResolver.resolve("Primary", palette: palette, labels: valid) == "#123456"
        )
    }

    @Test("A label keyed to a palette entry that does not exist is ignored")
    func orphanLabelIsIgnored() {
        let valid = WorkspaceColorSemanticLabelResolver.validLabels(
            rawLabels: ["Chartreuse": "GOAL: Primary"],
            palette: Self.palette
        )
        #expect(valid.isEmpty)
        #expect(
            WorkspaceColorSemanticLabelResolver.rejections(
                rawLabels: ["Chartreuse": "GOAL: Primary"],
                palette: Self.palette
            )["Chartreuse"] == .unknownPaletteName
        )
    }

    // MARK: - Resolution order

    @Test("A hex resolves to itself, normalized")
    func hexResolvesNormalized() {
        #expect(
            WorkspaceColorSemanticLabelResolver.resolve("#006b6b", palette: Self.palette, labels: [:]) == "#006B6B"
        )
        #expect(
            WorkspaceColorSemanticLabelResolver.resolve("006b6b", palette: Self.palette, labels: [:]) == "#006B6B"
        )
    }

    @Test("A raw palette name still resolves — permanent compatibility")
    func rawNameResolves() {
        #expect(
            WorkspaceColorSemanticLabelResolver.resolve("Teal", palette: Self.palette, labels: [:]) == "#006B6B"
        )
    }

    @Test("An exact case-sensitive name wins over a case-folded one")
    func exactCaseBeatsFolded() {
        // cmux.json may legitimately define both, because palette keys are trimmed but
        // never case-folded. Without the exact pass, ambiguity-fails-closed would break
        // BOTH — the command palette passes a verbatim entry name.
        let palette = ["Teal": "#006B6B", "teal": "#111111"]
        #expect(
            WorkspaceColorSemanticLabelResolver.resolve("Teal", palette: palette, labels: [:]) == "#006B6B"
        )
        #expect(
            WorkspaceColorSemanticLabelResolver.resolve("teal", palette: palette, labels: [:]) == "#111111"
        )
    }

    @Test("A raw name resolves case-insensitively when only one spelling exists")
    func foldedNameResolvesWhenUnambiguous() {
        #expect(
            WorkspaceColorSemanticLabelResolver.resolve("TEAL", palette: Self.palette, labels: [:]) == "#006B6B"
        )
    }

    @Test("An exact unique label resolves, case-folded after trim")
    func labelResolvesCaseFolded() {
        let labels = ["Teal": "GOAL: Primary"]
        #expect(
            WorkspaceColorSemanticLabelResolver.resolve("GOAL: Primary", palette: Self.palette, labels: labels) == "#006B6B"
        )
        #expect(
            WorkspaceColorSemanticLabelResolver.resolve("  goal: primary  ", palette: Self.palette, labels: labels) == "#006B6B"
        )
    }

    @Test("A raw name outranks a label that was allowed to shadow it")
    func rawNameOutranksLabel() {
        // Validation rejects this pairing, but resolve must not depend on that having run.
        #expect(
            WorkspaceColorSemanticLabelResolver.resolve(
                "Blue",
                palette: Self.palette,
                labels: ["Teal": "Blue"]
            ) == "#1565C0"
        )
    }

    @Test("An unknown value resolves to nothing rather than guessing")
    func unknownValueFailsClosed() {
        #expect(
            WorkspaceColorSemanticLabelResolver.resolve("Chartreuse", palette: Self.palette, labels: [:]) == nil
        )
        #expect(
            WorkspaceColorSemanticLabelResolver.resolve("", palette: Self.palette, labels: [:]) == nil
        )
    }

    // MARK: - Effective entries

    @Test("Effective entries carry their validated labels in palette order")
    func effectiveEntriesCarryLabels() {
        let entries = WorkspaceColorSemanticLabelResolver.effectiveEntries(
            orderedNames: ["Red", "Teal", "Blue"],
            palette: Self.palette,
            labels: ["Teal": "GOAL: Primary"]
        )
        #expect(entries.map(\.name) == ["Red", "Teal", "Blue"])
        #expect(entries.map(\.label) == [nil, "GOAL: Primary", nil])
        #expect(entries.map(\.displayName) == ["Red", "GOAL: Primary (Teal)", "Blue"])
    }

    @Test("An invalid label never reaches an effective entry")
    func invalidLabelNeverReachesEntries() {
        let entries = WorkspaceColorSemanticLabelResolver.effectiveEntries(
            orderedNames: ["Teal"],
            palette: Self.palette,
            labels: ["Teal": "blue"]
        )
        #expect(entries.map(\.label) == [nil])
    }

    // MARK: - Command identity

    @Test("Command IDs are stable per raw name and differ across names")
    func commandIDsAreStableAndDistinct() {
        let first = WorkspaceColorCommandIdentity.commandID(forPaletteName: "Custom 1")
        #expect(first == WorkspaceColorCommandIdentity.commandID(forPaletteName: "Custom 1"))
        #expect(first != WorkspaceColorCommandIdentity.commandID(forPaletteName: "Custom 2"))
        #expect(first.hasPrefix("palette.workspaceColor."))
    }

    @Test("Command identity matches the FNV-1a value ContentView shipped")
    func commandIDMatchesShippedHash() {
        // Guards the move out of ContentView: a changed hash would silently retarget
        // every existing cmux.json `actions` override keyed by these IDs.
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in "Teal".utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        #expect(
            WorkspaceColorCommandIdentity.commandID(forPaletteName: "Teal")
                == "palette.workspaceColor.\(String(hash, radix: 16))"
        )
    }
}
