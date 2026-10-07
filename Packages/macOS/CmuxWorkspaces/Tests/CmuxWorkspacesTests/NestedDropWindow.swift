import CoreGraphics
import Foundation

@testable import CmuxFoundation

// A window of loose workspaces and groups, nested to any depth, written as a list of rows (#cm-106). It builds the
// planner's request the way the app does: the workspaces in storage order, the groups parent first, and one visible
// row per workspace or header, 28 pt tall and 2 pt apart, 240 pt wide, a folded group showing only its header.

indirect enum DropRow {
    case ws(String, pinned: Bool = false)
    /// `own` is the workspace behind the group's name; nil is a header with no workspace of its own.
    case grp(String, own: String?, pinned: Bool = false, folded: Bool = false, [DropRow])
}

enum DropZone {
    case upper, lower, bottomEdge
}

enum DropHalf {
    case left, right
}

final class NestedDropWindow {
    private(set) var ids: [String: UUID] = [:]
    private(set) var workspaces: [SidebarWorkspaceReorderWorkspaceSnapshot] = []
    private(set) var groups: [SidebarWorkspaceReorderGroupSnapshot] = []
    private(set) var targets: [SidebarWorkspaceReorderDropTarget] = []
    private(set) var rowNames: [String] = []
    private var frames: [String: CGRect] = [:]
    let rowHeight: CGFloat = 28
    let width: CGFloat = 240

    init(_ rows: [DropRow]) {
        add(rows, parent: nil, parentPinned: false, hidden: false)
    }

    func id(_ name: String) -> UUID {
        if let existing = ids[name] { return existing }
        let id = UUID()
        ids[name] = id
        return id
    }

    func group(_ name: String) -> UUID { id("g:" + name) }

    /// The index of a workspace in storage order.
    func tab(_ name: String) -> Int { workspaces.firstIndex { $0.id == id(name) }! }

    private func addTarget(name: String, groupId: UUID?, isHeader: Bool, hidden: Bool) {
        guard !hidden else { return }
        let y = CGFloat(rowNames.count) * (rowHeight + 2)
        let frame = CGRect(x: 0, y: y, width: width, height: rowHeight)
        frames[name] = frame
        rowNames.append(name)
        targets.append(SidebarWorkspaceReorderDropTarget(workspaceId: id(name), groupId: groupId, isGroupHeader: isHeader, frame: frame))
    }

    private func add(_ rows: [DropRow], parent: UUID?, parentPinned: Bool, hidden: Bool) {
        for row in rows {
            switch row {
            case .ws(let name, let pinned):
                workspaces.append(SidebarWorkspaceReorderWorkspaceSnapshot(id: id(name), isPinned: pinned, groupId: parent))
                addTarget(name: name, groupId: parent, isHeader: false, hidden: hidden)
            case .grp(let name, let own, let pinned, let folded, let children):
                let gid = group(name)
                let anchorName = own ?? ("hdr:" + name)
                groups.append(SidebarWorkspaceReorderGroupSnapshot(
                    id: gid, anchorWorkspaceId: id(anchorName), isPinned: pinned, isEmpty: own == nil, parentGroupId: parent
                ))
                if own != nil {
                    workspaces.append(SidebarWorkspaceReorderWorkspaceSnapshot(id: id(anchorName), isPinned: pinned, groupId: gid))
                }
                addTarget(name: anchorName, groupId: gid, isHeader: true, hidden: hidden)
                add(children, parent: gid, parentPinned: pinned, hidden: hidden || folded)
            }
        }
    }

    func frame(_ rowName: String) -> CGRect { frames[rowName]! }

    func point(_ rowName: String, _ zone: DropZone, _ half: DropHalf) -> CGPoint {
        let f = frame(rowName)
        let y: CGFloat
        switch zone {
        case .upper: y = f.minY + 7
        case .lower: y = f.minY + 21
        case .bottomEdge: y = f.maxY - 1
        }
        return CGPoint(x: half == .left ? 60 : 180, y: y)
    }

    func request(
        dragged: UUID,
        at point: CGPoint,
        block: Set<UUID> = [],
        foreignIsPinned: Bool? = nil,
        targets overrideTargets: [SidebarWorkspaceReorderDropTarget]? = nil
    ) -> SidebarWorkspaceReorderDropRequest {
        SidebarWorkspaceReorderDropRequest(
            point: point,
            draggedWorkspaceId: dragged,
            foreignDraggedIsPinned: foreignIsPinned,
            workspaces: workspaces,
            groups: groups,
            targets: overrideTargets ?? targets,
            draggedBlockWorkspaceIds: block
        )
    }

    func plan(
        _ dragged: String,
        _ rowName: String,
        _ zone: DropZone,
        _ half: DropHalf,
        block: Set<UUID> = []
    ) -> SidebarWorkspaceReorderDropPlan? {
        SidebarWorkspaceReorderDropResolver().plan(
            for: request(dragged: id(dragged), at: point(rowName, zone, half), block: block)
        )
    }

    /// A pointer below every row.
    func belowAll(_ half: DropHalf) -> CGPoint {
        CGPoint(x: half == .left ? 60 : 180, y: CGFloat(rowNames.count) * (rowHeight + 2) + 40)
    }
}

extension SidebarWorkspaceReorderDropPlan {
    var reorder: (index: Int, topLevel: Bool, group: UUID?)? {
        guard case .reorder(let index, let topLevel, let group) = action else { return nil }
        return (index, topLevel, group)
    }
}
