import Foundation
import Testing
@testable import CmuxAgentJournal

struct AgentJournalSourceTitleTests {
    @Test func legacyNotificationDecodesWithoutASourceTitle() throws {
        let data = Data(#"{"title":"Pi","subtitle":"project","body":"Done","category":"turn-complete"}"#.utf8)
        let notification = try JSONDecoder().decode(AgentJournalNotification.self, from: data)
        #expect(notification.sourceTitle == nil)
        #expect(notification.title == "Pi")
    }

    @Test func piSessionSourceTitleSurvivesTheJournalWireRoundTrip() throws {
        let notification = AgentJournalNotification(title: "Pi · fix login bug · Finished", subtitle: "project",
            body: "Done", category: "turn-complete", sourceTitle: "Pi · fix login bug")
        let decoded = try JSONDecoder().decode(AgentJournalNotification.self, from: JSONEncoder().encode(notification))
        #expect(decoded.sourceTitle == "Pi · fix login bug")
        #expect(decoded.title == "Pi · fix login bug · Finished")
    }
}
