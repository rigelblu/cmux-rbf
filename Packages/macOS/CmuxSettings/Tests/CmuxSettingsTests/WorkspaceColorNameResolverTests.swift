import Testing
@testable import CmuxSettings

@Suite("WorkspaceColorNameResolver")
struct WorkspaceColorNameResolverTests {
    private let resolver = WorkspaceColorNameResolver()
    private let palette = [
        "Red": "#C0392B",
        "Custom 11": "#FF8300",
        "Custom 12": "#0080FF",
    ]
    private let builtIns: Set<String> = ["Red"]

    @Test("Display names and labels share one case-insensitive namespace")
    func allAliasesShareOneNamespace() {
        let result = resolver.validate(
            rawDisplayNames: ["Custom 11": "Tangerine"],
            rawLabels: ["Custom 12": "tAnGeRiNe"],
            palette: palette,
            builtInNames: builtIns
        )

        #expect(result.displayNames.isEmpty)
        #expect(result.labels.isEmpty)
        #expect(result.displayNameRejections["Custom 11"] == .collidesWithAlias(
            paletteName: "Custom 12",
            kind: .semanticLabel
        ))
        #expect(result.labelRejections["Custom 12"] == .collidesWithAlias(
            paletteName: "Custom 11",
            kind: .customDisplayName
        ))
    }

    @Test("Every imported duplicate claimant fails closed")
    func importedDuplicateClaimantsAllFailClosed() {
        let result = resolver.validate(
            rawDisplayNames: ["Custom 11": "Focus", "Custom 12": "FOCUS"],
            rawLabels: [:],
            palette: palette,
            builtInNames: builtIns
        )

        #expect(result.displayNames.isEmpty)
        #expect(result.displayNameRejections.count == 2)
    }

    @Test("Raw names remain usable and reject colliding aliases")
    func rawNamesRemainAuthoritative() {
        let result = resolver.validate(
            rawDisplayNames: ["Custom 11": "red"],
            rawLabels: ["Custom 12": "CUSTOM 11"],
            palette: palette,
            builtInNames: builtIns
        )

        #expect(result.displayNameRejections["Custom 11"] == .collidesWithRawName("Red"))
        #expect(result.labelRejections["Custom 12"] == .collidesWithRawName("Custom 11"))
        #expect(resolver.resolve(
            "Red",
            palette: palette,
            displayNames: ["Custom 11": "red"],
            labels: [:],
            builtInNames: builtIns
        ) == "#C0392B")
    }

    @Test("Imported metadata for missing and built-in entries fails closed")
    func invalidMetadataOwnersFailClosed() {
        let result = resolver.validate(
            rawDisplayNames: ["Red": "Rose", "Custom 99": "Missing"],
            rawLabels: ["Custom 99": "Orphan"],
            palette: palette,
            builtInNames: builtIns
        )

        #expect(result.displayNameRejections["Red"] == .builtInPaletteEntry)
        #expect(result.displayNameRejections["Custom 99"] == .unknownPaletteName)
        #expect(result.labelRejections["Custom 99"] == .unknownPaletteName)
    }

    @Test("Names trim, accept 64 characters, and reject 65")
    func aliasLengthBoundary() {
        let accepted = String(repeating: "a", count: 64)
        let rejected = String(repeating: "b", count: 65)
        let result = resolver.validate(
            rawDisplayNames: ["Custom 11": "  \(accepted)  "],
            rawLabels: ["Custom 12": rejected],
            palette: palette,
            builtInNames: builtIns
        )

        #expect(result.displayNames["Custom 11"] == accepted)
        #expect(result.labelRejections["Custom 12"] == .tooLong)
    }

    @Test("Menu display and resolver use the same accepted aliases")
    func entriesAndResolutionStayInParity() {
        let displayNames = ["Custom 11": "Tangerine"]
        let labels = ["Custom 11": "Goal: Continuous", "Custom 12": "Goal: Primary"]
        let entries = resolver.effectiveEntries(
            orderedNames: ["Red", "Custom 11", "Custom 12"],
            palette: palette,
            displayNames: displayNames,
            labels: labels,
            builtInNames: builtIns
        )

        #expect(entries.map(\.displayName) == [
            "Red",
            "Goal: Continuous (Tangerine)",
            "Goal: Primary (Custom 12)",
        ])
        #expect(resolver.resolve(
            "tangerine",
            palette: palette,
            displayNames: displayNames,
            labels: labels,
            builtInNames: builtIns
        ) == "#FF8300")
        #expect(resolver.resolve(
            "GOAL: PRIMARY",
            palette: palette,
            displayNames: displayNames,
            labels: labels,
            builtInNames: builtIns
        ) == "#0080FF")
    }
}
