import Testing
@testable import CmuxWorkspaces

/// The eight rows of the cycle's table, each with his eleven and with lists that are not his.
@Suite struct WorkspaceStatusCycleTests {
    typealias F = WorkspaceStatusFixtures
    typealias Target = WorkspaceStatusCycle.Target

    private func target(_ resolution: WorkspaceStatusResolution, list: WorkspaceStatusList) -> Target? {
        WorkspaceStatusCycle().target(resolution: resolution, list: list)
    }

    private func autoTarget(inferred: WorkspaceTaskStatus, list: WorkspaceStatusList) -> Target? {
        target(.detected(inferred), list: list)
    }

    private let cmuxWorking = WorkspaceStatusEntry(id: "working", name: nil)

    // Row 1: cmux's five in use.
    @Test func row1CmuxsFiveAdvanceByCmuxsOwnRule() {
        #expect(autoTarget(inferred: .todo, list: .cmuxFive) == .cmux(.working))
        #expect(autoTarget(inferred: .done, list: .cmuxFive) == .cmux(.todo))
        let held = WorkspaceStatusResolution.cmuxInEffect(WorkspaceStatusEntry(id: "review", name: nil), offered: true)
        #expect(target(held, list: .cmuxFive) == .cmux(.done))
    }

    // Row 2: an empty list.
    @Test func row2AnEmptyListChangesNothing() {
        let empty = WorkspaceStatusList(entries: [], source: .file)
        #expect(autoTarget(inferred: .todo, list: empty) == nil)
        #expect(target(.ownNotListed(id: "x", detected: .todo), list: empty) == nil)
    }

    // Row 3: one status.
    @Test func row3AListOfOneGoesToThatOne() {
        let single = WorkspaceStatusList(entries: [F.parked], source: .file)
        #expect(autoTarget(inferred: .done, list: single) == .entry(F.parked))
        #expect(target(.ownInEffect(F.parked), list: single) == .entry(F.parked))
    }

    // Row 4: holding a status the list has: the next one up.
    @Test func row4HoldingGoesUpOneAndTheTopGoesToTheBottom() {
        #expect(target(.ownInEffect(F.parked), list: F.toms) == .entry(F.upcoming))
        #expect(target(.ownInEffect(F.dogfood), list: F.toms) == .entry(F.future))
        #expect(target(.ownInEffect(F.y), list: F.other) == .entry(F.x))
        #expect(target(.ownInEffect(F.x), list: F.other) == .entry(F.z))
    }

    @Test func row4AnOwnStatusThatWaitsGoesUpToo() {
        #expect(target(.ownWaiting(F.parked), list: F.toms) == .entry(F.upcoming))
    }

    @Test func row4ACmuxStatusTheListHasGoesUpToo() {
        #expect(target(.cmuxInEffect(F.done, offered: true), list: F.toms) == .entry(F.dogfood))
    }

    /// After a restart with a typo in the file the list in use is the stored copy. It is his list, not cmux's five.
    @Test func aStoredListCyclesAsHisListDoes() {
        #expect(target(.ownInEffect(F.parked), list: F.tomsStored) == .entry(F.upcoming))
        #expect(autoTarget(inferred: .todo, list: F.tomsStored) == .entry(F.paused))
        // Review has an entry in his list, so the press in a wait answers it, with its color.
        #expect(autoTarget(inferred: .needsAttention, list: F.tomsStored) == .entry(F.review))
    }

    // Row 5: anything else starts from the status in effect. None leaves the workspace `.detected`, which is
    // Auto's call; the cycle takes no hidden flag.
    @Test func row5WorkingSetByHandStartsFromWorkingWhateverCmuxDetects() {
        let resolution = WorkspaceStatusResolution.cmuxInEffect(cmuxWorking, offered: false)
        #expect(target(resolution, list: F.toms) == .entry(F.doingPrimary))
        #expect(target(resolution, list: F.mixed) == .cmux(.needsAttention))
    }

    @Test func row5ALapsedStatusStartsFromWhatCmuxDetects() {
        #expect(target(.cmuxLapsed(detected: .working), list: F.toms) == .entry(F.doingPrimary))
        #expect(target(.cmuxLapsed(detected: .todo), list: F.mixed) == .entry(F.x))
    }

    @Test func row5AnOwnStatusTheListLacksStartsFromWhatCmuxDetects() {
        let resolution = WorkspaceStatusResolution.ownNotListed(id: "retired", detected: .working)
        #expect(target(resolution, list: F.toms) == .entry(F.doingPrimary))
        #expect(target(.ownNotListed(id: "retired", detected: .review), list: F.mixed) == .entry(F.rev))
    }

    // Row 6: an entry whose id is the status in effect.
    @Test func row6AnEntryWithThatIDWinsOverOneThatExtendsIt() {
        // `dogfood` extends review and sits above `review`; the entry with the id is the one.
        #expect(autoTarget(inferred: .review, list: F.toms) == .entry(F.review))
        #expect(autoTarget(inferred: .done, list: F.toms) == .entry(F.done))
        // The same in a list that is not his: `z` extends review and sits above the entry `review`.
        #expect(autoTarget(inferred: .review, list: F.mixed) == .entry(F.rev))
    }

    // Row 7: the first entry from the top that extends it.
    @Test func row7TheFirstEntryFromTheTopThatExtendsIt() {
        #expect(autoTarget(inferred: .todo, list: F.toms) == .entry(F.paused))
        #expect(autoTarget(inferred: .working, list: F.toms) == .entry(F.doingPrimary))
        let reordered = WorkspaceStatusList(entries: [F.future, F.paused, F.doingSecondary, F.doingPrimary], source: .file)
        #expect(autoTarget(inferred: .todo, list: reordered) == .entry(F.future))
        #expect(autoTarget(inferred: .working, list: reordered) == .entry(F.doingSecondary))
        // A list that is not his: x extends todo, y working, z review.
        #expect(autoTarget(inferred: .todo, list: F.other) == .entry(F.x))
        #expect(autoTarget(inferred: .working, list: F.other) == .entry(F.y))
        #expect(autoTarget(inferred: .review, list: F.other) == .entry(F.z))
    }

    // Row 8: else cmux's next status.
    /// His list has `review`, with a color: the press answers that entry, so the write path writes the color.
    @Test func row8InAWaitHisListGivesHisReviewEntry() {
        #expect(autoTarget(inferred: .needsAttention, list: F.toms) == .entry(F.review))
        // A lapsed cmux status while an agent waits starts from Needs Attention too: nothing in his list is that or
        // extends it, so row 8 answers.
        #expect(target(.cmuxLapsed(detected: .needsAttention), list: F.toms) == .entry(F.review))
    }

    /// Another next status: cmux detects Done, the list has nothing for `done` or extending it, and has an entry
    /// with the id `todo`, which is what follows Done. The press answers that entry.
    @Test func row8WithAnotherNextStatusAnswersHisEntryForIt() {
        let todo = WorkspaceStatusEntry(id: "todo", name: "To do", color: "6: TODO")
        let list = WorkspaceStatusList(entries: [todo, F.next], source: .file)
        #expect(autoTarget(inferred: .done, list: list) == .entry(todo))
    }

    /// The same press with a list of his that has no `review`: cmux's own Review, and no color to write.
    @Test func row8InAWaitAListWithNoReviewGivesCmuxsReview() {
        let noReview = WorkspaceStatusList(entries: F.tomsEntries.filter { $0.id != "review" }, source: .file)
        #expect(noReview.entries.count == F.tomsEntries.count - 1)
        #expect(autoTarget(inferred: .needsAttention, list: noReview) == .cmux(.review))
    }


    @Test func row8AListThatHasNothingForTheStatusGoesToCmuxsNext() {
        // Nothing in `other` is `done` or extends it; cmux's next after done is todo.
        #expect(autoTarget(inferred: .done, list: F.other) == .cmux(.todo))
        #expect(autoTarget(inferred: .needsAttention, list: F.other) == .cmux(.review))
    }
}
