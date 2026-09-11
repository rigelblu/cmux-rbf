import CmuxFoundation
import CmuxSettings
import Foundation
import SwiftUI

/// **Reply** section — the Reply panel's quick labels (`cm-69.3`, board `N13`).
///
/// One editable row per label, in order. Above a note the panel shows as many
/// as fit its width as chips and puts the rest in its `⌄` menu, so where the
/// split falls depends on the panel, not on this list — the note says so, and
/// the list carries no group labels (Tom, 2026-09-11).
///
/// **A Settings edit outranks `cmux.json`**, as everywhere in Settings: the
/// store ranks the user's choice over the file's imported value, and a file
/// value re-applies only when the file changes.
@MainActor
public struct ReplySection: View {
    @State private var labels: DefaultsValueModel<[String]>

    /// The rows as typed. Every edit is saved through the same normaliser the
    /// file uses — so a blank row never becomes an empty chip — and the rows
    /// themselves are tidied only once no field is being typed into.
    @State private var drafts: [String]
    @FocusState private var focusedRow: Int?

    /// Creates the Reply settings section.
    ///
    /// - Parameters:
    ///   - defaultsStore: The store the labels are read from and written to.
    ///   - catalog: The catalog that provides `reply.labels`.
    public init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        let model = DefaultsValueModel(store: defaultsStore, key: catalog.reply.labels)
        _labels = State(initialValue: model)
        _drafts = State(initialValue: model.current)
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.reply", defaultValue: "Reply"), section: .reply)
            Text(String(localized: "settings.reply.quickLabels.header", defaultValue: "Quick Labels"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
            SettingsCard {
                SettingsCardNote(
                    String(localized: "settings.reply.quickLabels.note", defaultValue: "Click a label to put its text in your note. Labels show in this order; any that don't fit go in the ⌄ menu.")
                )
                if drafts.isEmpty {
                    SettingsCardNote(
                        String(localized: "settings.reply.quickLabels.empty", defaultValue: "No labels — add one, or Reset to get the built-in labels back.")
                    )
                } else {
                    ForEach(drafts.indices, id: \.self) { index in
                        SettingsCardDivider()
                        labelRow(index)
                    }
                }
                SettingsCardDivider()
                addRow
                SettingsCardDivider()
                resetRow
            }
            Text(String(localized: "settings.reply.quickLabels.jsonHint", defaultValue: "Also settable as reply.labels in cmux.json."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
        }
        .task { labels.startObserving() }
        // A write from elsewhere — `cmux.json`, or Reset — replaces the rows,
        // but never while one is being typed into.
        .onChange(of: labels.current) { stored in
            if focusedRow == nil, stored != drafts { drafts = stored }
        }
        // Saved as typed, like every other Settings field. Saving only on
        // Return or focus-leave lost the edit when the window closed with the
        // field still focused (Tom, dogfood 2026-09-11) — closing a window
        // moves no focus, so neither trigger ever fired.
        // Save only, no tidying: `Add Label` appends a blank row a pass before
        // it focuses it, and tidying here would delete it before it's typed in.
        .onChange(of: drafts) { _ in commit(tidy: false) }
        .onChange(of: focusedRow) { [focusedRow] _ in
            if focusedRow != nil { commit() }
        }
    }

    private func labelRow(_ index: Int) -> some View {
        SettingsEditableTitleCardRow(configurationReview: .json("reply.labels"), subtitle: nil) {
            TextField("", text: Binding(
                get: { drafts.indices.contains(index) ? drafts[index] : "" },
                set: { if drafts.indices.contains(index) { drafts[index] = $0 } }
            ))
            .textFieldStyle(.roundedBorder)
            .focused($focusedRow, equals: index)
            .onSubmit { commit() }
            .accessibilityLabel(String(localized: "settings.reply.quickLabels.field.accessibility", defaultValue: "Label"))
        } trailing: {
            HStack(spacing: 6) {
                Button { move(index, by: -1) } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(.borderless)
                    .disabled(index == 0)
                    .accessibilityLabel(String(localized: "settings.reply.quickLabels.moveUp.accessibility", defaultValue: "Move up"))
                Button { move(index, by: 1) } label: { Image(systemName: "arrow.down") }
                    .buttonStyle(.borderless)
                    .disabled(index == drafts.count - 1)
                    .accessibilityLabel(String(localized: "settings.reply.quickLabels.moveDown.accessibility", defaultValue: "Move down"))
                Button(String(localized: "settings.reply.quickLabels.remove", defaultValue: "Remove")) {
                    focusedRow = nil
                    drafts.remove(at: index)
                    commit()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var addRow: some View {
        HStack {
            Button(String(localized: "settings.reply.quickLabels.add", defaultValue: "Add Label")) {
                drafts.append("")
                // The row's field does not exist until the next pass, and
                // focus set on a field that does not exist is dropped silently.
                let newRow = drafts.count - 1
                DispatchQueue.main.async { focusedRow = newRow }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var resetRow: some View {
        SettingsCardRow(
            configurationReview: .action,
            searchAnchorID: "setting:reply:quick-labels",
            String(localized: "settings.reply.quickLabels.reset.title", defaultValue: "Reset Labels"),
            subtitle: String(localized: "settings.reply.quickLabels.reset.subtitle", defaultValue: "Restore the built-in labels.")
        ) {
            Button(String(localized: "settings.reply.quickLabels.reset.button", defaultValue: "Reset")) {
                // Written as a choice, not a cleared override: clearing falls
                // back to `cmux.json` when it sets labels, so Reset showed the
                // file's list under a row promising the built-in labels (Tom,
                // dogfood 2026-09-11). As a choice it outranks the file until
                // the file next changes, like any other Settings edit.
                focusedRow = nil
                drafts = ReplyCatalogSection.defaultLabels
                labels.set(ReplyCatalogSection.defaultLabels)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard drafts.indices.contains(index), drafts.indices.contains(target) else { return }
        focusedRow = nil
        drafts.swapAt(index, target)
        commit()
    }

    /// Saves the rows as the label list, dropping blanks; with `tidy`, also
    /// drops them from the rows once no field is being typed into.
    private func commit(tidy: Bool = true) {
        let cleaned = ReplyCatalogSection.normalizedLabels(drafts)
        if cleaned != labels.current { labels.set(cleaned) }
        if tidy, focusedRow == nil, cleaned != drafts { drafts = cleaned }
    }
}
