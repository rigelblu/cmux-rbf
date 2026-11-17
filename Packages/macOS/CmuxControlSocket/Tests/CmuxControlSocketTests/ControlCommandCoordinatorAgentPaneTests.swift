import Foundation
import Testing
@testable import CmuxControlSocket

// cmux-rbf #cm-126.3: the real coordinator dispatch and payload contract.
@MainActor
@Suite("ControlCommandCoordinator Agent Pane")
struct ControlCommandCoordinatorAgentPaneTests {
    private let terminalID = UUID()
    private let surfaceID = UUID()
    private let paneID = UUID()
    private let workspaceID = UUID()
    private let ownerStableID = UUID()
    private let page = URL(string: "https://example.org/update")!

    private func request(_ method: String = "agent_pane.show", _ params: [String: JSONValue]? = nil) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: params ?? [
            "surface_id": .string(terminalID.uuidString), "url": .string(page.absoluteString)
        ])
    }

    private func context(_ action: ControlAgentPaneApplied.Action = .opened, hasPane: Bool = true) -> FakeAgentPaneControlCommandContext {
        let context = FakeAgentPaneControlCommandContext()
        let planned: ControlAgentPanePlan.Action
        switch action {
        case .opened: planned = .open
        case .navigated: planned = .navigate(panelID: surfaceID, others: 2)
        case .heldDesignFocus: planned = .hold(panelID: hasPane ? surfaceID : nil, others: 2)
        case .cleared: planned = .clear(panelID: surfaceID, others: 2)
        case .alreadyCleared: planned = .alreadyCleared(panelID: surfaceID, others: 2)
        }
        context.checkResult = .ready(ControlAgentPanePlan(
            action: planned, workspaceID: workspaceID, terminalID: terminalID,
            ownerStableID: ownerStableID, url: page
        ))
        context.applied = ControlAgentPaneApplied(
            action: action, surfaceID: hasPane ? surfaceID : nil, paneID: hasPane ? paneID : nil,
            workspaceID: workspaceID, ownerSurfaceID: terminalID, ownerStableID: ownerStableID,
            url: page, others: 2
        )
        return context
    }

    private func payload(_ result: ControlCallResult?) throws -> [String: JSONValue] {
        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected Agent Pane payload, got \(String(describing: result))")
            throw MissingPayload()
        }
        return payload
    }

    private struct MissingPayload: Error {}

    private func expectOutcome(_ action: ControlAgentPaneApplied.Action) throws {
        let context = context(action)
        let coordinator = ControlCommandCoordinator(context: context)
        let result = try payload(coordinator.handle(request()))
        #expect(result["action"] == .string(action.rawValue))
        #expect(result["surface_id"] == .string(surfaceID.uuidString))
        #expect(result["pane_id"] == .string(paneID.uuidString))
        #expect(result["workspace_id"] == .string(workspaceID.uuidString))
        #expect(result["owner_surface_id"] == .string(terminalID.uuidString))
        #expect(result["owner_stable_id"] == .string(ownerStableID.uuidString))
        #expect(result["url"] == .string(page.absoluteString))
        #expect(result["others"] == .int(2))
        for (key, kind, id) in [
            ("surface_ref", ControlHandleKind.surface, surfaceID),
            ("pane_ref", .pane, paneID), ("workspace_ref", .workspace, workspaceID),
            ("owner_surface_ref", .surface, terminalID)
        ] {
            #expect(result[key] == coordinator.ref(kind, id))
        }
        #expect(context.checkCalls.count == 1)
        #expect(context.checkCalls.first?.0 == terminalID)
        #expect(context.checkCalls.first?.1 == page)
        guard case .ready(let plan) = context.checkResult else { return }
        #expect(context.applyCalls == [plan])
    }

    @Test("opened maps the actual result with refs, owner ids, URL, and others")
    func openedPayloadHasRefs() throws { try expectOutcome(.opened) }

    @Test("navigated maps the actual result without losing others")
    func navigatedPayloadHasRefs() throws { try expectOutcome(.navigated) }

    @Test("a held update names the existing pane and keeps held-design-focus")
    func heldPayloadHasRefs() throws { try expectOutcome(.heldDesignFocus) }

    @Test("a hold before creation returns null surface and pane handles")
    func heldBeforeCreationHasNullHandles() throws {
        let context = context(.heldDesignFocus, hasPane: false)
        let result = try payload(ControlCommandCoordinator(context: context).handle(request()))
        #expect(result["action"] == .string("held-design-focus"))
        for key in ["surface_id", "surface_ref", "pane_id", "pane_ref"] {
            #expect(result[key] == .null)
        }
        #expect(result["owner_surface_id"] == .string(terminalID.uuidString))
        #expect(result["others"] == .int(2))
    }

    private struct RefusalCase: Sendable, CustomStringConvertible {
        let refusal: ControlAgentPaneRefusal
        let code: String
        let reason: String
        var description: String { reason }
    }

    private nonisolated static let refusals: [RefusalCase] = [
        .init(refusal: .notFound(surfaceID: UUID()), code: "not_found", reason: "not_found"),
        .init(refusal: .notTerminal(surfaceID: UUID(), type: "browser"), code: "invalid_params", reason: "not_terminal"),
        .init(refusal: .inDock, code: "unsupported", reason: "in_dock"),
        .init(refusal: .badScheme, code: "invalid_params", reason: "bad_scheme"),
        .init(refusal: .figmaAddress, code: "invalid_params", reason: "figma_address"),
        .init(refusal: .urlBlocked(message: "Policy refusal"), code: "browser_url_blocked", reason: "url_blocked"),
        .init(refusal: .insecureHTTP(host: "example.org"), code: "invalid_params", reason: "insecure_http"),
        .init(refusal: .browserOff, code: "unavailable", reason: "browser_off"),
        .init(refusal: .noAgentPane, code: "invalid_params", reason: "no_agent_pane")
    ]

    @Test("each refusal keeps its code and reason and never calls apply", arguments: refusals)
    private func refusalsNeverApply(_ testCase: RefusalCase) throws {
        let context = context()
        context.checkResult = .refused(testCase.refusal)
        let result = ControlCommandCoordinator(context: context).handle(request())
        guard case .err(let code, let message, .object(let data)) = result else {
            Issue.record("expected refusal \(testCase.reason), got \(String(describing: result))")
            return
        }
        #expect(code == testCase.code)
        #expect(data["reason"] == .string(testCase.reason))
        #expect(context.checkCalls.count == 1)
        #expect(context.applyCalls.isEmpty, "apply called \(context.applyCalls.count) times, expected 0")
        switch testCase.refusal {
        case .notFound(let id), .notTerminal(let id, _):
            #expect(data["surface"] == .string(id.uuidString))
        case .insecureHTTP(let host): #expect(data["host"] == .string(host))
        case .urlBlocked(let expected):
            #expect(message == expected)
            #expect(data["url"] == .string(page.absoluteString))
        default: break
        }
    }

    @Test("missing or invalid show parameters never reach the witness", arguments: [
        [String: JSONValue](), ["url": .string("https://example.org")],
        ["surface_id": .string(UUID().uuidString)],
        ["surface_id": .string("no-surface"), "url": .string("https://example.org")],
        ["surface_id": .string(UUID().uuidString), "url": .int(17)]
    ])
    func invalidShowParamsNeverCallWitness(_ params: [String: JSONValue]) {
        let context = context()
        let result = ControlCommandCoordinator(context: context).handle(request("agent_pane.show", params))
        guard case .err(let code, _, .object(let data)) = result else {
            Issue.record("expected invalid_params, got \(String(describing: result))")
            return
        }
        #expect(code == "invalid_params")
        #expect(data["reason"] == .string("invalid_show_params"))
        #expect(context.checkCalls.isEmpty)
        #expect(context.applyCalls.isEmpty)
    }

    @Test("list keeps live and stable owners separate, including an orphan")
    func listRowsKeepLiveAndStableOwnerSeparate() throws {
        let context = context()
        context.summaries = [terminalID, nil].map { owner in
            ControlAgentPaneSummary(
                surfaceID: UUID(), paneID: paneID, workspaceID: workspaceID,
                ownerSurfaceID: owner, ownerStableID: ownerStableID, url: page.absoluteString, others: 1
            )
        }
        let coordinator = ControlCommandCoordinator(context: context)
        let result = try payload(coordinator.handle(request("agent_pane.list", [
            "workspace_id": coordinator.ref(.workspace, workspaceID)
        ])))
        guard case .array(let rows) = result["agent_panes"] else {
            Issue.record("missing agent_panes array")
            return
        }
        #expect(rows.count == 2)
        for (index, row) in rows.enumerated() {
            guard case .object(let fields) = row else { Issue.record("list row is not an object"); continue }
            #expect(fields["owner_stable_id"] == .string(ownerStableID.uuidString))
            #expect(fields["owner_surface_id"] == (index == 0 ? .string(terminalID.uuidString) : .null))
            #expect(fields["owner_surface_ref"] == (index == 0 ? coordinator.ref(.surface, terminalID) : .null))
            #expect(fields["others"] == .int(1))
            #expect(fields["action"] == nil)
            #expect(fields["surface_ref"] != nil)
            #expect(fields["pane_ref"] == coordinator.ref(.pane, paneID))
            #expect(fields["workspace_ref"] == coordinator.ref(.workspace, workspaceID))
            #expect(fields["url"] == .string(page.absoluteString))
        }
        #expect(context.listCalls.count == 1)
        #expect(context.listCalls[0] == workspaceID)
    }

    @Test("an empty all-workspace list is an empty array")
    func emptyAgentPaneListIsAnArray() throws {
        let context = context()
        let result = try payload(ControlCommandCoordinator(context: context).handle(request("agent_pane.list", [:])))
        #expect(result["agent_panes"] == .array([]))
        #expect(context.listCalls.count == 1)
        #expect(context.listCalls[0] == nil)
    }

    @Test("a missing workspace gives not_found; invalid workspace params reach no witness")
    func unknownAgentPaneWorkspaceFails() {
        let context = context()
        context.summaries = nil
        let coordinator = ControlCommandCoordinator(context: context)
        let missing = coordinator.handle(request("agent_pane.list", ["workspace_id": .string(workspaceID.uuidString)]))
        guard case .err(let code, _, _) = missing else { Issue.record("expected missing workspace error"); return }
        #expect(code == "not_found")
        let invalid = coordinator.handle(request("agent_pane.list", ["workspace_id": .int(1)]))
        guard case .err(let invalidCode, _, _) = invalid else { Issue.record("expected invalid workspace error"); return }
        #expect(invalidCode == "invalid_params")
        #expect(context.listCalls.count == 1)
    }

    @Test("every method rejects even otherwise valid relay provenance", arguments: ["agent_pane.show", "agent_pane.list", "agent_pane.clear"])
    func localOnlyAgentPaneRejectsRelay(_ method: String) {
        let context = context()
        var params = request().params
        params["_cmux_remote_workspace_id"] = .string(workspaceID.uuidString)
        let result = ControlCommandCoordinator(context: context).handle(request(method, params))
        guard case .err(let code, _, _) = result else { Issue.record("expected relay refusal"); return }
        #expect(code == "remote_relay_authentication_failed")
        #expect(context.checkCalls.isEmpty && context.applyCalls.isEmpty && context.listCalls.isEmpty)
    }

    @Test("a failed apply returns internal_error")
    func failedAgentPaneApplyIsAnInternalError() {
        let context = context()
        context.applied = nil
        let result = ControlCommandCoordinator(context: context).handle(request())
        guard case .err(let code, _, _) = result else { Issue.record("expected internal_error"); return }
        #expect(code == "internal_error")
        #expect(context.applyCalls.count == 1)
    }

    // MARK: - clear (cmux-rbf #cm-126.14)

    private var clearRequest: ControlRequest {
        request("agent_pane.clear", ["surface_id": .string(terminalID.uuidString)])
    }

    private let clearedPage = URL(string: "file:///cleared/pane.html")!

    private func clearContext(_ action: ControlAgentPaneApplied.Action, planned: ControlAgentPanePlan.Action) -> FakeAgentPaneControlCommandContext {
        let context = FakeAgentPaneControlCommandContext()
        context.clearCheckResult = .ready(ControlAgentPanePlan(
            action: planned, workspaceID: workspaceID, terminalID: terminalID,
            ownerStableID: ownerStableID, url: clearedPage
        ))
        context.applied = ControlAgentPaneApplied(
            action: action, surfaceID: surfaceID, paneID: paneID, workspaceID: workspaceID,
            ownerSurfaceID: terminalID, ownerStableID: ownerStableID, url: clearedPage, others: 2
        )
        return context
    }

    @Test("clear checks the caller once, applies the plan it got, and maps the result with refs and the action")
    func clearMapsTheAppliedResult() throws {
        let cases: [(ControlAgentPaneApplied.Action, ControlAgentPanePlan.Action)] = [
            (.cleared, .clear(panelID: surfaceID, others: 2)),
            (.alreadyCleared, .alreadyCleared(panelID: surfaceID, others: 2)),
            (.heldDesignFocus, .holdClear(panelID: surfaceID, others: 2))
        ]
        for (action, planned) in cases {
            let context = clearContext(action, planned: planned)
            let coordinator = ControlCommandCoordinator(context: context)
            let result = try payload(coordinator.handle(clearRequest))
            #expect(result["action"] == .string(action.rawValue))
            #expect(result["surface_id"] == .string(surfaceID.uuidString))
            #expect(result["surface_ref"] == coordinator.ref(.surface, surfaceID))
            #expect(result["pane_ref"] == coordinator.ref(.pane, paneID))
            #expect(result["workspace_ref"] == coordinator.ref(.workspace, workspaceID))
            #expect(result["owner_surface_id"] == .string(terminalID.uuidString))
            #expect(result["url"] == .string(clearedPage.absoluteString))
            #expect(result["others"] == .int(2))
            #expect(context.clearCheckCalls == [terminalID])
            #expect(context.checkCalls.isEmpty, "clear must not run show's page check")
            guard case .ready(let plan) = context.clearCheckResult else { continue }
            #expect(context.applyCalls == [plan])
        }
    }

    @Test("a clear refusal keeps its code and reason, names no page, and never applies", arguments: refusals)
    private func clearRefusalsNeverApply(_ testCase: RefusalCase) {
        let context = FakeAgentPaneControlCommandContext()
        context.clearCheckResult = .refused(testCase.refusal)
        let result = ControlCommandCoordinator(context: context).handle(clearRequest)
        guard case .err(let code, _, .object(let data)) = result else {
            Issue.record("expected refusal \(testCase.reason), got \(String(describing: result))")
            return
        }
        #expect(code == testCase.code)
        #expect(data["reason"] == .string(testCase.reason))
        #expect(data["url"] == nil, "a clear has no requested page to name")
        #expect(context.clearCheckCalls.count == 1)
        #expect(context.applyCalls.isEmpty)
    }

    @Test("a missing or malformed clear surface_id reaches no witness", arguments: [
        [String: JSONValue](), ["surface_id": .string("no-surface")], ["surface_id": .int(7)]
    ])
    func clearInvalidParamsNeverCallWitness(_ params: [String: JSONValue]) {
        let context = FakeAgentPaneControlCommandContext()
        let result = ControlCommandCoordinator(context: context).handle(request("agent_pane.clear", params))
        guard case .err(let code, _, .object(let data)) = result else {
            Issue.record("expected invalid_params, got \(String(describing: result))")
            return
        }
        #expect(code == "invalid_params")
        #expect(data["reason"] == .string("invalid_show_params"))
        #expect(context.clearCheckCalls.isEmpty && context.checkCalls.isEmpty && context.applyCalls.isEmpty)
    }

    @Test("a failed clear apply returns internal_error")
    func failedClearApplyIsAnInternalError() {
        let context = clearContext(.cleared, planned: .clear(panelID: surfaceID, others: 0))
        context.applied = nil
        let result = ControlCommandCoordinator(context: context).handle(clearRequest)
        guard case .err(let code, let message, _) = result else { Issue.record("expected internal_error"); return }
        #expect(code == "internal_error")
        #expect(message == "Agent Pane could not be cleared")
        #expect(context.applyCalls.count == 1)
    }

    @Test("a clear held with no pane open yet answers null for the surface, the pane and the url")
    func heldClearBeforeAnyPaneHasNullHandlesAndUrl() throws {
        let context = clearContext(.heldDesignFocus, planned: .holdClear(panelID: nil, others: 0))
        context.applied = ControlAgentPaneApplied(
            action: .heldDesignFocus, surfaceID: nil, paneID: nil, workspaceID: workspaceID,
            ownerSurfaceID: terminalID, ownerStableID: ownerStableID, url: nil, others: 0
        )
        let result = try payload(ControlCommandCoordinator(context: context).handle(clearRequest))
        #expect(result["action"] == .string("held-design-focus"))
        for key in ["surface_id", "surface_ref", "pane_id", "pane_ref", "url"] {
            #expect(result[key] == .null, "\(key) was \(String(describing: result[key]))")
        }
        #expect(result["owner_surface_id"] == .string(terminalID.uuidString))
    }
}
