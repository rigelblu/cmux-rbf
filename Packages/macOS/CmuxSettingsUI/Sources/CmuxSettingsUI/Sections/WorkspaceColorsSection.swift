import CmuxFoundation
import AppKit
import CmuxSettings
import SwiftUI

/// **Workspace Colors** section — mirrors the legacy in-app section:
/// indicator-style picker, selection highlight color, notification
/// badge color, then a per-palette-entry editor and a Reset Palette
/// action.
@MainActor
public struct WorkspaceColorsSection: View {
    private let jsonStore: JSONConfigStore
    private let catalog: SettingCatalog
    private let errorLog: SettingsErrorLog
    private let hostActions: SettingsHostActions

    @State private var selectionHex: DefaultsValueModel<String>
    @State private var badgeHex: DefaultsValueModel<String>
    @State private var paletteModel: DefaultsValueModel<[String: String]>
    /// Editable display names for custom entries, keyed by stable raw identity.
    @State private var displayNamesModel: DefaultsValueModel<[String: String]>
    /// Optional semantic labels keyed by raw palette name.
    @State private var labelsModel: DefaultsValueModel<[String: String]>
    /// Highest `Custom N` ever minted. This section writes the palette straight to
    /// defaults, bypassing the app target, so it must advance the mark itself or a
    /// removed custom name becomes reusable — taking its label and command ID with it.
    @State private var customNameHighWaterMark: DefaultsValueModel<Int>
    @State private var paletteReconcileTracker = WorkspacePaletteColorReconcileTracker()
    @State private var pendingColorEdit: WorkspacePaletteColorEditPreview?
    @State private var colorEditErrors: [String: String] = [:]

    /// Built-in palette order and default hexes. Mirrors
    /// `WorkspaceTabColorSettings.defaultPalette` in the legacy app target.
    /// Kept in this file so the section can render the full effective
    /// palette (built-ins + customs) with `Base:` subtitles and Remove
    /// gating without reaching outside the package.
    private static let builtInPalette: [(name: String, hex: String)] = [
        ("Red", "#C0392B"),
        ("Crimson", "#922B21"),
        ("Orange", "#A04000"),
        ("Amber", "#7D6608"),
        ("Olive", "#4A5C18"),
        ("Green", "#196F3D"),
        ("Teal", "#006B6B"),
        ("Aqua", "#0E6B8C"),
        ("Blue", "#1565C0"),
        ("Navy", "#1A5276"),
        ("Indigo", "#283593"),
        ("Purple", "#6A1B9A"),
        ("Magenta", "#AD1457"),
        ("Rose", "#880E4F"),
        ("Brown", "#7B3F00"),
        ("Charcoal", "#3E4B5E"),
    ]

    public init(
        defaultsStore: UserDefaultsSettingsStore,
        jsonStore: JSONConfigStore,
        catalog: SettingCatalog,
        errorLog: SettingsErrorLog,
        hostActions: SettingsHostActions
    ) {
        self.jsonStore = jsonStore
        self.catalog = catalog
        self.errorLog = errorLog
        self.hostActions = hostActions
        _selectionHex = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.workspaceColors.selectionColorHex))
        _badgeHex = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.workspaceColors.notificationBadgeColorHex))
        _paletteModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.workspaceColors.palette))
        _displayNamesModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.workspaceColors.displayNames))
        _labelsModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.workspaceColors.labels))
        _customNameHighWaterMark = State(
            initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.workspaceColors.customNameHighWaterMark)
        )
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.workspaceColors", defaultValue: "Workspace Colors"), section: .workspaceColors)
            mainCard
        }
        .task {
            startObservingSettings()
            paletteReconcileTracker.startTracking(effectivePaletteMap(stored: paletteModel.current))
        }
        .onChange(of: paletteModel.current) { _, newPalette in
            paletteReconcileTracker.reconcileExternalHexes(effectivePaletteMap(stored: newPalette))
            advanceCustomNameHighWaterMark(for: newPalette)
        }
        .confirmationDialog(
            colorEditConfirmationTitle,
            isPresented: Binding(
                get: { pendingColorEdit != nil },
                set: { if !$0 { pendingColorEdit = nil } }
            ),
            presenting: pendingColorEdit
        ) { preview in
            Button(String(localized: "settings.workspaceColors.edit.updateAssignments", defaultValue: "Update Assignments")) {
                applyColorEdit(preview, decision: .paletteAndAssignments)
            }
            Button(String(localized: "settings.workspaceColors.edit.paletteOnly", defaultValue: "Palette Only")) {
                applyColorEdit(preview, decision: .paletteOnly)
            }
            Button(String(localized: "alert.customColor.cancel", defaultValue: "Cancel"), role: .cancel) {
                paletteReconcileTracker.rejectPickerWrite(name: preview.paletteName)
                pendingColorEdit = nil
            }
        } message: { preview in
            Text(colorEditConfirmationMessage(preview))
        }
        .task {
            // Cover a palette that already contained Custom N entries before this section
            // was ever opened — Remove could otherwise free the highest name on first use.
            advanceCustomNameHighWaterMark(for: paletteModel.current)
        }
    }

    private func startObservingSettings() {
        let models: [any SettingObservationStarting] = [
            selectionHex,
            badgeHex,
            paletteModel,
            // Without these, a cmux.json reload would not refresh the label fields and the
            // mint mark could be read stale after an external palette write.
            labelsModel,
            displayNamesModel,
            customNameHighWaterMark,
        ]
        models.forEach { $0.startObserving() }
    }

    @ViewBuilder
    private var mainCard: some View {
        SettingsCard {
            colorRow(
                title: String(localized: "settings.workspaceColors.selectionColor", defaultValue: "Selection Highlight"),
                subtitle: String(localized: "settings.workspaceColors.selectionColor.subtitle", defaultValue: "Background color of the selected workspace in the sidebar."),
                json: "workspaceColors.selectionColor",
                resetLabel: String(localized: "settings.workspaceColors.selectionColor.reset", defaultValue: "Reset"),
                model: selectionHex
            )
            SettingsCardDivider()
            colorRow(
                title: String(localized: "settings.workspaceColors.notificationBadgeColor", defaultValue: "Notification Badge"),
                subtitle: String(localized: "settings.workspaceColors.notificationBadgeColor.subtitle", defaultValue: "Color of the unread notification badge on workspace tabs."),
                json: "workspaceColors.notificationBadgeColor",
                resetLabel: String(localized: "settings.workspaceColors.notificationBadgeColor.reset", defaultValue: "Reset"),
                model: badgeHex
            )
            SettingsCardDivider()

            SettingsCardNote(
                String(localized: "settings.workspaceColors.dictionaryNote", defaultValue: "Edit cmux.json to add or remove named colors. \"Choose Custom Color...\" still adds local Custom N entries.")
            )

            let entries = effectivePaletteEntries(overrides: paletteModel.current)
            if entries.isEmpty {
                SettingsCardNote(
                    String(localized: "settings.workspaceColors.emptyPalette", defaultValue: "No palette entries. Add colors in cmux.json or use \"Choose Custom Color...\" from a workspace context menu.")
                )
            } else {
                ForEach(Array(entries.enumerated()), id: \.element.name) { index, entry in
                    if index > 0 { SettingsCardDivider() }
                    paletteEntryRow(entry: entry, paletteModel: paletteModel)
                }
            }

            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .action,
                searchAnchorID: "setting:workspaceColors:palette",
                String(localized: "settings.workspaceColors.resetPalette", defaultValue: "Reset Palette"),
                subtitle: String(localized: "settings.workspaceColors.resetPalette.subtitleV2", defaultValue: "Restore the built-in palette and remove extra named colors.")
            ) {
                Button(String(localized: "settings.workspaceColors.resetPalette.button", defaultValue: "Reset")) {
                    paletteModel.reset()
                    displayNamesModel.reset()
                    pruneOrphanedMetadata(against: effectivePaletteMap(stored: [:]))
                    paletteReconcileTracker.recordPaletteReset(resultingHexes: effectivePaletteMap(stored: [:]))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    /// Raises the mint high-water mark to cover every `Custom N` in `palette`.
    ///
    /// Called from `onChange`/`task`, never from a body computation, so this cannot
    /// become a re-render feedback loop.
    private func advanceCustomNameHighWaterMark(for palette: [String: String]) {
        let highest = WorkspaceColorCustomNameMint.highestIndex(in: palette.keys)
        guard highest > customNameHighWaterMark.current else { return }
        customNameHighWaterMark.set(highest)
    }

    /// Names that currently resolve, and why any claimant was rejected.
    private func nameValidation(
        displayNames: [String: String]? = nil,
        labels: [String: String]? = nil
    ) -> WorkspaceColorNameResolver.Validation {
        let palette = effectivePaletteMap(stored: paletteModel.current)
        return WorkspaceColorNameResolver().validate(
            rawDisplayNames: displayNames ?? displayNamesModel.current,
            rawLabels: labels ?? labelsModel.current,
            palette: palette,
            builtInNames: Set(Self.builtInPalette.map(\.name))
        )
    }

    /// Stores a label, or removes it when cleared. Clearing restores the raw palette name.
    ///
    /// A commit for a palette name that no longer exists is dropped rather than written.
    /// A row can be torn down *because* its entry disappeared — **Reset Palette** or
    /// **Remove** while its field is focused — and the teardown commit would otherwise
    /// persist a label keyed to a colour nothing renders, where no `.unknownPaletteName`
    /// message can ever surface it. It would then silently reattach if a name with the
    /// same spelling ever returned.
    private func commitLabel(_ text: String, for paletteName: String) -> String? {
        guard effectivePaletteMap(stored: paletteModel.current)[paletteName] != nil else {
            return Self.aliasRejectionMessage(.unknownPaletteName)
        }
        var labels = labelsModel.current
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            labels.removeValue(forKey: paletteName)
        } else {
            labels[paletteName] = trimmed
        }
        if let rejection = nameValidation(labels: labels).labelRejections[paletteName] {
            return Self.aliasRejectionMessage(rejection)
        }
        labelsModel.set(labels)
        return nil
    }

    private func commitDisplayName(_ text: String, for paletteName: String) -> String? {
        guard effectivePaletteMap(stored: paletteModel.current)[paletteName] != nil,
              baseHex(for: paletteName) == nil else {
            return Self.aliasRejectionMessage(.builtInPaletteEntry)
        }
        var displayNames = displayNamesModel.current
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            displayNames.removeValue(forKey: paletteName)
        } else {
            displayNames[paletteName] = trimmed
        }
        if let rejection = nameValidation(displayNames: displayNames).displayNameRejections[paletteName] {
            return Self.aliasRejectionMessage(rejection)
        }
        displayNamesModel.set(displayNames)
        return nil
    }

    /// Drops label keys whose palette entry is gone.
    ///
    /// **Remove** and **Reset Palette** mutate `workspaceColors.colors` only, so a
    /// removed entry's label lingered in defaults indefinitely — invisible, because with
    /// no row there is nothing to render its rejection on — and silently reattached if
    /// that name ever came back. Monotonic minting covers `Custom N`, but a `cmux.json`
    /// entry removed and re-added by hand keeps its old meaning.
    private func pruneOrphanedMetadata(against palette: [String: String]) {
        let labels = labelsModel.current
        let survivors = labels.filter { palette[$0.key] != nil }
        if survivors.count != labels.count { labelsModel.set(survivors) }
        let displayNames = displayNamesModel.current
        let survivingDisplayNames = displayNames.filter { palette[$0.key] != nil && baseHex(for: $0.key) == nil }
        if survivingDisplayNames.count != displayNames.count {
            displayNamesModel.set(survivingDisplayNames)
        }
    }

    /// Why a label cannot be used, in the user's words.
    private static func aliasRejectionMessage(
        _ rejection: WorkspaceColorNameResolver.AliasRejection
    ) -> String {
        switch rejection {
        case .empty:
            return String(localized: "settings.workspaceColors.label.error.empty", defaultValue: "Enter a label or leave the field blank to use the color name.")
        case .tooLong:
            return String(
                format: String(
                    localized: "settings.workspaceColors.label.error.tooLong",
                    defaultValue: "Labels are limited to %lld characters."
                ),
                WorkspaceColorNameResolver.maximumAliasLength
            )
        case let .collidesWithAlias(otherName, _):
            return String(
                format: String(
                    localized: "settings.workspaceColors.label.error.duplicate",
                    defaultValue: "Already used by %@. Labels must be unique."
                ),
                otherName
            )
        case let .collidesWithRawName(name):
            return String(
                format: String(
                    localized: "settings.workspaceColors.label.error.collides",
                    defaultValue: "“%@” is already a color name. Choose different wording."
                ),
                name
            )
        case .unknownPaletteName:
            return String(localized: "settings.workspaceColors.label.error.unknown", defaultValue: "No color with this name exists.")
        case .builtInPaletteEntry:
            return String(localized: "settings.workspaceColors.label.error.unknown", defaultValue: "No color with this name exists.")
        }
    }

    @ViewBuilder
    private func colorRow(title: String, subtitle: String, json: String, resetLabel: String, model: DefaultsValueModel<String>) -> some View {
        let isCustom = !model.current.isEmpty
        SettingsCardRow(
            configurationReview: .json(json),
            title,
            subtitle: subtitle
        ) {
            HStack(spacing: 8) {
                if isCustom {
                    Button(resetLabel) { model.reset() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                HexColorPicker(
                    storedHex: model.current,
                    fallback: Self.cmuxAccentColor(),
                    reconcileRevision: model.revision
                ) { hex in
                    model.set(hex)
                }
                Text(isCustom ? model.current : String(localized: "settings.sidebarAppearance.defaultLabel", defaultValue: "Default"))
                    .cmuxFont(size: 12, weight: .medium, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .frame(width: 76, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private func paletteEntryRow(
        entry: (name: String, hex: String),
        paletteModel: DefaultsValueModel<[String: String]>
    ) -> some View {
        if let baseHex = baseHex(for: entry.name) {
            builtInPaletteEntryRow(entry: entry, baseHex: baseHex, paletteModel: paletteModel)
        } else {
            customPaletteEntryRow(entry: entry, paletteModel: paletteModel)
        }
    }

    private func builtInPaletteEntryRow(
        entry: (name: String, hex: String),
        baseHex: String,
        paletteModel: DefaultsValueModel<[String: String]>
    ) -> some View {
        let validation = nameValidation()
        return SettingsCardRow(
            configurationReview: .json("workspaceColors.colors", "workspaceColors.labels"),
            entry.name,
            subtitle: String(localized: "settings.workspaceColors.base", defaultValue: "Base: \(baseHex)")
        ) {
            HStack(spacing: 8) {
                WorkspaceColorAliasField(
                    paletteName: entry.name,
                    storedValue: labelsModel.current[entry.name] ?? "",
                    placeholder: String(localized: "settings.workspaceColors.label.placeholder", defaultValue: "Label"),
                    accessibilityLabel: String(
                        format: String(
                            localized: "settings.workspaceColors.label.accessibility",
                            defaultValue: "Label for %@"
                        ),
                        entry.name
                    ),
                    accessibilityIdentifier: "SettingsWorkspaceColorLabelField.\(entry.name)",
                    importedErrorMessage: validation.labelRejections[entry.name].map(Self.aliasRejectionMessage),
                    commit: { commitLabel($0, for: entry.name) }
                )
                HexColorPicker(
                    storedHex: entry.hex,
                    fallback: Color(nsColor: .systemBlue),
                    reconcileRevision: paletteReconcileTracker.revision(for: entry.name),
                    commitBehavior: .interactionEnd
                ) { hex in
                    requestBuiltInColorEdit(name: entry.name, proposedHex: hex)
                }
                VStack(alignment: .trailing, spacing: 2) {
                    Text(entry.hex)
                        .cmuxFont(size: 12, weight: .medium, design: .monospaced)
                        .foregroundStyle(.secondary)
                        .frame(width: 190, alignment: .trailing)
                    if let error = colorEditErrors[entry.name] {
                        Text(error)
                            .cmuxFont(size: 10, weight: .regular)
                            .foregroundStyle(.red)
                            .frame(width: 190, alignment: .trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func customPaletteEntryRow(
        entry: (name: String, hex: String),
        paletteModel: DefaultsValueModel<[String: String]>
    ) -> some View {
        let validation = nameValidation()
        return SettingsEditableTitleCardRow(
            configurationReview: .json(
                "workspaceColors.colors",
                "workspaceColors.displayNames",
                "workspaceColors.labels"
            ),
            subtitle: String(localized: "settings.workspaceColors.customEntry", defaultValue: "Named palette entry.")
        ) {
            WorkspaceColorAliasField(
                paletteName: entry.name,
                storedValue: displayNamesModel.current[entry.name] ?? "",
                placeholder: entry.name,
                accessibilityLabel: String(localized: "settings.workspaceColors.displayName.accessibility", defaultValue: "Custom color name"),
                accessibilityIdentifier: "SettingsWorkspaceColorDisplayNameField.\(entry.name)",
                importedErrorMessage: validation.displayNameRejections[entry.name].map(Self.aliasRejectionMessage),
                commit: { commitDisplayName($0, for: entry.name) }
            )
        } trailing: {
            HStack(spacing: 8) {
                WorkspaceColorAliasField(
                    paletteName: entry.name,
                    storedValue: labelsModel.current[entry.name] ?? "",
                    placeholder: String(localized: "settings.workspaceColors.label.placeholder", defaultValue: "Label"),
                    accessibilityLabel: String(
                        format: String(
                            localized: "settings.workspaceColors.label.accessibility",
                            defaultValue: "Label for %@"
                        ),
                        entry.name
                    ),
                    accessibilityIdentifier: "SettingsWorkspaceColorLabelField.\(entry.name)",
                    importedErrorMessage: validation.labelRejections[entry.name].map(Self.aliasRejectionMessage),
                    commit: { commitLabel($0, for: entry.name) }
                )
                HexColorPicker(
                    storedHex: entry.hex,
                    fallback: Color(nsColor: .systemBlue),
                    reconcileRevision: paletteReconcileTracker.revision(for: entry.name),
                    commitBehavior: .interactionEnd
                ) { hex in
                    requestColorEdit(name: entry.name, oldHex: entry.hex, proposedHex: hex)
                }
                WorkspaceColorHexField(
                    paletteName: entry.name,
                    storedHex: entry.hex,
                    reconcileRevision: paletteReconcileTracker.revision(for: entry.name),
                    errorMessage: colorEditErrors[entry.name],
                    commit: { requestColorEdit(name: entry.name, oldHex: entry.hex, proposedHex: $0) }
                )
                Button(String(localized: "settings.workspaceColors.remove", defaultValue: "Remove")) {
                    var snapshot = effectivePaletteMap(stored: paletteModel.current)
                    snapshot.removeValue(forKey: entry.name)
                    paletteModel.set(snapshot)
                    pruneOrphanedMetadata(against: snapshot)
                    colorEditErrors.removeValue(forKey: entry.name)
                    paletteReconcileTracker.reconcileExternalHexes(snapshot)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var colorEditConfirmationTitle: String {
        String(localized: "settings.workspaceColors.edit.confirmation.title", defaultValue: "Update existing assignments?")
    }

    private func colorEditConfirmationMessage(_ preview: WorkspacePaletteColorEditPreview) -> String {
        String(
            format: String(
                localized: "settings.workspaceColors.edit.confirmation.message",
                defaultValue: "Change %@ from %@ to %@? This value is used by %lld explicit workspaces and %lld explicit groups."
            ),
            preview.paletteName,
            preview.oldHex,
            preview.newHex,
            preview.workspaceCount,
            preview.groupCount
        )
    }

    private func requestColorEdit(name: String, oldHex: String, proposedHex: String) {
        colorEditErrors.removeValue(forKey: name)
        guard WorkspaceColorHex.normalized(oldHex) != WorkspaceColorHex.normalized(proposedHex) else { return }
        switch hostActions.previewWorkspacePaletteColorEdit(
            paletteName: name,
            expectedOldHex: oldHex,
            proposedHex: proposedHex
        ) {
        case .success(let preview) where preview.requiresConfirmation:
            pendingColorEdit = preview
        case .success(let preview):
            applyColorEdit(preview, decision: .paletteOnly)
        case .failure(let rejection):
            colorEditErrors[name] = Self.colorEditRejectionMessage(rejection)
            paletteReconcileTracker.rejectPickerWrite(name: name)
        }
    }

    private func requestBuiltInColorEdit(name: String, proposedHex: String) {
        colorEditErrors.removeValue(forKey: name)
        guard let normalized = WorkspaceColorHex.normalized(proposedHex) else {
            colorEditErrors[name] = Self.colorEditRejectionMessage(.invalidHex)
            paletteReconcileTracker.rejectPickerWrite(name: name)
            return
        }
        var snapshot = effectivePaletteMap(stored: paletteModel.current)
        if let duplicate = snapshot.first(where: { entry in
            entry.key != name && WorkspaceColorHex.normalized(entry.value) == normalized
        }) {
            colorEditErrors[name] = Self.colorEditRejectionMessage(
                .duplicatePaletteValue(paletteName: duplicate.key)
            )
            paletteReconcileTracker.rejectPickerWrite(name: name)
            return
        }
        snapshot[name] = normalized
        paletteModel.set(snapshot)
        paletteReconcileTracker.recordPickerWrite(name: name, resultingHexes: snapshot)
    }

    private func applyColorEdit(
        _ preview: WorkspacePaletteColorEditPreview,
        decision: WorkspacePaletteColorEditDecision
    ) {
        pendingColorEdit = nil
        switch hostActions.applyWorkspacePaletteColorEdit(preview, decision: decision) {
        case .applied(let palette):
            paletteModel.acceptCommittedValue(palette)
            paletteReconcileTracker.reconcileExternalHexes(palette)
            colorEditErrors.removeValue(forKey: preview.paletteName)
        case .stale:
            paletteReconcileTracker.rejectPickerWrite(name: preview.paletteName)
            colorEditErrors[preview.paletteName] = String(
                localized: "settings.workspaceColors.edit.error.stale",
                defaultValue: "This color changed elsewhere. Review the current value and try again."
            )
        case .rejected(let rejection):
            paletteReconcileTracker.rejectPickerWrite(name: preview.paletteName)
            colorEditErrors[preview.paletteName] = Self.colorEditRejectionMessage(rejection)
        case .failedRestored(let palette):
            paletteModel.acceptCommittedValue(palette)
            paletteReconcileTracker.reconcileExternalHexes(palette)
            paletteReconcileTracker.rejectPickerWrite(name: preview.paletteName)
            colorEditErrors[preview.paletteName] = String(
                localized: "settings.workspaceColors.edit.error.restored",
                defaultValue: "cmux couldn’t save the complete change, so it restored the previous colors."
            )
        case .failedUnrecovered(let palette):
            paletteModel.acceptCommittedValue(palette)
            paletteReconcileTracker.reconcileExternalHexes(palette)
            paletteReconcileTracker.rejectPickerWrite(name: preview.paletteName)
            colorEditErrors[preview.paletteName] = String(
                localized: "settings.workspaceColors.edit.error.unrecovered",
                defaultValue: "cmux couldn’t restore every color. Review the current values before continuing."
            )
        }
    }

    private static func colorEditRejectionMessage(_ rejection: WorkspacePaletteColorEditRejection) -> String {
        switch rejection {
        case .invalidHex:
            String(localized: "alert.invalidColor.emptyMessage", defaultValue: "Enter a hex color in the format #RRGGBB.")
        case .duplicatePaletteValue(let paletteName):
            String(
                format: String(
                    localized: "settings.workspaceColors.edit.error.duplicateHex",
                    defaultValue: "Already used by %@. Palette colors must be unique."
                ),
                paletteName
            )
        case .unavailablePaletteEntry:
            String(localized: "settings.workspaceColors.edit.error.stale", defaultValue: "This color changed elsewhere. Review the current value and try again.")
        case .staleValue:
            String(localized: "settings.workspaceColors.edit.error.stale", defaultValue: "This color changed elsewhere. Review the current value and try again.")
        }
    }

    /// Returns the effective palette entries: built-in entries first
    /// (in `builtInPalette` order, with overrides applied or default
    /// hex), followed by custom entries sorted by name. Mirrors
    /// `WorkspaceTabColorSettings.palette()`.
    private func effectivePaletteEntries(overrides: [String: String]) -> [(name: String, hex: String)] {
        let resolved = effectivePaletteMap(stored: overrides)
        let builtInNames = Set(Self.builtInPalette.map(\.name))
        let builtIn: [(name: String, hex: String)] = Self.builtInPalette.compactMap { entry in
            guard let hex = resolved[entry.name] else { return nil }
            return (name: entry.name, hex: hex)
        }
        let customs = resolved
            .filter { !builtInNames.contains($0.key) }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { (name: $0.key, hex: $0.value) }
        return builtIn + customs
    }

    /// Returns the full effective palette dictionary. When `stored` is
    /// empty (no UserDefaults entry yet) this is the built-in default
    /// palette; otherwise the stored map is returned verbatim. Matches
    /// legacy `WorkspaceTabColorSettings.effectivePaletteMap`.
    private func effectivePaletteMap(stored: [String: String]) -> [String: String] {
        if stored.isEmpty {
            return Dictionary(uniqueKeysWithValues: Self.builtInPalette.map { ($0.name, $0.hex) })
        }
        return stored
    }

    private func baseHex(for name: String) -> String? {
        Self.builtInPalette.first(where: { $0.name == name })?.hex
    }

    /// cmux-themed accent color used as the live ColorPicker fallback
    /// when the selection or notification badge has no custom hex.
    /// Mirrors the legacy `cmuxAccentColor()` helper (see
    /// `Sources/Sidebar/SidebarAppearanceSupport.swift`) so the rendered
    /// swatch matches the rest of the app instead of the system accent.
    private static func cmuxAccentColor() -> Color {
        let nsColor = NSColor(name: nil) { appearance in
            let bestMatch = appearance.bestMatch(from: [.darkAqua, .aqua])
            if bestMatch == .darkAqua {
                return NSColor(srgbRed: 0, green: 145.0 / 255.0, blue: 1.0, alpha: 1.0)
            }
            return NSColor(srgbRed: 0, green: 136.0 / 255.0, blue: 1.0, alpha: 1.0)
        }
        return Color(nsColor: nsColor)
    }
}

/// Editable custom display name or semantic label for one palette entry.
///
/// Keeps a local draft and commits on submit or when focus leaves, so a settings write
/// happens once per edit rather than once per keystroke. Invalid text stays visible and
/// editable — it simply never enters the effective resolver — because silently discarding
/// what someone typed is worse than showing why it cannot be used.
@MainActor
private struct WorkspaceColorAliasField: View {
    let paletteName: String
    let storedValue: String
    let placeholder: String
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let importedErrorMessage: String?
    let commit: (String) -> String?

    @State private var draft: String
    /// The value `draft` was last set *from* — an external label, or our own commit.
    ///
    /// `draft != storedLabel` cannot mean "the user typed", because `draft` is
    /// deliberately not synced while the field holds focus, so an external write moves
    /// `storedLabel` underneath an untouched draft. Comparing against what we last
    /// synced separates the two: only the user can make `draft` diverge from this.
    @State private var syncedValue: String
    @State private var localErrorMessage: String?
    @FocusState private var isFocused: Bool

    init(
        paletteName: String,
        storedValue: String,
        placeholder: String,
        accessibilityLabel: String,
        accessibilityIdentifier: String,
        importedErrorMessage: String?,
        commit: @escaping (String) -> String?
    ) {
        self.paletteName = paletteName
        self.storedValue = storedValue
        self.placeholder = placeholder
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityIdentifier = accessibilityIdentifier
        self.importedErrorMessage = importedErrorMessage
        self.commit = commit
        _draft = State(initialValue: storedValue)
        _syncedValue = State(initialValue: storedValue)
    }

    /// Commits `draft` and records what was written, so the same edit cannot commit twice.
    ///
    /// `commitLabel` trims; `draft` does not. Without folding the trimmed result back in,
    /// a submitted `"  GOAL: X  "` stayed untrimmed forever — `onChange(of: storedLabel)`
    /// is suppressed while focused — and that row re-committed on every later close.
    private func commitDraft() {
        guard draft != syncedValue else { return }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        localErrorMessage = commit(trimmed)
        guard localErrorMessage == nil else { return }
        draft = trimmed
        syncedValue = trimmed
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            TextField(
                placeholder,
                text: $draft
            )
            .textFieldStyle(.roundedBorder)
            .cmuxFont(size: 12, weight: .regular)
            .frame(width: 190)
            .focused($isFocused)
            .onSubmit { commitDraft() }
            .onChange(of: isFocused) { _, focused in
                if !focused { commitDraft() }
            }
            // An external edit (cmux.json reload, Reset Palette) wins over a stale draft
            // the user is not currently typing into.
            .onChange(of: storedValue) { _, newValue in
                if !isFocused {
                    draft = newValue
                    syncedValue = newValue
                    localErrorMessage = nil
                }
            }
            .onChange(of: draft) { _, _ in
                localErrorMessage = nil
            }
            // Teardown backstop. @FocusState reports focus *transitions*, and a view
            // that is destroyed never transitions — it just stops existing. Closing
            // Settings with the caret still in this field therefore never runs the
            // commit above, and the draft dies with the @State holding it.
            //
            // Measured on the performClose path Cmd-W drives: onChange(of: isFocused)
            // does not fire, onDisappear does. Reported from dogfood 2026-08-01, where
            // the only way to save a label was an undocumented blur-first gesture.
            //
            // The guard is `syncedValue`, not `storedLabel`. Comparing against
            // `storedLabel` looked equivalent and was the opposite of correct: because
            // `draft` is deliberately not synced while focused, an external write moves
            // `storedLabel` underneath an untouched draft, so the comparison read as a
            // user edit and the teardown committed a stale value *over* that write — or
            // resurrected a label the external edit had just deleted. `syncedValue` only
            // diverges when the user actually types.
            .onDisappear {
                if draft != syncedValue { commitDraft() }
            }
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier(accessibilityIdentifier)

            if let errorMessage = localErrorMessage ?? importedErrorMessage {
                Text(errorMessage)
                    .cmuxFont(size: 10, weight: .regular)
                    .foregroundStyle(.red)
                    .frame(width: 190, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Direct `#RRGGBB` editor that commits once on Return, blur, or teardown.
@MainActor
private struct WorkspaceColorHexField: View {
    let paletteName: String
    let storedHex: String
    let reconcileRevision: Int
    let errorMessage: String?
    let commit: (String) -> Void

    @State private var draft: String
    @State private var syncedValue: String
    @FocusState private var isFocused: Bool

    init(
        paletteName: String,
        storedHex: String,
        reconcileRevision: Int,
        errorMessage: String?,
        commit: @escaping (String) -> Void
    ) {
        self.paletteName = paletteName
        self.storedHex = storedHex
        self.reconcileRevision = reconcileRevision
        self.errorMessage = errorMessage
        self.commit = commit
        _draft = State(initialValue: storedHex)
        _syncedValue = State(initialValue: storedHex)
    }

    private func commitDraft() {
        guard draft != syncedValue else { return }
        commit(draft)
        syncedValue = draft
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            TextField("#RRGGBB", text: $draft)
                .textFieldStyle(.roundedBorder)
                .cmuxFont(size: 12, weight: .regular, design: .monospaced)
                .frame(width: 92)
                .focused($isFocused)
                .onSubmit { commitDraft() }
                .onChange(of: isFocused) { _, focused in
                    if !focused { commitDraft() }
                }
                .onChange(of: storedHex) { _, newValue in
                    if !isFocused {
                        draft = newValue
                        syncedValue = newValue
                    }
                }
                .onChange(of: reconcileRevision) { _, _ in
                    draft = storedHex
                    syncedValue = storedHex
                }
                .onDisappear {
                    if draft != syncedValue { commitDraft() }
                }
                .accessibilityLabel(
                    String(
                        format: String(
                            localized: "settings.workspaceColors.hex.accessibility",
                            defaultValue: "Hex color for %@"
                        ),
                        paletteName
                    )
                )
                .accessibilityIdentifier("SettingsWorkspaceColorHexField.\(paletteName)")

            if let errorMessage {
                Text(errorMessage)
                    .cmuxFont(size: 10, weight: .regular)
                    .foregroundStyle(.red)
                    .frame(width: 190, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
