import AppKit
import CmuxFoundation
import CmuxSettings
import CmuxWorkspaces
import SwiftUI

/// The words of the notice for a problem in his status list (#cm-109.2, step 2i). Pure: a problem goes in and text
/// comes out. A value that came from his file (an id, a color, a parser's detail) is an argument of a localized
/// format, never part of the format, and every view below draws the result with `Text(verbatim:)`, so nothing in his
/// file is read as Markdown, as a format string or as anything to run.
enum WorkspaceStatusProblemWords {
    /// "1 file problem", or the count and "file problems".
    static func pill(count: Int) -> String {
        String(localized: "sidebar.statusFile.pill", defaultValue: "\(count) file problems")
    }

    /// "1 problem in cmux.json": the pill's accessibility label, which names the file.
    static func accessibilityLabel(count: Int) -> String {
        String(localized: "sidebar.statusFile.pill.accessibility", defaultValue: "\(count) problems in cmux.json")
    }

    /// One sentence for each kind of problem, in the voice of "· not in your list".
    static func line(_ problem: WorkspaceStatusListProblem) -> String {
        switch problem {
        case .fileNotRead(let missing, _):
            if missing {
                return String(
                    localized: "sidebar.statusFile.problem.fileNotReadMissing",
                    defaultValue: "cmux.json is missing. Your status list is kept until the file is back."
                )
            }
            return String(
                localized: "sidebar.statusFile.problem.fileNotRead",
                defaultValue: "cmux.json could not be read. Nothing in your status list changed."
            )
        case .notAList:
            return String(
                localized: "sidebar.statusFile.problem.notAList",
                defaultValue: "workspaceStatuses is not a list. Nothing in your status list changed."
            )
        case .entryNotAnObject(let entry):
            return String(
                localized: "sidebar.statusFile.problem.entryNotAnObject",
                defaultValue: "Entry \(entry) is not a status entry, so it was skipped."
            )
        case .noID(let entry):
            return String(
                localized: "sidebar.statusFile.problem.noId",
                defaultValue: "Entry \(entry) has no id, so it was skipped."
            )
        case .reservedID(let entry, let id):
            return String(
                localized: "sidebar.statusFile.problem.reservedId",
                defaultValue: "Entry \(entry) uses the id “\(id)”, which cmux keeps for itself, so it was skipped."
            )
        case .repeatedID(let entry, let id):
            return String(
                localized: "sidebar.statusFile.problem.repeatedId",
                defaultValue: "Entry \(entry) repeats the id “\(id)”. The first one is kept, and this one was skipped."
            )
        case .noName(let entry, let id):
            return String(
                localized: "sidebar.statusFile.problem.noName",
                defaultValue: "Entry \(entry), “\(id)”, has no name, so it was skipped."
            )
        case .noExtends(let entry, let id):
            return String(
                localized: "sidebar.statusFile.problem.noExtends",
                defaultValue: "Entry \(entry), “\(id)”, has no “extends”, so it was skipped. Check how the key is spelled."
            )
        case .unknownExtends(let entry, let id, let value):
            return String(
                localized: "sidebar.statusFile.problem.unknownExtends",
                defaultValue: "Entry \(entry), “\(id)”, extends “\(value)”, which is not a cmux status, so it was skipped. Use todo, working, needs-attention, review or done."
            )
        case .colorNotInThisApp(let id, let color):
            return String(
                localized: "sidebar.statusFile.problem.colorNotInThisApp",
                defaultValue: "“\(id)” names the color “\(color)”, which this app does not have. Setting this status keeps the workspace’s color."
            )
        }
    }

    /// The parser's own words after the sentence, in English as they come, for a file that could not be read.
    /// `nil` when there are none (and always for a file that is gone).
    static func detail(_ problem: WorkspaceStatusListProblem) -> String? {
        guard case .fileNotRead(let missing, let detail) = problem, !missing, !detail.isEmpty else { return nil }
        return detail
    }

    /// Whether this problem is a file that is gone: the list then leaves "Open cmux.json" off, because the
    /// opener only beeps on a missing file.
    static func isFileMissing(_ problem: WorkspaceStatusListProblem) -> Bool {
        if case .fileNotRead(let missing, _) = problem { return missing }
        return false
    }
}

/// The footer wrapper: it shows the file pill while the store holds a problem, and otherwise draws its content (the
/// update pill) (#cm-109.2, step 2i). It reads the store's problems in its `body`; the store is `@Observable`, so the
/// body runs again when they change. It sits in the sidebar's footer, not below the list boundary, and it is the only
/// view of this notice that reads the store. With a problem it does not build its content.
struct WorkspaceStatusFooterPills<Content: View>: View {
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        let problems = AppDelegate.shared?.workspaceStatusListStore.problems ?? []
        ZStack {
            if problems.isEmpty {
                content()
            } else {
                WorkspaceStatusFilePill(problems: problems)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        // The update pill's own fade and scale (`UpdatePill.swift:35`, `:40`).
        .animation(.easeInOut(duration: 0.25), value: problems.isEmpty)
    }
}

/// The pill: it copies the update pill's shape (a 14 pt icon in a fixed frame, 11 pt medium text on one line cut at the
/// tail, a capsule) without its error colors. It holds values only; a click is the only thing that opens its list.
struct WorkspaceStatusFilePill: View {
    let problems: [WorkspaceStatusListProblem]

    /// Set to true by the button's action and nowhere else. It starts false each time the pill is built.
    @State private var showPopover = false
    @Environment(\.colorScheme) private var colorScheme

    /// Light: `#C2410C`, which reads 4.18:1 on the footer. Dark: the system orange, which reads 5.58:1.
    private var iconColor: Color {
        colorScheme == .dark ? Color.orange : Color(red: 194.0 / 255.0, green: 65.0 / 255.0, blue: 12.0 / 255.0)
    }

    var body: some View {
        let text = WorkspaceStatusProblemWords.pill(count: problems.count)
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(iconColor)
                    .frame(width: 14, height: 14)
                    .layoutPriority(1)
                Text(verbatim: text)
                    .cmuxFont(size: 11, weight: .medium)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .safeHelp(text)
        .accessibilityLabel(WorkspaceStatusProblemWords.accessibilityLabel(count: problems.count))
        .accessibilityIdentifier("WorkspaceStatusFilePill")
        .background(
            SidebarWorkspaceTodoPopoverHost(
                isPresented: $showPopover,
                model: problems,
                minWidth: 280,
                preferredEdge: .maxX
            ) { problems, close in
                WorkspaceStatusFilePillList(
                    problems: problems,
                    onOpenFile: {
                        PreferredEditorService(defaults: .standard).open(CmuxConfigLocation().userConfigFile)
                        close()
                    }
                )
            }
        )
    }
}

/// The list a click opens: the heading, one line for each problem in the store's order, and "Open cmux.json", which is
/// left off when the file is gone. It scrolls past six rows. It holds the problems as values and nothing else.
struct WorkspaceStatusFilePillList: View {
    let problems: [WorkspaceStatusListProblem]
    let onOpenFile: () -> Void

    private static let lineFontSize: CGFloat = 12
    private static let rowSpacing: CGFloat = 8
    private static let visibleRows: CGFloat = 6

    /// A row's height: two lines of the text's own font (most sentences wrap to two at this width) and the gap below
    /// it. Worked out from the font, not typed.
    private static var rowHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: lineFontSize)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        return lineHeight * 2 + rowSpacing
    }

    /// Six rows; past that the list scrolls, so six problems do not make the popover taller than the sidebar.
    static var maxListHeight: CGFloat { rowHeight * visibleRows }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "sidebar.statusFile.title", defaultValue: "Problems in your status list"))
                .cmuxFont(size: 13, weight: .semibold)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Self.rowSpacing) {
                    ForEach(Array(problems.enumerated()), id: \.offset) { _, problem in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: WorkspaceStatusProblemWords.line(problem))
                                .cmuxFont(size: Self.lineFontSize)
                                .fixedSize(horizontal: false, vertical: true)
                            if let detail = WorkspaceStatusProblemWords.detail(problem) {
                                Text(verbatim: detail)
                                    .cmuxFont(size: 11)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: Self.maxListHeight)
            if !problems.contains(where: WorkspaceStatusProblemWords.isFileMissing) {
                Button(action: onOpenFile) {
                    Text(String(localized: "sidebar.statusFile.open", defaultValue: "Open cmux.json"))
                }
                .accessibilityIdentifier("WorkspaceStatusFilePillOpenFile")
            }
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
    }
}
