import Testing
@testable import CmuxWorkspaces

/// The picker's rows: his eleven in the file's order between Auto and None, the greyed row in both forms, and
/// cmux's five asking for cmux's own names.
@Suite struct WorkspaceStatusPickerTests {
    typealias F = WorkspaceStatusFixtures

    private func state(
        _ resolution: WorkspaceStatusResolution,
        inferred: WorkspaceTaskStatus,
        isHidden: Bool = false,
        list: WorkspaceStatusList = F.toms
    ) -> WorkspaceStatusPickerState {
        WorkspaceStatusPicker().rows(resolution: resolution, inferred: inferred, isHidden: isHidden, list: list)
    }

    private func checked(_ state: WorkspaceStatusPickerState) -> [String] {
        state.rows.filter(\.isChecked).map(\.id)
    }

    private let cmuxWorking = WorkspaceStatusEntry(id: "working", name: nil)

    @Test func hisElevenInTheFilesOrderBetweenAutoAndNone() {
        let rows = state(.detected(.todo), inferred: .todo).rows
        #expect(rows.map(\.id) == ["auto"] + F.tomsIDs + ["none"])
        #expect(rows.first?.action == .auto)
        #expect(rows.last?.action == .hide)
        #expect(rows.dropFirst().dropLast().map(\.action) == F.tomsIDs.map { .status(id: $0) })
    }

    @Test func eachStatusRowCarriesItsLabelGlyphAndColor() {
        let rows = state(.detected(.todo), inferred: .todo).rows.dropFirst().dropLast()
        #expect(rows.map(\.label) == F.tomsNames.map { .named($0) })
        #expect(rows.map(\.glyph) == F.tomsEntries.map(\.behavesAs))
        #expect(rows.map(\.color) == F.tomsEntries.map(\.color))
        let all = state(.detected(.todo), inferred: .todo).rows
        #expect(all.first?.glyph == nil && all.first?.color == nil && all.first?.label == nil)
        #expect(all.last?.glyph == nil && all.last?.color == nil && all.last?.label == nil)
    }

    @Test func onAutoOnlyAutoIsChecked() {
        #expect(checked(state(.detected(.working), inferred: .working)) == ["auto"])
    }

    @Test func aLapsedCmuxStatusShowsAutoChecked() {
        #expect(checked(state(.cmuxLapsed(detected: .working), inferred: .working)) == ["auto"])
    }

    @Test func aStatusInEffectIsTheOnlyOneChecked() {
        #expect(checked(state(.ownInEffect(F.parked), inferred: .todo)) == ["parked"])
        #expect(checked(state(.cmuxInEffect(F.done, offered: true), inferred: .todo)) == ["done"])
    }

    @Test func noneIsCheckedOnlyWhenHidden() {
        #expect(checked(state(.detected(.todo), inferred: .todo, isHidden: true)) == ["none"])
        #expect(checked(state(.detected(.todo), inferred: .todo)).contains("none") == false)
    }

    /// Today's rows are gated by None: with None on, no row for a status is checked.
    @Test func withNoneOnNoStatusRowIsChecked() {
        let held: [WorkspaceStatusResolution] = [
            .ownInEffect(F.parked), .cmuxInEffect(F.done, offered: true),
        ]
        for resolution in held {
            let rows = state(resolution, inferred: .needsAttention, isHidden: true).rows
            #expect(checked(WorkspaceStatusPickerState(rows: rows)) == ["none"], "\(resolution)")
        }
    }

    @Test func aCmuxStatusTheListLeavesOutGetsOneGreyedCheckedRowAskingForCmuxsName() {
        let rows = state(.cmuxInEffect(cmuxWorking, offered: false), inferred: .todo).rows
        #expect(rows.map(\.id) == ["auto"] + F.tomsIDs + [" held", "none"])
        let held = rows[F.tomsIDs.count + 1]
        #expect(held.kind == .held(label: .cmux(.working), cmuxStatus: .working))
        #expect(held.isChecked)
        #expect(held.action == nil)
        #expect(held.glyph == .working)
        #expect(held.color == nil)
        #expect(checked(WorkspaceStatusPickerState(rows: rows)) == [" held"])
    }

    @Test func oneOfHisOwnThatTheListLacksGetsOneGreyedCheckedRowNamedByItsID() {
        let rows = state(.ownNotListed(id: "retired", detected: .todo), inferred: .todo).rows
        let held = rows[F.tomsIDs.count + 1]
        #expect(rows.map(\.id) == ["auto"] + F.tomsIDs + [" held", "none"])
        #expect(held.kind == .held(label: .named("retired"), cmuxStatus: nil))
        #expect(held.isChecked)
        #expect(held.action == nil)
        #expect(held.glyph == nil)
        #expect(checked(WorkspaceStatusPickerState(rows: rows)) == [" held"])
    }

    /// A status he named `held` is valid. The greyed row's id begins with a space, which no id from the file can,
    /// so every row of the picker has its own id.
    @Test func aStatusNamedHeldDoesNotShareTheGreyedRowsID() {
        let heldEntry = WorkspaceStatusEntry(id: "held", name: "Held", extends: .todo)
        let list = WorkspaceStatusList(entries: [heldEntry, F.paused], source: .file)
        let rows = state(.cmuxInEffect(cmuxWorking, offered: false), inferred: .todo, list: list).rows
        #expect(rows.map(\.id) == ["auto", "held", "paused", " held", "none"])
        #expect(Set(rows.map(\.id)).count == rows.count)
        #expect(WorkspaceStatusPickerRow.heldRowID == " held")
    }

    @Test func otherCasesHaveNoGreyedRow() {
        let resolutions: [WorkspaceStatusResolution] = [
            .detected(.todo),
            .cmuxInEffect(F.done, offered: true),
            .cmuxLapsed(detected: .working),
            .ownInEffect(F.parked),
        ]
        for resolution in resolutions {
            let ids = state(resolution, inferred: .todo).rows.map(\.id)
            #expect(!ids.contains(WorkspaceStatusPickerRow.heldRowID), "\(resolution)")
        }
    }

    @Test func autoNamesTheDetectedStatusByHisWordWhenTheListNamesItAndByCmuxsOtherwise() {
        let renamed = WorkspaceStatusList(
            entries: [WorkspaceStatusEntry(id: "done", name: "Finished"), F.paused], source: .file
        )
        let his = state(.detected(.done), inferred: .done, list: renamed).rows[0]
        #expect(his.kind == .auto(detected: .done, detectedLabel: .named("Finished"), returning: false))
        let cmuxs = state(.detected(.todo), inferred: .todo, list: renamed).rows[0]
        #expect(cmuxs.kind == .auto(detected: .todo, detectedLabel: .cmux(.todo), returning: false))
    }

    /// A stored copy is his words too.
    @Test func aStoredListShowsHisWordsNotCmuxs() {
        let rows = state(.detected(.done), inferred: .done, list: F.tomsStored).rows
        #expect(rows.map(\.id) == ["auto"] + F.tomsIDs + ["none"])
        #expect(rows[0].kind == .auto(detected: .done, detectedLabel: .named("Done"), returning: false))
        #expect(rows.dropFirst().dropLast().map(\.label) == F.tomsNames.map { .named($0) })
    }

    /// Today's popover says "return to" only while a status is in effect (`SidebarWorkspaceStatusPopover`), and
    /// "Auto - x" in every other case, including a status held through a wait and one the list lacks.
    @Test func autoReturnsToItOnlyWhileAStatusIsInEffect() {
        let inEffect: [WorkspaceStatusResolution] = [
            .cmuxInEffect(F.done, offered: true),
            .cmuxInEffect(cmuxWorking, offered: false),
            .ownInEffect(F.parked),
        ]
        let notInEffect: [WorkspaceStatusResolution] = [
            .detected(.todo),
            .cmuxLapsed(detected: .todo),
            .ownNotListed(id: "retired", detected: .todo),
        ]
        for resolution in inEffect {
            guard case .auto(_, _, let returning) = state(resolution, inferred: .todo).rows[0].kind else {
                Issue.record("first row is not Auto"); continue
            }
            #expect(returning, "\(resolution)")
        }
        for resolution in notInEffect {
            guard case .auto(_, _, let returning) = state(resolution, inferred: .todo).rows[0].kind else {
                Issue.record("first row is not Auto"); continue
            }
            #expect(!returning, "\(resolution)")
        }
    }

    /// With cmux's five in use the rows are today's, one for one, and each asks for cmux's own name.
    @Test func cmuxsFiveGiveTodaysRowsAskingForCmuxsNames() {
        let rows = state(.detected(.done), inferred: .done, list: .cmuxFive).rows
        #expect(rows.map(\.id) == ["auto", "todo", "working", "needs-attention", "review", "done", "none"])
        let statusRows = rows.dropFirst().dropLast()
        #expect(statusRows.map(\.glyph) == WorkspaceTaskStatus.allCases)
        #expect(statusRows.map(\.label) == WorkspaceTaskStatus.allCases.map { .cmux($0) })
        #expect(rows[0].kind == .auto(detected: .done, detectedLabel: .cmux(.done), returning: false))
        #expect(checked(WorkspaceStatusPickerState(rows: rows)) == ["auto"])
        let working = state(.cmuxInEffect(cmuxWorking, offered: true), inferred: .todo, list: .cmuxFive)
        #expect(checked(working) == ["working"])
    }

    @Test func anEmptyListShowsAutoAndNone() {
        let rows = state(.detected(.todo), inferred: .todo, list: WorkspaceStatusList(entries: [], source: .file)).rows
        #expect(rows.map(\.id) == ["auto", "none"])
    }

    /// `resolve` and `rows` together, from what a workspace holds to the rows drawn.
    @Test func rowsFollowFromWhatAWorkspaceHolds() {
        let picker = WorkspaceStatusPicker()
        func rows(
            override: WorkspaceTaskStatusOverride? = nil,
            own: WorkspaceOwnStatus? = nil,
            inferred: WorkspaceTaskStatus,
            isHidden: Bool = false,
            list: WorkspaceStatusList = F.toms
        ) -> WorkspaceStatusPickerState {
            let resolution = WorkspaceStatusResolution.resolve(
                override: override, own: own, inferred: inferred, list: list
            )
            return picker.rows(resolution: resolution, inferred: inferred, isHidden: isHidden, list: list)
        }
        // Nothing held.
        #expect(checked(rows(inferred: .working)) == ["auto"])
        // One of his own, in effect; and the same during a wait, where it shows Needs Attention.
        #expect(checked(rows(own: WorkspaceOwnStatus(id: "parked"), inferred: .todo)) == ["parked"])
        #expect(checked(rows(own: WorkspaceOwnStatus(id: "parked"), inferred: .needsAttention)) == ["parked"])
        // One of his own that the list lacks: the greyed row.
        #expect(checked(rows(own: WorkspaceOwnStatus(id: "retired"), inferred: .todo)) == [" held"])
        // A cmux status the list leaves out, in effect, then after detection moved.
        #expect(checked(rows(override: F.override(.working, at: .review), inferred: .review)) == [" held"])
        #expect(checked(rows(override: F.override(.working, at: .review), inferred: .done)) == ["auto"])
        // A cmux status the list has: set at a state before release, stays in effect under detection without states .todo.
        #expect(checked(rows(override: F.override(.done, at: .working), inferred: .todo)) == ["done"])
        #expect(checked(rows(override: F.override(.review, at: .needsAttention), inferred: .todo)) == ["review"])
        // None.
        #expect(checked(rows(inferred: .todo, isHidden: true)) == ["none"])
        // A list that is not his: x, y and z. Review is left out of it.
        let other = F.other
        #expect(rows(inferred: .todo, list: other).rows.map(\.id) == ["auto", "x", "y", "z", "none"])
        #expect(checked(rows(own: WorkspaceOwnStatus(id: "y"), inferred: .needsAttention, list: other)) == ["y"])
        #expect(
            checked(rows(override: F.override(.review, at: .needsAttention), inferred: .todo, list: other))
                == [" held"]
        )
        #expect(checked(rows(override: F.override(.review, at: .needsAttention), inferred: .review, list: other)) == ["auto"])
    }

    /// With None on, only None is checked: the greyed row is checked like an entry's row, only when None is off.
    @Test func withNoneOnTheGreyedRowStaysButIsNotChecked() {
        let cmuxStatus = state(.cmuxInEffect(cmuxWorking, offered: false), inferred: .todo, isHidden: true).rows
        #expect(cmuxStatus.map(\.id) == ["auto"] + F.tomsIDs + [" held", "none"])
        #expect(checked(WorkspaceStatusPickerState(rows: cmuxStatus)) == ["none"])
        let own = state(.ownNotListed(id: "retired", detected: .todo), inferred: .todo, isHidden: true).rows
        #expect(own.map(\.id) == ["auto"] + F.tomsIDs + [" held", "none"])
        #expect(checked(WorkspaceStatusPickerState(rows: own)) == ["none"])
    }

    /// Auto keeps "return to" under None while a status is in effect, as today.
    @Test func autoKeepsReturnToUnderNoneWhileAStatusIsInEffect() {
        let held = state(.ownInEffect(F.parked), inferred: .todo, isHidden: true).rows[0]
        #expect(held.kind == .auto(detected: .todo, detectedLabel: .cmux(.todo), returning: true))
        let none = state(.detected(.todo), inferred: .todo, isHidden: true).rows[0]
        #expect(none.kind == .auto(detected: .todo, detectedLabel: .cmux(.todo), returning: false))
    }

    /// The greyed row's label is read through `row.label`, in both forms.
    @Test func theGreyedRowsLabelIsCmuxsNameOrTheRawID() {
        let cmuxRows = state(.cmuxInEffect(cmuxWorking, offered: false), inferred: .todo).rows
        #expect(cmuxRows[F.tomsIDs.count + 1].label == .cmux(.working))
        let lacks = WorkspaceStatusList(entries: [F.paused, F.next], source: .file)
        let ownRows = state(.ownNotListed(id: "parked", detected: .todo), inferred: .todo, list: lacks).rows
        #expect(ownRows.map(\.id) == ["auto", "paused", "next", " held", "none"])
        #expect(ownRows[3].label == .named("parked"))
    }

    /// Every combination a workspace can hold, with every detected status, None on and off, and every kind of list:
    /// one row is checked, none when None is on but None, and no two rows share an id.
    @Test func exactlyOneRowIsCheckedAndNoTwoRowsShareAnID() {
        // Every one of cmux's five as an id, with one of his own beside them.
        let cmuxIDsAndHis = WorkspaceStatusList(
            entries: WorkspaceTaskStatus.allCases.map { WorkspaceStatusEntry(id: $0.rawValue, name: "W-\($0.rawValue)") }
                + [F.parked],
            source: .file
        )
        let lists: [(String, WorkspaceStatusList)] = [
            ("his eleven from the file", F.toms),
            ("his eleven from the stored copy", F.tomsStored),
            ("cmux's five", .cmuxFive),
            ("empty", WorkspaceStatusList(entries: [], source: .file)),
            ("one entry", WorkspaceStatusList(entries: [F.parked], source: .file)),
            ("all five of cmux's ids and one of his", cmuxIDsAndHis),
            // The one id that can meet the greyed row's, if the greyed row's id were a plain word.
            ("a status named held", WorkspaceStatusList(
                entries: [WorkspaceStatusEntry(id: "held", name: "Held", extends: .todo), F.paused], source: .file
            )),
        ]
        var held: [(String, WorkspaceTaskStatusOverride?, WorkspaceOwnStatus?)] = [("nothing", nil, nil)]
        for status in WorkspaceTaskStatus.allCases {
            for at in WorkspaceTaskStatus.allCases {
                held.append(("\(status) set at \(at)", F.override(status, at: at), nil))
            }
        }
        for id in ["parked", "paused", "retired"] {
            held.append(("own \(id)", nil, WorkspaceOwnStatus(id: id)))
        }

        var cases = 0
        for (listName, list) in lists {
            for (heldName, override, own) in held {
                for inferred in WorkspaceTaskStatus.allCases {
                    for isHidden in [false, true] {
                        let resolution = WorkspaceStatusResolution.resolve(
                            override: override, own: own, inferred: inferred, list: list
                        )
                        let rows = WorkspaceStatusPicker().rows(
                            resolution: resolution, inferred: inferred, isHidden: isHidden, list: list
                        ).rows
                        let context = "\(listName) / \(heldName) / detected \(inferred) / None \(isHidden)"
                        let ids = rows.filter(\.isChecked).map(\.id)
                        #expect(ids.count == 1, "\(context): \(ids)")
                        if isHidden { #expect(ids == ["none"], "\(context): \(ids)") }
                        #expect(Set(rows.map(\.id)).count == rows.count, "\(context)")
                        cases += 1
                    }
                }
            }
        }
        #expect(cases == 7 * (1 + 25 + 3) * 5 * 2)
    }
}
