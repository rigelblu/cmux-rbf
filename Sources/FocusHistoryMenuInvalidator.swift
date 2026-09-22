import AppKit
import SwiftUI
import CmuxFoundation

@MainActor
final class FocusHistoryMenuInvalidator: ObservableObject {
    @Published private(set) var revision: UInt64 = 0

    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    init(center: NotificationCenter = .default) {
        self.center = center
        observers.append(center.addObserver(
            forName: .tabManagerFocusHistoryRevisionDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.revision &+= 1
            }
        })
        observers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.revision &+= 1
            }
        })
        observers.append(center.addObserver(
            forName: .paneZoomDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.revision &+= 1
            }
        })
        // A terminal's font can change through Ghostty's own bindings, which
        // bypass cmux's zoom routing; Ghostty reports every such change as a
        // cell-size action.
        observers.append(center.addObserver(
            forName: .ghosttyDidUpdateCellSize,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.revision &+= 1
            }
        })
        observers.append(center.addObserver(
            forName: GlobalFontMagnification.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.revision &+= 1
            }
        })
    }

    deinit {
        for observer in observers {
            center.removeObserver(observer)
        }
    }
}
