import CmuxSidebar
import CmuxWorkspaces
import Foundation

/// Workspace-level todo logic: sampling the live signals that drive
/// task-status inference, resolving the effective status against the manual
/// override, and the shared checklist mutation entry points used by the
/// socket verbs, the CLI, and the sidebar UI.
extension Workspace {
    // MARK: - Status signals

    /// Samples the live signals that drive task-status inference: agent
    /// lifecycle states (needs-input / running) for panels that still exist,
    /// the sidebar pull-request rows, and git working-tree dirtiness.
    ///
    /// Takes the panel order **once** and hands it to both sidebar queries.
    /// Each of them otherwise calls `sidebarOrderedPanelIds()` itself, and that
    /// is not a cheap read — it snapshots the bonsplit tree and builds a
    /// dictionary per pane, so the no-argument forms sampled it twice per call.
    /// `#cm-28` made this path hotter (the sidebar now resolves shortcut
    /// eligibility for every workspace on every render pass, on top of the
    /// per-row sampling that was already there), which is what surfaced the
    /// duplication in a cold review.
    func taskStatusSignals() -> WorkspaceTaskStatusSignals {
        taskStatusSignals(orderedPanelIds: sidebarOrderedPanelIds())
    }

    /// The sampling above, for a caller that already holds the panel order.
    func taskStatusSignals(orderedPanelIds: [UUID]) -> WorkspaceTaskStatusSignals {
        var anyAgentNeedsInput = false
        var anyAgentRunning = false
        for (panelId, states) in agentLifecycleStatesByPanelId where panels[panelId] != nil {
            for state in states.values {
                if state == .needsInput { anyAgentNeedsInput = true }
                if state == .running { anyAgentRunning = true }
            }
        }
        let pullRequests = sidebarPullRequestsInDisplayOrder(orderedPanelIds: orderedPanelIds)
        return WorkspaceTaskStatusSignals(
            anyAgentNeedsInput: anyAgentNeedsInput,
            anyAgentRunning: anyAgentRunning,
            anyOpenPullRequest: pullRequests.contains { $0.status == .open },
            hasPullRequests: !pullRequests.isEmpty,
            allPullRequestsMergedOrClosed: !pullRequests.isEmpty
                && pullRequests.allSatisfy { $0.status != .open },
            isGitDirty: sidebarGitBranchesInDisplayOrder(orderedPanelIds: orderedPanelIds)
                .contains { $0.isDirty }
        )
    }

    // MARK: - Status resolution

    /// The status inferred from the current live signals.
    var inferredTaskStatus: WorkspaceTaskStatus {
        WorkspaceTaskStatus.inferred(from: taskStatusSignals())
    }

    /// The status to display and report: the manual override while its
    /// recorded inference still matches, otherwise the live inference. Pure
    /// (never mutates state), so it is safe to read from view bodies; the
    /// expired-override cleanup happens in
    /// ``reconcileExpiredTaskStatusOverride()`` at mutation/read entry points.
    var effectiveTaskStatus: WorkspaceTaskStatus {
        WorkspaceTaskStatusOverride.effectiveStatus(
            override: todoState.statusOverride,
            inferred: inferredTaskStatus
        ).effective
    }

    /// **The** definition of the "attention lane" — the value
    /// ``SidebarWorkspaceRowVisualPalette/suppressesAccentStrip(attentionTaskStatus:)``
    /// is asked about, and the one `#cm-28`'s `⌘1…9` numbering reads to decide
    /// which workspaces carry a digit.
    ///
    /// Two callers must never disagree — the sidebar factory draws the Accent
    /// Strip from it, the shortcut eligibility decides numbering from it, and
    /// the user need behind the numbering is literally "the ones with a strip".
    /// A striped row that carries no number is the drift a single definition
    /// exists to prevent. **It guarantees one rule, not one sampling instant:**
    /// the strip is drawn from a cached row snapshot whose `presentationKey`
    /// does not include task status, so within a refresh window an unrelated
    /// re-render can pair a stale strip with a fresh badge. Bounded and
    /// self-healing; do not "fix" it by feeding the numbering from the cached
    /// snapshots, which would move the skew onto badge-vs-key — the pair
    /// `#cm-28` deliberately keeps exact.
    ///
    /// **Deliberately ignores `statusHidden`**, unlike the status glyph: hiding
    /// the status is a display opt-out, not a statement that the workspace left
    /// play. `nil` means the todo feature is off, so nothing suppresses and
    /// every workspace stays numbered.
    ///
    /// Lives here, on `Workspace`, beside the `effectiveTaskStatus` it wraps
    /// behind one flag. It reached this file the long way: first as a private
    /// copy inside the shortcut eligibility (which let it drift from the
    /// factory silently), then on the row *palette* — a type that resolves
    /// colours from an immutable snapshot and never called this at all.
    func attentionTaskStatus(todoControlsEnabled: Bool) -> WorkspaceTaskStatus? {
        todoControlsEnabled ? effectiveTaskStatus : nil
    }

    /// Clears the stored override when the live inference has moved away from
    /// what it was at override time (anti-rot). Call from explicit entry
    /// points (socket verbs, CLI, user actions), never from view-body
    /// computations.
    func reconcileExpiredTaskStatusOverride() {
        guard WorkspaceTaskStatusOverride.effectiveStatus(
            override: todoState.statusOverride,
            inferred: inferredTaskStatus
        ).shouldClearOverride else { return }
        todoState.statusOverride = nil
    }

    /// Applies a manual status override, recording the current inference so
    /// the override expires as soon as the live signals change lanes. Picking
    /// a lane re-engages the feature (clears any None opt-out).
    func setTaskStatusOverride(_ status: WorkspaceTaskStatus) {
        todoState.statusHidden = false
        todoState.statusOverride = WorkspaceTaskStatusOverride(
            status: status,
            inferredAtOverride: inferredTaskStatus
        )
    }

    /// Returns the status to automatic by clearing the manual override (and
    /// any None opt-out), so the glyph shows the inferred lane again.
    func clearTaskStatusOverride() {
        todoState.statusHidden = false
        todoState.statusOverride = nil
    }

    /// Opts this workspace out of the status feature: no glyph is drawn before
    /// the title (the "None" state, distinct from Auto). Clears any override.
    func hideTaskStatus() {
        todoState.statusOverride = nil
        todoState.statusHidden = true
    }

    /// Cycles the effective status one lane forward (round-robin
    /// todo → working → needs-attention → review → done → todo) by pinning a
    /// manual override to the lane after the current effective status. Shared
    /// by the `cycleWorkspaceStatus` shortcut and `workspace.status.cycle`.
    func cycleTaskStatus() {
        setTaskStatusOverride(effectiveTaskStatus.next)
    }

    // MARK: - Checklist entry points (shared by socket, CLI, UI)

    /// Appends a checklist item (trims text, rejects empty, caps count and
    /// length per `WorkspaceChecklistItem` limits).
    func addChecklistItem(
        text: String,
        state: WorkspaceChecklistItem.State = .pending,
        origin: WorkspaceChecklistItem.Origin = .user
    ) -> Result<WorkspaceChecklistItem, WorkspaceChecklistItem.AddError> {
        notifyingChecklistCompletion {
            todoState.checklist.addChecklistItem(text, state: state, origin: origin)
        }
    }

    /// Sets one checklist item's state (keeping completed items last in
    /// storage; see `Array.setChecklistItemState`).
    ///
    /// - Returns: `true` if the item existed.
    @discardableResult
    func setChecklistItemState(id: UUID, state: WorkspaceChecklistItem.State) -> Bool {
        notifyingChecklistCompletion {
            todoState.checklist.setChecklistItemState(id: id, state: state)
        }
    }

    /// Moves one checklist item toward a new 0-based position, staying within
    /// its completion partition (see `Array.moveChecklistItem`).
    ///
    /// - Returns: `true` if the item existed.
    @discardableResult
    func moveChecklistItem(id: UUID, toIndex: Int) -> Bool {
        todoState.checklist.moveChecklistItem(id: id, toIndex: toIndex)
    }

    /// Rewrites one checklist item's text (same normalization as add).
    ///
    /// - Returns: `true` if the item existed and the text was non-empty.
    @discardableResult
    func setChecklistItemText(id: UUID, text: String) -> Bool {
        todoState.checklist.setChecklistItemText(id: id, text: text)
    }

    /// Appends image attachment references to one checklist item.
    ///
    /// The referenced image files remain user-owned; removing checklist state
    /// deletes only these references, never the files on disk.
    @discardableResult
    func addChecklistAttachments(
        itemId: UUID,
        attachments: [WorkspaceChecklistAttachment]
    ) -> Bool {
        guard !attachments.isEmpty,
              let index = todoState.checklist.firstIndex(where: { $0.id == itemId }) else {
            return false
        }
        todoState.checklist[index].attachments.append(contentsOf: attachments)
        return true
    }

    /// Removes one image attachment reference from one checklist item.
    ///
    /// - Returns: `true` if both the item and attachment reference existed.
    @discardableResult
    func removeChecklistAttachment(itemId: UUID, attachmentId: UUID) -> Bool {
        guard let itemIndex = todoState.checklist.firstIndex(where: { $0.id == itemId }),
              let attachmentIndex = todoState.checklist[itemIndex].attachments.firstIndex(where: { $0.id == attachmentId }) else {
            return false
        }
        todoState.checklist[itemIndex].attachments.remove(at: attachmentIndex)
        return true
    }

    /// Removes one checklist item.
    ///
    /// - Returns: `true` if the item existed.
    @discardableResult
    func removeChecklistItem(id: UUID) -> Bool {
        notifyingChecklistCompletion {
            todoState.checklist.removeChecklistItem(id: id)
        }
    }

    /// Removes every checklist item.
    ///
    /// - Returns: The number of items removed.
    @discardableResult
    func clearChecklist() -> Int {
        todoState.checklist.clearChecklist()
    }

    /// Atomically replaces the checklist, preserving identity (and origin)
    /// for incoming items whose id matches an existing item. See
    /// `Array.replaceChecklist(with:)` in CmuxWorkspaces for the merge rules.
    ///
    /// - Parameter items: The full desired checklist.
    /// - Returns: The resulting checklist, or the rejection reason (nothing
    ///   is mutated on rejection).
    @discardableResult
    func replaceChecklist(
        with items: [WorkspaceChecklistReplacementItem]
    ) -> Result<[WorkspaceChecklistItem], WorkspaceChecklistReplaceError> {
        notifyingChecklistCompletion {
            todoState.checklist.replaceChecklist(with: items)
        }
    }

    /// The checklist item at a 0-based display index, if in bounds.
    func checklistItem(atIndex index: Int) -> WorkspaceChecklistItem? {
        guard todoState.checklist.indices.contains(index) else { return nil }
        return todoState.checklist[index]
    }

    /// The checklist progress readout (completed/total, first unchecked).
    var checklistProgressSummary: WorkspaceChecklistProgressSummary {
        todoState.checklist.checklistProgressSummary
    }

    // MARK: - Session persistence

    /// Folds the persisted todo fields into the session-autosave fingerprint
    /// so an override or checklist change triggers a save.
    func combineTodoStateIntoSessionAutosaveFingerprint(into hasher: inout Hasher) {
        hasher.combine(todoState.statusOverride)
        hasher.combine(todoState.statusHidden)
        hasher.combine(todoState.checklist)
    }

    /// Restores the todo fields from a session snapshot (absent fields, e.g.
    /// from manifests written before this feature, restore to empty state).
    func restoreTodoState(from snapshot: SessionWorkspaceSnapshot) {
        todoState.statusOverride = snapshot.restoredTaskStatusOverride
        todoState.statusHidden = snapshot.taskStatusHidden ?? false
        todoState.checklist = snapshot.restoredChecklist
    }
}
