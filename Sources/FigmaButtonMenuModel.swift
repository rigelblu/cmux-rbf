import Foundation

// cmux-rbf #cm-73.16: pure menu contents; AppKit only renders these rows.
struct FigmaButtonMenuModel {
    enum Action: Equatable {
        // cmux-rbf #cm-73.17: the two explicit agent jobs.
        case putDesignIntoFigma, newDesignInFigma
        case file(String), newFile(FigmaNewFileLink.Kind), chooseFolder, recents, enterDesignFocus
    }
    struct Row: Equatable {
        var title: String
        var action: Action?
        var enabled: Bool = true
        var toolTip: String? = nil
        var shortcut: StoredShortcut? = nil
        static var separator: Row { Row(title: "", action: nil) }
    }
    let rows: [Row]
    init(files: FigmaFileList, folder: String?, canEnterDesignFocus: Bool, shortcut: StoredShortcut?, canHandOff: Bool = false) {
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
        // cmux-rbf #cm-73.17: always present, in their own group above Design Focus.
        result.append(.separator)
        let handOffTip = canHandOff ? nil : String(localized: "figma.menu.handOffUnavailable", defaultValue: "Available when your agent is waiting for you")
        result.append(Row(title: String(localized: "figma.menu.putDesignIntoFigma", defaultValue: "Put Design into Figma"), action: .putDesignIntoFigma, enabled: canHandOff, toolTip: handOffTip))
        result.append(Row(title: String(localized: "figma.menu.newDesignInFigma", defaultValue: "New Design in Figma"), action: .newDesignInFigma, enabled: canHandOff, toolTip: handOffTip))
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
