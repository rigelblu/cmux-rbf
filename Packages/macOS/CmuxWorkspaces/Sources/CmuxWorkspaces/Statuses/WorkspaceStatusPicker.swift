/// One row of a status picker.
public struct WorkspaceStatusPickerRow: Equatable, Sendable, Identifiable {
    /// What a row is. The greyed row has no action, which is how the type says it cannot be chosen.
    public enum Kind: Equatable, Sendable {
        /// Auto. `detectedLabel` is what to draw for the status cmux detects: his word when his list names it,
        /// else cmux's own name. `returning` is true while a status is in effect: "return to".
        case auto(detected: WorkspaceTaskStatus, detectedLabel: WorkspaceStatusLabel, returning: Bool)
        /// One entry of the list. Draw its ``WorkspaceStatusEntry/label``.
        case status(WorkspaceStatusEntry)
        /// The greyed row for a held status the list does not offer. `label` is cmux's own name when the held
        /// status is one of cmux's five that the list leaves out (`cmuxStatus` is then set), and the id as he
        /// typed it when it is one of his own that the list lacks (`cmuxStatus` is `nil`).
        case held(label: WorkspaceStatusLabel, cmuxStatus: WorkspaceTaskStatus?)
        /// None.
        case hide
    }

    /// The id of the greyed row. It begins with a space: an id from the file is trimmed, so no id from the file
    /// can equal it, and `auto` and `none` (the ids of the other two rows) are reserved besides.
    public static let heldRowID = " held"

    public let id: String
    public let kind: Kind
    public let isChecked: Bool

    /// Creates a row.
    public init(id: String, kind: Kind, isChecked: Bool) {
        self.id = id
        self.kind = kind
        self.isChecked = isChecked
    }

    /// What choosing the row asks for. `nil` for the greyed row.
    public var action: WorkspaceStatusPickAction? {
        switch kind {
        case .auto: .auto
        case .status(let entry): .status(id: entry.id)
        case .held: nil
        case .hide: .hide
        }
    }

    /// What to draw for a status or the greyed row. `nil` for Auto and None, whose words the caller owns.
    public var label: WorkspaceStatusLabel? {
        switch kind {
        case .status(let entry): entry.label
        case .held(let label, _): label
        case .auto, .hide: nil
        }
    }

    /// The cmux status the row's glyph draws. `nil` for Auto, None, and the greyed row of a status the list
    /// does not have.
    public var glyph: WorkspaceTaskStatus? {
        switch kind {
        case .auto, .hide: nil
        case .status(let entry): entry.behavesAs
        case .held(_, let cmuxStatus): cmuxStatus
        }
    }

    /// The color as typed, for the dot. `nil` for every row but an entry with a color.
    public var color: String? {
        if case .status(let entry) = kind { return entry.color }
        return nil
    }
}

/// The rows every picker draws, as one value. A snapshot's `picker` holds it.
public struct WorkspaceStatusPickerState: Equatable, Sendable {
    public let rows: [WorkspaceStatusPickerRow]

    /// Creates the state.
    public init(rows: [WorkspaceStatusPickerRow]) {
        self.rows = rows
    }
}

/// Builds the rows of a status picker.
public struct WorkspaceStatusPicker: Sendable {
    /// Creates the picker.
    public init() {}

    /// Auto, one row for each entry in the file's order, at most one greyed row, and None.
    ///
    /// With cmux's five in use the rows are today's, one for one, and every label says to draw cmux's own name.
    ///
    /// - Parameters:
    ///   - resolution: What the workspace shows now.
    ///   - inferred: What cmux detects now.
    ///   - isHidden: Whether the workspace is on None.
    ///   - list: The list in use.
    public func rows(
        resolution: WorkspaceStatusResolution,
        inferred: WorkspaceTaskStatus,
        isHidden: Bool,
        list: WorkspaceStatusList
    ) -> WorkspaceStatusPickerState {
        var rows: [WorkspaceStatusPickerRow] = []

        // Auto: his word for the detected status when his list names it, else cmux's own name. "Return to" only
        // while a status is in effect, as today's popover has it.
        let detectedLabel = list.entry(id: inferred.rawValue)?.label ?? .cmux(inferred)
        rows.append(WorkspaceStatusPickerRow(
            id: "auto",
            kind: .auto(detected: inferred, detectedLabel: detectedLabel, returning: resolution.inEffect != nil),
            isChecked: !isHidden && resolution.held == nil
        ))

        for entry in list.entries {
            rows.append(WorkspaceStatusPickerRow(
                id: entry.id,
                kind: .status(entry),
                isChecked: !isHidden && resolution.inEffect?.id == entry.id
            ))
        }

        // The greyed row is checked like an entry's row: only when None is off.
        switch resolution {
        case .cmuxInEffect(let entry, offered: false):
            rows.append(WorkspaceStatusPickerRow(
                id: WorkspaceStatusPickerRow.heldRowID,
                kind: .held(label: .cmux(entry.behavesAs), cmuxStatus: entry.behavesAs),
                isChecked: !isHidden
            ))
        case .ownNotListed(let id, _):
            rows.append(WorkspaceStatusPickerRow(
                id: WorkspaceStatusPickerRow.heldRowID,
                kind: .held(label: .named(id), cmuxStatus: nil),
                isChecked: !isHidden
            ))
        default:
            break
        }

        rows.append(WorkspaceStatusPickerRow(id: "none", kind: .hide, isChecked: isHidden))
        return WorkspaceStatusPickerState(rows: rows)
    }
}
