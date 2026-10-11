import Foundation
import Testing
@testable import CmuxWorkspaces

/// The small value types: the entry, the list, the pick action, the origin and the held status.
@Suite struct WorkspaceStatusValuesTests {
    typealias F = WorkspaceStatusFixtures

    @Test func anEntryOfCmuxsFiveBehavesAsItselfAndOneOfHisOwnAsWhatItExtends() {
        #expect(F.done.isCmuxOwn)
        #expect(F.done.behavesAs == .done)
        #expect(!F.parked.isCmuxOwn)
        #expect(F.parked.behavesAs == .todo)
        #expect(F.doingPrimary.behavesAs == .working)
        #expect(F.dogfood.behavesAs == .review)
        // An id of cmux's five wins over a stray extends built by hand.
        let odd = WorkspaceStatusEntry(id: "review", name: "Review", extends: .todo)
        #expect(odd.behavesAs == .review)
    }

    /// Built by hand, an entry of his own with no `extends` behaves as `todo`. The parser never builds one.
    @Test func anEntryOfHisOwnBuiltWithNoExtendsBehavesAsTodo() {
        #expect(WorkspaceStatusEntry(id: "x", name: "X").behavesAs == .todo)
    }

    @Test func anEntryDrawsHisWordOrAsksForCmuxsName() {
        #expect(F.parked.label == .named("Parked"))
        #expect(F.done.label == .named("Done"))
        #expect(WorkspaceStatusEntry(id: "done", name: nil).label == .cmux(.done))
    }

    /// The stored copy holds entries as JSON. The key names are a file format: a build that renames one would read
    /// an older copy wrongly.
    @Test func theStoredCopyHasTheseKeyNames() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let dogfood = try String(decoding: encoder.encode(F.dogfood), as: UTF8.self)
        #expect(dogfood == #"{"color":"2: DOGFOOD","extends":"review","id":"dogfood","name":"Dogfood"}"#)
        let done = try String(decoding: encoder.encode(F.done), as: UTF8.self)
        #expect(done == #"{"color":"1: DONE","id":"done","name":"Done"}"#)
        let bare = try String(decoding: encoder.encode(WorkspaceStatusEntry(id: "a", name: "A", extends: .todo)), as: UTF8.self)
        #expect(bare == #"{"extends":"todo","id":"a","name":"A"}"#)
    }

    /// The entry is written and never decoded: the copy is read back through the parser. Only the conformance can be
    /// pinned here; `name` not being public cannot, because this target uses `@testable import`.
    @Test func anEntryIsEncodableAndNotDecodable() {
        #expect(!((F.done as Any) is any Decodable))
        #expect((F.done as Any) is any Encodable)
    }

    /// The copy is read back through the same checks as the file: `JSONSerialization`, then the parser. An entry
    /// with a nil field is written without that key, and the parser reads a missing `extends` or `color` as given
    /// nowhere: his own entry needs `extends`, one of cmux's five ignores it, `color` is optional.
    @Test func theStoredCopyReadsBackThroughTheParserAsTheSameEntries() throws {
        // His eleven all have a color; the twelfth has none.
        let entries = F.tomsEntries + [WorkspaceStatusEntry(id: "plain", name: "Plain", extends: .todo)]
        let data = try JSONEncoder().encode(entries)
        let value = try JSONSerialization.jsonObject(with: data)
        let result = WorkspaceStatusListParser().parse(value)
        #expect(result.problems.isEmpty)
        #expect(result.list?.entries == entries)
        #expect(result.list?.source == .file)
    }

    @Test func aStoredCopyThatBreaksARuleGivesAProblemSoTheStoreCanTellABadCopy() throws {
        let noName = try JSONSerialization.jsonObject(with: Data(#"[{"id":"x"}]"#.utf8))
        #expect(WorkspaceStatusListParser().parse(noName).problems == [.noName(entry: 1, id: "x")])
        let twice = try JSONSerialization.jsonObject(
            with: Data(#"[{"extends":"todo","id":"x","name":"X"},{"extends":"todo","id":"x","name":"Y"}]"#.utf8)
        )
        #expect(WorkspaceStatusListParser().parse(twice).problems == [.repeatedID(entry: 2, id: "x")])
        let notAList = try JSONSerialization.jsonObject(with: Data(#"{"id":"x"}"#.utf8))
        #expect(WorkspaceStatusListParser().parse(notAList).problems == [.notAList])
    }

    @Test func cmuxsFiveAreTheFiveInCmuxsOrderWithSourceCmuxAndNoDisplayNames() {
        let list = WorkspaceStatusList.cmuxFive
        #expect(list.source == .cmux)
        #expect(list.entries.map(\.id) == ["todo", "working", "needs-attention", "review", "done"])
        #expect(list.entries.allSatisfy { $0.isCmuxOwn && $0.extends == nil && $0.color == nil })
        #expect(list.entries.allSatisfy { $0.name == nil })
        #expect(list.entries.map(\.label) == WorkspaceTaskStatus.allCases.map { .cmux($0) })
    }

    @Test func aListLooksUpByExactIDAndByWhatAnEntryExtends() {
        #expect(F.toms.entry(id: "parked") == F.parked)
        #expect(F.toms.entry(id: "Parked") == nil)
        #expect(F.toms.entry(id: "working") == nil)
        #expect(F.toms.firstExtending(.todo) == F.paused)
        #expect(F.toms.firstExtending(.working) == F.doingPrimary)
        #expect(F.toms.firstExtending(.review) == F.dogfood)
        #expect(F.toms.firstExtending(.done) == nil)
        #expect(F.toms.firstExtending(.needsAttention) == nil)
    }

    @Test func theAcceptedIDsAreHisThenCmuxsThatHeLeavesOutThenAutoAndNone() {
        #expect(F.toms.acceptedIDs == F.tomsIDs + ["todo", "working", "needs-attention", "auto", "none"])
        #expect(WorkspaceStatusList.cmuxFive.acceptedIDs
            == ["todo", "working", "needs-attention", "review", "done", "auto", "none"])
        #expect(WorkspaceStatusList(entries: [], source: .file).acceptedIDs
            == ["todo", "working", "needs-attention", "review", "done", "auto", "none"])
        // A list that holds all five of cmux's ids, in an order of his own, with one of his beside them.
        let all = WorkspaceStatusList(
            entries: [
                WorkspaceStatusEntry(id: "done", name: "D"), WorkspaceStatusEntry(id: "parked", name: "P", extends: .todo),
                WorkspaceStatusEntry(id: "todo", name: "T"), WorkspaceStatusEntry(id: "review", name: "R"),
                WorkspaceStatusEntry(id: "working", name: "W"), WorkspaceStatusEntry(id: "needs-attention", name: "N"),
            ],
            source: .file
        )
        #expect(all.acceptedIDs == ["done", "parked", "todo", "review", "working", "needs-attention", "auto", "none"])
    }

    /// A problem answers the four fields a script reads. `value` is the refused text for two cases and `nil` for the
    /// rest; `fileNotRead`'s detail is not a value.
    @Test func aProblemAnswersItsCodeEntryIDAndValue() {
        typealias P = WorkspaceStatusListProblem
        let rows: [(P, String, Int?, String?, String?)] = [
            (.fileNotRead(missing: false, detail: "no good"), "file_not_read", nil, nil, nil),
            (.fileNotRead(missing: true, detail: ""), "file_not_read", nil, nil, nil),
            (.notAList, "not_a_list", nil, nil, nil),
            (.entryNotAnObject(entry: 3), "entry_not_an_object", 3, nil, nil),
            (.noID(entry: 4), "no_id", 4, nil, nil),
            (.reservedID(entry: 5, id: "None"), "reserved_id", 5, "None", nil),
            (.repeatedID(entry: 6, id: "a"), "repeated_id", 6, "a", nil),
            (.noName(entry: 7, id: "b"), "no_name", 7, "b", nil),
            (.noExtends(entry: 8, id: "c"), "no_extends", 8, "c", nil),
            (.unknownExtends(entry: 9, id: "d", value: " Paused "), "unknown_extends", 9, "d", " Paused "),
            (.colorNotInThisApp(id: "e", color: "7: NOPE"), "color_not_in_this_app", nil, "e", "7: NOPE"),
        ]
        for (problem, code, entry, id, value) in rows {
            #expect(problem.code == code, "\(problem)")
            #expect(problem.entry == entry, "\(problem)")
            #expect(problem.id == id, "\(problem)")
            #expect(problem.value == value, "\(problem)")
        }
        // Ten cases, ten different words.
        #expect(Set(rows.map(\.0.code)).count == 10)
    }

    @Test func markDoneIsCmuxsDoneByID() {
        #expect(WorkspaceStatusPickAction.done == .status(id: "done"))
    }

    @Test func theOriginIsThisMacUnlessACallerSaysPhone() {
        #expect(WorkspaceStatusOrigin.current == .mac)
        WorkspaceStatusOrigin.$current.withValue(.phone) {
            #expect(WorkspaceStatusOrigin.current == .phone)
        }
    }

    @Test func aHeldOwnStatusDefaultsToNotHeldThroughAWait() {
        #expect(WorkspaceOwnStatus(id: "parked").heldThroughWait == false)
    }
}
