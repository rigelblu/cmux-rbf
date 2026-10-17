import Testing
@testable import CmuxWorkspaces

/// Each row of the resolution table, one fixture per case, with `heldID` checked in each.
@Suite struct WorkspaceStatusResolutionTests {
    typealias F = WorkspaceStatusFixtures

    private func resolve(
        override: WorkspaceTaskStatusOverride? = nil,
        own: WorkspaceOwnStatus? = nil,
        inferred: WorkspaceTaskStatus,
        list: WorkspaceStatusList = F.toms
    ) -> WorkspaceStatusResolution {
        .resolve(override: override, own: own, inferred: inferred, list: list)
    }

    @Test func nothingHeldIsWhatCmuxDetects() {
        let resolution = resolve(inferred: .working)
        #expect(resolution == .detected(.working))
        #expect(resolution.effective == .working)
        #expect(resolution.inEffect == nil)
        #expect(resolution.held == nil)
        #expect(resolution.heldID == nil)
        #expect(!resolution.shouldClearOverride)
    }

    @Test func aCmuxStatusInHisListIsInEffectUnderHisName() {
        let resolution = resolve(override: F.override(.done, at: .todo), inferred: .todo)
        #expect(resolution == .cmuxInEffect(F.done, offered: true))
        #expect(resolution.effective == .done)
        #expect(resolution.inEffect == F.done)
        #expect(resolution.held == .inEffect)
        #expect(resolution.heldID == "done")
        #expect(!resolution.shouldClearOverride)
    }

    /// Sub-step 3c. A pre-release record naming a state (.working or .needsAttention) for .done, .review, or .todo
    /// is compared as if it had recorded .todo when a list is in use, so it stays in effect while detection without
    /// states is .todo and lapses when a pull request makes it .review. Under .cmuxFive, upstream's behavior applies.
    @Test func aPreReleaseRecordNamingAStateIsComparedAsIfItHadRecordedTodo() {
        let atWorking = F.override(.done, at: .working)
        let atNeedsAttention = F.override(.done, at: .needsAttention)

        // With a list in use: compared as if it recorded .todo.
        // Detection without states .todo -> in effect:
        #expect(resolve(override: atWorking, inferred: .todo) == .cmuxInEffect(F.done, offered: true))
        #expect(resolve(override: atNeedsAttention, inferred: .todo) == .cmuxInEffect(F.done, offered: true))

        // When detection without states moves to .review (open PR) -> lapsed:
        #expect(resolve(override: atWorking, inferred: .review) == .cmuxLapsed(detected: .review))

        // Under .cmuxFive: compared against actual inferredAtOverride (.working):
        let cmuxDone = WorkspaceStatusList.cmuxFive.entry(id: "done") ?? F.done
        #expect(resolve(override: atWorking, inferred: .working, list: .cmuxFive) == .cmuxInEffect(cmuxDone, offered: true))
        #expect(resolve(override: atWorking, inferred: .todo, list: .cmuxFive) == .cmuxLapsed(detected: .todo))
    }

    /// O5: A .todo (Future) record at .working is compared as if it had recorded .todo when a list is in use.
    @Test func aPreReleaseTodoRecordAtWorkingIsComparedAsIfItHadRecordedTodo() {
        let atWorking = F.override(.todo, at: .working)

        // With his list: compared as if it recorded .todo. With inferred .todo, it stays in effect.
        // His list does not offer cmux's "todo" id directly, so offered is false:
        let todoEntry = WorkspaceStatusEntry(id: "todo", name: nil)
        #expect(resolve(override: atWorking, inferred: .todo) == .cmuxInEffect(todoEntry, offered: false))
        #expect(resolve(override: atWorking, inferred: .todo).effective == .todo)

        // When detection without states moves to .review (open PR), it lapses:
        #expect(resolve(override: atWorking, inferred: .review) == .cmuxLapsed(detected: .review))

        // Under .cmuxFive: compared against actual inferredAtOverride (.working):
        let cmuxTodo = WorkspaceStatusList.cmuxFive.entry(id: "todo") ?? todoEntry
        #expect(resolve(override: atWorking, inferred: .working, list: .cmuxFive) == .cmuxInEffect(cmuxTodo, offered: true))
        #expect(resolve(override: atWorking, inferred: .todo, list: .cmuxFive) == .cmuxLapsed(detected: .todo))
    }

    @Test func aCmuxStatusHisListLeavesOutIsInEffectAsCmuxsOwnEntryAndNotOffered() {
        let resolution = resolve(override: F.override(.working, at: .review), inferred: .review)
        let cmuxWorking = WorkspaceStatusList.cmuxFive.entry(id: "working")
        #expect(cmuxWorking != nil)
        #expect(resolution == .cmuxInEffect(cmuxWorking ?? F.done, offered: false))
        #expect(resolution.inEffect?.name == nil)
        #expect(resolution.effective == .working)
        #expect(resolution.inEffect?.id == "working")
        #expect(resolution.held == .notOffered)
        #expect(resolution.heldID == "working")
        #expect(!resolution.shouldClearOverride)
    }

    @Test func cmuxsFiveInUseOfferEveryCmuxStatus() {
        let resolution = resolve(
            override: F.override(.working, at: .done), inferred: .done, list: .cmuxFive
        )
        #expect(resolution.held == .inEffect)
        #expect(resolution.inEffect?.id == "working")
    }

    @Test func aCmuxStatusWhoseDetectionChangedHasLapsedAndHoldsNoID() {
        let resolution = resolve(override: F.override(.done, at: .review), inferred: .working)
        #expect(resolution == .cmuxLapsed(detected: .working))
        #expect(resolution.effective == .working)
        #expect(resolution.inEffect == nil)
        #expect(resolution.held == nil)
        #expect(resolution.heldID == nil)
        #expect(resolution.shouldClearOverride)
    }

    @Test func oneOfHisOwnWithNoWaitIsInEffectAndBehavesAsWhatItExtends() {
        let paused = resolve(own: WorkspaceOwnStatus(id: "paused"), inferred: .working)
        #expect(paused == .ownInEffect(F.paused))
        #expect(paused.effective == .todo)
        #expect(paused.inEffect == F.paused)
        #expect(paused.held == .inEffect)
        #expect(paused.heldID == "paused")
        #expect(!paused.shouldClearOverride)

        let doing = resolve(own: WorkspaceOwnStatus(id: "doing-primary"), inferred: .todo)
        #expect(doing.effective == .working)
        #expect(doing.heldID == "doing-primary")
    }

    /// A cmux status his list leaves out lapses like any other when detection moves: it is not "not offered".
    @Test func aCmuxStatusHisListLeavesOutLapsesWhenDetectionMoves() {
        let resolution = resolve(override: F.override(.working, at: .needsAttention), inferred: .review)
        #expect(resolution == .cmuxLapsed(detected: .review))
        #expect(resolution.heldID == nil)
        #expect(resolution.held == nil)
        #expect(resolution.shouldClearOverride)
    }

    /// A cmux status set during a wait is still in effect in that wait under cmux's five: detection has not moved since it was set.
    @Test func aCmuxStatusSetDuringAWaitStaysInEffectInThatWait() {
        let cmuxReview = WorkspaceStatusList.cmuxFive.entry(id: "review") ?? F.review
        let listed = resolve(override: F.override(.review, at: .needsAttention), inferred: .needsAttention, list: .cmuxFive)
        #expect(listed == .cmuxInEffect(cmuxReview, offered: true))
        #expect(listed.effective == .review)
        #expect(listed.heldID == "review")
        #expect(!listed.shouldClearOverride)
        let leftOut = resolve(
            override: F.override(.working, at: .needsAttention), inferred: .needsAttention, list: F.other
        )
        #expect(leftOut.held == .notOffered)
        #expect(leftOut.effective == .working)
        // When the wait ends, detection moved: it lapses like any other.
        let ended = resolve(override: F.override(.review, at: .needsAttention), inferred: .todo, list: .cmuxFive)
        #expect(ended == .cmuxLapsed(detected: .todo))
    }

    @Test func oneOfHisOwnWhileAnAgentWaitsIsInEffectAndHoldsItsID() {
        let resolution = resolve(own: WorkspaceOwnStatus(id: "parked"), inferred: .needsAttention)
        #expect(resolution == .ownInEffect(F.parked))
        #expect(resolution.effective == .todo)
        #expect(resolution.inEffect == F.parked)
        #expect(resolution.held == .inEffect)
        #expect(resolution.heldID == "parked")
        #expect(!resolution.shouldClearOverride)
    }

    @Test func oneOfHisOwnThatTheListLacksShowsWhatAutoShowsAndHoldsItsID() {
        let resolution = resolve(own: WorkspaceOwnStatus(id: "retired"), inferred: .working)
        #expect(resolution == .ownNotListed(id: "retired", detected: .working))
        #expect(resolution.effective == .working)
        #expect(resolution.inEffect == nil)
        #expect(resolution.held == .notListed)
        #expect(resolution.heldID == "retired")
        #expect(!resolution.shouldClearOverride)
    }

    @Test func oneOfHisOwnThatTheListLacksStaysSoInAWait() {
        let resolution = resolve(own: WorkspaceOwnStatus(id: "retired"), inferred: .needsAttention)
        #expect(resolution == .ownNotListed(id: "retired", detected: .needsAttention))
    }

    /// No input gives `.cmuxLapsed` for one of his own: nothing but his own action clears a status of his.
    @Test func noInputGivesLapsedForOneOfHisOwn() {
        for inferred in WorkspaceTaskStatus.allCases {
            for id in ["paused", "parked", "retired", "doing-primary"] {
                for list in [F.toms, F.other, WorkspaceStatusList.cmuxFive] {
                    for override in [nil, F.override(.done, at: .todo), F.override(.review, at: .needsAttention)] {
                        let resolution = resolve(
                            override: override,
                            own: WorkspaceOwnStatus(id: id),
                            inferred: inferred,
                            list: list
                        )
                        #expect(!resolution.shouldClearOverride, "\(id) \(inferred) \(list.source)")
                        #expect(resolution.heldID == id)
                    }
                }
            }
        }
    }
}
