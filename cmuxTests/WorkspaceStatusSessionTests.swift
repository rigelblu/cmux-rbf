import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// Save and restore of a workspace's own status (#cm-109.2): a session that holds the field `taskStatusOwnID` is
/// decoded and encoded again, and the field must come back out.
struct WorkspaceStatusSessionTests {
    private func makeSnapshot() -> SessionWorkspaceSnapshot {
        SessionWorkspaceSnapshot(
            processTitle: "Terminal",
            isPinned: false,
            currentDirectory: "/tmp",
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: [],
            statusEntries: [],
            logEntries: []
        )
    }

    /// Reads three things, not one, so the same run also measures what a build without the field does with a
    /// session that holds it: the decode does not throw, every other field comes back (the
    /// `taskStatusOverride` pair included), and the encoded JSON keeps `taskStatusOwnID`.
    @Test
    func theOwnStatusFieldSurvivesDecodeAndEncode() throws {
        var snapshot = makeSnapshot()
        snapshot.taskStatusOverride = "review"
        snapshot.taskStatusInferredAtOverride = "working"
        let written = try JSONEncoder().encode(snapshot)
        var object = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        object["taskStatusOwnID"] = "parked"
        let withField = try JSONSerialization.data(withJSONObject: object)

        let decoded: SessionWorkspaceSnapshot
        do {
            decoded = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: withField)
        } catch {
            Issue.record("the decode threw on a session that holds taskStatusOwnID: \(error)")
            return
        }
        #expect(decoded.taskStatusOverride == "review")
        #expect(decoded.taskStatusInferredAtOverride == "working")

        let encodedAgain = try JSONEncoder().encode(decoded)
        let again = try #require(try JSONSerialization.jsonObject(with: encodedAgain) as? [String: Any])

        var expectedOthers = object
        expectedOthers.removeValue(forKey: "taskStatusOwnID")
        var otherFields = again
        otherFields.removeValue(forKey: "taskStatusOwnID")
        #expect(NSDictionary(dictionary: otherFields) == NSDictionary(dictionary: expectedOthers))

        #expect(
            again["taskStatusOwnID"] as? String == "parked",
            "taskStatusOwnID was dropped; the encoded keys are \(again.keys.sorted())"
        )
    }
}
