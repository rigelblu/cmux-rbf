import AppKit
import CmuxWorkspaces
import Foundation

/// The words and the row adapter for the status pickers and the palette (#cm-109.2). Pure: a list or a picker state
/// goes in and values come out; nothing here reads the store.
enum WorkspaceStatusPresentation {
    /// A label as text: his word, or cmux's own localized name for a cmux status.
    static func text(_ label: WorkspaceStatusLabel) -> String {
        switch label {
        case .named(let word): word
        case .cmux(let status): status.displayName
        }
    }

    /// "Auto — return to {name}" while a status is in effect, else "Auto — {name}"; today's two forms, with the
    /// detected status named by his word when his list has one and by cmux's own name when it does not.
    static func autoTitle(detected: WorkspaceStatusLabel, returning: Bool) -> String {
        let name = text(detected)
        if returning {
            return String(
                format: String(
                    localized: "sidebar.status.autoReturn",
                    defaultValue: "Auto — return to %@"
                ),
                locale: .current,
                name
            )
        }
        return String(
            format: String(
                localized: "contextMenu.workspaceStatus.auto",
                defaultValue: "Auto — %@"
            ),
            locale: .current,
            name
        )
    }

    /// The name of the status a workspace shows, for the glyph's label and tooltip: the name on the picker's checked
    /// row of an entry (his word, or cmux's own name for a cmux status), or `nil` when no entry row is checked.
    static func checkedName(in picker: WorkspaceStatusPickerState?) -> String? {
        guard let picker else { return nil }
        for row in picker.rows where row.isChecked {
            if case .status(let entry) = row.kind { return text(entry.label) }
        }
        return nil
    }

    /// The color of a row's dot, worked out the way the Workspace Color menu works out its swatch.
    static func dotColor(hex: String, isDark: Bool) -> NSColor {
        WorkspaceTabColorSettings.displayNSColor(hex: hex, colorScheme: isDark ? .dark : .light, forceBright: false)
            ?? NSColor(hex: hex) ?? .gray
    }

    /// The greyed row's words: a status a workspace holds that the list does not have.
    static func notInListTitle(_ label: WorkspaceStatusLabel) -> String {
        String(
            format: String(
                localized: "sidebar.status.notInList",
                defaultValue: "%@ · not in your list"
            ),
            locale: .current,
            text(label)
        )
    }

    /// The palette's id for a status of the list in use. For cmux's five it is today's id.
    static func paletteStatusCommandID(_ id: String) -> String {
        "palette.workspaceStatus.\(id)"
    }

    /// "Workspace Status: {name}" for an entry, by his word or cmux's own name.
    static func paletteStatusTitle(_ entry: WorkspaceStatusEntry) -> String {
        String(
            format: String(
                localized: "command.workspaceStatus.title",
                defaultValue: "Workspace Status: %@"
            ),
            locale: .current,
            text(entry.label)
        )
    }
}

/// What the todo pane works out from the resolution (#cm-109): pure, so a test can call it. The pane's popover rows are
/// built with `isHidden: false`, as the release's popover hosts did (none of them passed the flag): a workspace on None
/// shows Auto checked there, as before.
struct WorkspaceStatusPaneState: Equatable {
    /// Whether a status is in effect and the controls are on (the glyph's "set manually").
    let hasOverride: Bool
    /// The cmux status in effect, which alone pins the popover's footnote (a status of his stays until he changes it).
    let cmuxOverride: WorkspaceTaskStatus?
    /// His word for the status in effect, when it has one; used for the header's label and the glyph's tooltip.
    let hisWord: String?
    /// The rows the popover draws.
    let picker: WorkspaceStatusPickerState

    static func make(
        resolution: WorkspaceStatusResolution,
        inferred: WorkspaceTaskStatus,
        list: WorkspaceStatusList,
        controlsEnabled: Bool
    ) -> Self {
        let cmuxOverride: WorkspaceTaskStatus?
        if case .cmuxInEffect(let entry, _) = resolution { cmuxOverride = entry.behavesAs } else { cmuxOverride = nil }
        let hisWord: String?
        if controlsEnabled, let entry = resolution.inEffect, case .named(let word) = entry.label {
            hisWord = word
        } else {
            hisWord = nil
        }
        return Self(
            hasOverride: controlsEnabled && resolution.inEffect != nil,
            cmuxOverride: cmuxOverride,
            hisWord: hisWord,
            picker: WorkspaceStatusPicker().rows(resolution: resolution, inferred: inferred, isHidden: false, list: list)
        )
    }
}

extension WorkspaceTodoStatusLane {
    /// The ordered rows of a picker, from the picker's state (#cm-109.2): Auto, one row for each entry of the list in
    /// the file's order, at most one greyed row, None. Each row carries the action a pick applies, which is empty for
    /// the greyed row, and the color the app resolved for its status (`colorHexes`, by id), if any.
    static func lanes(
        picker: WorkspaceStatusPickerState,
        colorHexes: [String: String] = [:]
    ) -> [WorkspaceTodoStatusLane] {
        picker.rows.map { row in
            switch row.kind {
            case .auto(_, let detectedLabel, let returning):
                return WorkspaceTodoStatusLane(
                    status: nil,
                    title: WorkspaceStatusPresentation.autoTitle(detected: detectedLabel, returning: returning),
                    isSelected: row.isChecked,
                    action: row.action
                )
            case .status(let entry):
                return WorkspaceTodoStatusLane(
                    status: row.glyph,
                    title: WorkspaceStatusPresentation.text(entry.label),
                    isSelected: row.isChecked,
                    action: row.action,
                    colorHex: colorHexes[entry.id]
                )
            case .held(let label, _):
                return WorkspaceTodoStatusLane(
                    status: row.glyph,
                    title: WorkspaceStatusPresentation.notInListTitle(label),
                    isSelected: row.isChecked,
                    action: nil
                )
            case .hide:
                return WorkspaceTodoStatusLane(
                    status: nil,
                    title: String(localized: "sidebar.status.none", defaultValue: "None (hide status)"),
                    isSelected: row.isChecked,
                    action: row.action,
                    isNone: true
                )
            }
        }
    }
}
