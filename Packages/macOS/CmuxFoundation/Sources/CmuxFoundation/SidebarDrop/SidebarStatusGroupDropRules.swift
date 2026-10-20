public import CoreGraphics
public import Foundation

/// Status-aware admission consumes immutable geometry and authoritative projected membership.
public struct SidebarStatusGroupDropRules: Sendable {
    public enum SourceKind: Equatable, Sendable {
        case workspace
        case workspaceGroupHeader(groupId: UUID)
        case unknown
    }

    public struct Source: Equatable, Sendable {
        public let workspaceId: UUID
        public let kind: SourceKind
        public let isLocal: Bool
        public let isPinned: Bool
        public let groupId: UUID?
        public let isColorSectionMember: Bool

        public init(workspaceId: UUID, kind: SourceKind = .workspace, isLocal: Bool = true,
                    isPinned: Bool = false, groupId: UUID? = nil, isColorSectionMember: Bool = false) {
            self.workspaceId = workspaceId
            self.kind = kind
            self.isLocal = isLocal
            self.isPinned = isPinned
            self.groupId = groupId
            self.isColorSectionMember = isColorSectionMember
        }
    }

    public struct Group: Equatable, Sendable {
        public let statusId: String
        public let memberWorkspaceIds: [UUID]
        public init(statusId: String, memberWorkspaceIds: [UUID]) {
            self.statusId = statusId
            self.memberWorkspaceIds = memberWorkspaceIds
        }
    }

    public enum AreaBoundary: Equatable, Sendable { case aboveArea, belowAll }
    public enum Decision: Equatable, Sendable {
        case unrelated
        case refused
        case statusGroup(SidebarStatusGroupWorkspaceDropPlan)
        case areaBoundary(AreaBoundary, indicator: SidebarDropIndicator)
    }

    public struct Request: Equatable, Sendable {
        public let point: CGPoint
        public let source: Source
        public let targets: [SidebarWorkspaceReorderDropTarget]
        public let groups: [Group]
        public let areaIsLast: Bool
        public let controlsEnabled: Bool
        public let hasUserStatusList: Bool

        public init(point: CGPoint, source: Source, targets: [SidebarWorkspaceReorderDropTarget], groups: [Group],
                    areaIsLast: Bool, controlsEnabled: Bool = true, hasUserStatusList: Bool = true) {
            self.point = point
            self.source = source
            self.targets = targets
            self.groups = groups
            self.areaIsLast = areaIsLast
            self.controlsEnabled = controlsEnabled
            self.hasUserStatusList = hasUserStatusList
        }
    }

    public init() {}

    public func permitsLeavingStatusGroup(action: SidebarWorkspaceReorderDropAction) -> Bool {
        if case .reorder(_, _, .some) = action { return true }
        return false
    }

    public func plan(_ request: Request) -> Decision {
        let targets = request.targets.filter { $0.frame.width > 0 && $0.frame.height > 0 }
            .sorted { $0.frame.minY < $1.frame.minY }
        // A structural member owns no loose status membership, even when its whole group is displayed here.
        let sourceGroup = request.source.groupId == nil
            ? request.groups.first { $0.memberWorkspaceIds.contains(request.source.workspaceId) } : nil
        func statusId(_ row: SidebarWorkspaceReorderDropTarget) -> String? {
            if case .statusGroupHeader(let id) = row.kind { return id }
            return request.groups.first { $0.memberWorkspaceIds.contains(row.workspaceId) }?.statusId
        }
        func resolve(_ row: SidebarWorkspaceReorderDropTarget, edge: SidebarDropEdge) -> Decision {
            if let id = statusId(row) {
                guard request.controlsEnabled, request.hasUserStatusList, request.source.isLocal,
                      request.source.kind == .workspace,
                      let group = request.groups.first(where: { $0.statusId == id }) else { return .refused }
                let placement: SidebarStatusGroupWorkspaceDropPlan.Placement
                let indicator: SidebarDropIndicator
                if case .statusGroupHeader = row.kind {
                    placement = .first; indicator = .init(tabId: row.workspaceId, edge: .bottom)
                } else {
                    placement = .member(row.workspaceId, insertBefore: edge == .top)
                    indicator = .init(tabId: row.workspaceId, edge: edge)
                }
                return .statusGroup(.init(statusId: id, placement: placement,
                    setsStatus: !group.memberWorkspaceIds.contains(request.source.workspaceId), indicator: indicator))
            }
            if row.kind == .statusesArea {
                guard request.source.isLocal else { return .unrelated }
                guard request.controlsEnabled, request.hasUserStatusList else { return .refused }
                if case .workspaceGroupHeader = request.source.kind {
                    return .areaBoundary(.aboveArea, indicator: .init(tabId: row.workspaceId, edge: .top))
                }
                return .refused
            }
            if sourceGroup != nil && row.groupId == nil { return .refused }
            return .unrelated
        }
        for row in targets where request.point.y >= row.frame.minY && request.point.y <= row.frame.maxY {
            return resolve(row, edge: request.point.y < row.frame.midY ? .top : .bottom)
        }
        for index in targets.indices.dropLast() {
            let previous = targets[index], next = targets[index + 1]
            guard request.point.y > previous.frame.maxY, request.point.y < next.frame.minY else { continue }
            if statusId(previous) != nil && statusId(next) == nil { return resolve(previous, edge: .bottom) }
            let upper = request.point.y < (previous.frame.maxY + next.frame.minY) / 2
            return resolve(upper ? previous : next, edge: upper ? .bottom : .top)
        }
        if let last = targets.last, request.point.y > last.frame.maxY,
           !request.groups.isEmpty {
            guard request.source.isLocal else { return .unrelated }
            if request.source.isPinned { return .unrelated }
            if case .workspaceGroupHeader = request.source.kind {
                guard request.controlsEnabled, request.hasUserStatusList else { return .refused }
                return .areaBoundary(.belowAll, indicator: .init(tabId: nil, edge: .bottom))
            }
            if request.areaIsLast {
                guard request.controlsEnabled, request.hasUserStatusList, request.source.kind == .workspace,
                      sourceGroup == nil, !request.source.isColorSectionMember else { return .refused }
                return .areaBoundary(.belowAll, indicator: .init(tabId: nil, edge: .bottom))
            }
            return resolve(last, edge: .bottom)
        }
        return sourceGroup == nil ? .unrelated : .refused
    }
}
