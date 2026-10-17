import AppKit
import CmuxFoundation
import CmuxWorkspaces
import Foundation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct SidebarWorkspaceStatusDropPaintTests {
    enum Landing: CaseIterable, Sendable { case emptyHeader, foldedHeader, finalMember, canonicalSourceGap }
    enum Renderer: CaseIterable, Sendable { case native, swiftUI }
    enum Ending: CaseIterable, Sendable { case refusal, ended, reuse }

    @Test(arguments: Landing.allCases)
    func actualWorkspaceStatusPaintHasOneMemberLevelLineInBothRenderers(_ landing: Landing) async throws {
        let f = await Fixture.mount(landing)
        defer { f.close() }
        let nativePoint = CGPoint(x: 60, y: 10)
        try #require(f.controller.updateReorderDrag(windowPoint: f.container.reorderDropView.convert(nativePoint, to: nil)))
        try #require(f.lastPlan == f.plan)
        let row = try #require(f.items.firstIndex { $0.headerDropIdentity == f.expectedTarget })
        let frame = f.container.tableView.convert(f.container.tableView.rect(ofRow: row), to: f.container)
        let inset = SidebarNestedDropLine.inset(level: 2, availableWidth: 300)
        let expectedNative = NSRect(x: 8 + inset, y: (f.expectedEdge == .top ? frame.maxY : frame.minY) - 1, width: 284 - inset, height: 2)
        let nativeLines = visibleLineFrames(in: f.container, root: f.container)
        #expect(nativeLines.count == 1)
        #expect(nativeLines.first == expectedNative)
        let painter = SidebarWorkspaceTableReorderIndicatorPainter(indicator: f.plan.indicator, scope: f.plan.indicatorScope,
            draggedWorkspaceId: f.source, indicatorRowIds: f.items.compactMap(\.headerDropIdentity), level: 2)
        #expect(!painter.paint(forRowWorkspaceId: f.source).top && !painter.paint(forRowWorkspaceId: f.source).bottom)

        let frames = Dictionary(uniqueKeysWithValues: f.items.enumerated().compactMap { index, item -> (UUID, CGRect)? in
            item.headerDropIdentity.map { ($0, CGRect(x: 0, y: CGFloat(index) * 30, width: 300, height: 26)) }
        })
        let expectedRow = try #require(frames[f.expectedTarget])
        let expected = CGRect(x: 8 + inset, y: (f.expectedEdge == .top ? expectedRow.minY : expectedRow.maxY) - 1, width: 284 - inset, height: 2)
        let headerY = try #require(frames[f.header]).minY
        let content = AnyView(Color.white.frame(width: 300, height: 200).overlay(alignment: .topLeading) {
            SidebarStatusGroupSwiftUIHeader(statusId: "parked", presentation: .init(name: "Parked", tintHex: "#555555", glyph: nil, behavesAs: .todo),
                memberCount: f.members.count, isCollapsed: landing == .foldedHeader, listWidth: 300,
                colorScheme: .light, fontScale: 1, globalFontMagnificationPercent: 100)
                .frame(width: 300, height: 26).offset(y: headerY)
        })
        let baseline = try await raster(content)
        let calibration = try await raster(AnyView(content.overlay(alignment: .topLeading) {
            Rectangle().fill(cmuxAccentColor()).frame(width: expected.width, height: expected.height).offset(x: expected.minX, y: expected.minY)
        }))
        let control = try #require(differenceBounds(baseline, calibration))
        try verifyGeometry(control, expected: expected, baseline: baseline, painted: calibration, required: true)
        let actualFrame = VerticalTabsSidebar.workspaceStatusDropGapFrame(statusId: "parked", draggedId: f.source,
            indicator: f.plan.indicator, items: f.items, memberWorkspaceIds: f.members, frames: frames, width: 300)
        let painted = try await raster(AnyView(content.overlay(alignment: .topLeading) {
            SidebarStatusHeaderSourceGapOverlay(frame: actualFrame)
        }))
        let actual = differenceBounds(baseline, painted)
        #expect(actual != nil)
        if let actual { try verifyGeometry(actual, expected: expected, baseline: baseline, painted: painted, required: false) }
    }

    @Test(arguments: Landing.allCases, Ending.allCases)
    func acceptedWorkspaceStatusPaintClearsOnRefusalEndAndReuse(_ landing: Landing, _ ending: Ending) async throws {
        let f = await Fixture.mount(landing)
        defer { f.close() }
        let point = f.container.reorderDropView.convert(CGPoint(x: 60, y: 10), to: nil)
        try #require(f.controller.updateReorderDrag(windowPoint: point))
        try #require(f.lastPlan == f.plan)
        try #require(visibleLineFrames(in: f.container, root: f.container).count == 1)
        switch ending {
        case .refusal:
            f.accepts = false
            #expect(!f.controller.updateReorderDrag(windowPoint: point))
        case .ended: f.controller.reorderDropDragExited()
        case .reuse:
            f.controller.reorderDropDragExited()
            for row in f.items.indices {
                (f.container.tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView)?.prepareForReuse()
            }
        }
        #expect(visibleLineFrames(in: f.container, root: f.container).isEmpty)
        let content = AnyView(Color.white.frame(width: 300, height: 200))
        let baseline = try await raster(content)
        let accepted = try await raster(AnyView(content.overlay(alignment: .topLeading) {
            SidebarStatusHeaderSourceGapOverlay(frame: CGRect(x: 40, y: 60, width: 252, height: 2))
        }))
        try #require(differenceBounds(baseline, accepted) != nil)
        let cleared = try await raster(AnyView(content.overlay(alignment: .topLeading) {
            SidebarStatusHeaderSourceGapOverlay(frame: nil)
        }))
        #expect(differenceBounds(baseline, cleared) == nil)
    }

    @Test(arguments: Renderer.allCases)
    func actualRowBuildersKeepStatusHeaderAndAreaKindsForWorkspaceDrops(_ renderer: Renderer) async throws {
        let f = await Fixture.mount(.finalMember)
        defer { f.close() }
        let measured: [SidebarWorkspaceReorderDropOverlay.Target]
        if renderer == .native { measured = f.controller.refreshReorderDropTargets(includeHeaders: true) }
        else {
            let frames = Dictionary(uniqueKeysWithValues: f.items.enumerated().compactMap { index, item -> (UUID, CGRect)? in
                item.headerDropIdentity.map { ($0, CGRect(x: 0, y: CGFloat(index) * 30, width: 300, height: 26)) }
            })
            measured = VerticalTabsSidebar.statusAwareSwiftUITargets(items: f.items, frames: frames, workspaceGroupIds: [:])
        }
        try #require(measured.count == f.items.count)
        try #require(measured.contains { $0.renderItemId == .statusesArea() } && measured.contains { $0.renderItemId == .statusGroup("parked") })
        let actual = VerticalTabsSidebar.workspaceStatusDropTargets(items: f.items, measured: measured)
        #expect(actual.count == measured.count)
        #expect(actual.first(where: { $0.workspaceId == f.header })?.kind == .statusGroupHeader(statusId: "parked"))
        #expect(actual.first(where: { $0.workspaceId == SidebarStatusHeaderIdentity.statusesAreaUUID })?.kind == .statusesArea)
        #expect(actual.first(where: { $0.workspaceId == f.member })?.kind == .workspace)
    }

    @Test(arguments: [false, true])
    func statusWorkspaceAndOuterAreaPlansDeclareTheirLandingLevel(_ boundary: Bool) {
        let value = SidebarStatusGroupWorkspaceDropPlan(statusId: "parked", placement: .first, setsStatus: true,
            indicator: .init(tabId: UUID(), edge: .bottom))
        let action: SidebarWorkspaceReorderDropAction = boundary
            ? .statusAreaBoundaryDrop(plan: .init(boundary: .belowAll, move: .workspaces(targetIndex: 3, usesTopLevelRows: true, explicitGroupId: nil)), sessionId: UUID())
            : .statusGroupDrop(plan: value, sessionId: UUID())
        #expect(SidebarStatusHeaderDropAdapter.lineLevel(for: action) == (boundary ? 0 : 2))
    }

    private func verifyGeometry(_ bounds: CGRect, expected: CGRect, baseline: NSBitmapImageRep,
                                painted: NSBitmapImageRep, required: Bool) throws {
        let scale = CGFloat(painted.pixelsWide) / 300
        let topAtZero = try markerIsAtZero(baseline)
        let top = topAtZero ? bounds.minY / scale : (CGFloat(painted.pixelsHigh) - bounds.maxY) / scale
        let valid = abs(bounds.minX / scale - expected.minX) < 1.5 && abs(bounds.width / scale - expected.width) < 2
            && abs(bounds.height / scale - 2) < 1 && abs(top - expected.minY) < 1.5
        if required { try #require(valid) } else { #expect(valid) }
    }

    @MainActor
    private final class Fixture {
        let outside = UUID(), sourceMember = UUID(), member = UUID(), following = UUID(), token = UUID()
        let landing: Landing
        let controller = SidebarWorkspaceTableController()
        let container: SidebarWorkspaceTableContainerView
        let window: NSWindow
        var lastPlan: SidebarWorkspaceReorderDropPlan?
        var accepts = true
        var source: UUID { landing == .canonicalSourceGap ? sourceMember : outside }
        var header: UUID { SidebarStatusHeaderIdentity.uuid(forStatusId: "parked") }
        var members: [UUID] {
            switch landing {
            case .emptyHeader: return []
            case .foldedHeader, .finalMember: return [member]
            case .canonicalSourceGap: return [member, sourceMember, following]
            }
        }
        var items: [SidebarWorkspaceRenderItem] {
            let group: [SidebarWorkspaceRenderItem] = [.statusesHeader, .statusGroupHeader(statusId: "parked")]
            switch landing {
            case .emptyHeader, .foldedHeader: return [.workspace(workspaceId: outside)] + group
            case .finalMember: return [.workspace(workspaceId: outside)] + group + [.workspace(workspaceId: member)]
            case .canonicalSourceGap: return group + members.map { .workspace(workspaceId: $0) }
            }
        }
        var indicator: SidebarDropIndicator {
            .init(tabId: landing == .emptyHeader || landing == .foldedHeader ? header : member, edge: .bottom)
        }
        var expectedTarget: UUID { landing == .canonicalSourceGap ? source : (landing == .finalMember ? member : header) }
        var expectedEdge: SidebarDropEdge { landing == .canonicalSourceGap ? .top : .bottom }
        var plan: SidebarWorkspaceReorderDropPlan {
            let value = SidebarStatusGroupWorkspaceDropPlan(statusId: "parked",
                placement: landing == .emptyHeader || landing == .foldedHeader ? .first : .member(member, insertBefore: false),
                setsStatus: landing != .canonicalSourceGap, indicator: indicator)
            return .init(draggedWorkspaceId: source, indicator: indicator, indicatorScope: .group(header), action: .statusGroupDrop(plan: value, sessionId: token))
        }
        init(_ landing: Landing) {
            self.landing = landing
            container = controller.makeContainerView()
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = container
        }
        static func mount(_ landing: Landing) async -> Fixture {
            _ = NSApplication.shared
            let f = Fixture(landing)
            let environment = SidebarWorkspaceTableEnvironmentSnapshot(colorScheme: .light, globalFontMagnificationPercent: 100, lazyContractProbe: .init())
            var rows: [SidebarWorkspaceTableRowConfiguration] = []
            for item in f.items {
                switch item {
                case .statusesHeader:
                    rows.append(VerticalTabsSidebar.statusHeaderConfiguration(kind: .statusesArea, presentation: nil, memberCount: 1, memberIds: [], folds: .init(), environment: environment, onToggle: {}))
                case .statusGroupHeader:
                    rows.append(VerticalTabsSidebar.statusHeaderConfiguration(kind: .statusGroup("parked"),
                        presentation: .init(name: "Parked", tintHex: "#555555", glyph: nil, behavesAs: .todo), memberCount: f.members.count,
                        memberIds: Set(f.members), folds: .init(collapsedStatusIds: landing == .foldedHeader ? ["parked"] : []), environment: environment, onToggle: {}))
                case .workspace(let id):
                    var model = SidebarAppKitRowCellTests.makeModel(workspaceId: id, colorSchemeIsDark: false)
                    model.depth = f.members.contains(id) ? 2 : 0
                    rows.append(.init(workspaceRowModel: model, actions: Self.rowActions(model), groupId: nil, isPinned: false, environment: environment))
                default: break
                }
            }
            var actions = f.actions()
            actions.usesStatusHeaderDropTargets = { true }
            f.controller.apply(rows: rows, actions: actions, workspaceIds: rows.filter { $0.statusHeaderKind == nil }.map(\.workspaceId), selectedWorkspaceId: nil, selectedScrollTargetWorkspaceId: nil)
            await withCheckedContinuation { c in RunLoop.main.perform(inModes: [.common]) { c.resume() } }
            f.container.layoutSubtreeIfNeeded(); f.container.tableView.layoutSubtreeIfNeeded()
            return f
        }
        func close() { controller.reorderDropDragExited(); controller.dismantleContainerView(container); window.contentView = nil; window.close() }
        func actions() -> SidebarWorkspaceTableActions {
            SidebarWorkspaceTableActions(attachScrollView: { _ in }, closeWorkspace: { _ in }, createWorkspaceAtEnd: {}, createEmptyWorkspaceGroup: {},
                beginWorkspaceDrag: { _ in }, movingWorkspaceCount: { _ in 1 }, endWorkspaceDrag: {}, isValidWorkspaceDrag: { true },
                updateWorkspaceDrag: { [self] _, _, _ in
                    guard accepts else { return nil }
                    let accepted = self.plan; lastPlan = accepted
                    return .init(indicator: indicator, scope: accepted.indicatorScope, draggedWorkspaceId: source,
                        indicatorRowIds: VerticalTabsSidebar.workspaceStatusDropIndicatorRows(statusId: "parked", items: items, memberWorkspaceIds: members) ?? [], plan: accepted, level: 2)
                }, performWorkspaceDrop: { _, _, _ in false }, commitWorkspaceDropPlan: { _ in true }, clearWorkspaceDropIndicator: {}, currentDropIndicator: { nil },
                currentDropIndicatorScope: { .raw }, canPerformBonsplitAction: { _, _ in false }, moveBonsplitToExistingWorkspace: { _, _ in false },
                moveBonsplitToNewWorkspace: { _, _ in nil }, didMoveBonsplitToWorkspace: { _ in }, updateDragAutoscroll: {}, setBonsplitDropTargetCollectionActive: { _ in }, setBonsplitDropIndicator: { _ in })
        }
        private static func rowActions(_ model: SidebarWorkspaceRowModel) -> SidebarAppKitRowActions {
            let commands = SidebarWorkspaceRowCommands(tab: Workspace(), tabManager: nil, notificationStore: nil, index: 0,
                contextMenuWorkspaceIds: [model.workspaceId], remoteContextMenuWorkspaceIds: [], allRemoteContextMenuTargetsConnecting: false,
                allRemoteContextMenuTargetsDisconnected: false, contextMenuPinState: nil, workspaceGroupMenuSnapshot: .init(items: []), colorScheme: .light,
                refreshSnapshot: {}, readSelectedTabIds: { [] }, writeSelectedTabIds: { _ in }, readLastSelectionIndex: { nil }, writeLastSelectionIndex: { _ in },
                setSelectionToTabs: {}, snapshotProvider: { nil })
            return SidebarAppKitRowActions(commands: commands, onOpenStatusURL: { _ in }, onOpenWorkspaceDescriptionURL: { _ in }, onOpenPullRequest: { _ in }, onOpenPort: { _ in },
                onToggleChecklistExpansion: {}, onToggleMetadataExpansion: {}, onToggleMarkdownExpansion: {}, onConsumeChecklistAddFieldActivation: {},
                checklistSetItemState: { _, _ in }, checklistRemoveItem: { _ in }, checklistAddItem: { _ in }, checklistEditItem: { _, _ in }, checklistMoveItem: { _, _ in },
                checklistOpenPane: {}, checklistAddAttachments: { _ in }, checklistRemoveAttachment: { _, _ in }, checklistOpenAttachments: { _, _ in },
                onChecklistPopoverPresentedChange: { _ in }, onBeginChecklistItemEdit: { _ in }, onEndChecklistItemEdit: { _ in }, applyTodoStatus: { _ in }, hideTodoStatus: {}, commitRename: { _ in })
        }
    }
    private func raster(_ content: AnyView) async throws -> NSBitmapImageRep {
        let view = content.frame(width: 300, height: 200).background(Color.white)
            .overlay(alignment: .topLeading) { Color.red.frame(width: 2, height: 2) }
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: 300, height: 200)
        renderer.scale = 2
        let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        let diagnostic = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("p4-workspace-paint-\(UUID().uuidString).png")
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: diagnostic)
        print("P4 SwiftUI body raster: \(diagnostic.path)")
        _ = try markerIsAtZero(bitmap) // A transparent/unrendered fixture cannot count as missing-line proof.
        return bitmap
    }
    private func markerIsAtZero(_ bitmap: NSBitmapImageRep) throws -> Bool {
        func red(_ y: Int) -> Bool {
            guard let c = bitmap.colorAt(x: 0, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return c.alphaComponent > 0.9 && c.redComponent > max(c.greenComponent, c.blueComponent) + 0.4
        }
        let first = red(0), last = red(bitmap.pixelsHigh - 1)
        if first == last {
            for y in [0, bitmap.pixelsHigh - 1] {
                print("P4 marker pixel y=\(y): \(String(describing: bitmap.colorAt(x: 0, y: y)?.usingColorSpace(.deviceRGB)))")
            }
        }
        try #require(first != last)
        return first
    }
    private func differenceBounds(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> CGRect? {
        guard lhs.pixelsWide == rhs.pixelsWide, lhs.pixelsHigh == rhs.pixelsHigh else { return nil }
        var result: CGRect?
        for y in 0..<lhs.pixelsHigh {
            for x in 0..<lhs.pixelsWide {
                guard let a = lhs.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let b = rhs.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let delta = abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
                    + abs(a.blueComponent - b.blueComponent) + abs(a.alphaComponent - b.alphaComponent)
                if delta > 0.18 {
                    let pixel = CGRect(x: x, y: y, width: 1, height: 1)
                    result = result.map { $0.union(pixel) } ?? pixel
                }
            }
        }
        return result
    }
    private func visibleLineFrames(in view: NSView, root: NSView) -> [NSRect] {
        let isLine = view === (root as? SidebarWorkspaceTableContainerView)?.emptyDropIndicatorView || view is SidebarReorderIndicatorView
        let own = isLine && !view.isHiddenOrHasHiddenAncestor && view.frame.width > 0
            ? [view.convert(view.bounds, to: root)] : []
        return own + view.subviews.flatMap { visibleLineFrames(in: $0, root: root) }
    }
}
