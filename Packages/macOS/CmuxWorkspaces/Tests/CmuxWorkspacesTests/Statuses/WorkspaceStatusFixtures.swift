import Foundation
@testable import CmuxWorkspaces

/// Tom's eleven statuses, in the file's order, built entry by entry so a test of the cycle or the picker does not
/// depend on the parser.
enum WorkspaceStatusFixtures {
    static let dogfood = WorkspaceStatusEntry(id: "dogfood", name: "Dogfood", extends: .review, color: "2: DOGFOOD")
    static let done = WorkspaceStatusEntry(id: "done", name: "Done", color: "1: DONE")
    static let review = WorkspaceStatusEntry(id: "review", name: "Review", color: "2: REVIEW")
    static let paused = WorkspaceStatusEntry(id: "paused", name: "Paused", extends: .todo, color: "3: PAUSED")
    static let blocked = WorkspaceStatusEntry(id: "blocked", name: "Blocked", extends: .todo, color: "3: BLOCKED")
    static let doingPrimary = WorkspaceStatusEntry(
        id: "doing-primary", name: "Doing (Primary)", extends: .working, color: "3: DOING (Primary)"
    )
    static let doingSecondary = WorkspaceStatusEntry(
        id: "doing-secondary", name: "Doing (Secondary)", extends: .working, color: "3: DOING (Secondary)"
    )
    static let next = WorkspaceStatusEntry(id: "next", name: "Next", extends: .todo, color: "4: NEXT")
    static let upcoming = WorkspaceStatusEntry(id: "upcoming", name: "Upcoming", extends: .todo, color: "5: UPCOMING")
    static let parked = WorkspaceStatusEntry(id: "parked", name: "Parked", extends: .todo, color: "5: PARKED")
    static let future = WorkspaceStatusEntry(id: "future", name: "Future", extends: .todo, color: "6: FUTURE")

    static let tomsEntries = [
        dogfood, done, review, paused, blocked, doingPrimary, doingSecondary, next, upcoming, parked, future,
    ]
    /// His words, typed out so a test of a label does not read `name` back from the entries it checks.
    static let tomsNames = [
        "Dogfood", "Done", "Review", "Paused", "Blocked", "Doing (Primary)", "Doing (Secondary)", "Next", "Upcoming",
        "Parked", "Future",
    ]
    static let tomsIDs = [
        "dogfood", "done", "review", "paused", "blocked", "doing-primary", "doing-secondary", "next", "upcoming",
        "parked", "future",
    ]

    /// His list as the file gives it.
    static let toms = WorkspaceStatusList(entries: tomsEntries, source: .file)
    /// The same list as the app's stored copy gives it, after a restart with a typo in the file.
    static let tomsStored = WorkspaceStatusList(entries: tomsEntries, source: .stored)

    /// A short list that is not his: no cmux id in it, and nothing extends `done` or `needs-attention`.
    static let x = WorkspaceStatusEntry(id: "x", name: "X", extends: .todo)
    static let y = WorkspaceStatusEntry(id: "y", name: "Y", extends: .working)
    static let z = WorkspaceStatusEntry(id: "z", name: "Z", extends: .review)
    static let other = WorkspaceStatusList(entries: [x, y, z], source: .file)

    /// A second list that is not his, with an entry whose id is a cmux id (`review`) below one that extends
    /// `review`, and nothing for `working`, `needs-attention` or `done`.
    static let rev = WorkspaceStatusEntry(id: "review", name: "Rev")
    static let mixed = WorkspaceStatusList(entries: [z, rev, x], source: .file)

    static func override(
        _ status: WorkspaceTaskStatus,
        at inferred: WorkspaceTaskStatus
    ) -> WorkspaceTaskStatusOverride {
        WorkspaceTaskStatusOverride(status: status, inferredAtOverride: inferred)
    }
}
