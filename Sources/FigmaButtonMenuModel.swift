import Foundation

// cmux-rbf #cm-73.16: pure menu contents; AppKit only renders these rows.
struct FigmaButtonMenuModel {
    enum Action: Equatable {
        case file(String), newFile(FigmaNewFileLink.Kind), chooseFolder, recents, enterDesignFocus
    }
    struct Row: Equatable {
        var title: String
        var action: Action?
        var enabled: Bool = true
        var shortcut: StoredShortcut? = nil
        static var separator: Row { Row(title: "", action: nil) }
    }
    let rows: [Row]
    init(files: FigmaFileList, folder: String?, canEnterDesignFocus: Bool, shortcut: StoredShortcut?) {
        var result = files.entries.map {
            Row(title: $0.displayName, action: .file($0.key))
        }
        if !result.isEmpty { result.append(.separator) }
        if FigmaNewFileLink.address(kind: .design, folder: folder) != nil {
            result += [
                Row(title: String(localized: "figma.menu.newDesign", defaultValue: "New Design File"), action: .newFile(.design)),
                Row(title: String(localized: "figma.menu.newBoard", defaultValue: "New FigJam Board"), action: .newFile(.board)),
                Row(title: String(localized: "figma.menu.newSlides", defaultValue: "New Slide Deck"), action: .newFile(.slides))
            ]
        } else {
            result.append(Row(title: String(localized: "figma.menu.chooseFolder", defaultValue: "Choose Figma Folder…"), action: .chooseFolder))
        }
        result.append(Row(title: String(localized: "figma.menu.recents", defaultValue: "Recents…"), action: .recents))
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
