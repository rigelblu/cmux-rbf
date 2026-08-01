import Foundation

/// Title and description ownership: which of the process title, the custom
/// title, and the custom description a workspace presents, who set them, and
/// how automatic process-title changes reach the sidebar's settled
/// observation stream.
extension Workspace {
    // MARK: - Title Management

    /// Who set a custom title. Direct cmux names outrank explicit agent-session
    /// names, which outrank automatic names. The provenance round-trips through
    /// session persistence for both workspace and panel custom titles.
    enum CustomTitleSource: String, Codable, Sendable {
        case user
        case agentSession
        case auto

        func canReplace(_ existing: CustomTitleSource?) -> Bool {
            switch self {
            case .user:
                return true
            case .agentSession:
                return existing != .user
            case .auto:
                return existing == nil || existing == .auto
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
            }
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
        if processTitle != title {
            processTitle = title
        }
        guard customTitle == nil else { return }
        guard self.title != title else { return }
#if DEBUG
        cmuxDebugLog(
            "workspace.title.applyProcess workspace=\(id.uuidString.prefix(5)) " +
            "from=\"\(debugWorkspaceDescriptionPreview(self.title, limit: 80))\" " +
            "to=\"\(debugWorkspaceDescriptionPreview(title, limit: 80))\""
        )
#endif
        applyAutomaticTitle(title)
    }

    /// The single write path for automatic (non-user) workspace titles.
    /// Every mutation of `title` that does not come from a custom-title edit
    /// must go through here: the sidebar's settled observation stream only
    /// sees changes signaled at this chokepoint, and a writer that sets
    /// `title` directly leaves rows permanently stale (updatePanelTitle's
    /// single-panel branch did exactly that).
    func applyAutomaticTitle(_ title: String) {
        guard self.title != title else { return }
        self.title = title
        sidebarProcessTitleObservation.processTitleDidChange()
    }

    @discardableResult
    func updatePanelTitle(panelId: UUID, title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, panels[panelId] != nil else { return false }
        var didMutate = false
        var didMutatePanelTitle = false
        var didMutateWorkspaceTitle = false

        if !isRemoteTmuxMirror, panelTitles[panelId] != trimmed {
            panelTitles[panelId] = trimmed
            didMutate = true
            didMutatePanelTitle = true
        }

        if didMutatePanelTitle,
           let tabId = surfaceIdFromPanelId(panelId),
           let panel = panels[panelId],
           let existing = bonsplitController.tab(tabId) {
            let baseTitle = panelTitles[panelId] ?? panel.displayTitle
            let resolvedTitle = resolvedPanelTitle(panelId: panelId, fallback: baseTitle)
            let titleUpdate: String? = existing.title == resolvedTitle ? nil : resolvedTitle
            let hasCustomTitle = panelCustomTitles[panelId] != nil
            if titleUpdate != nil || existing.hasCustomTitle != hasCustomTitle {
                bonsplitController.updateTab(
                    tabId,
                    title: titleUpdate,
                    hasCustomTitle: hasCustomTitle
                )
            }
        }

        if !isRemoteTmuxMirror, panels.count == 1, customTitle == nil {
            if self.title != trimmed {
                applyAutomaticTitle(trimmed)
                didMutate = true
                didMutateWorkspaceTitle = true
            }
            if processTitle != trimmed {
                processTitle = trimmed
            }
        }

#if DEBUG
        if didMutate {
            cmuxDebugLog(
                "workspace.title.updatePanel workspace=\(id.uuidString.prefix(5)) " +
                "panel=\(panelId.uuidString.prefix(5)) panels=\(panels.count) custom=\(customTitle == nil ? 0 : 1) " +
                "panelChanged=\(didMutatePanelTitle ? 1 : 0) workspaceChanged=\(didMutateWorkspaceTitle ? 1 : 0) " +
                "title=\"\(debugWorkspaceDescriptionPreview(trimmed, limit: 80))\""
            )
        }
#endif
        return didMutate
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
    /// Lower-priority writes are rejected, and non-user sources never clear —
    /// an empty write from an agent or an automatic namer leaves the existing
    /// title alone rather than wiping the label the user is reading.
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
    /// Codex name land. A `nil` or blank `title` is a proven explicit clear.
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
        customDescription = normalizedDescription
    }
}
