import Testing
@testable import CmuxWorkspaces

/// `shownEntry(list:)` (#cm-109.3): the entry a glyph draws for a workspace, one case of the resolution at a time, and
/// that wherever the picker checks an entry row it is the same entry.
@Suite struct WorkspaceStatusShownEntryTests {
    typealias F = WorkspaceStatusFixtures

    /// His list with an icon on every entry, so the entry a glyph draws is told apart by more than its id. `todo` and
    /// `needs-attention` are cmux ids under his words, as `todo` is his Future in the verification setup.
    private static let withIcons = WorkspaceStatusList(entries: [
        WorkspaceStatusEntry(id: "done", name: "Done", color: "1: DONE", icon: .shape(.check)),
        WorkspaceStatusEntry(id: "review", name: "Review", icon: .shape(.threeQuarters)),
        WorkspaceStatusEntry(id: "needs-attention", name: "Stuck", icon: .shape(.half)),
        WorkspaceStatusEntry(id: "paused", name: "Paused", extends: .todo, icon: .shape(.ring)),
        WorkspaceStatusEntry(id: "doing", name: "Doing", extends: .working, icon: .shape(.quarter)),
        WorkspaceStatusEntry(id: "todo", name: "Future", icon: .shape(.dottedRing)),
    ], source: .file)
    private var list: WorkspaceStatusList { Self.withIcons }

    private func resolve(
        override: WorkspaceTaskStatusOverride? = nil,
        own: WorkspaceOwnStatus? = nil,
        inferred: WorkspaceTaskStatus
    ) -> WorkspaceStatusResolution {
        .resolve(override: override, own: own, inferred: inferred, list: list)
    }

    @Test func aWorkspaceOnAutoShowsTheEntryWhoseIDIsWhatCmuxDetects() {
        #expect(resolve(inferred: .todo).shownEntry(list: list)?.icon == .shape(.dottedRing))
        #expect(resolve(inferred: .review).shownEntry(list: list)?.icon == .shape(.threeQuarters))
        #expect(resolve(inferred: .needsAttention).shownEntry(list: list)?.icon == .shape(.half))
    }

    @Test func aDetectedStatusTheListHasNoEntryForShowsNoEntry() {
        #expect(resolve(inferred: .working).shownEntry(list: list) == nil)
        #expect(WorkspaceStatusResolution.detected(.working).shownEntry(list: F.toms) == nil)
    }

    @Test func aLapsedCmuxStatusShowsWhatCmuxDetects() {
        let lapsed = resolve(override: F.override(.done, at: .working), inferred: .review)
        #expect(lapsed == .cmuxLapsed(detected: .review))
        #expect(lapsed.shownEntry(list: list)?.id == "review")
    }

    @Test func aCmuxStatusInEffectShowsItsEntry() {
        let done = resolve(override: F.override(.done, at: .todo), inferred: .todo)
        #expect(done.shownEntry(list: list)?.icon == .shape(.check))
    }

    @Test func aCmuxStatusTheListLeavesOutShowsCmuxsOwnEntryWithNoIconAndNoColor() {
        let working = resolve(override: F.override(.working, at: .review), inferred: .review)
        #expect(working.shownEntry(list: list) == WorkspaceStatusList.cmuxFive.entry(id: "working"))
        #expect(working.shownEntry(list: list)?.icon == nil)
        #expect(working.shownEntry(list: list)?.color == nil)
    }

    @Test func aStatusOfHisInEffectShowsItsEntry() {
        let own = resolve(own: WorkspaceOwnStatus(id: "doing"), inferred: .todo)
        #expect(own.shownEntry(list: list)?.icon == .shape(.quarter))
    }

    /// While an agent waits the workspace reports needs-attention, whose entry has another icon; the glyph keeps the
    /// status held through the wait.
    @Test func aStatusOfHisHeldDuringAWaitShowsItNotTheEntryForTheWait() {
        let waiting = resolve(own: WorkspaceOwnStatus(id: "paused"), inferred: .needsAttention)
        #expect(waiting == .ownInEffect(list.entry(id: "paused") ?? F.x))
        #expect(waiting.effective == .todo)
        #expect(waiting.shownEntry(list: list)?.icon == .shape(.ring))
    }

    @Test func aStatusOfHisThatIsNotListedShowsWhatCmuxDetects() {
        let gone = resolve(own: WorkspaceOwnStatus(id: "gone"), inferred: .review)
        #expect(gone.shownEntry(list: list)?.icon == .shape(.threeQuarters))
    }

    /// The row's glyph and the picker's checked row are two reads of one list. Wherever the picker checks an entry row,
    /// that entry is what `shownEntry` gives.
    @Test func wherePickerChecksAnEntryRowItIsTheShownEntry() {
        let cases: [(WorkspaceStatusResolution, WorkspaceTaskStatus)] = [
            (resolve(override: F.override(.done, at: .todo), inferred: .todo), .todo),
            (resolve(own: WorkspaceOwnStatus(id: "doing"), inferred: .todo), .todo),
            (resolve(own: WorkspaceOwnStatus(id: "paused"), inferred: .needsAttention), .needsAttention),
        ]
        for (resolution, inferred) in cases {
            let state = WorkspaceStatusPicker().rows(resolution: resolution, inferred: inferred, isHidden: false, list: list)
            let checked = state.rows.filter(\.isChecked).compactMap { row -> WorkspaceStatusEntry? in
                if case .status(let entry) = row.kind { return entry }
                return nil
            }
            #expect(checked.count == 1, "\(resolution)")
            #expect(checked.first == resolution.shownEntry(list: list), "\(resolution)")
        }
    }
}
