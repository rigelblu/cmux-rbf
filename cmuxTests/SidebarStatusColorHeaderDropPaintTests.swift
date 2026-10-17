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

#if DEBUG
@MainActor
@Suite(.serialized)
struct SidebarStatusColorHeaderDropPaintTests {
    @Test(arguments: [false, true])
    func nativeColorHeaderActuallyPaintsTheCanonicalDivider(_ fromPreviousBottom: Bool) async throws {
        let fixture = await Fixture.mount()
        defer { fixture.close() }
        let point = try fixture.point(fromPreviousBottom: fromPreviousBottom)
        #expect(fixture.controller.updateReorderDrag(windowPoint: fixture.container.reorderDropView.convert(point, to: nil)))
        let expectedIndicator = SidebarDropIndicator(tabId: fromPreviousBottom ? fixture.previous : fixture.colorId,
                                                   edge: fromPreviousBottom ? .bottom : .top)
        #expect(fixture.lastPlan?.indicator == expectedIndicator)
        let line = fixture.container.emptyDropIndicatorView
        #expect(!line.isHidden)
        let frame = fixture.container.tableView.convert(fixture.container.tableView.rect(ofRow: 1), to: fixture.container)
        #expect(line.frame == NSRect(x: 8, y: frame.maxY - 1, width: fixture.container.bounds.width - 16, height: 2))
        #expect((line.layer?.backgroundColor?.alpha ?? 0) > 0)
        #expect(visibleLineCount(in: fixture.container, fallback: line) == 1)
    }

    @Test(arguments: [false, true])
    func swiftUIColorHeaderRendersTheImmutableCanonicalPaint(_ fromPreviousBottom: Bool) async throws {
        let previous = UUID(), source = SidebarStatusHeaderIdentity.statusesAreaUUID
        let section = Self.section(member: UUID())
        let color = try #require(SidebarWorkspaceRenderItemID.colorSection(section.id).colorHeaderDropIdentity)
        let indicator = SidebarDropIndicator(tabId: fromPreviousBottom ? previous : color,
                                            edge: fromPreviousBottom ? .bottom : .top)
        let paint = SidebarStatusHeaderDropPaint.forRow(color, draggedId: source, indicator: indicator,
            rowIds: [previous, color, source], level: 0, availableWidth: 300)
        try #require(paint.top && !paint.bottom && paint.inset == 0)
        let baseline = try await raster(rawHeader(section))
        let painted = try await raster(decoratedHeader(section, paint: paint))
        let bounds = differenceBounds(baseline, painted)
        #expect(bounds != nil)
        if let bounds {
            let scale = CGFloat(painted.pixelsWide) / 300
            #expect(abs(bounds.minX / scale - 8) < 1.5)
            #expect(abs(bounds.width / scale - 284) < 2)
            #expect(bounds.height / scale <= 2.5)
            let topAtZero = try markerIsAtZero(baseline)
            #expect(topAtZero ? bounds.minY / scale < 1 : (CGFloat(painted.pixelsHigh) - bounds.maxY) / scale < 1)
        }
    }

    enum SourceGap: CaseIterable, Sendable {
        case groupAfterWholeA, areaAfterPinsOnly, areaAfterPinsBeforeLoose
        var level: Int { self == .groupAfterWholeA ? 1 : 0 }
    }

    @Test(arguments: SourceGap.allCases)
    func nativeSourceGapPaintsOutsideTheDraggedHeader(_ scenario: SourceGap) async throws {
        let fixture = await Fixture.mount(sourceGap: scenario)
        defer { fixture.close() }
        let targets = fixture.controller.refreshReorderDropTargets(includeHeaders: true)
        let target = try #require(targets.first { $0.workspaceId == fixture.previous })
        let point = CGPoint(x: target.frame.midX, y: target.frame.minY + target.frame.height * 0.9)
        #expect(fixture.controller.updateReorderDrag(windowPoint: fixture.container.reorderDropView.convert(point, to: nil)))
        let plan = try #require(fixture.lastPlan)
        if scenario == .groupAfterWholeA {
            #expect(plan.indicator == .init(tabId: fixture.previous, edge: .bottom))
            #expect(plan.action == .reorderStatusGroup(targetStatusId: "a", insertBefore: false, sessionId: fixture.token))
        } else {
            #expect(plan.indicator == .init(tabId: fixture.sourceId, edge: .top))
            #expect(plan.action == .moveStatusesArea(aboveRow: "top", belowRow: scenario == .areaAfterPinsOnly ? nil : "workspace:\(fixture.tail.uuidString)", last: scenario == .areaAfterPinsOnly, sessionId: fixture.token))
        }
        let sourceRow = try #require(fixture.items.firstIndex { $0.headerDropIdentity == fixture.sourceId })
        let sourceFrame = fixture.container.tableView.convert(fixture.container.tableView.rect(ofRow: sourceRow), to: fixture.container)
        let line = fixture.container.emptyDropIndicatorView
        let inset = SidebarNestedDropLine.inset(level: scenario.level, availableWidth: 300)
        #expect(!line.isHidden)
        #expect(line.frame == NSRect(x: 8 + inset, y: sourceFrame.maxY - 1, width: 284 - inset, height: 2))
        #expect(visibleLineCount(in: fixture.container, fallback: line) == 1)
        let painter = SidebarWorkspaceTableReorderIndicatorPainter(indicator: plan.indicator, scope: .raw,
            draggedWorkspaceId: fixture.sourceId, indicatorRowIds: fixture.items.compactMap(\.headerDropIdentity), level: scenario.level)
        #expect(!painter.paint(forRowWorkspaceId: fixture.sourceId).top) // The ghost/source cell remains clean.
    }

    @Test(arguments: SourceGap.allCases)
    func swiftUISourceGapPaintsInTheParentOverlay(_ scenario: SourceGap) async throws {
        let previous = UUID(), source = scenario == .groupAfterWholeA
            ? SidebarStatusHeaderIdentity.uuid(forStatusId: "b") : SidebarStatusHeaderIdentity.statusesAreaUUID
        let indicator = SidebarDropIndicator(tabId: scenario == .groupAfterWholeA ? previous : source,
            edge: scenario == .groupAfterWholeA ? .bottom : .top)
        let frame = try #require(SidebarStatusHeaderSourceGapOverlay.frame(draggedId: source, indicator: indicator,
            rowIds: [previous, source], frames: [source: CGRect(x: 0, y: 1, width: 300, height: 25)],
            level: scenario.level, width: 300))
        let header = AnyView(SidebarStatusesAreaSwiftUIHeader(groupCount: 2, isCollapsed: false).frame(width: 300, height: 26))
        let baseline = try await raster(header)
        try await calibrateParentOverlay(header: header, baseline: baseline, frame: frame)
        let painted = try await raster(AnyView(header.overlay(alignment: .topLeading) {
            SidebarStatusHeaderSourceGapOverlay(frame: frame)
        }))
        let bounds = differenceBounds(baseline, painted)
        #expect(bounds != nil)
        if let bounds {
            let scale = CGFloat(painted.pixelsWide) / 300
            #expect(abs(bounds.minX / scale - frame.minX) < 1.5)
            #expect(abs(bounds.width / scale - frame.width) < 2)
            #expect(bounds.height / scale <= 2.5)
            let topAtZero = try markerIsAtZero(baseline)
            let top = topAtZero ? bounds.minY / scale : (CGFloat(painted.pixelsHigh) - bounds.maxY) / scale
            #expect(abs(top - frame.minY) < 1.5)
        }
        let sourcePaint = SidebarStatusHeaderDropPaint.forRow(source, draggedId: source, indicator: indicator,
            rowIds: [previous, source], level: scenario.level, availableWidth: 300)
        #expect(!sourcePaint.top && !sourcePaint.bottom)
    }

    enum EndGap: CaseIterable, Sendable {
        case groupEmpty, groupWithMember, area
        var level: Int { self == .area ? 0 : 1 }
    }
    enum ClearRoute: CaseIterable, Sendable { case color, sourceGroup, sourceArea, endGroup, endArea }
    enum ClearEnding: CaseIterable, Sendable { case refused, ended, reused, committed }

    private func nativeFinalAppendControl(_ scenario: EndGap) async throws {
        let fixture = await Fixture.mount(endGap: scenario)
        defer { fixture.close() }
        let point = try fixture.endPoint()
        try #require(fixture.controller.updateReorderDrag(windowPoint: fixture.container.reorderDropView.convert(point, to: nil)))
        let plan = try #require(fixture.lastPlan)
        let last = try #require(fixture.items.last?.headerDropIdentity)
        #expect(plan.indicator == .init(tabId: last, edge: .bottom))
        let line = fixture.container.emptyDropIndicatorView
        let row = fixture.container.tableView.convert(fixture.container.tableView.rect(ofRow: fixture.items.count - 1), to: fixture.container)
        let inset = SidebarNestedDropLine.inset(level: scenario.level, availableWidth: 300)
        #expect(!line.isHidden)
        #expect(line.frame == NSRect(x: 8 + inset, y: row.minY - 1, width: 284 - inset, height: 2))
        #expect(visibleLineCount(in: fixture.container, fallback: line) == 1)
    }

    @Test(arguments: EndGap.allCases)
    func swiftUIFinalAppendActuallyPaintsTheParentEndRoute(_ scenario: EndGap) async throws {
        try await nativeFinalAppendControl(scenario)
        let source = UUID(), last = UUID()
        let frame = try #require(VerticalTabsSidebar.statusHeaderFinalAppendFrame(draggedId: source,
            indicator: .init(tabId: last, edge: .bottom), rowIds: [source, last],
            frames: [last: CGRect(x: 0, y: 0, width: 300, height: 25)], level: scenario.level, width: 300))
        let header = AnyView(SidebarStatusesAreaSwiftUIHeader(groupCount: 2, isCollapsed: false).frame(width: 300, height: 26))
        let baseline = try await raster(header)
        try await calibrateParentOverlay(header: header, baseline: baseline, frame: frame)
        let painted = try await raster(AnyView(header.overlay(alignment: .topLeading) {
            VerticalTabsSidebar.statusHeaderFinalAppendOverlay(frame: frame)
        }))
        let bounds = differenceBounds(baseline, painted)
        #expect(bounds != nil)
        if let bounds {
            let scale = CGFloat(painted.pixelsWide) / 300
            #expect(abs(bounds.minX / scale - frame.minX) < 1.5)
            #expect(abs(bounds.width / scale - frame.width) < 2)
            #expect(bounds.height / scale <= 2.5)
            let topAtZero = try markerIsAtZero(baseline)
            let top = topAtZero ? bounds.minY / scale : (CGFloat(painted.pixelsHigh) - bounds.maxY) / scale
            #expect(abs(top - frame.minY) < 1.5)
        }
    }

    @Test(arguments: ClearRoute.allCases, ClearEnding.allCases)
    func nativePaintClearsAfterRefusalEndReuseOrCachedCommit(_ route: ClearRoute, _ ending: ClearEnding) async throws {
        let fixture: Fixture
        switch route {
        case .color: fixture = await Fixture.mount()
        case .sourceGroup: fixture = await Fixture.mount(sourceGap: .groupAfterWholeA)
        case .sourceArea: fixture = await Fixture.mount(sourceGap: .areaAfterPinsOnly)
        case .endGroup: fixture = await Fixture.mount(endGap: .groupWithMember)
        case .endArea: fixture = await Fixture.mount(endGap: .area)
        }
        defer { fixture.close() }
        let point: CGPoint
        switch route {
        case .color: point = try fixture.point(fromPreviousBottom: false)
        case .sourceGroup, .sourceArea:
            let target = try #require(fixture.controller.refreshReorderDropTargets(includeHeaders: true).first { $0.workspaceId == fixture.previous })
            point = CGPoint(x: target.frame.midX, y: target.frame.minY + target.frame.height * 0.9)
        case .endGroup, .endArea: point = try fixture.endPoint()
        }
        try #require(fixture.controller.updateReorderDrag(windowPoint: fixture.container.reorderDropView.convert(point, to: nil)))
        let line = fixture.container.emptyDropIndicatorView
        try #require(!line.isHidden && visibleLineCount(in: fixture.container, fallback: line) == 1)
        let originalPlan = try #require(fixture.lastPlan)
        switch ending {
        case .refused:
            fixture.allowsPlan = false
            #expect(!fixture.controller.updateReorderDrag(windowPoint: fixture.container.reorderDropView.convert(point, to: nil)))
        case .ended: fixture.controller.reorderDropDragExited()
        case .reused:
            fixture.controller.reorderDropDragExited()
            let table = fixture.container.tableView
            for row in fixture.items.indices {
                (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView)?.prepareForReuse()
            }
        case .committed:
            let perform = try #require(fixture.container.reorderDropView.performDropAtPoint)
            #expect(perform(CGPoint(x: -500, y: -500), [])) // Release drift must commit the originally painted action/token.
            #expect(fixture.committedPlan == originalPlan)
        }
        #expect(line.isHidden)
        #expect(visibleLineCount(in: fixture.container, fallback: line) == 0)
    }

    @Test(arguments: ClearRoute.allCases)
    func swiftUIImmutablePaintClearsIncludingTheEndGeometry(_ route: ClearRoute) async throws {
        let section = Self.section(member: UUID())
        let header = rawHeader(section)
        let baseline = try await raster(header)
        let painted: AnyView
        let cleared: AnyView
        if route == .color {
            painted = decoratedHeader(section, paint: .init(top: true, bottom: false, inset: 0))
            cleared = decoratedHeader(section, paint: .none)
        } else {
            let level = route == .sourceGroup || route == .endGroup ? 1 : 0
            let inset = SidebarNestedDropLine.inset(level: level, availableWidth: 300)
            let y: CGFloat = route == .endGroup || route == .endArea ? 24 : 0
            let frame = CGRect(x: 8 + inset, y: y, width: 284 - inset, height: 2)
            painted = AnyView(header.overlay(alignment: .topLeading) { SidebarStatusHeaderSourceGapOverlay(frame: frame) })
            cleared = AnyView(header.overlay(alignment: .topLeading) { SidebarStatusHeaderSourceGapOverlay(frame: nil) })
        }
        let accepted = try await raster(painted)
        try #require(differenceBounds(baseline, accepted) != nil) // Accepted visible control precedes every clear assertion.
        let empty = try await raster(cleared)
        #expect(differenceBounds(baseline, empty) == nil)
    }

    private func calibrateParentOverlay(header: AnyView, baseline: NSBitmapImageRep, frame: CGRect) async throws {
        // An independent accent rectangle proves the expected line fits this canvas before observing the SUT.
        let control = try await raster(AnyView(header.overlay(alignment: .topLeading) {
            Rectangle().fill(cmuxAccentColor()).frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
        }))
        let bounds = try #require(differenceBounds(baseline, control))
        let scale = CGFloat(control.pixelsWide) / 300
        let topAtZero = try markerIsAtZero(baseline)
        let top = topAtZero ? bounds.minY / scale : (CGFloat(control.pixelsHigh) - bounds.maxY) / scale
        try #require(abs(bounds.minX / scale - frame.minX) < 1.5)
        try #require(abs(bounds.width / scale - frame.width) < 2)
        try #require(abs(bounds.height / scale - frame.height) < 1)
        try #require(abs(top - frame.minY) < 1.5)
    }

    private static func section(member: UUID) -> SidebarWorkspaceColorSection {
        .init(id: .init(normalizedHex: "#AABBCC", pinTier: .unpinned), title: "Color", memberWorkspaceIds: [member], isCollapsed: false)
    }
    private func rawHeader(_ section: SidebarWorkspaceColorSection) -> AnyView {
        AnyView(SidebarWorkspaceColorSectionHeader(section: section, colorScheme: .light, onToggle: {}))
    }
    private func decoratedHeader(_ section: SidebarWorkspaceColorSection, paint: SidebarStatusHeaderDropPaint) -> AnyView {
        AnyView(VerticalTabsSidebar.statusColorHeaderRow(section: section, colorScheme: .light,
            collectTargets: false, toggle: { _ in }, frameChanged: { _, _ in }, disappeared: { _ in }, paint: paint))
    }
    private func raster(_ content: AnyView) async throws -> NSBitmapImageRep {
        let view = content.frame(width: 300, height: 26).background(Color.white)
            .overlay(alignment: .topLeading) { Color.red.frame(width: 2, height: 2) }
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: 300, height: 26)
        renderer.scale = 2
        let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        let diagnostic = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("p3-r1-raster-\(UUID().uuidString).png")
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: diagnostic)
        print("R1 SwiftUI body raster: \(diagnostic.path)")
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
                print("R1 marker pixel y=\(y): \(String(describing: bitmap.colorAt(x: 0, y: y)?.usingColorSpace(.deviceRGB)))")
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
    private func visibleLineCount(in view: NSView, fallback: NSView) -> Int {
        let line = view === fallback || view is SidebarReorderIndicatorView
        return (line && !view.isHiddenOrHasHiddenAncestor && view.frame.width > 0 ? 1 : 0)
            + view.subviews.reduce(0) { $0 + visibleLineCount(in: $1, fallback: fallback) }
    }
    private func flush() async {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.common]) { continuation.resume() }
        }
    }

    private struct Row: View, Equatable { var body: some View { Color.clear.frame(height: 30) } }

    @MainActor
    private final class Fixture {
        let previous: UUID, member: UUID, tail: UUID, token = UUID()
        let sourceGap: SourceGap?
        let endGap: EndGap?
        var sourceId: UUID {
            if let endGap, endGap != .area { return SidebarStatusHeaderIdentity.uuid(forStatusId: "a") }
            return sourceGap == .groupAfterWholeA ? SidebarStatusHeaderIdentity.uuid(forStatusId: "b") : SidebarStatusHeaderIdentity.statusesAreaUUID
        }
        let controller = SidebarWorkspaceTableController()
        let container: SidebarWorkspaceTableContainerView
        let window: NSWindow
        let section: SidebarWorkspaceColorSection
        let items: [SidebarWorkspaceRenderItem]
        var lastPlan: SidebarWorkspaceReorderDropPlan?
        var committedPlan: SidebarWorkspaceReorderDropPlan?
        var allowsPlan = true
        var colorId: UUID { SidebarWorkspaceRenderItemID.colorSection(section.id).colorHeaderDropIdentity! }
        init(sourceGap: SourceGap?, endGap: EndGap?) {
            let previous = UUID(), member = UUID(), tail = UUID()
            self.previous = previous; self.member = member; self.tail = tail; self.sourceGap = sourceGap; self.endGap = endGap
            let section = SidebarStatusColorHeaderDropPaintTests.section(member: member)
            self.section = section
            if let endGap {
                if endGap == .area { items = [.statusesHeader, .workspace(workspaceId: tail)] }
                else {
                    items = [.statusesHeader, .statusGroupHeader(statusId: "a"), .statusGroupHeader(statusId: "b")]
                        + (endGap == .groupWithMember ? [.workspace(workspaceId: tail)] : [])
                }
            } else { switch sourceGap {
            case .groupAfterWholeA:
                items = [.statusesHeader, .statusGroupHeader(statusId: "a"), .workspace(workspaceId: previous), .statusGroupHeader(statusId: "b")]
            case .areaAfterPinsOnly: items = [.workspace(workspaceId: previous), .statusesHeader]
            case .areaAfterPinsBeforeLoose: items = [.workspace(workspaceId: previous), .statusesHeader, .workspace(workspaceId: tail)]
            case nil:
                items = [.workspace(workspaceId: previous), .colorSectionHeader(section: section), .workspace(workspaceId: member),
                         .workspace(workspaceId: tail), .statusesHeader]
            } }
            container = controller.makeContainerView()
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = container
        }
        static func mount(sourceGap: SourceGap? = nil, endGap: EndGap? = nil) async -> Fixture {
            _ = NSApplication.shared
            let fixture = Fixture(sourceGap: sourceGap, endGap: endGap)
            let environment = SidebarWorkspaceTableEnvironmentSnapshot(colorScheme: .light,
                globalFontMagnificationPercent: 100, lazyContractProbe: .init())
            var rows: [SidebarWorkspaceTableRowConfiguration] = []
            for item in fixture.items {
                switch item {
                case .colorSectionHeader(let section):
                    let header = SidebarWorkspaceColorSectionHeader(section: section, colorScheme: .light, onToggle: {})
                    rows.append(.init(id: item.id, workspaceId: fixture.member, groupId: nil, isGroupHeader: false,
                        isPinned: false, colorSectionToggle: {}, environment: environment, equivalenceValue: header,
                        makeContent: { _, _ in AnyView(header) }))
                case .statusesHeader:
                    rows.append(VerticalTabsSidebar.statusHeaderConfiguration(kind: .statusesArea, presentation: nil,
                        memberCount: 0, memberIds: [], folds: .init(), environment: environment, onToggle: {}))
                case .statusGroupHeader(let id):
                    rows.append(VerticalTabsSidebar.statusHeaderConfiguration(kind: .statusGroup(id),
                        presentation: .init(name: id, tintHex: nil, glyph: nil, behavesAs: .working),
                        memberCount: id == "a" ? 1 : 0, memberIds: [], folds: .init(), environment: environment,
                        onToggle: {}, isBeingDragged: SidebarStatusHeaderIdentity.uuid(forStatusId: id) == fixture.sourceId))
                case .workspace(let id):
                    rows.append(.init(id: item.id, workspaceId: id, groupId: nil, isGroupHeader: false,
                        isPinned: sourceGap != nil && sourceGap != .groupAfterWholeA && id == fixture.previous, environment: environment, equivalenceValue: Row(), makeContent: { _, _ in AnyView(Row()) }))
                default: break
                }
            }
            var actions = fixture.actions()
            actions.usesStatusHeaderDropTargets = { true }
            fixture.controller.apply(rows: rows, actions: actions, workspaceIds: [fixture.previous, fixture.member, fixture.tail],
                selectedWorkspaceId: nil, selectedScrollTargetWorkspaceId: nil)
            await withCheckedContinuation { continuation in
                RunLoop.main.perform(inModes: [.common]) { continuation.resume() }
            }
            fixture.container.layoutSubtreeIfNeeded()
            fixture.container.tableView.layoutSubtreeIfNeeded()
            _ = fixture.container.tableView.view(atColumn: 0, row: 1, makeIfNecessary: true)
            return fixture
        }
        func point(fromPreviousBottom: Bool) throws -> CGPoint {
            let id = fromPreviousBottom ? SidebarWorkspaceRenderItemID.workspace(previous) : .colorSection(section.id)
            let target = try #require(controller.refreshReorderDropTargets(includeHeaders: true).first { $0.renderItemId == id })
            return CGPoint(x: target.frame.midX, y: target.frame.minY + target.frame.height * (fromPreviousBottom ? 0.75 : 0.25))
        }
        func endPoint() throws -> CGPoint {
            let last = try #require(controller.refreshReorderDropTargets(includeHeaders: true).last)
            return CGPoint(x: last.frame.midX, y: last.frame.minY + last.frame.height * 0.9)
        }
        func close() { controller.reorderDropDragExited(); controller.dismantleContainerView(container); window.contentView = nil; window.close() }
        func actions() -> SidebarWorkspaceTableActions {
            SidebarWorkspaceTableActions(attachScrollView: { _ in }, closeWorkspace: { _ in }, createWorkspaceAtEnd: {},
                createEmptyWorkspaceGroup: {}, beginWorkspaceDrag: { _ in }, movingWorkspaceCount: { _ in 1 },
                endWorkspaceDrag: {}, isValidWorkspaceDrag: { true },
                updateWorkspaceDrag: { [weak self] point, measured, _ in
                    guard let self, allowsPlan else { return nil }
                    let projection: WorkspaceStatusGroupProjection?
                    if sourceGap == .groupAfterWholeA {
                        projection = .init(groups: [.init(statusId: "a", memberWorkspaceIds: [previous]), .init(statusId: "b", memberWorkspaceIds: [])])
                    } else if let endGap, endGap != .area {
                        projection = .init(groups: [.init(statusId: "a", memberWorkspaceIds: []),
                            .init(statusId: "b", memberWorkspaceIds: endGap == .groupWithMember ? [tail] : [])])
                    } else { projection = nil }
                    let targets = SidebarStatusAreaLayout(items: items, statusProjection: projection).headerDropTargets(measured: measured).map { target in
                        SidebarStatusHeaderDropTarget(rowId: target.rowId, frame: target.frame, topLevelRowId: target.topLevelRowId,
                            statusId: target.statusId, isStatusesArea: target.isStatusesArea,
                            isPinned: self.sourceGap != nil && self.sourceGap != .groupAfterWholeA && target.rowId == self.previous)
                    }
                    guard let raw = SidebarStatusHeaderDropPlanner().plan(point: point,
                        draggedStatusId: sourceGap == .groupAfterWholeA ? "b" : (endGap != nil && endGap != .area ? "a" : nil), targets: targets) else { return nil }
                    let action: SidebarWorkspaceReorderDropAction
                    switch raw.action {
                    case .area(let above, let below, let last):
                        action = .moveStatusesArea(aboveRow: above, belowRow: below, last: last, sessionId: token)
                    case .statusGroup(let target, let before):
                        action = .reorderStatusGroup(targetStatusId: target, insertBefore: before, sessionId: token)
                    }
                    let plan = SidebarWorkspaceReorderDropPlan(draggedWorkspaceId: sourceId,
                        indicator: raw.indicator, action: action)
                    lastPlan = plan
                    return .init(indicator: raw.indicator, scope: .raw, draggedWorkspaceId: plan.draggedWorkspaceId,
                        indicatorRowIds: items.compactMap(\.headerDropIdentity), plan: plan, level: sourceGap?.level ?? endGap?.level ?? 0)
                }, performWorkspaceDrop: { _, _, _ in false }, commitWorkspaceDropPlan: { [weak self] plan in self?.committedPlan = plan; return true },
                clearWorkspaceDropIndicator: {}, currentDropIndicator: { nil }, currentDropIndicatorScope: { .raw },
                canPerformBonsplitAction: { _, _ in false }, moveBonsplitToExistingWorkspace: { _, _ in false },
                moveBonsplitToNewWorkspace: { _, _ in nil }, didMoveBonsplitToWorkspace: { _ in },
                updateDragAutoscroll: {}, setBonsplitDropTargetCollectionActive: { _ in }, setBonsplitDropIndicator: { _ in })
        }
    }
}
#endif
