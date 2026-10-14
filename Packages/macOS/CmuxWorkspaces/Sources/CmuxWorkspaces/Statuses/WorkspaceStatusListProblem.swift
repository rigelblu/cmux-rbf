/// One thing wrong with the list. `entry` is the 1-based place in the file, counting skipped entries.
public enum WorkspaceStatusListProblem: Equatable, Sendable {
    /// The file is missing, unreadable, or does not parse. The last list stays in use. `missing` picks the
    /// sentence and leaves "Open cmux.json" off. Found by the store, never by the parser.
    case fileNotRead(missing: Bool, detail: String)
    /// `workspaceStatuses` is not an array.
    case notAList
    case entryNotAnObject(entry: Int)
    case noID(entry: Int)
    /// The id is `auto` or `none`, in any case.
    case reservedID(entry: Int, id: String)
    /// An earlier entry has this id. The first is kept.
    case repeatedID(entry: Int, id: String)
    case noName(entry: Int, id: String)
    /// One of his own with no `extends`. A misspelt key lands here.
    case noExtends(entry: Int, id: String)
    case unknownExtends(entry: Int, id: String, value: String)
    /// The color names nothing this app has. Found by the app, never by the parser.
    case colorNotInThisApp(id: String, color: String)

    /// The fixed word a script reads for this case. Hard to change once scripts read it.
    public var code: String {
        switch self {
        case .fileNotRead: "file_not_read"
        case .notAList: "not_a_list"
        case .entryNotAnObject: "entry_not_an_object"
        case .noID: "no_id"
        case .reservedID: "reserved_id"
        case .repeatedID: "repeated_id"
        case .noName: "no_name"
        case .noExtends: "no_extends"
        case .unknownExtends: "unknown_extends"
        case .colorNotInThisApp: "color_not_in_this_app"
        }
    }

    /// The 1-based place in the file, or `nil` for a problem with no place.
    public var entry: Int? {
        switch self {
        case .fileNotRead, .notAList, .colorNotInThisApp: nil
        case .entryNotAnObject(let entry), .noID(let entry): entry
        case .reservedID(let entry, _), .repeatedID(let entry, _), .noName(let entry, _), .noExtends(let entry, _),
             .unknownExtends(let entry, _, _): entry
        }
    }

    /// The entry's id, or `nil` when the problem has none.
    public var id: String? {
        switch self {
        case .fileNotRead, .notAList, .entryNotAnObject, .noID: nil
        case .reservedID(_, let id), .repeatedID(_, let id), .noName(_, let id), .noExtends(_, let id),
             .unknownExtends(_, let id, _), .colorNotInThisApp(let id, _): id
        }
    }

    /// The text that was refused, for `unknown_extends` and `color_not_in_this_app`; `nil` for every other case,
    /// `fileNotRead`'s detail included. The sentence a person reads is not the package's.
    public var value: String? {
        switch self {
        case .unknownExtends(_, _, let value): value
        case .colorNotInThisApp(_, let color): color
        case .fileNotRead, .notAList, .entryNotAnObject, .noID, .reservedID, .repeatedID, .noName, .noExtends: nil
        }
    }
}
