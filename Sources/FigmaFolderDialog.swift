import AppKit
import CmuxSettings
import Foundation

// cmux-rbf #cm-73.42: the Set Figma Folder dialog and the one write path the Figma button's
// Set Folder and Remove Folder share. The rules (the pop-up, what is selected, when Set Folder
// is enabled) are `FigmaFolderDialogState`'s; this file draws them and writes.

/// What a pressed Set Folder hands back: the link that passed the check and the picked directory
/// with symlinks resolved, which is the key to write.
struct FigmaFolderDialogResult {
    let link: FigmaFolderLink
    let directory: String
}

/// The write both menu actions use (`CLAUDE.md`, "Shared behavior policy": one mutation path).
///
/// **It reads the file again at the press.** `JSONConfigStore` is an actor in each process with no
/// lock between the app and a CLI, so a plan made from the entries read when the menu opened would
/// drop an entry an agent's `set --dir` wrote while the dialog was open. `write` reads with
/// ``JSONConfigStore/strictRoot()``: a file that cannot be read, or is not valid JSON, gets the
/// alert and nothing is written. A `figma.folders` that is not an object is written over by Set.
struct FigmaFolderWriter {
    var store: JSONConfigStore
    /// The plan. A test replaces it with one that counts calls.
    var planner: (FigmaFolders.Change, String, FigmaFolderEntries) -> FigmaFolders.Plan = {
        FigmaFolders.plan($0, directory: $1, entries: $2)
    }
    /// Shows the error alert with the house's words.
    var showError: @MainActor (String) -> Void = FigmaFolderWriter.showAlert

    @MainActor
    func write(_ change: FigmaFolders.Change, directory resolved: String) async {
        do {
            let root = try store.strictRoot()
            let entries = (try? FigmaFolderChoice.strictEntries(root: root).get()) ?? .empty
            let plan = planner(change, resolved, entries)
            try await FigmaFolders.apply(plan, to: store)
        } catch {
            showError("figma.folders: \(Self.message(for: error))")
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case JSONConfigStoreStrictReadError.notValidJSON:
            return String(localized: "figma.folderDialog.invalidJSON", defaultValue: "cmux.json is not valid JSON.")
        case JSONConfigStoreStrictReadError.unreadable(let reason):
            return reason
        default:
            return error.localizedDescription
        }
    }

    /// The alert Settings shows for a write that failed, as an AppKit alert: the Settings one is an
    /// internal SwiftUI modifier a `Workspace` cannot use.
    @MainActor
    static func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "settings.error.alert.title", defaultValue: "Couldn't save setting")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "settings.error.alert.dismiss", defaultValue: "OK"))
        _ = alert.runCmuxModal()
    }
}

/// The write started by the last menu action, so a test can wait for it.
@MainActor
enum FigmaFolderWriteTracker {
    static var last: Task<Void, Never>?
}

@MainActor
enum FigmaFolderDialog {
    /// Runs the dialog. `nil` for Cancel and Escape.
    static func run(state: FigmaFolderDialogState, presentingWindow: NSWindow?) -> FigmaFolderDialogResult? {
        let controller = Controller(state: state)
        let alert = NSAlert()
        alert.messageText = String(localized: "figma.folderDialog.title", defaultValue: "Set Figma Folder")
        alert.informativeText = String(
            localized: "figma.folderDialog.message",
            defaultValue: "New designs made in this directory, or any directory inside it, go to the Figma folder you paste here."
        )
        alert.accessoryView = controller.view
        alert.addButton(withTitle: String(localized: "figma.folderDialog.set", defaultValue: "Set Folder"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        controller.setButton = alert.buttons.first
        controller.refresh()
        let window = alert.window
        window.initialFirstResponder = controller.field
        let response = alert.runCmuxModal(presentingWindow: presentingWindow) { _ in
            window.makeFirstResponder(controller.field)
        }
        guard response == .alertFirstButtonReturn, let link = controller.state.link else { return nil }
        return FigmaFolderDialogResult(link: link, directory: controller.state.resolvedDirectory)
    }

    @MainActor
    final class Controller: NSObject, NSTextFieldDelegate {
        private(set) var state: FigmaFolderDialogState
        let field = NSTextField()
        let view = NSStackView()
        weak var setButton: NSButton?
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        let refusal = NSTextField(wrappingLabelWithString: "")

        init(state: FigmaFolderDialogState) {
            self.state = state
            super.init()
            let width: CGFloat = 380

            let directoryLabel = NSTextField(labelWithString: String(localized: "figma.folderDialog.directory", defaultValue: "Directory"))
            let linkLabel = NSTextField(labelWithString: String(localized: "figma.folderDialog.link", defaultValue: "Folder link"))

            let hasFolder = String(localized: "figma.folderDialog.hasFolder", defaultValue: "has a folder")
            let tab = NSMutableParagraphStyle()
            tab.tabStops = [NSTextTab(textAlignment: .right, location: width - 28)]
            for item in state.items {
                let menuItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                if item.hasFolder {
                    let text = NSMutableAttributedString(
                        string: item.title + "\t",
                        attributes: [.paragraphStyle: tab, .font: NSFont.menuFont(ofSize: 0)]
                    )
                    text.append(NSAttributedString(
                        string: hasFolder,
                        attributes: [
                            .paragraphStyle: tab,
                            .font: NSFont.menuFont(ofSize: 0),
                            .foregroundColor: NSColor.secondaryLabelColor
                        ]
                    ))
                    menuItem.attributedTitle = text
                }
                popUp.menu?.addItem(menuItem)
            }
            popUp.selectItem(at: state.selectedIndex)
            popUp.target = self
            popUp.action = #selector(directoryChanged)

            field.placeholderString = String(localized: "figma.folderDialog.placeholder", defaultValue: "Paste a folder link from Figma")
            field.stringValue = state.text
            field.delegate = self
            refusal.textColor = .secondaryLabelColor
            refusal.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            refusal.preferredMaxLayoutWidth = width

            view.orientation = .vertical
            view.alignment = .leading
            view.spacing = 6
            for subview in [directoryLabel, popUp, linkLabel, field, refusal] { view.addArrangedSubview(subview) }
            view.setCustomSpacing(12, after: popUp)
            popUp.widthAnchor.constraint(equalToConstant: width).isActive = true
            field.widthAnchor.constraint(equalToConstant: width).isActive = true
            refusal.widthAnchor.constraint(equalToConstant: width).isActive = true
            view.frame = NSRect(origin: .zero, size: NSSize(width: width, height: 130))
            view.layoutSubtreeIfNeeded()
            view.frame.size = view.fittingSize
        }

        /// Draws what the state says: the field's text, the refusal line, and Set Folder's enabled state.
        func refresh() {
            if field.stringValue != state.text { field.stringValue = state.text }
            if let reason = state.refusal {
                let text: String
                switch reason {
                case .noTeam:
                    text = String(
                        localized: "figma.folderDialog.noTeam",
                        defaultValue: "This link has no team in it. Open it in your browser and copy the link from the address bar."
                    )
                case .notAFolderLink:
                    text = String(
                        localized: "figma.folderDialog.notAFolder",
                        defaultValue: "This is not a link to a Figma folder. Copy the link from the folder's page in Figma."
                    )
                }
                refusal.stringValue = "⚠ " + text
                field.setAccessibilityHelp(text)
            } else {
                refusal.stringValue = ""
                field.setAccessibilityHelp(nil)
            }
            refusal.isHidden = state.refusal == nil
            setButton?.isEnabled = state.canSet
        }

        @objc private func directoryChanged() {
            state.select(popUp.indexOfSelectedItem)
            refresh()
        }

        func controlTextDidChange(_ notification: Notification) {
            state.type(field.stringValue)
            refresh()
        }
    }
}
