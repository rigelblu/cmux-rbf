import CmuxSettings
import SwiftUI

/// The `Figma Default Folder` row: one text field for the folder link, with the
/// state in the row's one subtitle and **Open Folder in Figma** under the field.
///
/// **The row says what is stored, never what was sent.** Every decision is
/// ``FigmaDefaultFolderRowState`` in `CmuxSettings` (where `cmuxTests` runs it as
/// sequences), and "stored" is always `model.current`, passed in on each call. A save asks
/// the model to write and waits for `model.current` to change; if the write fails it
/// never changes, the house alert shows, and the subtitle keeps describing the old value.
///
/// The whole `SettingsCardRow` sits inside this view because its subtitle reads the
/// draft and the refusal, which the state struct holds.
///
/// Saving follows `WorkspaceColorsSection`: on Return, on leaving the field, and when the
/// row goes away (closing Settings with the caret in the field never reports a focus
/// change). Not on each keystroke: a half-typed link would be refused on every character.
///
/// An outside change (the command, a hand edit) updates the field only while the caret is
/// not in it, so a draft being typed is never replaced; the subtitle and the link follow
/// `model.current` either way.
@MainActor
struct FigmaDefaultFolderRow: View {
    let model: JSONValueModel<String>
    let controlWidth: CGFloat

    @State private var state: FigmaDefaultFolderRowState
    @FocusState private var isFocused: Bool

    init(model: JSONValueModel<String>, controlWidth: CGFloat) {
        self.model = model
        self.controlWidth = controlWidth
        // The model outlives this view when the section is scrolled or rebuilt,
        // so a new row starts from what it already holds.
        _state = State(initialValue: FigmaDefaultFolderRowState(stored: model.current))
    }

    private var title: String {
        String(localized: "settings.automation.figma.defaultFolder", defaultValue: "Figma Default Folder")
    }

    var body: some View {
        SettingsCardRow(
            configurationReview: .json("figma.defaultFolder"),
            title,
            subtitle: subtitle,
            controlWidth: controlWidth,
            verticalAlignment: .firstTextBaseline
        ) {
            VStack(alignment: .trailing, spacing: 4) {
                TextField(
                    String(
                        localized: "settings.automation.figma.defaultFolder.placeholder",
                        defaultValue: "Paste a folder link from Figma"
                    ),
                    text: $state.draft
                )
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit { commit() }
                .onChange(of: isFocused) { _, focused in
                    if !focused { commit() }
                }
                .accessibilityLabel(title)
                .accessibilityIdentifier("SettingsFigmaDefaultFolderField")

                if let url = state.openLink(stored: model.current) {
                    Link(
                        String(localized: "settings.automation.figma.defaultFolder.open", defaultValue: "Open Folder in Figma"),
                        destination: url
                    )
                    .cmuxFont(.caption)
                    .accessibilityIdentifier("SettingsFigmaDefaultFolderOpenLink")
                }
            }
        }
        // The model's first value arrives after the view is up, and an outside write
        // or our own write landing arrives at any time; all go through here.
        .onChange(of: model.current) { _, new in
            state.storedChanged(to: new, isFocused: isFocused)
        }
        // Teardown backstop. A view that is destroyed never reports a focus
        // change, so closing Settings with the caret in the field would lose the
        // draft (`WorkspaceColorsSection`, "Measured on the performClose path").
        .onDisappear {
            if state.hasUnsavedDraft { commit() }
        }
    }

    private func commit() {
        model.apply(state.commit(stored: model.current))
    }

    /// The one subtitle. The warning mark and its space are put here and are not
    /// part of any translated string; `Not saved.` is inside its two strings,
    /// because a joining space is wrong in Japanese, Chinese, Thai and Khmer.
    private var subtitle: String {
        let warning = "\u{26A0} "
        switch state.subtitle(stored: model.current) {
        case .notSet:
            return String(
                localized: "settings.automation.figma.defaultFolder.subtitle.notSet",
                defaultValue: "Not set. New designs your agent creates go to your Figma Drafts."
            )
        case .set(let folderId):
            return String(
                format: String(
                    localized: "settings.automation.figma.defaultFolder.subtitle.set",
                    defaultValue: "New designs your agent creates go to Figma folder %@."
                ),
                folderId
            )
        case .storedNoTeam:
            return warning + String(
                localized: "settings.automation.figma.defaultFolder.subtitle.noTeam",
                defaultValue: "This link has no team in it. Open it in your browser and copy the link from the address bar."
            )
        case .storedNotAFolder:
            return warning + String(
                localized: "settings.automation.figma.defaultFolder.subtitle.notAFolder",
                defaultValue: "This is not a link to a Figma folder. Copy the link from the folder's page in Figma."
            )
        case .notSavedNoTeam:
            return warning + String(
                localized: "settings.automation.figma.defaultFolder.subtitle.notSaved.noTeam",
                defaultValue: "Not saved. This link has no team in it. Open it in your browser and copy the link from the address bar."
            )
        case .notSavedNotAFolder:
            return warning + String(
                localized: "settings.automation.figma.defaultFolder.subtitle.notSaved.notAFolder",
                defaultValue: "Not saved. This is not a link to a Figma folder. Copy the link from the folder's page in Figma."
            )
        }
    }
}

extension JSONValueModel where Value == String {
    /// Asks the model to do what a save of the Figma row decided: store the link, or remove
    /// the key (never write `""`). Failures go to the model's error log, which shows the
    /// house alert; `current` changes only when the store confirms.
    ///
    /// - Parameter effect: The effect ``FigmaDefaultFolderRowState/commit(stored:)`` returned.
    func apply(_ effect: FigmaDefaultFolderRowState.Effect) {
        switch effect {
        case .none: break
        case .write(let link): set(link)
        case .remove: reset()
        }
    }
}
