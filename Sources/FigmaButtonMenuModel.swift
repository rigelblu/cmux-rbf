import CmuxSettings
import Foundation

// cmux-rbf #cm-73.16: pure menu contents; AppKit only renders these rows.
struct FigmaButtonMenuModel {
    enum Action: Equatable {
        // cmux-rbf #cm-73.17: the two explicit agent jobs.
        case putDesignIntoFigma, newDesignInFigma
        case file(String), newFile(FigmaNewFileLink.Kind), chooseFolder, recents, enterDesignFocus
        // cmux-rbf #cm-73.42: the folder row and what its submenu does.
        case folderRow, folderNote, openFolder, setFolder
        /// Remove the entry for this key (as written, `~` expanded).
        case removeFolder(key: String)
    }
    struct Row: Equatable {
        var title: String
        var action: Action?
        var enabled: Bool = true
        var toolTip: String? = nil
        var shortcut: StoredShortcut? = nil
        /// cmux-rbf #cm-73.42: rows of the submenu a row opens; empty for no submenu.
        var submenu: [Row] = []
        static var separator: Row { Row(title: "", action: nil) }
    }
    let rows: [Row]

    /// - Parameters:
    ///   - choice: Which folder answers for the workspace's directory (`FigmaFolderChoice`, the rule
    ///     `cmux figma folder` runs too). A usable answer shows the New entries and a folder row; a
    ///     refused entry for this directory shows the row with the reason and no New entries; anything
    ///     else keeps "Choose Figma Folder…".
    ///   - canSetFolder: False for a workspace with no local directory (a remote one): its submenu can
    ///     open the default's folder and nothing more.
    ///   - home: What `~` stands for in a path and what `Home` names.
    init(
        files: FigmaFileList,
        choice: FigmaFolderChoice,
        canEnterDesignFocus: Bool,
        shortcut: StoredShortcut?,
        canHandOff: Bool = false,
        canSetFolder: Bool = true,
        home: String = FigmaFolderPath.homeDirectory
    ) {
        var result = files.entries.map {
            Row(title: $0.displayName, action: .file($0.key))
        }
        if !result.isEmpty { result.append(.separator) }

        func newEntries() -> [Row] {
            [
                Row(title: String(localized: "figma.menu.newDesign", defaultValue: "New Design File"), action: .newFile(.design)),
                Row(title: String(localized: "figma.menu.newBoard", defaultValue: "New FigJam Board"), action: .newFile(.board)),
                Row(title: String(localized: "figma.menu.newSlides", defaultValue: "New Slide Deck"), action: .newFile(.slides))
            ]
        }
        func note(_ title: String) -> Row { Row(title: title, action: .folderNote, enabled: false) }
        func openRow() -> Row {
            Row(title: String(localized: "figma.menu.folder.open", defaultValue: "Open Folder in Figma"), action: .openFolder)
        }
        func setRow() -> Row {
            Row(title: String(localized: "figma.menu.folder.set", defaultValue: "Set Figma Folder…"), action: .setFolder)
        }
        func name(of key: String) -> String {
            FigmaFolderPath.lastPart(of: key, home: home)
                ?? String(localized: "figma.menu.folder.home", defaultValue: "Home")
        }
        func forPath(_ key: String) -> Row {
            let path = FigmaFolderPath.displayPath(FigmaFolderPath.expandingHome(key, home: home), home: home)
            return note(String(format: String(localized: "figma.menu.folder.forPath", defaultValue: "For %@"), path))
        }
        func directoryRow(key: String, warning: Bool, middle: [Row]) -> Row {
            let title = String(
                format: String(localized: "figma.menu.folder.forDirectory", defaultValue: "Figma Folder for %@"),
                name(of: key)
            )
            // Remove stays when Set is hidden (a workspace in `/`, `/Volumes` or `/Users`), so an
            // entry that answers there can still be taken away.
            let remove = Row(
                title: String(
                    format: String(localized: "figma.menu.folder.remove", defaultValue: "Remove Folder for %@"),
                    name(of: key)
                ),
                action: .removeFolder(key: key)
            )
            let submenu = [forPath(key)] + middle + [.separator] + (canSetFolder ? [setRow()] : []) + [remove]
            return Row(title: (warning ? "⚠ " : "") + title, action: .folderRow, submenu: submenu)
        }
        func reason(_ refusal: FigmaFolderLink.Refusal?) -> Row {
            switch refusal {
            case .noTeam?:
                return note(String(localized: "figma.menu.folder.noTeam", defaultValue: "This link has no team in it."))
            case .notAFolderLink?:
                return note(String(localized: "figma.menu.folder.notAFolder", defaultValue: "This is not a link to a Figma folder."))
            case nil:
                return note(String(localized: "figma.menu.folder.notText", defaultValue: "This folder setting is not text."))
            }
        }

        var chooseFolder = false
        var folderRow: Row?
        switch choice {
        case .folder(_, let source):
            result += newEntries()
            switch source {
            case .directory(let key):
                folderRow = directoryRow(key: key, warning: false, middle: [openRow()])
            case .default:
                var submenu = [
                    note(String(localized: "figma.menu.folder.defaultScope", defaultValue: "For directories without their own folder")),
                    openRow()
                ]
                if canSetFolder { submenu += [.separator, setRow()] }
                folderRow = Row(
                    title: String(localized: "figma.menu.folder.default", defaultValue: "Figma Default Folder"),
                    action: .folderRow,
                    submenu: submenu
                )
            }
        case .refused(let refusal, from: .directory(let key)):
            folderRow = directoryRow(key: key, warning: true, middle: [reason(refusal)])
        case .notText(from: .directory(let key)):
            folderRow = directoryRow(key: key, warning: true, middle: [reason(nil)])
        case .refused(_, from: .default), .notText(from: .default), .none:
            chooseFolder = true
        }
        if chooseFolder {
            result.append(Row(title: String(localized: "figma.menu.chooseFolder", defaultValue: "Choose Figma Folder…"), action: .chooseFolder))
        }
        if let folderRow { result.append(folderRow) }
        result.append(Row(title: String(localized: "figma.menu.recents", defaultValue: "Recents…"), action: .recents))
        // cmux-rbf #cm-73.17: always present, in their own group above Design Focus.
        result.append(.separator)
        let handOffTip = canHandOff ? nil : String(localized: "figma.menu.handOffUnavailable", defaultValue: "Available when your agent is waiting for you")
        result.append(Row(title: String(localized: "figma.menu.putDesignIntoFigma", defaultValue: "Put Design into Figma"), action: .putDesignIntoFigma, enabled: canHandOff, toolTip: handOffTip))
        result.append(Row(title: String(localized: "figma.menu.newDesignInFigma", defaultValue: "Ask Agent to Design in Figma"), action: .newDesignInFigma, enabled: canHandOff, toolTip: handOffTip))
        result.append(.separator)
        result.append(Row(
            title: String(localized: "figma.menu.enterDesignFocus", defaultValue: "Enter Design Focus"),
            action: .enterDesignFocus,
            enabled: canEnterDesignFocus,
            shortcut: shortcut
        ))
        rows = result
    }
}
