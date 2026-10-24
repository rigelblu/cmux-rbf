import CmuxWorkspaces
import CryptoKit
import Foundation

/// Provides deterministic UUID identities for status group headers and the Statuses area header.
/// Uses RFC 4122 UUIDv5 (SHA-1) with a fixed private namespace so that generated UUIDs
/// use version 5 (0x50) and can never collide with standard version 4 (random) workspace or group UUIDs. // (#cm-110.1)
enum SidebarStatusHeaderIdentity { // (#cm-110.1)
    private static let namespace = UUID(uuidString: "7b4c6e12-3f8a-5b9d-a1c4-8e9f2d3a4b5c")!

    /// Fixed deterministic UUID for the `Statuses` header row.
    static let statusesAreaUUID = deterministicUUID(name: "cmux:statuses-area")
    static let workspacesAreaUUID = deterministicUUID(name: "cmux:workspaces-area") // (#cm-110.4)
    static let pinnedAreaUUID = deterministicUUID(name: "cmux:pinned-area") // (#cm-110.5)

    /// Deterministic UUID for a status group header by status id. Cached: a row's `id` reads it on every list diff,
    /// and the hash allocates.
    static func uuid(forStatusId statusId: String) -> UUID {
        cache.uuid(forStatusId: statusId) { deterministicUUID(name: "cmux:status-group:\(statusId)") }
    }

    static func uuid(for kind: SidebarStatusHeaderKind) -> UUID {
        switch kind {
        case .statusesArea: return statusesAreaUUID
        case .workspacesArea: return workspacesAreaUUID // (#cm-110.4)
        case .pinnedArea: return pinnedAreaUUID // (#cm-110.5)
        case .statusGroup(let id): return uuid(forStatusId: id)
        }
    }

    static func kind(forDragId id: UUID, list: WorkspaceStatusList) -> SidebarStatusHeaderKind? {
        guard list.source != .cmux, !list.entries.isEmpty else { return nil }
        if id == statusesAreaUUID { return .statusesArea }
        if id == workspacesAreaUUID { return .workspacesArea } // (#cm-110.4)
        if id == pinnedAreaUUID { return .pinnedArea } // (#cm-110.5)
        return list.entries.first { uuid(forStatusId: $0.id) == id }.map { .statusGroup($0.id) }
    }

    /// A color header's drop identity differs from the first member it otherwise represents.
    static func colorRowUUID(kind: UInt8, colorKey: UInt32) -> UUID? {
        guard kind == 3 else { return nil }
        let name = "cmux:color-header:\(colorKey)"
        return colorCache.uuid(forStatusId: name) { deterministicUUID(name: name) }
    }

    private static let cache = StatusIdCache()
    private static let colorCache = StatusIdCache()

    private final class StatusIdCache: @unchecked Sendable {
        private let lock = NSLock()
        private var uuidByStatusId: [String: UUID] = [:]

        func uuid(forStatusId statusId: String, make: () -> UUID) -> UUID {
            lock.lock()
            defer { lock.unlock() }
            if let cached = uuidByStatusId[statusId] { return cached }
            let made = make()
            uuidByStatusId[statusId] = made
            return made
        }
    }

    private static func deterministicUUID(name: String) -> UUID {
        var data = Data()
        withUnsafeBytes(of: namespace.uuid) { data.append(contentsOf: $0) }
        data.append(contentsOf: name.utf8)
        let hash = Insecure.SHA1.hash(data: data)
        var bytes = Array(hash.prefix(16))
        // Set version to 5 (0x50)
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        // Set variant to RFC 4122 (0x80)
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
