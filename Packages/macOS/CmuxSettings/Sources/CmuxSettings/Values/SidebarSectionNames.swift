import Foundation

/// User-supplied section names; localized defaults remain owned by the app's header text.
public enum SidebarSectionNames {
    public enum Key: String, CaseIterable {
        case pinned
        case workspaces
        case statuses
    }

    public static func normalized(_ object: [String: Any]) -> [String: String] {
        var names: [String: String] = [:]
        for key in Key.allCases {
            guard let name = object[key.rawValue] as? String else { continue }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            names[key.rawValue] = trimmed
        }
        return names
    }
}
