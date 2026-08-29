import AppKit
import SwiftUI

enum HexColorPickerCommitBehavior: Equatable {
    case continuous
    case interactionEnd
}

enum HexColorPickerInteractionEvent: Equatable {
    case colorPanelWillClose
    case colorPanelDidResignKey
    case viewDisappeared

    var shouldCommit: Bool {
        switch self {
        case .colorPanelWillClose, .viewDisappeared:
            true
        case .colorPanelDidResignKey:
            false
        }
    }
}

@MainActor
struct HexColorPicker: View {
    private let reconcileState: HexColorPickerReconcileState
    private let onChange: (String) -> Void
    private let commitBehavior: HexColorPickerCommitBehavior

    @State private var selection: HexColorPickerSelection

    init(
        storedHex: String,
        fallback: Color,
        reconcileRevision: Int,
        commitBehavior: HexColorPickerCommitBehavior = .continuous,
        onChange: @escaping (String) -> Void
    ) {
        let initialState = HexColorPickerReconcileState(storedHex: storedHex, revision: reconcileRevision)
        self.reconcileState = initialState
        self.onChange = onChange
        self.commitBehavior = commitBehavior
        _selection = State(initialValue: HexColorPickerSelection(state: initialState, fallback: fallback))
    }

    private func finishInteraction() {
        guard commitBehavior == .interactionEnd,
              let hex = selection.finishPendingSelection() else { return }
        onChange(hex)
    }

    var body: some View {
        ColorPicker(
            selection: Binding(
                get: { selection.color },
                set: { newColor in
                    let hex = selection.applyPickerSelection(newColor)
                    if commitBehavior == .continuous { onChange(hex) }
                }
            ),
            supportsOpacity: false
        ) {
            EmptyView()
        }
        .labelsHidden()
        .frame(width: 38)
        .onChange(of: reconcileState) { _, newState in
            selection.reconcile(state: newState)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSColorPanel.willCloseNotification)) { _ in
            if HexColorPickerInteractionEvent.colorPanelWillClose.shouldCommit {
                finishInteraction()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            guard notification.object is NSColorPanel else { return }
            if HexColorPickerInteractionEvent.colorPanelDidResignKey.shouldCommit {
                finishInteraction()
            }
        }
        .onDisappear {
            if HexColorPickerInteractionEvent.viewDisappeared.shouldCommit {
                finishInteraction()
            }
        }
    }
}
