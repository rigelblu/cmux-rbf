import Foundation

/// Validates and resolves raw palette names, custom display names, and semantic labels.
public struct WorkspaceColorNameResolver: Sendable {
    /// Longest accepted custom display name or semantic label.
    public static let maximumAliasLength = 64

    /// The kind of user-authored alias being validated.
    public enum AliasKind: Equatable, Sendable {
        /// Editable display name for a custom palette entry.
        case customDisplayName
        /// Semantic meaning layered over any palette entry.
        case semanticLabel
    }

    /// Why a user-authored alias cannot enter the shared name resolver.
    public enum AliasRejection: Equatable, Sendable {
        /// Empty after trimming.
        case empty
        /// Longer than ``maximumAliasLength``.
        case tooLong
        /// Keyed to a palette entry that does not exist.
        case unknownPaletteName
        /// A display name was supplied for a built-in entry.
        case builtInPaletteEntry
        /// Case-insensitively equal to a stable raw palette name.
        case collidesWithRawName(String)
        /// Case-insensitively equal to another accepted alias claimant.
        case collidesWithAlias(paletteName: String, kind: AliasKind)
    }

    /// Accepted aliases and claimant-specific rejections for one palette snapshot.
    public struct Validation: Equatable, Sendable {
        /// Accepted display names keyed by stable raw identity.
        public let displayNames: [String: String]
        /// Accepted semantic labels keyed by stable raw identity.
        public let labels: [String: String]
        /// Rejected display-name claimants keyed by stable raw identity.
        public let displayNameRejections: [String: AliasRejection]
        /// Rejected semantic-label claimants keyed by stable raw identity.
        public let labelRejections: [String: AliasRejection]

        /// Creates one complete alias-validation result.
        public init(
            displayNames: [String: String],
            labels: [String: String],
            displayNameRejections: [String: AliasRejection],
            labelRejections: [String: AliasRejection]
        ) {
            self.displayNames = displayNames
            self.labels = labels
            self.displayNameRejections = displayNameRejections
            self.labelRejections = labelRejections
        }
    }

    /// Creates a shared workspace-color name resolver.
    public init() {}

    /// Validates every non-raw alias as one case-insensitive namespace.
    ///
    /// Raw identities always remain usable. Imported conflicts reject every conflicting
    /// display name and semantic label rather than choosing a winner by dictionary order.
    ///
    /// - Parameters:
    ///   - rawDisplayNames: Unvalidated display-name metadata.
    ///   - rawLabels: Unvalidated semantic-label metadata.
    ///   - palette: Effective raw-name-to-hex palette.
    ///   - builtInNames: Stable names that cannot receive editable display names.
    /// - Returns: Accepted aliases and a rejection for every invalid claimant.
    public func validate(
        rawDisplayNames: [String: String],
        rawLabels: [String: String],
        palette: [String: String],
        builtInNames: Set<String>
    ) -> Validation {
        struct Claim {
            let paletteName: String
            let kind: AliasKind
            let value: String
        }

        let canonicalRawNames = Dictionary(
            palette.keys.map { ($0.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var displayRejections: [String: AliasRejection] = [:]
        var labelRejections: [String: AliasRejection] = [:]
        var claims: [Claim] = []

        func basicRejection(
            paletteName: String,
            rawValue: String,
            kind: AliasKind
        ) -> (trimmed: String, rejection: AliasRejection?) {
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard palette[paletteName] != nil else { return (trimmed, .unknownPaletteName) }
            if kind == .customDisplayName, builtInNames.contains(paletteName) {
                return (trimmed, .builtInPaletteEntry)
            }
            guard !trimmed.isEmpty else { return (trimmed, .empty) }
            guard trimmed.count <= Self.maximumAliasLength else { return (trimmed, .tooLong) }
            if let rawName = canonicalRawNames[trimmed.lowercased()] {
                return (trimmed, .collidesWithRawName(rawName))
            }
            return (trimmed, nil)
        }

        for (paletteName, rawValue) in rawDisplayNames {
            let result = basicRejection(
                paletteName: paletteName,
                rawValue: rawValue,
                kind: .customDisplayName
            )
            if let rejection = result.rejection {
                displayRejections[paletteName] = rejection
            } else {
                claims.append(.init(paletteName: paletteName, kind: .customDisplayName, value: result.trimmed))
            }
        }

        for (paletteName, rawValue) in rawLabels {
            let result = basicRejection(
                paletteName: paletteName,
                rawValue: rawValue,
                kind: .semanticLabel
            )
            if let rejection = result.rejection {
                labelRejections[paletteName] = rejection
            } else {
                claims.append(.init(paletteName: paletteName, kind: .semanticLabel, value: result.trimmed))
            }
        }

        let claimsByFoldedValue = Dictionary(grouping: claims, by: { $0.value.lowercased() })
        for claimants in claimsByFoldedValue.values where claimants.count > 1 {
            for claimant in claimants {
                let other = claimants
                    .filter { $0.paletteName != claimant.paletteName || $0.kind != claimant.kind }
                    .sorted { lhs, rhs in
                        if lhs.paletteName != rhs.paletteName { return lhs.paletteName < rhs.paletteName }
                        return String(describing: lhs.kind) < String(describing: rhs.kind)
                    }
                    .first ?? claimant
                let rejection = AliasRejection.collidesWithAlias(
                    paletteName: other.paletteName,
                    kind: other.kind
                )
                switch claimant.kind {
                case .customDisplayName:
                    displayRejections[claimant.paletteName] = rejection
                case .semanticLabel:
                    labelRejections[claimant.paletteName] = rejection
                }
            }
        }

        var displayNames: [String: String] = [:]
        var labels: [String: String] = [:]
        for claim in claims {
            switch claim.kind {
            case .customDisplayName where displayRejections[claim.paletteName] == nil:
                displayNames[claim.paletteName] = claim.value
            case .semanticLabel where labelRejections[claim.paletteName] == nil:
                labels[claim.paletteName] = claim.value
            default:
                break
            }
        }

        return Validation(
            displayNames: displayNames,
            labels: labels,
            displayNameRejections: displayRejections,
            labelRejections: labelRejections
        )
    }

    /// Resolves explicit hex, raw name, custom display name, semantic label, or bare hex.
    ///
    /// - Parameters:
    ///   - input: User-supplied color value.
    ///   - palette: Effective raw-name-to-hex palette.
    ///   - displayNames: Unvalidated custom display-name metadata.
    ///   - labels: Unvalidated semantic-label metadata.
    ///   - builtInNames: Stable built-in names.
    /// - Returns: A normalized hex when the input resolves unambiguously.
    public func resolve(
        _ input: String,
        palette: [String: String],
        displayNames: [String: String],
        labels: [String: String],
        builtInNames: Set<String>
    ) -> String? {
        if WorkspaceColorHex.isExplicitHex(input), let hex = WorkspaceColorHex.normalized(input) {
            return hex
        }

        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let hex = palette[trimmed] { return hex }

        let folded = trimmed.lowercased()
        let rawMatches = palette.filter { $0.key.lowercased() == folded }
        if rawMatches.count == 1 { return rawMatches.first?.value }
        if rawMatches.count > 1 { return nil }

        let validation = validate(
            rawDisplayNames: displayNames,
            rawLabels: labels,
            palette: palette,
            builtInNames: builtInNames
        )
        let aliasMatches = validation.displayNames
            .filter { $0.value.lowercased() == folded }
            .map(\.key)
            + validation.labels
                .filter { $0.value.lowercased() == folded }
                .map(\.key)
        guard aliasMatches.count <= 1 else { return nil }
        if let name = aliasMatches.first { return palette[name] }
        return WorkspaceColorHex.normalized(trimmed)
    }

    /// Builds effective menu and command entries in palette order.
    ///
    /// - Parameters:
    ///   - orderedNames: Stable raw names in display order.
    ///   - palette: Effective raw-name-to-hex palette.
    ///   - displayNames: Unvalidated custom display-name metadata.
    ///   - labels: Unvalidated semantic-label metadata.
    ///   - builtInNames: Stable built-in names.
    /// - Returns: Entries carrying only aliases that resolve unambiguously.
    public func effectiveEntries(
        orderedNames: [String],
        palette: [String: String],
        displayNames: [String: String],
        labels: [String: String],
        builtInNames: Set<String>
    ) -> [WorkspaceColorPaletteEntry] {
        let validation = validate(
            rawDisplayNames: displayNames,
            rawLabels: labels,
            palette: palette,
            builtInNames: builtInNames
        )
        return orderedNames.compactMap { name in
            guard let hex = palette[name] else { return nil }
            return WorkspaceColorPaletteEntry(
                name: name,
                hex: hex,
                label: validation.labels[name],
                customDisplayName: validation.displayNames[name]
            )
        }
    }
}
