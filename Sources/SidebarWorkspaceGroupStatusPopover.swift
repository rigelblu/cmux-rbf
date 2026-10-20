import AppKit
import CmuxWorkspaces
import SwiftUI

/// Owns the transparent glyph hit target and the existing shared status popover presenter.
@MainActor
final class SidebarWorkspaceGroupStatusPopoverHost {
    let button = SidebarHeaderGlyphButton()
    private let presenter = SidebarRowSwiftUIPopoverPresenter()
    private var menu: SidebarWorkspaceGroupStatusMenu?
    private var apply: (WorkspaceStatusPickAction) -> Void = { _ in }
    var isShown: Bool { presenter.isShown }

    init() {
        button.isHidden = true
        button.isTransparent = true
        button.focusRingType = .none
        button.setAccessibilityIdentifier("SidebarWorkspaceGroupStatusIndicatorMenu")
        button.onClick = { [weak self] in self?.toggle() }
        presenter.maxHeight = 400
    }
    func install(in view: NSView) { view.addSubview(button) }
    func configure(menu: SidebarWorkspaceGroupStatusMenu?, showsGlyph: Bool, name: String? = nil,
                   apply: @escaping (WorkspaceStatusPickAction) -> Void) {
        let changed = self.menu != menu
        self.menu = menu
        self.apply = apply
        button.isHidden = !showsGlyph || menu == nil
        button.isEnabled = !button.isHidden
        guard !button.isHidden else { close(); return }
        let name = name ?? menu?.rows.first(where: \.isSelected)?.title ?? ""
        let label = String(localized: "sidebar.status.compactLabel", defaultValue: "Status: \(name)")
        button.setAccessibilityLabel(label)
        button.toolTip = label
        if changed, presenter.isShown { presenter.update(content()) }
    }
    func updateFrame(_ frame: NSRect) { button.frame = frame }
    func close() { presenter.close() }

    private func toggle() {
        if presenter.isShown { close(); return }
        guard !button.isHidden, menu != nil, button.window != nil else { return }
        presenter.present(content(), relativeTo: button.bounds, of: button, preferredEdge: .maxX)
    }
    private func content() -> AnyView {
        guard let menu else { return AnyView(EmptyView()) }
        return AnyView(SidebarWorkspaceGroupStatusPopoverContent(model: menu.popoverModel,
            apply: { [weak self] action in self?.apply(action) }, close: { [weak self] in self?.close() }))
    }
}

/// Both renderers use the existing status picker, with the group's explicit lanes and action path.
private struct SidebarWorkspaceGroupStatusPopoverContent: View {
    let model: SidebarWorkspaceStatusPopoverModel
    let apply: (WorkspaceStatusPickAction) -> Void
    let close: @MainActor () -> Void
    var body: some View {
        SidebarWorkspaceStatusPopover(model: model, onSelectLane: apply,
                                      onSelectNone: { apply(.hide) }, onClose: close)
    }
}

struct SidebarWorkspaceGroupStatusGlyphButton: View {
    let glyph: SidebarWorkspaceGroupStatusGlyph
    let menu: SidebarWorkspaceGroupStatusMenu?
    let fontScale: CGFloat
    let colorScheme: ColorScheme
    let band: SidebarGroupHeaderBandPalette
    let apply: (WorkspaceStatusPickAction) -> Void
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(nsImage: glyph.image(fontScale: fontScale, colorScheme: colorScheme, band: band))
                .frame(width: SidebarWorkspaceGroupHeaderMetrics(fontScale: fontScale).iconFrame,
                       height: SidebarWorkspaceGroupHeaderMetrics(fontScale: fontScale).iconFrame)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if let menu {
                SidebarWorkspaceTodoPopoverHost(isPresented: $isPresented, model: menu.popoverModel,
                                                minWidth: 200, maxHeight: 400, preferredEdge: .maxX) { model, close in
                    SidebarWorkspaceGroupStatusPopoverContent(model: model, apply: apply, close: close)
                }
            }
        }
        .safeHelp(String(localized: "sidebar.status.compactLabel", defaultValue: "Status: \(glyph.name)"))
        .accessibilityLabel(String(localized: "sidebar.status.compactLabel", defaultValue: "Status: \(glyph.name)"))
        .accessibilityIdentifier("SidebarWorkspaceGroupStatusIndicatorMenu")
    }
}
