import CmuxWorkspaces
import Foundation
import Testing

/// The cycle key's record of the group the previous press opened (#cm-110.14).
@Suite("Status group cycle record")
struct StatusGroupCycleRecordTests {
    private let subject = UUID()

    @Test func foldsBackTheGroupItOpenedWhileItIsStillOpenAndTheSameSubjectIsCycled() {
        let record = StatusGroupCycleRecord(subject: subject, statusId: "doing")
        #expect(record.foldBack(subject: subject, collapsedStatusIds: ["parked"]) == "doing")
    }

    @Test func foldsNothingBackForAnotherSubject() {
        let record = StatusGroupCycleRecord(subject: subject, statusId: "doing")
        #expect(record.foldBack(subject: UUID(), collapsedStatusIds: []) == nil)
    }

    @Test func foldsNothingBackWhenHeFoldedTheGroupHimself() {
        let record = StatusGroupCycleRecord(subject: subject, statusId: "doing")
        #expect(record.foldBack(subject: subject, collapsedStatusIds: ["doing"]) == nil)
    }

    @Test func recordsTheOneGroupAPressOpened() {
        let record = StatusGroupCycleRecord.recording(subject: subject, before: ["a", "b"], after: ["b"])
        #expect(record == StatusGroupCycleRecord(subject: subject, statusId: "a"))
    }

    @Test func recordsNothingWhenAPressOpenedNoGroupOrFoldedOne() {
        #expect(StatusGroupCycleRecord.recording(subject: subject, before: ["a"], after: ["a"]) == nil)
        #expect(StatusGroupCycleRecord.recording(subject: subject, before: [], after: ["a"]) == nil)
    }

    @Test func recordsNothingWhenAPressOpenedSeveralGroups() {
        #expect(StatusGroupCycleRecord.recording(subject: subject, before: ["a", "b"], after: []) == nil)
    }
}
