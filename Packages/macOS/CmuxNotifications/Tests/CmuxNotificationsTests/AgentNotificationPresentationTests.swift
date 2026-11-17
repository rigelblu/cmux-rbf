import Testing
@testable import CmuxNotifications

struct AgentNotificationPresentationTests {
    @Test(arguments: [
        (AgentNotificationPresentation.Kind.finished, "Finished"),
        (.answer, "Needs your answer"),
        (.approval, "Needs your approval"),
        (.error, "Stopped on an error"),
        (.unreadReminder, "Finished 1 min ago, still unread"),
        (.errorUnreadReminder, "Stopped on an error 1 min ago, still unread")
    ])
    func sourceLineNamesTheKind(_ kind: AgentNotificationPresentation.Kind, _ label: String) {
        let value = AgentNotificationPresentation(agentTitle: "Claude Code", kind: kind, cwd: "/work/cm-128")
        #expect(value.title == "Claude Code · \(label)")
        #expect(value.subtitle == "cm-128")
    }

    // cm-124.5: the first-ever banner for a type no row maps names the type on its title line.
    @Test func aNewNotificationTypeIsNamedOnTheTitleLine() {
        let value = AgentNotificationPresentation(agentTitle: "Claude Code",
            kind: .newNotificationType("worker_permission_prompt"), cwd: "/work/cm-124.5")
        #expect(value.title == "Claude Code · New notification type: worker_permission_prompt")
        #expect(value.subtitle == "cm-124.5")
    }

    @Test(arguments: ["a%@b", "100%", "%d%s", "plugin_notification"])
    func theTypeIsInsertedAsIsNeverReadAsAFormat(_ type: String) {
        let value = AgentNotificationPresentation(agentTitle: "Kimi", kind: .newNotificationType(type), cwd: nil)
        #expect(value.title == "Kimi · New notification type: \(type)")
    }

    @Test func piKeepsItsSessionTitleAndPushKeepsItsBareName() {
        #expect(AgentNotificationPresentation(agentTitle: "Pi · fix login bug", kind: .finished,
            cwd: nil).title == "Pi · fix login bug · Finished")
        #expect(AgentNotificationPresentation(agentTitle: "Pi · fix login bug", kind: .errorUnreadReminder,
            cwd: nil).title == "Pi · fix login bug · Stopped on an error 1 min ago, still unread")
        let push = AgentNotificationPresentation(agentTitle: "Claude Code", kind: nil, cwd: "/work/cm-128")
        #expect(push.title == "Claude Code")
        #expect(push.subtitle == "cm-128")
    }

    @Test(arguments: [nil, "", "  ", "/", "///"] as [String?])
    func absentFolderIsEmpty(_ cwd: String?) {
        #expect(AgentNotificationPresentation(agentTitle: "Codex", kind: .finished, cwd: cwd).subtitle.isEmpty)
    }

    @Test func trailingSlashDoesNotLoseTheFolder() {
        #expect(AgentNotificationPresentation(agentTitle: "Codex", kind: .finished,
            cwd: " /work/cm-128/ \n").subtitle == "cm-128")
    }
}
