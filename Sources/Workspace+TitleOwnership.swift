import CmuxCloud
import Foundation
import CmuxTerminalCore

/// Title and description ownership: which of the process title, the custom
/// title, and the custom description a workspace presents, who set them, and
/// how automatic process-title changes reach the sidebar's settled
/// observation stream.
extension Workspace {
    // MARK: - Title Management

    /// Direct cmux names outrank agent-session and automatic names. A remote
    /// daemon observation is authoritative for a cloud-bound projection and
    /// may replace a local title after another client changes the daemon name.
    /// Provenance round-trips through session persistence.
    enum CustomTitleSource: String, Codable, Sendable {
        case user
        case agentSession
        case auto
        case remote

        func canReplace(_ existing: CustomTitleSource?) -> Bool {
            switch self {
            case .user:
                return true
            case .agentSession:
                return existing != .user && existing != .remote
            case .auto:
                return existing == nil || existing == .auto
            case .remote:
                return true
            }
        }

        /// Whether this source may clear a title it owns.
        ///
        /// Only the user clears a title. An automatic namer producing an empty
        /// string must not wipe the label the user is reading, and Codex offers
        /// no way to clear a thread name — a bare `/rename` opens a prompt
        /// pre-filled with the current name (verified against Codex 0.146.0 on
        /// 2026-07-31), so an explicit agent clear has no gesture to mirror.
        ///
        /// If Codex ever gains one — a bare `/rename` that empties the name, or
        /// a `/rename --clear` — add `.agentSession` here. The typed-input line
        /// already sees the exact submitted text, so detecting it is small.
        var canClearOwnTitle: Bool {
            switch self {
            case .user:
                return true
            case .auto, .agentSession:
                return false
            case .remote:
                return true
            }
        }

        /// Session manifests are also read by older cmux builds. Those builds
        /// know `user` and `auto`, but not `remote`. Decode unknown values as
        /// user-owned so a newer source can never make an older title unsafe
        /// to overwrite. New session snapshots carry a separate compatibility
        /// marker when the source is remote and encode this field as `user`.
        init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: value) ?? .user
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            // `remote` is represented by the optional snapshot marker. Keeping
            // this enum value in the old vocabulary makes downgrade restores
            // safe instead of making the whole manifest unreadable.
            try container.encode(self == .remote ? Self.user.rawValue : rawValue)
        }
    }

    var hasCustomTitle: Bool {
        let trimmed = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !trimmed.isEmpty
    }

    /// The provenance of the current custom title, normalizing legacy state:
    /// `nil` when no custom title is set; `.user` when a title exists but
    /// provenance was never recorded (pre-provenance snapshots, carried moves).
    var effectiveCustomTitleSource: CustomTitleSource? {
        hasCustomTitle ? (customTitleSource ?? .user) : nil
    }

    var hasCustomDescription: Bool {
        Self.normalizedCustomDescription(customDescription) != nil
    }

    func applyProcessTitle(_ title: String) {
        guard let stableTitle = AutomaticTerminalTitle(title)?.value else {
            return
        }
        applyResolvedProcessTitle(stableTitle)
    }

    private func applyResolvedProcessTitle(_ title: String) {
        if processTitle != title { processTitle = title }
        guard customTitle == nil, self.title != title else { return }
#if DEBUG
        cmuxDebugLog(
            "workspace.title.applyProcess workspace=\(id.uuidString.prefix(5)) " +
            "from=\"\(debugWorkspaceDescriptionPreview(self.title, limit: 80))\" " +
            "to=\"\(debugWorkspaceDescriptionPreview(title, limit: 80))\""
        )
#endif
        applyAutomaticTitle(title)
    }

    /// Restores the workspace title after panel metadata has been rebuilt.
    ///
    /// The snapshot process title remains the compatibility fallback, but a
    /// successfully restored focused panel is the authoritative source for a
    /// local workspace's automatic title. This prevents a restored terminal's
    /// startup command from replacing friendlier panel metadata persisted in
    /// the same snapshot.
    func restoreTitleState(
        from snapshot: SessionWorkspaceSnapshot,
        restoredPanelIds: [UUID: UUID]
    ) {
        applyProcessTitle(snapshot.processTitle)
        if let persistedPanelId = snapshot.focusedPanelId,
           let restoredPanelId = restoredPanelIds[persistedPanelId] {
            applyFocusedPanelTitle(panelId: restoredPanelId, requiresFocus: false)
        }
        setCustomTitle(
            snapshot.customTitle,
            source: snapshot.customTitleAuthority ?? snapshot.effectiveCustomTitleSource ?? .user
        )
    }

    /// Reconciles a local workspace's automatic title with the resolved title
    /// of its focused panel. Resolved panel titles include intentional surface
    /// names, so later raw OSC title events cannot replace a friendly surface
    /// name with the serialized command that launched a resumed agent.
    ///
    /// An agent-named panel is the one title that does *not* reconcile. A Codex
    /// session names its own tab and nothing around it, so a session `#cm-9`
    /// already ruled ineligible for the workspace title cannot reach that title
    /// anyway through the panel it *is* allowed to rename. A name the user or
    /// the process put on the panel still fills in an unnamed workspace.
    ///
    /// The check lives here rather than at the call sites because four paths
    /// reach this helper with a possibly agent-owned panel title — both
    /// branches of `setPanelCustomTitle`, snapshot restore, and focused-surface
    /// transfer — and a guard written into one entrypoint is not inherited by
    /// the next.
    @discardableResult
    func applyFocusedPanelTitle(panelId: UUID, requiresFocus: Bool = true) -> Bool {
        guard !isRemoteTmuxMirror,
              !requiresFocus || focusedPanelId == panelId,
              !panelTitleIsAgentOwned(panelId: panelId),
              let resolvedTitle = panelTitle(panelId: panelId)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !resolvedTitle.isEmpty else {
            return false
        }
        let previousProcessTitle = processTitle
        let previousTitle = title
        // A custom panel name is authored metadata even when it supplies the
        // workspace's automatic display tier. Preserve it and non-terminal titles.
        if panelCustomTitles[panelId] != nil || panels[panelId]?.panelType != .terminal {
            applyResolvedProcessTitle(resolvedTitle)
        } else {
            applyProcessTitle(resolvedTitle)
        }
        return processTitle != previousProcessTitle || title != previousTitle
    }

    /// Whether the panel's visible name was written by an agent session.
    ///
    /// Mirrors `resolvedPanelTitle`: only a non-empty custom title counts,
    /// because that is the only case where the panel shows something other than
    /// its own process or display title. A custom title carrying no recorded
    /// source reads as the user's, matching how panel ownership resolves
    /// everywhere else.
    private func panelTitleIsAgentOwned(panelId: UUID) -> Bool {
        guard let custom = panelCustomTitles[panelId]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !custom.isEmpty else {
            return false
        }
        return (panelCustomTitleSources[panelId] ?? .user) == .agentSession
    }

    /// The single write path for automatic (non-user) workspace titles.
    /// Every mutation of `title` that does not come from a custom-title edit
    /// must go through here: the sidebar's settled observation stream only
    /// sees changes signaled at this chokepoint, and a writer that sets
    /// `title` directly leaves rows permanently stale (updatePanelTitle's
    /// single-panel branch did exactly that).
    func applyAutomaticTitle(_ title: String) {
        guard self.title != title else { return }
        withAutomaticTitleMutation {
            self.title = title
        }
        sidebarProcessTitleObservation.processTitleDidChange()
    }

    /// Applies a terminal title.
    ///
    /// `title` is the frame the terminal just emitted; `stableTitle` is that
    /// frame with any spinner glyph removed, so consecutive animation ticks
    /// share one. The tab label always takes `title`, which keeps the spinner
    /// animating. Everything else keys off `stableTitle`, so an advancing
    /// spinner never writes `@Published` state, never reaches the sidebar's
    /// observation stream, and never refreshes the titlebar.
    ///
    /// Returns whether anything beyond the tab label changed. Callers that pass
    /// no `stableTitle` (socket and restore paths) also get `true` when only the
    /// tab label was reconciled, matching the pre-spinner-split contract.
    @discardableResult
    func updatePanelTitle(panelId: UUID, title: String, stableTitle: String? = nil) -> Bool {
        let remote = cloudProjectedResource(forPanel: panelId).flatMap { $0.kind == .terminal ? $0 : nil }
        let candidate = remote?.cloudProcessDisplayTitle ?? title
        let admitted = panels[panelId]?.panelType == .terminal
            ? AutomaticTerminalTitle(candidate)?.value : candidate
        guard let admitted else { return false }
        let trimmed = admitted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, panels[panelId] != nil else { return false }
        guard remote != nil || shouldApplyRestoredPanelTitle(panelId: panelId, rawTitle: trimmed) else {
            return false
        }
        // A cloud-projected terminal displays the cloud process title, so the
        // local PTY's stable title must not leak into panelTitles or the
        // workspace title there.
        let trimmedStable = remote == nil
            ? stableTitle?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let stable = trimmedStable.flatMap { $0.isEmpty ? nil : $0 } ?? trimmed

        // Runs on every frame, which is what keeps the animation. It still
        // invalidates the tab bar's own SwiftUI subtree; what it avoids is the
        // app-wide cascade below.
        let didRefreshTabLabel = refreshTabLabel(panelId: panelId, displayTitle: trimmed)

        // Only the spinner advanced. Everything below either writes @Published
        // state or signals the sidebar chokepoint, and all of it would land on
        // the same values it already holds.
        guard !isRemoteTmuxMirror, panelTitles[panelId] != stable else {
            return stableTitle == nil && didRefreshTabLabel
        }

        var didMutateWorkspaceTitle = false
        panelTitles[panelId] = stable

        if !isRemoteTmuxMirror {
            syncTerminalTabAgentIconAsset(forPanelId: panelId)
        }

        let previousWorkspaceTitle = self.title
        if applyFocusedPanelTitle(panelId: panelId) {
            didMutateWorkspaceTitle = self.title != previousWorkspaceTitle
        }

#if DEBUG
        cmuxDebugLog(
            "workspace.title.updatePanel workspace=\(id.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) panels=\(panels.count) custom=\(customTitle == nil ? 0 : 1) " +
            "panelChanged=1 workspaceChanged=\(didMutateWorkspaceTitle ? 1 : 0) " +
            "title=\"\(debugWorkspaceDescriptionPreview(stable, limit: 80))\""
        )
#endif
        return true
    }

    /// Pushes a title straight to the Bonsplit tab model without touching
    /// `panelTitles` or the workspace title, so an animation frame reaches the
    /// tab label without waking the sidebar, the titlebar, or the App body.
    ///
    /// Bonsplit observes the tab item itself, so this title-only update reaches
    /// the affected tab view without re-rendering the entire tab bar.
    @discardableResult
    private func refreshTabLabel(panelId: UUID, displayTitle: String) -> Bool {
        guard !isRemoteTmuxMirror,
              let tabId = surfaceIdFromPanelId(panelId),
              let existing = bonsplitController.tab(tabId) else { return false }
        let resolvedTitle = resolvedPanelTitle(panelId: panelId, fallback: displayTitle)
        let titleUpdate: String? = existing.title == resolvedTitle ? nil : resolvedTitle
        let hasCustomTitle = panelCustomTitles[panelId] != nil
        guard titleUpdate != nil || existing.hasCustomTitle != hasCustomTitle else { return false }
        bonsplitController.updateTab(
            tabId,
            title: titleUpdate,
            hasCustomTitle: hasCustomTitle
        )
        return true
    }

    private static func normalizedCustomDescription(_ description: String?) -> String? {
        let normalizedLineEndings = description?
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let trimmed = normalizedLineEndings?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return normalizedLineEndings
    }

    /// Sets, replaces, or clears (empty/nil `title`) the workspace custom title.
    ///
    /// Lower-priority writes are rejected. A remote daemon observation may
    /// replace a local title; automatic writes never clear an existing title.
    /// Returns whether the write landed.
    @discardableResult
    func setCustomTitle(_ title: String?, source: CustomTitleSource = .user) -> Bool {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if source != .user {
            if trimmed.isEmpty {
                guard source.canClearOwnTitle,
                      effectiveCustomTitleSource == source else { return false }
            } else {
                guard source.canReplace(effectiveCustomTitleSource) else { return false }
            }
        }
        if trimmed.isEmpty {
            if customTitle != nil {
                sidebarProcessTitleObservation.cancelPendingProcessTitleChange()
            }
            customTitle = nil
            customTitleSource = nil
            self.title = processTitle
        } else {
            sidebarProcessTitleObservation.cancelPendingProcessTitleChange()
            customTitle = trimmed
            customTitleSource = source
            self.title = trimmed
        }
#if DEBUG
        cmuxDebugLog(
            "workspace.customTitle.write workspace=\(id.uuidString.prefix(8)) " +
            "source=\(source) title=\"\(debugWorkspaceDescriptionPreview(trimmed, limit: 40))\""
        )
#endif
        return true
    }

    /// Shared title mutation for an explicit Codex `/rename`, used by normal
    /// terminal Codex, embedded Codex, and Codex Teams alike so rename
    /// behavior never depends on how the session was launched.
    ///
    /// Workspace and panel ownership are independent: a direct cmux name
    /// blocks only the title it owns, and clearing it lets the next explicit
    /// Codex name land. A `nil` or blank `title` clears nothing: `canClearOwnTitle`
    /// is `true` only for `.user`, so an agent cannot clear its own title. The
    /// optional stays in the signature for the day Codex grows a real clear.
    ///
    /// - Parameter workspaceEligible: Whether this session may claim the
    ///   workspace title. Adapters pass `false` when the session is not the
    ///   workspace's sole live agent session, which keeps a sibling terminal
    ///   session or a Teams subagent to its own tab.
    @discardableResult
    func applyCodexSessionName(
        _ title: String?,
        panelId: UUID?,
        workspaceEligible: Bool
    ) -> (workspaceApplied: Bool, panelApplied: Bool?) {
        let workspaceApplied = workspaceEligible
            && setCustomTitle(title, source: .agentSession)
        let panelApplied = panelId.map {
            setPanelCustomTitle(panelId: $0, title: title, source: .agentSession)
        }
        return (workspaceApplied, panelApplied)
    }

    func setCustomDescription(_ description: String?) {
        let normalizedDescription = Self.normalizedCustomDescription(description)
#if DEBUG
        let inputNewlines = description?.reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        } ?? 0
        let normalizedNewlines = normalizedDescription?.reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        } ?? 0
        cmuxDebugLog(
            "workspace.customDescription.update workspace=\(id.uuidString.prefix(8)) " +
            "inputLen=\((description as NSString?)?.length ?? 0) " +
            "inputNewlines=\(inputNewlines) " +
            "normalizedLen=\((normalizedDescription as NSString?)?.length ?? 0) " +
            "normalizedNewlines=\(normalizedNewlines) " +
            "input=\"\(debugWorkspaceDescriptionPreview(description))\" " +
            "normalized=\"\(debugWorkspaceDescriptionPreview(normalizedDescription))\""
        )
#endif
        guard customDescription != normalizedDescription else { return }
        bumpCustomDescriptionRevision()
        customDescription = normalizedDescription
    }
}
