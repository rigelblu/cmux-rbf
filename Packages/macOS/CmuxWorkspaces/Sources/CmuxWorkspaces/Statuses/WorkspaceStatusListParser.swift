import Foundation

/// Checks the value under `workspaceStatuses` in `cmux.json` and builds the list from what passes.
///
/// It takes the value as `JSONSerialization` gives it, so the package reads no file. One pass, top to bottom.
/// A bad entry is skipped with one problem, the first rule it breaks, and the rest are kept. A kept entry whose
/// `icon` is neither one of the eight names nor a known SF Symbol is kept with one problem too.
public struct WorkspaceStatusListParser: Sendable {
    private let symbolExists: @Sendable (String) -> Bool

    /// Creates a parser. The default `symbolExists` check knows no symbols.
    public init(symbolExists: @escaping @Sendable (String) -> Bool = { _ in false }) {
        self.symbolExists = symbolExists
    }

    /// Checks the value under the key.
    ///
    /// - Parameter value: The value under `workspaceStatuses`, or `nil` when the file has no such key.
    /// - Returns: `list` is `nil` when the file has no key, and when the key holds something that is not an
    ///   array. The two are told apart by `problems`: `.notAList` for the second, none for the first.
    public func parse(_ value: Any?) -> (list: WorkspaceStatusList?, problems: [WorkspaceStatusListProblem]) {
        guard let value else { return (nil, []) }
        guard let rawEntries = value as? [Any] else { return (nil, [.notAList]) }

        var entries: [WorkspaceStatusEntry] = []
        var problems: [WorkspaceStatusListProblem] = []
        for (index, raw) in rawEntries.enumerated() {
            let place = index + 1
            switch check(raw, place: place, taken: entries) {
            case .kept(let entry, let problem):
                entries.append(entry)
                if let problem { problems.append(problem) }
            case .skipped(let problem): problems.append(problem)
            }
        }
        return (WorkspaceStatusList(entries: entries, source: .file), problems)
    }

    private enum Checked {
        /// The kept entry and, for a kept entry that has something wrong, the one problem.
        case kept(WorkspaceStatusEntry, problem: WorkspaceStatusListProblem?)
        case skipped(WorkspaceStatusListProblem)
    }

    private static let reservedIDs: Set<String> = ["auto", "none"]

    private func check(
        _ raw: Any,
        place: Int,
        taken: [WorkspaceStatusEntry]
    ) -> Checked {
        guard let object = raw as? [String: Any] else { return .skipped(.entryNotAnObject(entry: place)) }

        guard let id = trimmedText(object["id"]) else { return .skipped(.noID(entry: place)) }
        if Self.reservedIDs.contains(id.lowercased()) { return .skipped(.reservedID(entry: place, id: id)) }
        if taken.contains(where: { $0.id == id }) { return .skipped(.repeatedID(entry: place, id: id)) }

        guard let name = trimmedText(object["name"]) else { return .skipped(.noName(entry: place, id: id)) }

        let color = asTyped(object["color"])
        // Its problem is returned only with a kept entry, so an entry skipped for another reason gets that problem only.
        // It is read on both return paths below: an icon on one of cmux's five applies, unlike `extends`.
        let (icon, iconProblem) = checkIcon(object["icon"], place: place, id: id)

        // One of cmux's five behaves as itself: its `extends` is ignored, whatever it holds.
        if WorkspaceTaskStatus(rawValue: id) != nil {
            return .kept(
                WorkspaceStatusEntry(id: id, name: name, extends: nil, color: color, icon: icon),
                problem: iconProblem
            )
        }

        // A missing `extends`, and one that is only blank, are both "not given".
        guard let rawExtends = object["extends"], !isBlankText(rawExtends) else {
            return .skipped(.noExtends(entry: place, id: id))
        }
        guard let text = trimmedText(rawExtends), let extends = WorkspaceTaskStatus(rawValue: text) else {
            return .skipped(.unknownExtends(entry: place, id: id, value: typed(rawExtends)))
        }
        return .kept(
            WorkspaceStatusEntry(id: id, name: name, extends: extends, color: color, icon: icon),
            problem: iconProblem
        )
    }

    /// The icon a value names. A missing key, `null` and blank text are all "not given": no icon, no problem.
    /// Text that, trimmed, is exactly one of the eight names gives that shape. Text that `symbolExists` knows
    /// gives that symbol. Anything else, a number included, gives no icon and one problem that shows the value as
    /// he typed it.
    private func checkIcon(
        _ value: Any?,
        place: Int,
        id: String
    ) -> (icon: WorkspaceStatusGlyph?, problem: WorkspaceStatusListProblem?) {
        guard let value, !(value is NSNull), !isBlankText(value) else { return (nil, nil) }
        if let text = trimmedText(value) {
            if let icon = WorkspaceStatusIcon(rawValue: text) { return (.shape(icon), nil) }
            if symbolExists(text) { return (.symbol(text), nil) }
        }
        return (nil, .unknownIcon(entry: place, id: id, value: typed(value)))
    }

    /// The text of a JSON string, trimmed, or `nil` when the value is not text or is empty once trimmed.
    private func trimmedText(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The text of a JSON string exactly as typed, or `nil` when the value is not text or is blank.
    private func asTyped(_ value: Any?) -> String? {
        guard let text = value as? String, !isBlankText(text) else { return nil }
        return text
    }

    private func isBlankText(_ value: Any) -> Bool {
        guard let text = value as? String else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A value of the file shown as he typed it: text as it is; `true`, `false`, a number and `null` as JSON writes
    /// them; a list or an object as compact one-line JSON. An object's keys are written in sorted order, because
    /// the parsed value does not keep the order he typed them in.
    private func typed(_ value: Any) -> String {
        if let text = value as? String { return text }
        let options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
        // `data(withJSONObject:)` raises an Objective-C exception, which `try?` does not catch, for a value JSON
        // cannot write. No file Tom writes can reach that; the check is for a caller of this public parser.
        if JSONSerialization.isValidJSONObject([value]),
           let data = try? JSONSerialization.data(withJSONObject: value, options: options),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return String(describing: value)
    }
}
