import Foundation
import Testing
@testable import CmuxControlSocket

/// What a script reads from the status methods once a workspace can hold one of Tom's own statuses (#cm-109.2).
/// These tests drive the fake of the app in `ControlCommandCoordinatorWorkspaceTodoTests.swift`, so they cover the
/// shaping only.
@MainActor
@Suite("ControlCommandCoordinator workspace-status additions")
struct ControlCommandCoordinatorWorkspaceStatusTests {
    private func makeCoordinator() -> (ControlCommandCoordinator, FakeWorkspaceTodoControlCommandContext) {
        let context = FakeWorkspaceTodoControlCommandContext()
        return (ControlCommandCoordinator(context: context), context)
    }

    private func request(_ method: String, _ params: [String: JSONValue] = [:]) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: params)
    }

    private func statusSnapshot(_ workspaceID: UUID) -> ControlWorkspaceTodoStatusSnapshot {
        ControlWorkspaceTodoStatusSnapshot(
            workspaceID: workspaceID,
            effective: "review",
            inferred: "working",
            overrideStatus: "review",
            overrideInferredAt: "working",
            signals: ControlWorkspaceTodoStatusSnapshot.Signals(
                anyAgentNeedsInput: false,
                anyAgentRunning: true,
                anyOpenPullRequest: false,
                hasPullRequests: false,
                allPullRequestsMergedOrClosed: false,
                isGitDirty: true
            )
        )
    }

    /// Test 2. A script reads the id of the status set by hand in `status_id`, beside the fields it reads today.
    @Test func statusGetCarriesTheStatusIDKey() throws {
        let (coordinator, context) = makeCoordinator()
        context.statusResolution = .resolved(windowID: nil, status: statusSnapshot(UUID()))
        let result = try #require(coordinator.handle(request("workspace.status.get")))
        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected ok payload, got \(result)")
            return
        }
        #expect(
            payload["status_id"] != nil,
            "workspace.status.get has no status_id key; its keys are \(payload.keys.sorted())"
        )
    }

    /// Test 11. `workspace.status.list` is a method the socket knows and answers.
    @Test func statusListIsAKnownMethod() throws {
        let (coordinator, _) = makeCoordinator()
        let result = coordinator.handle(request("workspace.status.list"))
        #expect(result != nil, "the coordinator does not handle workspace.status.list")
    }

    // MARK: - The socket's answer (step 2e)

    private typealias Snapshot = ControlWorkspaceTodoStatusSnapshot
    private typealias ListSnapshot = ControlWorkspaceStatusListSnapshot

    private func makeStatusCoordinator() -> (ControlCommandCoordinator, FakeWorkspaceStatusControlCommandContext) {
        let context = FakeWorkspaceStatusControlCommandContext()
        return (ControlCommandCoordinator(context: context), context)
    }

    private func snapshot(
        statusID: String?, overrideStatus: String? = "review", overrideInferredAt: String? = "working"
    ) -> Snapshot {
        Snapshot(
            workspaceID: UUID(),
            effective: "review",
            inferred: "working",
            overrideStatus: overrideStatus,
            overrideInferredAt: overrideInferredAt,
            signals: Snapshot.Signals(
                anyAgentNeedsInput: false, anyAgentRunning: true, anyOpenPullRequest: false,
                hasPullRequests: false, allPullRequestsMergedOrClosed: false, isGitDirty: true
            ),
            statusID: statusID
        )
    }

    private func payload(_ result: ControlCallResult?) throws -> [String: JSONValue] {
        guard case .ok(.object(let payload))? = result else {
            throw PayloadError(text: "expected ok payload, got \(String(describing: result))")
        }
        return payload
    }

    private struct PayloadError: Error, CustomStringConvertible { let text: String; var description: String { text } }

    /// `status_id` carries the id in the answer of `get`, `set` and `cycle`, and is `null` when the snapshot has none.
    @Test func statusIDIsInTheAnswerOfGetSetAndCycle() throws {
        let (coordinator, context) = makeStatusCoordinator()
        for method in ["workspace.status.get", "workspace.status.set", "workspace.status.cycle"] {
            let params: [String: JSONValue] = method == "workspace.status.set" ? ["status": .string("parked")] : [:]
            context.statusResolution = .resolved(windowID: nil, status: snapshot(statusID: "parked"))
            let held = try payload(coordinator.handle(request(method, params)))
            #expect(held["status_id"] == .string("parked"), "\(method) answered \(String(describing: held["status_id"]))")

            context.statusResolution = .resolved(windowID: nil, status: snapshot(statusID: nil))
            let none = try payload(coordinator.handle(request(method, params)))
            #expect(none["status_id"] == .null, "\(method) answered \(String(describing: none["status_id"])) for no status")
        }
    }

    /// `override` is written exactly as the snapshot says: both fields give the object, either missing gives `null`.
    @Test func overrideIsWrittenOrNullAsTheSnapshotSays() throws {
        let (coordinator, context) = makeStatusCoordinator()
        context.statusResolution = .resolved(windowID: nil, status: snapshot(statusID: "parked"))
        let written = try payload(coordinator.handle(request("workspace.status.get")))
        #expect(written["override"] == .object([
            "status": .string("review"), "inferred_at_override": .string("working"),
        ]))

        context.statusResolution = .resolved(
            windowID: nil, status: snapshot(statusID: "parked", overrideStatus: nil, overrideInferredAt: nil)
        )
        let absent = try payload(coordinator.handle(request("workspace.status.get")))
        #expect(absent["override"] == .null)
    }

    /// A refused id comes back as `invalid_params` with `data.accepted` in the order it was handed and the sentence
    /// naming them in the same order.
    @Test func aRefusedIDCarriesTheAcceptedIDsInTheOrderItWasHanded() throws {
        let (coordinator, context) = makeStatusCoordinator()
        let accepted = ["doing", "parked", "todo", "working", "needs-attention", "review", "done", "auto", "none"]
        context.statusResolution = .unknownStatus("later", accepted: accepted)
        let result = try #require(coordinator.handle(request("workspace.status.set", ["status": .string("later")])))
        guard case .err(let code, let message, let data) = result else {
            Issue.record("expected an error, got \(result)")
            return
        }
        #expect(code == "invalid_params")
        #expect(message == "status must be one of: doing, parked, todo, working, needs-attention, review, done, auto, none")
        #expect(data == .object([
            "status": .string("later"),
            "accepted": .array(accepted.map { JSONValue.string($0) }),
        ]))
    }

    private func status(
        _ id: String, name: String? = nil, extends: String? = nil, color: String? = nil, hex: String? = nil
    ) -> ListSnapshot.Status {
        ListSnapshot.Status(id: id, name: name, extends: extends, color: color, colorHex: hex)
    }

    /// `workspace.status.list` answers the statuses in order with each field, the source, and the switch.
    @Test func theListAnswersItsStatusesInOrderWithEachField() throws {
        let (coordinator, context) = makeStatusCoordinator()
        context.statusList = ListSnapshot(
            controlsEnabled: true,
            source: .file,
            statuses: [
                status("parked", name: "Parked", extends: "todo", color: "#445566", hex: "#445566"),
                status("doing", name: "Doing", extends: "working", color: "Orange", hex: nil),
                status("done"),
            ],
            problems: []
        )
        let answer = try payload(coordinator.handle(request("workspace.status.list")))
        #expect(answer["controls_enabled"] == .bool(true))
        #expect(answer["source"] == .string("file"))
        #expect(answer["problems"] == .array([]))
        #expect(answer["statuses"] == .array([
            .object([
                "id": .string("parked"), "name": .string("Parked"), "extends": .string("todo"),
                "color": .string("#445566"), "color_hex": .string("#445566"),
            ]),
            .object([
                "id": .string("doing"), "name": .string("Doing"), "extends": .string("working"),
                "color": .string("Orange"), "color_hex": .null,
            ]),
            .object([
                "id": .string("done"), "name": .null, "extends": .null, "color": .null, "color_hex": .null,
            ]),
        ]))
        #expect(context.listReads == 1)
    }

    @Test func theListNamesEachSourceAndBothStatesOfTheSwitch() throws {
        let (coordinator, context) = makeStatusCoordinator()
        for (source, word) in [(ListSnapshot.Source.file, "file"), (.stored, "stored"), (.cmux, "cmux")] {
            for enabled in [false, true] {
                context.statusList = ListSnapshot(controlsEnabled: enabled, source: source, statuses: [], problems: [])
                let answer = try payload(coordinator.handle(request("workspace.status.list")))
                #expect(answer["source"] == .string(word))
                #expect(answer["controls_enabled"] == .bool(enabled))
            }
        }
    }

    /// With no context the list answers what the three status methods answer.
    @Test func theListWithNoContextAnswersWhatItsNeighboursAnswer() throws {
        let coordinator = ControlCommandCoordinator(context: nil)
        let list = try #require(coordinator.handle(request("workspace.status.list")))
        let get = try #require(coordinator.handle(request("workspace.status.get")))
        #expect(list == get)
        #expect(list == .err(code: "unavailable", message: "TabManager not available", data: nil))
    }

    /// Each of the eleven codes: all four fields and the sentence, pinned with fixed text. The sentences are third
    /// person and one for each code.
    @Test func aProblemAnswersItsCodeEntryIDValueAndMessage() throws {
        typealias P = ListSnapshot.Problem
        let rows: [(P, JSONValue)] = [
            (P(code: "file_not_read", entry: nil, id: nil, value: nil, fileMissing: true), .object([
                "code": .string("file_not_read"), "entry": .null, "id": .null, "value": .null,
                "message": .string("cmux.json is missing, so the status list in use is kept until the file is back."),
            ])),
            (P(code: "file_not_read", entry: nil, id: nil, value: "Unexpected character at line 3"), .object([
                "code": .string("file_not_read"), "entry": .null, "id": .null,
                "value": .string("Unexpected character at line 3"),
                "message": .string("cmux.json could not be read, so nothing in the status list changed."),
            ])),
            (P(code: "not_a_list", entry: nil, id: nil, value: nil), .object([
                "code": .string("not_a_list"), "entry": .null, "id": .null, "value": .null,
                "message": .string("workspaceStatuses in cmux.json is not a list, so nothing in the status list changed."),
            ])),
            (P(code: "entry_not_an_object", entry: 2, id: nil, value: nil), .object([
                "code": .string("entry_not_an_object"), "entry": .int(2), "id": .null, "value": .null,
                "message": .string("Entry 2 is not a status entry, so it was skipped."),
            ])),
            (P(code: "no_id", entry: 3, id: nil, value: nil), .object([
                "code": .string("no_id"), "entry": .int(3), "id": .null, "value": .null,
                "message": .string("Entry 3 has no id, so it was skipped."),
            ])),
            (P(code: "reserved_id", entry: 4, id: "auto", value: nil), .object([
                "code": .string("reserved_id"), "entry": .int(4), "id": .string("auto"), "value": .null,
                "message": .string("Entry 4 uses the id \"auto\", which cmux keeps for itself, so it was skipped."),
            ])),
            (P(code: "repeated_id", entry: 5, id: "parked", value: nil), .object([
                "code": .string("repeated_id"), "entry": .int(5), "id": .string("parked"), "value": .null,
                "message": .string("Entry 5 repeats the id \"parked\", so the first one is kept and this one was skipped."),
            ])),
            (P(code: "no_name", entry: 6, id: "parked", value: nil), .object([
                "code": .string("no_name"), "entry": .int(6), "id": .string("parked"), "value": .null,
                "message": .string("Entry 6, \"parked\", has no name, so it was skipped."),
            ])),
            (P(code: "no_extends", entry: 7, id: "parked", value: nil), .object([
                "code": .string("no_extends"), "entry": .int(7), "id": .string("parked"), "value": .null,
                "message": .string("Entry 7, \"parked\", has no \"extends\", so it was skipped."),
            ])),
            (P(code: "unknown_extends", entry: 8, id: "parked", value: "Paused"), .object([
                "code": .string("unknown_extends"), "entry": .int(8), "id": .string("parked"),
                "value": .string("Paused"),
                "message": .string(
                    "Entry 8, \"parked\", extends \"Paused\", which is not a cmux status, so it was skipped; "
                        + "the cmux statuses are todo, working, needs-attention, review and done."
                ),
            ])),
            (P(code: "unknown_icon", entry: 9, id: "parked", value: "Half"), .object([
                "code": .string("unknown_icon"), "entry": .int(9), "id": .string("parked"),
                "value": .string("Half"),
                "message": .string(
                    "Entry 9, \"parked\", names the icon \"Half\", which cmux does not have, so it is kept "
                        + "and drawn as if it named no icon; the icons are dotted-ring, ring, quarter, half, "
                        + "three-quarters, full, check and pause." // (#cm-109.3)
                ),
            ])),
            (P(code: "color_not_in_this_app", entry: nil, id: "parked", value: "Mauve"), .object([
                "code": .string("color_not_in_this_app"), "entry": .null, "id": .string("parked"),
                "value": .string("Mauve"),
                "message": .string(
                    "The status \"parked\" names the color \"Mauve\", which this app does not have, "
                        + "so setting it keeps the workspace's color."
                ),
            ])),
        ]
        let (coordinator, context) = makeStatusCoordinator()
        context.statusList = ListSnapshot(
            controlsEnabled: true, source: .file, statuses: [], problems: rows.map(\.0)
        )
        let answer = try payload(coordinator.handle(request("workspace.status.list")))
        #expect(answer["problems"] == .array(rows.map(\.1)), "the problems came back as \(String(describing: answer["problems"]))")
        // Eleven codes, twelve rows: `file_not_read` has two sentences.
        #expect(Set(rows.map(\.0.code)).count == 11)
    }
}
