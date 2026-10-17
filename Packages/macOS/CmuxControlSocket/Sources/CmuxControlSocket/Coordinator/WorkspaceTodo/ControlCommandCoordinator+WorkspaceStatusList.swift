internal import Foundation

/// `workspace.status.list` (#cm-109): the list of workspace statuses in use, where it came from, whether the
/// controls are on, and the problems the pill lists. Read-only; it takes no routing and no workspace.
extension ControlCommandCoordinator {
    /// `workspace.status.list`. With no context it answers what the status methods next to it answer.
    func workspaceStatusList(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let snapshot = context?.controlWorkspaceStatusList() else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        return .ok(.object([
            "controls_enabled": .bool(snapshot.controlsEnabled),
            "source": .string(snapshot.source.rawValue),
            "statuses": .array(snapshot.statuses.map { status in
                .object([
                    "id": .string(status.id),
                    "name": orNull(status.name),
                    "extends": orNull(status.extends),
                    "color": orNull(status.color),
                    "color_hex": orNull(status.colorHex),
                ])
            }),
            "problems": .array(snapshot.problems.map { problem in
                .object([
                    "code": .string(problem.code),
                    "entry": problem.entry.map { .int(Int64($0)) } ?? .null,
                    "id": orNull(problem.id),
                    "value": orNull(problem.value),
                    "message": .string(workspaceStatusProblemMessage(problem)),
                ])
            }),
        ]))
    }

    /// One English sentence for a problem, in the third person, built from its code and fields. Not localized, as
    /// every socket message is. A script reads `code`; the pill shows the localized sentence for the same case.
    func workspaceStatusProblemMessage(_ problem: ControlWorkspaceStatusListSnapshot.Problem) -> String {
        let entry = problem.entry.map(String.init) ?? "?"
        let id = problem.id ?? "?"
        let value = problem.value ?? ""
        switch problem.code {
        case "file_not_read":
            return problem.fileMissing
                ? "cmux.json is missing, so the status list in use is kept until the file is back."
                : "cmux.json could not be read, so nothing in the status list changed."
        case "not_a_list":
            return "workspaceStatuses in cmux.json is not a list, so nothing in the status list changed."
        case "entry_not_an_object":
            return "Entry \(entry) is not a status entry, so it was skipped."
        case "no_id":
            return "Entry \(entry) has no id, so it was skipped."
        case "reserved_id":
            return "Entry \(entry) uses the id \"\(id)\", which cmux keeps for itself, so it was skipped."
        case "repeated_id":
            return "Entry \(entry) repeats the id \"\(id)\", so the first one is kept and this one was skipped."
        case "no_name":
            return "Entry \(entry), \"\(id)\", has no name, so it was skipped."
        case "no_extends":
            return "Entry \(entry), \"\(id)\", has no \"extends\", so it was skipped."
        case "unknown_extends":
            return "Entry \(entry), \"\(id)\", extends \"\(value)\", which is not a cmux status, so it was skipped; "
                + "the cmux statuses are todo, working, needs-attention, review and done."
        case "unknown_icon":
            return "Entry \(entry), \"\(id)\", names the icon \"\(value)\", which is neither one of cmux's shapes "
                + "nor an SF Symbol on this Mac, so it is drawn as if it named none. Use dotted-ring, ring, quarter, "
                + "half, three-quarters, full, check or pause, or an SF Symbol's name in lowercase, such as moon.zzz.fill." // (#cm-109.6)
        case "color_not_in_this_app":
            return "The status \"\(id)\" names the color \"\(value)\", which this app does not have, "
                + "so setting it keeps the workspace's color."
        default:
            return "The status list has a problem (\(problem.code))."
        }
    }
}
