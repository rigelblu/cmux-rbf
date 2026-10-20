import AppKit
import CmuxFoundation
import CmuxNotifications
import SwiftUI

/// Immutable canonical divider paint, assembled by the parent rather than observed inside a row.
struct SidebarStatusHeaderDropPaint: Equatable {
    let top: Bool
    let bottom: Bool
    let inset: CGFloat
    static let none = Self(top: false, bottom: false, inset: 0)

    static func forRow(_ id: UUID, draggedId: UUID?, indicator: SidebarDropIndicator?, rowIds: [UUID],
                       level: Int, availableWidth: CGFloat?) -> Self {
        let predicate = SidebarTabDropIndicatorPredicate()
        return .init(top: draggedId != id && predicate.topVisible(forTabId: id, draggedTabId: draggedId,
            dropIndicator: indicator, tabIds: rowIds),
            bottom: draggedId != id && predicate.bottomVisible(forTabId: id, draggedTabId: draggedId,
                dropIndicator: indicator, tabIds: rowIds, indicatorScope: .raw),
            inset: SidebarNestedDropLine.inset(level: level, availableWidth: availableWidth))
    }
}

/// The source gap belongs to the list overlay, outside the header captured for the drag image.
struct SidebarStatusHeaderSourceGapOverlay: View {
    let frame: CGRect?
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let frame {
                Rectangle().fill(cmuxAccentColor()).frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
            }
        }.allowsHitTesting(false)
    }

    static func frame(draggedId: UUID?, indicator: SidebarDropIndicator?, rowIds: [UUID],
                      frames: [UUID: CGRect], level: Int, width: CGFloat) -> CGRect? {
        guard let draggedId, let row = frames[draggedId],
              SidebarTabDropIndicatorPredicate().topVisible(forTabId: draggedId, draggedTabId: draggedId,
                  dropIndicator: indicator, tabIds: rowIds) else { return nil }
        let inset = SidebarNestedDropLine.inset(level: level, availableWidth: width)
        return CGRect(x: 8 + inset, y: row.minY - 1, width: max(0, width - 16 - inset), height: 2)
    }
}

/// Row views retain immutable paint values and actions captured above the lazy-list boundary.
private struct SidebarStatusHeaderDragView<Content: View>: View {
    let content: Content
    let id: UUID
    let collectTargets: Bool
    let dragged: Bool
    let top: Bool
    let bottom: Bool
    let inset: CGFloat
    let frameChanged: (CGRect) -> Void
    let disappeared: () -> Void

    var body: some View {
        content
            .opacity(dragged ? 0.6 : 1)
            .sidebarWorkspaceFrameAnchor(id: id, isEnabled: collectTargets)
            .sidebarPointerFrameReporting(onFrameChange: frameChanged, onDisappear: disappeared)
            .overlay(alignment: .top) {
                if top { Rectangle().fill(cmuxAccentColor()).frame(height: 2).padding(.leading, inset).padding(.horizontal, 8) }
            }
            .overlay(alignment: .bottom) {
                if bottom { Rectangle().fill(cmuxAccentColor()).frame(height: 2).padding(.leading, inset).padding(.horizontal, 8) }
            }
    }
}

struct SidebarStatusHeaderSwiftUIRows {
    let area: AnyView
    let groups: [String: AnyView]
    let colors: [SidebarWorkspaceRenderItemID: SidebarStatusHeaderDropPaint]
    let colorFrameChanged: (SidebarWorkspaceRenderItemID, CGRect) -> Void
    let colorDisappeared: (SidebarWorkspaceRenderItemID) -> Void
}

extension VerticalTabsSidebar {
    func makeStatusHeaderSwiftUIRows(renderContext: WorkspaceListRenderContext, unreadSnapshot: SidebarUnreadSnapshot,
                                      collectTargets: Bool) -> SidebarStatusHeaderSwiftUIRows {
        let toggle = makeStatusHeaderToggleAction()
        let monitor = pointerInteractionMonitor
        let draggedId = dragState.draggedTabId
        let workspaceScope = Self.workspaceStatusDropScopeId(scope: dragState.dropIndicatorScope,
            projection: renderContext.statusGroupProjection)
        let areaRows = Self.workspaceAreaBoundaryPaintRows(draggedId: draggedId, scope: dragState.dropIndicatorScope,
            indicator: dragState.dropIndicator, level: dragState.dropIndicatorLevel,
            items: renderContext.workspaceRenderItems, projection: renderContext.statusGroupProjection)
        let indicator = workspaceScope == nil && areaRows == nil ? dragState.dropIndicator : nil
        let predicate = SidebarTabDropIndicatorPredicate()
        let rowIds = statusHeaderIndicatorRows(draggedId: draggedId, items: renderContext.workspaceRenderItems)
            ?? renderContext.sidebarReorderIds
        func wrapped<V: View>(_ view: V, kind: SidebarStatusHeaderKind) -> AnyView {
            let id = SidebarStatusHeaderIdentity.uuid(for: kind)
            let row: SidebarWorkspaceRenderItemID
            let level: Int
            switch kind {
            case .statusesArea: row = .statusesArea(); level = 0
            case .statusGroup(let id): row = .statusGroup(id); level = 1
            }
            let isSource = draggedId == id
            return AnyView(SidebarStatusHeaderDragView(content: view, id: id, collectTargets: collectTargets,
                dragged: isSource,
                top: !isSource && predicate.topVisible(forTabId: id, draggedTabId: draggedId, dropIndicator: indicator, tabIds: rowIds),
                bottom: !isSource && predicate.bottomVisible(forTabId: id, draggedTabId: draggedId,
                    dropIndicator: indicator, tabIds: rowIds, indicatorScope: .raw),
                inset: SidebarNestedDropLine.inset(level: level, availableWidth: renderContext.listWidth),
                frameChanged: { frame in monitor.updateFrame(frame, for: row, workspaceId: id) },
                disappeared: { monitor.removeFrame(for: row) }))
        }
        let area = wrapped(Self.sidebarStatusesAreaHeaderRow(renderContext: renderContext,
            unreadSnapshot: unreadSnapshot, onToggle: { toggle(.statusesArea) }), kind: .statusesArea)
        var groups: [String: AnyView] = [:]
        for group in renderContext.statusGroupProjection?.groups ?? [] {
            let id = group.statusId
            if let view = Self.sidebarStatusGroupHeaderRow(statusId: id, projection: renderContext.statusGroupProjection,
                presentations: renderContext.statusGroupPresentationById, listWidth: renderContext.listWidth,
                environment: renderContext.environment, folds: renderContext.statusGroupFolds,
                unreadSnapshot: unreadSnapshot, onToggle: { toggle(.statusGroup(id)) }) {
                groups[id] = wrapped(view, kind: .statusGroup(id))
            }
        }
        var colors: [SidebarWorkspaceRenderItemID: SidebarStatusHeaderDropPaint] = [:]
        for item in renderContext.workspaceRenderItems {
            guard case .colorSectionHeader = item, let id = item.headerDropIdentity else { continue }
            colors[item.id] = .forRow(id, draggedId: draggedId, indicator: indicator,
                rowIds: rowIds, level: 0, availableWidth: renderContext.listWidth)
        }
        return .init(area: area, groups: groups, colors: colors, colorFrameChanged: { row, frame in
            guard let id = row.colorHeaderDropIdentity else { return }
            monitor.setWorkspaceDragEnabled(false, for: row)
            monitor.updateFrame(frame, for: row, workspaceId: id)
        }, colorDisappeared: { monitor.removeFrame(for: $0) })
    }

    func makeStatusColorHeaderToggle() -> (String) -> Void {
        let state = sidebarState
        return { state.toggleColorSection(hex: $0) }
    }

    static func statusColorHeaderRow(section: SidebarWorkspaceColorSection, colorScheme: ColorScheme,
        collectTargets: Bool, toggle: @escaping (String) -> Void,
        frameChanged: @escaping (SidebarWorkspaceRenderItemID, CGRect) -> Void,
        disappeared: @escaping (SidebarWorkspaceRenderItemID) -> Void,
        paint: SidebarStatusHeaderDropPaint = .none) -> some View {
        let row = SidebarWorkspaceRenderItemID.colorSection(section.id)
        let header = SidebarWorkspaceColorSectionHeader(section: section, colorScheme: colorScheme,
            onToggle: { toggle(section.id.normalizedHex) })
            .sidebarWorkspaceFrameAnchor(id: row.colorHeaderDropIdentity!, isEnabled: collectTargets)
            .overlay(alignment: .top) {
                if paint.top { Rectangle().fill(cmuxAccentColor()).frame(height: 2).padding(.leading, paint.inset).padding(.horizontal, 8) }
            }
            .overlay(alignment: .bottom) {
                if paint.bottom { Rectangle().fill(cmuxAccentColor()).frame(height: 2).padding(.leading, paint.inset).padding(.horizontal, 8) }
            }
#if DEBUG
        return header.sidebarPointerFrameReporting(onFrameChange: { frameChanged(row, $0) }, onDisappear: { disappeared(row) })
#else
        return header
#endif
    }

    /// Captures only values before the preference/geometry closure; the overlay is outside every drag source.
    func makeStatusHeaderExternalGapOverlay(renderContext: WorkspaceListRenderContext) -> ([UUID: CGRect], CGFloat) -> AnyView {
        let dragged = dragState.draggedTabId
        let indicator = dragState.dropIndicator
        let rows = statusHeaderIndicatorRows(draggedId: dragged, items: renderContext.workspaceRenderItems)
        let workspaceStatusId = Self.workspaceStatusDropScopeId(scope: dragState.dropIndicatorScope,
            projection: renderContext.statusGroupProjection)
        let workspaceMembers = workspaceStatusId.flatMap { id in
            renderContext.statusGroupProjection.map { Self.workspaceStatusDisplayDropMembers(statusId: id,
                projection: $0, items: renderContext.workspaceRenderItems) }
        } ?? []
        let items = renderContext.workspaceRenderItems
        let areaRows = Self.workspaceAreaBoundaryPaintRows(draggedId: dragged, scope: dragState.dropIndicatorScope,
            indicator: indicator, level: dragState.dropIndicatorLevel, items: items, projection: renderContext.statusGroupProjection)
        let level = dragged == SidebarStatusHeaderIdentity.statusesAreaUUID ? 0 : 1
        return { frames, width in
            if let workspaceStatusId {
                return AnyView(SidebarStatusHeaderSourceGapOverlay(frame: Self.workspaceStatusDropGapFrame(
                    statusId: workspaceStatusId, draggedId: dragged, indicator: indicator, items: items,
                    memberWorkspaceIds: workspaceMembers, frames: frames, width: width)))
            }
            if let areaRows, let indicator {
                let frame: CGRect?
                if let id = indicator.tabId, let row = frames[id] {
                    frame = CGRect(x: 8, y: row.minY - 1, width: max(0, width - 16), height: 2)
                } else {
                    frame = Self.statusHeaderFinalAppendFrame(draggedId: dragged, indicator: indicator,
                        rowIds: areaRows, frames: frames, level: 0, width: width)
                }
                return AnyView(SidebarStatusHeaderSourceGapOverlay(frame: frame))
            }
            let source = rows.flatMap { SidebarStatusHeaderSourceGapOverlay.frame(draggedId: dragged, indicator: indicator,
                rowIds: $0, frames: frames, level: level, width: width) }
            let end = rows.flatMap { Self.statusHeaderFinalAppendFrame(draggedId: dragged, indicator: indicator,
                rowIds: $0, frames: frames, level: level, width: width) }
            return AnyView(ZStack(alignment: .topLeading) {
                SidebarStatusHeaderSourceGapOverlay(frame: source)
                Self.statusHeaderFinalAppendOverlay(frame: end)
            }.allowsHitTesting(false))
        }
    }

    static func statusHeaderFinalAppendFrame(draggedId: UUID?, indicator: SidebarDropIndicator?, rowIds: [UUID],
                                            frames: [UUID: CGRect], level: Int, width: CGFloat) -> CGRect? {
        guard SidebarTabDropIndicatorPredicate().emptyAreaTopVisible(draggedTabId: draggedId,
            dropIndicator: indicator, lastTabId: rowIds.last), let last = rowIds.last, let row = frames[last] else { return nil }
        let inset = SidebarNestedDropLine.inset(level: level, availableWidth: width)
        return CGRect(x: 8 + inset, y: row.maxY - 1, width: max(0, width - 16 - inset), height: 2)
    }

    static func statusHeaderFinalAppendOverlay(frame: CGRect?) -> some View {
        SidebarStatusHeaderSourceGapOverlay(frame: frame)
    }

    static func statusAwareSwiftUITargets(items: [SidebarWorkspaceRenderItem], frames: [UUID: CGRect],
                                          context: WorkspaceListRenderContext) -> [SidebarWorkspaceReorderDropOverlay.Target] {
        statusAwareSwiftUITargets(items: items, frames: frames, workspaceGroupIds: context.workspaceGroupIdByWorkspaceId)
    }

    static func statusAwareSwiftUITargets(items: [SidebarWorkspaceRenderItem], frames: [UUID: CGRect],
                                          workspaceGroupIds: [UUID: UUID?]) -> [SidebarWorkspaceReorderDropOverlay.Target] {
        items.compactMap { item in
            guard let id = item.headerDropIdentity, let frame = frames[id] else { return nil }
            let groupId: UUID?
            let isGroup: Bool
            switch item {
            case .groupHeader(let group, _): groupId = group; isGroup = true
            case .workspace(let workspace): groupId = workspaceGroupIds[workspace] ?? nil; isGroup = false
            default: groupId = nil; isGroup = false
            }
            return .init(workspaceId: id, groupId: groupId, isGroupHeader: isGroup, frame: frame, renderItemId: item.id)
        }
    }
}
