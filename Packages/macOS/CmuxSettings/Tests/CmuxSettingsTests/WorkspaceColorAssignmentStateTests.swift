import Foundation
import Testing
@testable import CmuxSettings

/// `cm-11.1` — native on/off/mixed state in the workspace color chooser.
///
/// State is derived from target hex snapshots only. cmux persists a color, not the
/// palette entry that produced it, so every entry matching the assigned hex is a
/// truthful answer and the menu marks all of them.
@Suite("WorkspaceColorAssignmentState")
struct WorkspaceColorAssignmentStateTests {
    // MARK: - Single target

    @Test("One uncolored workspace puts No Color on")
    func singleUncoloredTargetChecksNoColor() {
        #expect(.state(candidate: nil, targets: [nil]) == WorkspaceColorAssignmentState.on)
    }

    @Test("One colored workspace puts its own color on and No Color off")
    func singleColoredTarget() {
        #expect(.state(candidate: "#006B6B", targets: ["#006B6B"]) == WorkspaceColorAssignmentState.on)
        #expect(.state(candidate: nil, targets: ["#006B6B"]) == WorkspaceColorAssignmentState.off)
    }

    @Test("A non-matching candidate is off")
    func nonMatchingCandidateIsOff() {
        #expect(.state(candidate: "#C0392B", targets: ["#006B6B"]) == WorkspaceColorAssignmentState.off)
    }

    // MARK: - Multiple targets

    @Test("Several workspaces sharing one color put that color on")
    func sharedColorAcrossTargetsIsOn() {
        #expect(
            .state(candidate: "#006B6B", targets: ["#006B6B", "#006B6B", "#006B6B"])
                == WorkspaceColorAssignmentState.on
        )
    }

    @Test("A color held by some but not all targets is mixed")
    func partialMatchIsMixed() {
        #expect(
            .state(candidate: "#006B6B", targets: ["#006B6B", "#C0392B"])
                == WorkspaceColorAssignmentState.mixed
        )
    }

    @Test("No Color is mixed when only some targets are uncolored")
    func partiallyUncoloredIsMixedOnNoColor() {
        #expect(.state(candidate: nil, targets: [nil, "#006B6B"]) == WorkspaceColorAssignmentState.mixed)
    }

    @Test("Every target uncolored puts No Color on and any color off")
    func allUncolored() {
        #expect(.state(candidate: nil, targets: [nil, nil]) == WorkspaceColorAssignmentState.on)
        #expect(.state(candidate: "#006B6B", targets: [nil, nil]) == WorkspaceColorAssignmentState.off)
    }

    // MARK: - Normalization

    @Test("Comparison normalizes hex on both sides")
    func comparisonNormalizesBothSides() {
        // A workspace may have persisted a lower-case or unprefixed value.
        #expect(.state(candidate: "#006B6B", targets: ["006b6b"]) == WorkspaceColorAssignmentState.on)
        #expect(.state(candidate: "006b6b", targets: ["#006B6B"]) == WorkspaceColorAssignmentState.on)
    }

    @Test("An unparseable target hex is not treated as uncolored")
    func unparseableTargetIsNotNoColor() {
        // Silently folding junk into No Color would show a check next to a state the
        // workspace is not actually in.
        #expect(.state(candidate: nil, targets: ["not-a-hex"]) == WorkspaceColorAssignmentState.off)
    }

    // MARK: - Duplicate and unlisted colors

    @Test("Duplicate-hex palette entries all report the same truthful state")
    func duplicateHexEntriesAgree() {
        // If Teal and "Primary Teal" both resolve to #006B6B, both are truthful matches.
        // Choosing one as the remembered source would fabricate state cmux never stored.
        let targets = ["#006B6B"]
        #expect(.state(candidate: "#006B6B", targets: targets) == WorkspaceColorAssignmentState.on)
        #expect(.state(candidate: "#006b6b", targets: targets) == WorkspaceColorAssignmentState.on)
    }

    @Test("A color absent from the palette still reports state as a synthetic candidate")
    func unlistedAssignedHexReportsState() {
        // Removing a custom palette entry must not make a workspace's current color
        // disappear from the chooser.
        #expect(.state(candidate: "#ABCDEF", targets: ["#ABCDEF"]) == WorkspaceColorAssignmentState.on)
        #expect(
            .state(candidate: "#ABCDEF", targets: ["#ABCDEF", nil])
                == WorkspaceColorAssignmentState.mixed
        )
    }

    // MARK: - Degenerate input

    @Test("An empty target set is off, not on")
    func emptyTargetsIsOff() {
        // "every element matches" is vacuously true for an empty set; reporting .on would
        // draw a checkmark for a menu that acts on nothing.
        #expect(.state(candidate: nil, targets: []) == WorkspaceColorAssignmentState.off)
        #expect(.state(candidate: "#006B6B", targets: []) == WorkspaceColorAssignmentState.off)
    }
}
