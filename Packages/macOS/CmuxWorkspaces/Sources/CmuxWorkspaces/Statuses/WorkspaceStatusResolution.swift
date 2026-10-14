/// What a workspace shows, worked out from what it holds. The table's eight rows give six cases, and `resolve`
/// builds only those. A caller can still build a case by hand that `resolve` never gives, such as
/// `.cmuxInEffect` with one of his own entries.
public enum WorkspaceStatusResolution: Equatable, Sendable {
    /// Nothing held.
    case detected(WorkspaceTaskStatus)
    /// A cmux status set by hand, and detection unchanged since. `offered` is false when his list leaves it
    /// out; the entry is then cmux's own.
    case cmuxInEffect(WorkspaceStatusEntry, offered: Bool)
    /// A cmux status set by hand, stored, and detection changed since. It stays stored.
    case cmuxLapsed(detected: WorkspaceTaskStatus)
    /// One of his own, the list has it, and either no agent waits or he picked it during the wait.
    case ownInEffect(WorkspaceStatusEntry)
    /// One of his own, the list has it, and an agent waits.
    case ownWaiting(WorkspaceStatusEntry)
    /// One of his own that the list does not have. It shows what Auto shows.
    case ownNotListed(id: String, detected: WorkspaceTaskStatus)

    /// Why a held id is or is not in effect.
    public enum Held: Equatable, Sendable {
        case inEffect
        case waiting
        case notListed
        case notOffered
    }

    /// Works out what a workspace shows.
    ///
    /// - Parameters:
    ///   - override: The cmux status set by hand that the workspace stores, if any.
    ///   - own: One of his own statuses the workspace holds, if any. It wins if both are given; they are
    ///     never both set.
    ///   - inferred: What cmux detects now.
    ///   - list: The list in use.
    public static func resolve(
        override: WorkspaceTaskStatusOverride?,
        own: WorkspaceOwnStatus?,
        inferred: WorkspaceTaskStatus,
        list: WorkspaceStatusList
    ) -> WorkspaceStatusResolution {
        if let own {
            guard let entry = list.entry(id: own.id) else {
                return .ownNotListed(id: own.id, detected: inferred)
            }
            guard inferred == .needsAttention else { return .ownInEffect(entry) }
            return own.heldThroughWait ? .ownInEffect(entry) : .ownWaiting(entry)
        }
        if let override {
            guard override.inferredAtOverride == inferred else { return .cmuxLapsed(detected: inferred) }
            let id = override.status.rawValue
            if let entry = list.entry(id: id) { return .cmuxInEffect(entry, offered: true) }
            return .cmuxInEffect(WorkspaceStatusEntry(id: id, name: nil), offered: false)
        }
        return .detected(inferred)
    }

    /// The cmux status that decides behavior: quiet or in play, the glyph, Done's dimming, the phone.
    public var effective: WorkspaceTaskStatus {
        switch self {
        case .detected(let status): status
        case .cmuxInEffect(let entry, _): entry.behavesAs
        case .cmuxLapsed(let detected): detected
        case .ownInEffect(let entry): entry.behavesAs
        case .ownWaiting: .needsAttention
        case .ownNotListed(_, let detected): detected
        }
    }

    /// The status set by hand and in effect now, if any.
    public var inEffect: WorkspaceStatusEntry? {
        switch self {
        case .cmuxInEffect(let entry, _): entry
        case .ownInEffect(let entry): entry
        case .detected, .cmuxLapsed, .ownWaiting, .ownNotListed: nil
        }
    }

    /// What a script reads as `status_id`. `nil` for `.detected` and for `.cmuxLapsed`.
    public var heldID: String? {
        switch self {
        case .detected, .cmuxLapsed: nil
        case .cmuxInEffect(let entry, _): entry.id
        case .ownInEffect(let entry): entry.id
        case .ownWaiting(let entry): entry.id
        case .ownNotListed(let id, _): id
        }
    }

    /// Why a held id is or is not in effect. `nil` when nothing is held, and for a lapsed cmux status.
    public var held: Held? {
        switch self {
        case .detected, .cmuxLapsed: nil
        case .cmuxInEffect(_, let offered): offered ? .inEffect : .notOffered
        case .ownInEffect: .inEffect
        case .ownWaiting: .waiting
        case .ownNotListed: .notListed
        }
    }

    /// True only for `.cmuxLapsed`, as today. Nothing acts on it to remove the status any more.
    public var shouldClearOverride: Bool {
        if case .cmuxLapsed = self { return true }
        return false
    }
}
