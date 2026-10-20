import AppKit
import CmuxWorkspaces
import SwiftUI

/// The group's explicit choices, shared by its two context menus and its glyph popover.
struct SidebarWorkspaceGroupStatusMenu: Equatable, Hashable {
    struct Row: Equatable, Hashable, Identifiable {
        let action: WorkspaceStatusPickAction
        let title: String
        let isSelected: Bool
        let glyph: SidebarWorkspaceGroupStatusGlyph?
        var id: WorkspaceStatusPickAction { action }
    }
    let rows: [Row]

    static var title: String { String(localized: "contextMenu.workspaceStatus", defaultValue: "Status") }

    static func resolve(group: WorkspaceGroup, list: WorkspaceStatusList,
                        colorHexes: [String: String], controlsEnabled: Bool) -> Self? {
        guard controlsEnabled, list.source != .cmux else { return nil }
        let none = Row(action: .hide, title: String(localized: "workspaceGroup.status.none", defaultValue: "None"),
                       isSelected: group.statusId == nil, glyph: nil)
        let statuses = list.entries.map { entry in
            Row(action: .status(id: entry.id), title: WorkspaceStatusPresentation.text(entry.label),
                isSelected: group.statusId == entry.id,
                glyph: SidebarWorkspaceGroupStatusGlyph(status: entry.behavesAs,
                    name: WorkspaceStatusPresentation.text(entry.label), glyph: entry.icon, colorHex: colorHexes[entry.id]))
        }
        return Self(rows: [none] + statuses)
    }

    @MainActor
    func makeAppKit(apply: @escaping (WorkspaceStatusPickAction) -> Void, isDark: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, row) in rows.enumerated() {
            let target = GroupStatusMenuActionTarget { apply(row.action) }
            let item = NSMenuItem(title: row.title, action: #selector(GroupStatusMenuActionTarget.invoke(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = target
            item.state = row.isSelected ? .on : .off
            if let glyph = row.glyph {
                item.image = WorkspaceStatusMenuImage.make(status: glyph.status, icon: glyph.glyph,
                                                          colorHex: glyph.colorHex, isDark: isDark)
            }
            menu.addItem(item)
            if index == 0 { menu.addItem(.separator()) }
        }
        return menu
    }

    var popoverModel: SidebarWorkspaceStatusPopoverModel {
        let lanes = rows.map { row in
            WorkspaceTodoStatusLane(status: row.glyph?.status, title: row.title, isSelected: row.isSelected,
                                    action: row.action, isNone: row.action == .hide,
                                    colorHex: row.glyph?.colorHex, icon: row.glyph?.glyph)
        }
        return SidebarWorkspaceStatusPopoverModel(inferred: .todo, activeOverride: nil,
            picker: WorkspaceStatusPickerState(rows: []), colorHexes: [:], lanesOverride: lanes)
    }
}

@MainActor
private final class GroupStatusMenuActionTarget: NSObject {
    private let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func invoke(_ item: NSMenuItem) { run() }
}

@MainActor
extension VerticalTabsSidebar {
    static func bindWorkspaceGroupStatusActions(_ actions: inout SidebarGroupHeaderRowActions, tabManager: TabManager, groupId: UUID) {
        actions.onSetStatus = { [weak tabManager] action in
            guard let tabManager else { return }
            WorkspaceGroupStatusUIActions.app(tabManager: tabManager).applyGroup(action, groupId: groupId)
        }
        actions.statusMenu = { [weak tabManager] in
            guard let group = tabManager?.workspaceGroups.first(where: { $0.id == groupId }) else { return nil }
            return workspaceGroupStatusMenu(for: group)
        }
    }

    static func workspaceGroupStatusMenu(for group: WorkspaceGroup) -> SidebarWorkspaceGroupStatusMenu? {
        SidebarWorkspaceGroupStatusMenu.resolve(group: group, list: AppDelegate.statusListInUse,
            colorHexes: AppDelegate.shared?.workspaceStatusListStore.colorHexes ?? [:], controlsEnabled: WorkspaceTodoFeature.isEnabled)
    }
}

@MainActor
extension SidebarGroupHeaderTableCellView {
    func appendGroupStatusMenu(to menu: NSMenu, actions: SidebarGroupHeaderRowActions) {
        guard let value = actions.statusMenu() else { return }
        let parent = NSMenuItem(title: SidebarWorkspaceGroupStatusMenu.title, action: nil, keyEquivalent: "")
        parent.submenu = value.makeAppKit(apply: actions.onSetStatus,
                                         isDark: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        menu.addItem(parent)
    }
}

/// The same explicit row list in the SwiftUI header's context menu.
struct SidebarWorkspaceGroupStatusMenuView: View {
    let menu: SidebarWorkspaceGroupStatusMenu?
    let apply: (WorkspaceStatusPickAction) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let menu, let first = menu.rows.first {
            Menu(SidebarWorkspaceGroupStatusMenu.title) {
                row(first)
                Divider()
                ForEach(menu.rows.dropFirst()) { row($0) }
            }
        }
    }

    private func row(_ row: SidebarWorkspaceGroupStatusMenu.Row) -> some View {
        Button { apply(row.action) } label: {
            if let glyph = row.glyph {
                Label {
                    Text(row.title)
                } icon: {
                    HStack(spacing: 3) {
                        if row.isSelected { Image(systemName: "checkmark") }
                        else { Image(systemName: "checkmark").hidden() }
                        Image(nsImage: WorkspaceStatusMenuImage.make(status: glyph.status, icon: glyph.glyph,
                            colorHex: glyph.colorHex, isDark: colorScheme == .dark))
                    }
                }
            } else if row.isSelected { Label(row.title, systemImage: "checkmark") }
            else { Text(row.title) }
        }
    }
}
