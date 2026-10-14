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
        let resolution = resolve(override: F.override(.done, at: .working), inferred: .working)
        #expect(resolution == .cmuxInEffect(F.done, offered: true))
        #expect(resolution.effective == .done)
        #expect(resolution.inEffect == F.done)
        #expect(resolution.held == .inEffect)
        #expect(resolution.heldID == "done")
        #expect(!resolution.shouldClearOverride)
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

    @Test func theHeldFlagChangesNothingWhenNoAgentWaits() {
        let held = resolve(own: WorkspaceOwnStatus(id: "paused", heldThroughWait: true), inferred: .todo)
        let plain = resolve(own: WorkspaceOwnStatus(id: "paused"), inferred: .todo)
        #expect(held == plain)
        #expect(held == .ownInEffect(F.paused))
    }

    /// A cmux status his list leaves out lapses like any other when detection moves: it is not "not offered".
    @Test func aCmuxStatusHisListLeavesOutLapsesWhenDetectionMoves() {
        let resolution = resolve(override: F.override(.working, at: .needsAttention), inferred: .review)
        #expect(resolution == .cmuxLapsed(detected: .review))
        #expect(resolution.heldID == nil)
        #expect(resolution.held == nil)
        #expect(resolution.shouldClearOverride)
    }

    /// A cmux status set during a wait is still in effect in that wait: detection has not moved since it was set.
    @Test func aCmuxStatusSetDuringAWaitStaysInEffectInThatWait() {
        let listed = resolve(override: F.override(.review, at: .needsAttention), inferred: .needsAttention)
        #expect(listed == .cmuxInEffect(F.review, offered: true))
        #expect(listed.effective == .review)
        #expect(listed.heldID == "review")
        #expect(!listed.shouldClearOverride)
        let leftOut = resolve(
            override: F.override(.working, at: .needsAttention), inferred: .needsAttention, list: F.other
        )
        #expect(leftOut.held == .notOffered)
        #expect(leftOut.effective == .working)
        // When the wait ends, detection moved: it lapses like any other.
        let ended = resolve(override: F.override(.review, at: .needsAttention), inferred: .todo)
        #expect(ended == .cmuxLapsed(detected: .todo))
    }

    @Test func oneOfHisOwnWhileAnAgentWaitsShowsNeedsAttentionAndHoldsItsID() {
        let resolution = resolve(own: WorkspaceOwnStatus(id: "parked"), inferred: .needsAttention)
        #expect(resolution == .ownWaiting(F.parked))
        #expect(resolution.effective == .needsAttention)
        #expect(resolution.inEffect == nil)
        #expect(resolution.held == .waiting)
        #expect(resolution.heldID == "parked")
        #expect(!resolution.shouldClearOverride)
    }

    @Test func oneOfHisOwnPickedDuringAWaitStaysInEffectThroughIt() {
        let resolution = resolve(
            own: WorkspaceOwnStatus(id: "parked", heldThroughWait: true), inferred: .needsAttention
        )
        #expect(resolution == .ownInEffect(F.parked))
        #expect(resolution.effective == .todo)
        #expect(resolution.inEffect == F.parked)
        #expect(resolution.held == .inEffect)
        #expect(resolution.heldID == "parked")
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
                for heldThroughWait in [false, true] {
                    for list in [F.toms, F.other, WorkspaceStatusList.cmuxFive] {
                        for override in [nil, F.override(.done, at: .todo), F.override(.review, at: .needsAttention)] {
                            let resolution = resolve(
                                override: override,
                                own: WorkspaceOwnStatus(id: id, heldThroughWait: heldThroughWait),
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
}
