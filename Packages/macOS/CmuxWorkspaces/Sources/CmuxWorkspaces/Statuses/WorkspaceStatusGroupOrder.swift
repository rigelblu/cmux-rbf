/// Window-local order; absent means follow the file. Stored unknown IDs are kept for a returning list.
public enum WorkspaceStatusGroupOrder {
    public static func resolved(fileIds: [String], storedOrder: [String]?) -> [String] {
        WorkspaceStatusGroupProjection.orderedStatusIds(
            entries: fileIds.map { WorkspaceStatusEntry(id: $0, name: nil) }, storedOrder: storedOrder
        )
    }

    /// Adds newly listed IDs once, preserving the saved positions of IDs absent from this list.
    public static func adopting(fileIds: [String], storedOrder: [String]) -> [String] {
        var full: [String] = []
        for id in storedOrder where !full.contains(id) { full.append(id) }
        // Insert new file IDs without throwing away stored IDs temporarily absent from the file.
        for (index, id) in fileIds.enumerated() where !full.contains(id) {
            if let previous = fileIds[..<index].reversed().first(where: { full.contains($0) }),
               let position = full.firstIndex(of: previous) {
                full.insert(id, at: position + 1)
            } else if let next = fileIds.dropFirst(index + 1).first(where: { full.contains($0) }),
                      let position = full.firstIndex(of: next) {
                full.insert(id, at: position)
            } else { full.append(id) }
        }
        return full
    }

    public static func moving(_ draggedId: String, relativeTo targetId: String, insertBefore: Bool,
                              fileIds: [String], storedOrder: [String]?) -> [String]? {
        guard draggedId != targetId, fileIds.contains(draggedId), fileIds.contains(targetId) else { return nil }
        let original = resolved(fileIds: fileIds, storedOrder: storedOrder)
        var full = adopting(fileIds: fileIds, storedOrder: storedOrder ?? fileIds)
        full.removeAll { $0 == draggedId }
        guard let position = full.firstIndex(of: targetId) else { return nil }
        full.insert(draggedId, at: position + (insertBefore ? 0 : 1))
        return resolved(fileIds: fileIds, storedOrder: full) == original ? nil : full
    }
}
