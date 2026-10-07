import Foundation
import Testing
@testable import CmuxWorkspaces

// The hand-over guard (#cm-106).
//
// WHAT IT GUARDS. A workspace group can sit inside another one. The package keeps upstream's functions for a window
// where no group does, and each upstream function that must act differently in a nested window hands over to its
// nested version with one line (`if model.hasNestedWorkspaceGroup { return nested…() }`). A hand-over missing from a
// function that needs one is invisible to a build and to every test of the nested code: the function quietly reads one
// level (`tab.groupId`, `workspaceGroups`) and gives the answer for a flat window. This file makes two lists of the
// upstream functions that read a workspace's group or the groups, and fails when a source file and a list disagree:
//   1. every line that makes the choice between the flat and the nested code (the hand-over sites), against the
//      checks in `WorkspaceGroupNestedReviewTests` that run each of them in a flat window;
//   2. every function in the six upstream files that carry hand-overs that reads `groupId` or `workspaceGroups`,
//      against `readersOfGroups` below, where each entry says "hands over at <marker>" (and the marker is found in the
//      function), or "one level is right here because <reason>".
// A new upstream function that reads them therefore fails at the next upstream sync, until someone has read it and
// written which of the two it is.
//
// WHY NO BEHAVIOUR TEST CAN DO THIS. A behaviour test runs the functions that exist. This question is about a function
// nobody has written a nested test for yet, so the only thing to compare is the source text.
//
// THE ONE EXCEPTION. `skills/cmux-testing` forbids tests that read source text. This file is the single exception in
// this fork, kept on purpose; it reads the package's own sources, which are in this checkout, and nothing else. Do not
// add a second. If it ever fails for a reason that is not a new or removed function, fix the scan, do not loosen it.
@MainActor
struct WorkspaceGroupNestedHandOverGuardTests {
    /// One entry per line in the package's sources that hands an upstream function over to its nested version
    /// (or branches on the nested window inside one). Add a line to `aFlatWindowNeverEntersTheNestedPath...` and
    /// an entry here for each new hand-over, in the same edit that adds it.
    static let flatHandOverSites: [String] = [
        "deletionConfirmation",
        "deleteWorkspaceGroup",
        "removeGeneratedAnchorWorkspace: the guard on a group that holds groups",
        "createWorkspaceInGroup",
        "addWorkspaceToGroup",
        "removeWorkspaceFromGroup",
        "ungroupWorkspaceGroup",
        "toggleWorkspaceGroupCollapsed",
        "moveWorkspaceGroup",
        "moveTabsToTop",
        "moveTabToTopForNotification",
        "reorderWorkspace(tabId:toIndex:)",
        "applyDragInferredGroupMembership",
        "setPinned(workspaceIds:)",
        "topLevelWorkspaceIds(for:)",
        "sidebarTopLevelWorkspaceIds",
        "sidebarTopLevelWorkspaceIdsIncludingEmptyGroups",
        "topLevelWorkspaceIdsPreservingOrder",
        "clampedGroupedMemberReorderIndex",
        "isGlobalPinnedRow",
        "assignGroup",
        "normalizeWorkspaceGroupRunsPreservingOrder",
        "expandWorkspaceGroupForSelectionIfNeeded",
        "syncWorkspaceGroupsOrderToAnchorOrder",
        "moveWorkspaceGroupMembersAfterAnchors",
        "dissolveGroupsAnchoredBy: which groups keep the header",
        "dissolveGroupsAnchoredBy: the keep-header loop",
        "dissolveGroupsAnchoredBy: workspaces take the parent",
        "dissolveGroupsAnchoredBy: the parent's own workspace",
        "promoteAnchorOrRemoveGroupsAnchoredBy",
        "reorderSidebarWorkspace: a nested group's header",
        "reorderSidebarWorkspace: a workspace dropped on a group of a nested window",
        "reorderSidebarWorkspaces: headers that include a nested group's header",
        "reorderSidebarWorkspaces: workspaces dropped on a group of a nested window",
        "reorderSidebarWorkspaces: workspaces dropped at the top level of a nested window",
        "createWorkspaceGroup: the first eligible workspace in a group",
        "setWorkspaceGroupPinned: the notice ids",
        "moveTabsToTop: the notice ids",
        "moveTabToTopForNotification: the notice ids",
        "reorderWorkspace(tabId:toIndex:): the notice ids",
        "reorderTopLevelWorkspaceBlock: the notice ids",
        "reorderTopLevelWorkspaceItem: the notice ids",
        "reorderWorkspaces: the notice ids"
    ]

    /// The same sites as the scan finds them, one per line, as `file#function` (a function with several lines
    /// is listed once per line). A site removed in one place and added in another changes this list.
    static let handOverSourceSites: [String] = [
        "WorkspaceGroupCoordinator+DeletionConfirmation.swift#deleteWorkspaceGroup",
        "WorkspaceGroupCoordinator+DeletionConfirmation.swift#deletionConfirmation",
        "WorkspaceGroupCoordinator+GeneratedAnchorCleanup.swift#removeGeneratedAnchorWorkspace",
        "WorkspaceGroupCoordinator.swift#addWorkspaceToGroup",
        "WorkspaceGroupCoordinator.swift#createWorkspaceGroup",
        "WorkspaceGroupCoordinator.swift#createWorkspaceInGroup",
        "WorkspaceGroupCoordinator.swift#moveWorkspaceGroup",
        "WorkspaceGroupCoordinator.swift#removeWorkspaceFromGroup",
        "WorkspaceGroupCoordinator.swift#setWorkspaceGroupPinned",
        "WorkspaceGroupCoordinator.swift#toggleWorkspaceGroupCollapsed",
        "WorkspaceGroupCoordinator.swift#ungroupWorkspaceGroup",
        "WorkspaceReorderCoordinator.swift#applyDragInferredGroupMembership",
        "WorkspaceReorderCoordinator.swift#moveTabToTopForNotification",
        "WorkspaceReorderCoordinator.swift#moveTabToTopForNotification",
        "WorkspaceReorderCoordinator.swift#moveTabsToTop",
        "WorkspaceReorderCoordinator.swift#moveTabsToTop",
        "WorkspaceReorderCoordinator.swift#reorderTopLevelWorkspaceBlock",
        "WorkspaceReorderCoordinator.swift#reorderTopLevelWorkspaceItem",
        "WorkspaceReorderCoordinator.swift#reorderSidebarWorkspace",
        "WorkspaceReorderCoordinator.swift#reorderSidebarWorkspace",
        "WorkspaceReorderCoordinator.swift#reorderSidebarWorkspaces",
        "WorkspaceReorderCoordinator.swift#reorderSidebarWorkspaces",
        "WorkspaceReorderCoordinator.swift#reorderSidebarWorkspaces",
        "WorkspaceReorderCoordinator.swift#reorderWorkspace",
        "WorkspaceReorderCoordinator.swift#reorderWorkspace",
        "WorkspaceReorderCoordinator.swift#reorderWorkspaces",
        "WorkspaceReorderCoordinator.swift#setPinned",
        "WorkspacesModel+GroupInvariants.swift#assignGroup",
        "WorkspacesModel+GroupInvariants.swift#dissolveGroupsAnchoredBy",
        "WorkspacesModel+GroupInvariants.swift#dissolveGroupsAnchoredBy",
        "WorkspacesModel+GroupInvariants.swift#dissolveGroupsAnchoredBy",
        "WorkspacesModel+GroupInvariants.swift#dissolveGroupsAnchoredBy",
        "WorkspacesModel+GroupInvariants.swift#expandWorkspaceGroupForSelectionIfNeeded",
        "WorkspacesModel+GroupInvariants.swift#moveWorkspaceGroupMembersAfterAnchors",
        "WorkspacesModel+GroupInvariants.swift#normalizeWorkspaceGroupRunsPreservingOrder",
        "WorkspacesModel+GroupInvariants.swift#promoteAnchorOrRemoveGroupsAnchoredBy",
        "WorkspacesModel+GroupInvariants.swift#syncWorkspaceGroupsOrderToAnchorOrder",
        "WorkspacesModel+Ordering.swift#clampedGroupedMemberReorderIndex",
        "WorkspacesModel+Ordering.swift#isGlobalPinnedRow",
        "WorkspacesModel+Ordering.swift#sidebarTopLevelWorkspaceIds",
        "WorkspacesModel+Ordering.swift#sidebarTopLevelWorkspaceIdsIncludingEmptyGroups",
        "WorkspacesModel+Ordering.swift#topLevelWorkspaceIds",
        "WorkspacesModel+Ordering.swift#topLevelWorkspaceIdsPreservingOrder"
    ]

    /// Checks above that exercise a function with no hand-over line of its own (they reach one that does).
    static let flatChecksThatAreNotSites: Set<String> = [
        "normalizeWorkspaceGroupContiguity"
    ]

    /// Finds, in the package's non-test sources, the lines that decide between the flat code and the nested code:
    /// a call of `hasNestedWorkspaceGroup`, `holdsWorkspaceGroups(`, `keepsHeaderWhenEmptied(`,
    /// `parentGroupIdIfNested(`, `isNestedWorkspaceGroupHeader(`, `workspaceIdsInside(`, `workspaceIdsMovedUpThrough(` or
    /// `workspaceIdsNamedForBatchReorder(` (the last three choose the ids of an order-change notice: a call from an upstream function is a hand-over whatever
    /// the helper is named). Skipped: comment lines, and the files that
    /// define and implement the nested versions (their names hold "Nested" or "Nesting").
    @Test
    func everyHandOverSiteInThePackageHasALineInTheFlatWindowTest() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CmuxWorkspaces")
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let markers = ["hasNestedWorkspaceGroup", "holdsWorkspaceGroups(", "keepsHeaderWhenEmptied(", "parentGroupIdIfNested(", "isNestedWorkspaceGroupHeader(", "nestedPlaceNewWorkspaceGroup(", "workspaceIdsInside(", "workspaceIdsMovedUpThrough(", "workspaceIdsNamedForBatchReorder("]
        var sites: [String] = []
        var filesScanned = 0
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let name = file.lastPathComponent
            if name.contains("Nested") || name.contains("Nesting") { continue }
            filesScanned += 1
            let text = try String(contentsOf: file, encoding: .utf8)
            var function = "?"
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                if let range = line.range(of: #"func\s+([A-Za-z0-9_]+)"#, options: .regularExpression) {
                    function = String(line[range].drop(while: { $0 != " " }).trimmingCharacters(in: .whitespaces))
                }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                // A line that defines a marker's function is not a call of it.
                if markers.contains(where: { trimmed.contains($0) && !trimmed.contains("func " + $0) }) { sites.append("\(name)#\(function)") }
            }
        }
        #expect(filesScanned > 20, "scanned only \(filesScanned) files; is the path to the sources right?")
        #expect(
            sites.count == Self.flatHandOverSites.count,
            "\(sites.count) hand-over sites in the sources, \(Self.flatHandOverSites.count) in the flat window test. Add a check line and an entry in flatHandOverSites for the new one. Sites: \(sites.sorted())"
        )
        #expect(
            sites.sorted() == Self.handOverSourceSites.sorted(),
            "the hand-over sites in the sources are not the ones listed. Only in the sources: \(Set(sites).subtracting(Self.handOverSourceSites).sorted()). Only in the list: \(Set(Self.handOverSourceSites).subtracting(sites).sorted()). Add or remove the entry in handOverSourceSites and the line in the flat window test."
        )
    }

    // MARK: - Every function that reads a workspace's group or the groups

    /// The upstream files that carry hand-overs, relative to `Sources/CmuxWorkspaces`.
    private static let filesWithHandOvers = [
        "Coordinators/WorkspaceGroupCoordinator.swift",
        "Coordinators/WorkspaceGroupCoordinator+DeletionConfirmation.swift",
        "Coordinators/WorkspaceGroupCoordinator+GeneratedAnchorCleanup.swift",
        "Coordinators/WorkspaceReorderCoordinator.swift",
        "Model/WorkspacesModel+GroupInvariants.swift",
        "Model/WorkspacesModel+Ordering.swift"
    ]

    private static let handsOver = "hands over at "
    private static let oneLevel = "one level is right here because "
    private static let needsALook = "NEEDS A LOOK: "

    /// Every member (function or property) of those files that mentions `groupId` or `workspaceGroups`, as
    /// `file#name`, and why it is right. Written by reading each function (2026-10-10). Three kinds of reason:
    /// - "hands over at <marker>": the function calls the marker, which chooses between the flat and the nested code
    /// - "one level is right here because <reason>": the function is right for a window of any shape
    /// - "NEEDS A LOOK: <reason>": read, and not settled; it is a question for the owner, not a decision
    static let readersOfGroups: [String: String] = [
        // WorkspaceGroupCoordinator.swift
        "WorkspaceGroupCoordinator.swift#createWorkspaceGroup": "hands over at nestedPlaceNewWorkspaceGroup(",
        "WorkspaceGroupCoordinator.swift#createWorkspaceInGroup": "hands over at hasNestedWorkspaceGroup",
        "WorkspaceGroupCoordinator.swift#placeWithinGroup": "one level is right here because it is private and both callers, createWorkspaceInGroup and addWorkspaceToGroup, hand over before they reach it, so it runs only in a window with no nested group",
        "WorkspaceGroupCoordinator.swift#addWorkspaceToGroup": "hands over at hasNestedWorkspaceGroup",
        "WorkspaceGroupCoordinator.swift#removeWorkspaceFromGroup": "hands over at hasNestedWorkspaceGroup",
        "WorkspaceGroupCoordinator.swift#ungroupWorkspaceGroup": "hands over at hasNestedWorkspaceGroup",
        "WorkspaceGroupCoordinator.swift#deleteWorkspaceGroup": "one level is right here because it only forwards to deletionConfirmation(groupId:) and deleteWorkspaceGroup(confirmed:), which both hand over",
        "WorkspaceGroupCoordinator.swift#renameWorkspaceGroup": "one level is right here because it writes one group's own name, and the name of that group's own generated workspace; no other row is read",
        "WorkspaceGroupCoordinator.swift#toggleWorkspaceGroupCollapsed": "hands over at hasNestedWorkspaceGroup",
        "WorkspaceGroupCoordinator.swift#setWorkspaceGroupCollapsed": "one level is right here because it flips one group's own fold flag; what the fold hides is decided when rows are drawn",
        "WorkspaceGroupCoordinator.swift#toggleWorkspaceGroupPinned": "one level is right here because it only forwards to setWorkspaceGroupPinned, which hands over",
        "WorkspaceGroupCoordinator.swift#setWorkspaceGroupPinned": "hands over at workspaceIdsInside(",
        "WorkspaceGroupCoordinator.swift#setWorkspaceGroupColor": "one level is right here because it writes one group's own color",
        "WorkspaceGroupCoordinator.swift#setWorkspaceGroupIcon": "one level is right here because it writes one group's own icon",
        "WorkspaceGroupCoordinator.swift#setWorkspaceGroupAnchor": "NEEDS A LOOK: its order change notice lists only the group's direct workspaces (tabs.filter { groupId == … }), where setWorkspaceGroupPinned lists every workspace inside the group at every level; the order itself is right because normalizeWorkspaceGroupContiguity beneath it hands over. Reached from the socket's group anchor command",
        "WorkspaceGroupCoordinator.swift#moveWorkspaceGroup": "hands over at hasNestedWorkspaceGroup",
        "WorkspaceGroupCoordinator.swift#moveWorkspaceGroupSlot": "one level is right here because it is private and its only caller, moveWorkspaceGroup(groupId:toIndex:), hands over before it",
        "WorkspaceGroupCoordinator.swift#applyWorkspaceGroupSlotOrderToTabs": "one level is right here because it is private and its only caller, moveWorkspaceGroup(groupId:toIndex:), hands over before it",
        "WorkspaceGroupCoordinator.swift#nextAutoWorkspaceGroupName": "one level is right here because it reads only the names of the groups, at any level",
        "WorkspaceGroupCoordinator.swift#placeNewWorkspaceGroupAtCreationPosition": "one level is right here because it is private, runs after nestedPlaceNewWorkspaceGroup in createWorkspaceGroup, and orders through normalizeWorkspaceGroupContiguity, topLevelWorkspaceIdsPreservingOrder and syncWorkspaceGroupsOrderToAnchorOrder, which all hand over",
        // WorkspaceGroupCoordinator+DeletionConfirmation.swift
        "WorkspaceGroupCoordinator+DeletionConfirmation.swift#deletionConfirmation": "hands over at hasNestedWorkspaceGroup",
        "WorkspaceGroupCoordinator+DeletionConfirmation.swift#deleteWorkspaceGroup": "hands over at hasNestedWorkspaceGroup",
        // WorkspaceGroupCoordinator+GeneratedAnchorCleanup.swift
        "WorkspaceGroupCoordinator+GeneratedAnchorCleanup.swift#removeGeneratedAnchorWorkspace": "hands over at holdsWorkspaceGroups(",
        // WorkspaceReorderCoordinator.swift
        "WorkspaceReorderCoordinator.swift#moveTabsToTop": "hands over at hasNestedWorkspaceGroup",
        "WorkspaceReorderCoordinator.swift#moveTabToTopForNotification": "hands over at hasNestedWorkspaceGroup",
        "WorkspaceReorderCoordinator.swift#reorderWorkspace": "hands over at hasNestedWorkspaceGroup",
        "WorkspaceReorderCoordinator.swift#reorderWorkspaceWithinColorSection": "one level is right here because a color section holds only ungrouped workspaces, and the function refuses any grouped one",
        "WorkspaceReorderCoordinator.swift#sidebarReorderPinnedWorkspaceIds": "NEEDS A LOOK: builds the row space of the sidebar's older row-by-row drop (ContentView.swift performDrop(pointerX:), which commits through reorderSidebarWorkspace(s), and those hand over); whether a nested window can still reach that path was not traced",
        "WorkspaceReorderCoordinator.swift#sidebarReorderLegalInsertionRange": "NEEDS A LOOK: the legal range of a member drag counts the group's direct members (groupId == …) as one stretch, which holds child groups' workspaces too when a child group sits between them; same older drop path as sidebarReorderPinnedWorkspaceIds, not traced",
        "WorkspaceReorderCoordinator.swift#reorderSidebarWorkspace": "hands over at isNestedWorkspaceGroupHeader(",
        "WorkspaceReorderCoordinator.swift#reorderSidebarWorkspaces": "hands over at isNestedWorkspaceGroupHeader(",
        "WorkspaceReorderCoordinator.swift#sidebarBlockMembershipResolution": "one level is right here because it is private and is reached only by a drag with no explicit group and no top-level rows, which reorderSidebarWorkspaces sends to the nested versions first when the window holds a nested group",
        "WorkspaceReorderCoordinator.swift#reorderTopLevelWorkspaceBlock": "hands over at workspaceIdsInside(",
        "WorkspaceReorderCoordinator.swift#reorderTopLevelWorkspaceItem": "hands over at workspaceIdsInside(",
        "WorkspaceReorderCoordinator.swift#sidebarReorderUsesTopLevelRows": "NEEDS A LOOK: decides by the dragged and target workspaces' direct group and by isWorkspaceGroupHeader; reads one level; same older drop path as sidebarReorderPinnedWorkspaceIds, not traced",
        "WorkspaceReorderCoordinator.swift#applyDragInferredGroupMembership": "hands over at hasNestedWorkspaceGroup",
        "WorkspaceReorderCoordinator.swift#assignDraggedWorkspace": "one level is right here because it is private, reached from applyDragInferredGroupMembership after its hand-over, and reads only one group's own empty state; assignGroup and normalizeWorkspaceGroupContiguity beneath it hand over",
        "WorkspaceReorderCoordinator.swift#applyWorkspaceBatchReorder": "one level is right here because it rebuilds tabs and then repairs through syncWorkspaceGroupsOrderToAnchorOrder and normalizeWorkspaceGroupContiguity, which both hand over",
        "WorkspaceReorderCoordinator.swift#setPinned": "hands over at hasNestedWorkspaceGroup",
        "WorkspaceReorderCoordinator.swift#reorderTabForPinnedState": "one level is right here because a grouped workspace is repaired through normalizeWorkspaceGroupContiguity, which hands over, and an ungrouped one is placed after the leading pinned rows, which isGlobalPinnedRow counts",
        // WorkspacesModel+GroupInvariants.swift
        "WorkspacesModel+GroupInvariants.swift#assignGroup": "hands over at hasNestedWorkspaceGroup",
        "WorkspacesModel+GroupInvariants.swift#normalizeWorkspaceGroupRunsPreservingOrder": "hands over at hasNestedWorkspaceGroup",
        "WorkspacesModel+GroupInvariants.swift#normalizeWorkspaceGroupContiguity": "one level is right here because it reads groupId only to clear a groupId that names no group (rule 6), and then calls normalizeWorkspaceGroupRunsPreservingOrder and syncWorkspaceGroupsOrderToAnchorOrder, which both hand over",
        "WorkspacesModel+GroupInvariants.swift#expandWorkspaceGroupForSelectionIfNeeded": "hands over at hasNestedWorkspaceGroup",
        "WorkspacesModel+GroupInvariants.swift#syncWorkspaceGroupsOrderToAnchorOrder": "hands over at hasNestedWorkspaceGroup",
        "WorkspacesModel+GroupInvariants.swift#moveWorkspaceGroupMembersAfterAnchors": "hands over at hasNestedWorkspaceGroup",
        "WorkspacesModel+GroupInvariants.swift#dissolveGroupsAnchoredBy": "hands over at keepsHeaderWhenEmptied(",
        "WorkspacesModel+GroupInvariants.swift#promoteAnchorOrRemoveGroupsAnchoredBy": "hands over at keepsHeaderWhenEmptied(",
        // WorkspacesModel+Ordering.swift
        "WorkspacesModel+Ordering.swift#isWorkspaceGroupAnchor": "one level is right here because a group at any level has its own workspace, so the question is the same in every window",
        "WorkspacesModel+Ordering.swift#isWorkspaceGroupHeader": "one level is right here because a group at any level has a header identity, so the question is the same in every window",
        "WorkspacesModel+Ordering.swift#topLevelWorkspaceIds": "hands over at hasNestedWorkspaceGroup",
        "WorkspacesModel+Ordering.swift#sidebarTopLevelWorkspaceIds": "hands over at hasNestedWorkspaceGroup",
        "WorkspacesModel+Ordering.swift#sidebarTopLevelWorkspaceIdsIncludingEmptyGroups": "hands over at hasNestedWorkspaceGroup",
        "WorkspacesModel+Ordering.swift#topLevelWorkspaceIdsPreservingOrder": "hands over at hasNestedWorkspaceGroup",
        "WorkspacesModel+Ordering.swift#sidebarTopLevelPinnedWorkspaceIds": "one level is right here because it pins each top-level row id by the group that owns it, and sidebarTopLevelWorkspaceIds, which hands over, has already made those the top-level groups",
        "WorkspacesModel+Ordering.swift#sidebarTopLevelPinnedWorkspaceIdsIncludingEmptyGroups": "one level is right here because it pins each top-level row id by the group that owns it, and sidebarTopLevelWorkspaceIdsIncludingEmptyGroups, which hands over, has already made those the top-level groups",
        "WorkspacesModel+Ordering.swift#clampedGroupedMemberReorderIndex": "hands over at hasNestedWorkspaceGroup",
        "WorkspacesModel+Ordering.swift#isGlobalPinnedRow": "hands over at hasNestedWorkspaceGroup"
    ]

    /// A member (function or property) declaration at the indentation of a type's members.
    private static let memberDeclaration = try! NSRegularExpression(
        pattern: #"^ {4}(?:@[A-Za-z]+(?:\([^)]*\))? +)*(?:(?:public|private|fileprivate|internal|static|final|mutating|nonisolated|override) +)*(?:func|var|let|init|subscript)\s*([A-Za-z0-9_]*)"#
    )
    private static let readsGroups = try! NSRegularExpression(pattern: #"\bgroupId\b|\bworkspaceGroups\b"#)

    /// The members of one file that read `groupId` or `workspaceGroups`, as name to the non-comment text of the member
    /// (a name with several overloads is one entry). The text includes the declaration line, so a parameter named
    /// `groupId` counts: a function that takes a group is a function that deals with levels.
    private func readers(inFile relativePath: String) throws -> [String: String] {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CmuxWorkspaces")
        let text = try String(contentsOf: sources.appendingPathComponent(relativePath), encoding: .utf8)
        var bodies: [String: String] = [:]
        var current: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(line)
            let range = NSRange(line.startIndex..., in: line)
            if let match = Self.memberDeclaration.firstMatch(in: line, range: range), let name = Range(match.range(at: 1), in: line) {
                current = String(line[name])
            }
            guard let current, !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
            bodies[current, default: ""] += line + "\n"
        }
        return bodies.filter { Self.readsGroups.firstMatch(in: $0.value, range: NSRange($0.value.startIndex..., in: $0.value)) != nil }
    }

    @Test
    func everyFunctionThatReadsAWorkspacesGroupOrTheGroupsIsListedWithTheReasonItIsRight() throws {
        var found: [String: String] = [:]
        for file in Self.filesWithHandOvers {
            let name = URL(fileURLWithPath: file).lastPathComponent
            for (member, body) in try readers(inFile: file) { found["\(name)#\(member)"] = body }
        }
        #expect(found.count > 40, "found only \(found.count) functions that read the groups; is the scan reading the files?")
        #expect(
            Set(found.keys) == Set(Self.readersOfGroups.keys),
            "Not in the list (read each, then add 'hands over at <marker>' or 'one level is right here because <reason>'): \(Set(found.keys).subtracting(Self.readersOfGroups.keys).sorted()). In the list and no longer reading the groups (remove): \(Set(Self.readersOfGroups.keys).subtracting(found.keys).sorted())"
        )
        for (key, reason) in Self.readersOfGroups {
            guard let body = found[key] else { continue }
            if reason.hasPrefix(Self.handsOver) {
                let marker = String(reason.dropFirst(Self.handsOver.count))
                #expect(body.contains(marker), "\(key) is listed as handing over at \(marker), and its text does not contain it")
            } else if reason.hasPrefix(Self.oneLevel) {
                #expect(reason.count > Self.oneLevel.count + 15, "\(key): say why one level is right")
            } else {
                #expect(reason.hasPrefix(Self.needsALook), "\(key): a reason is 'hands over at …', 'one level is right here because …' or 'NEEDS A LOOK: …'")
            }
        }
        let open = Self.readersOfGroups.filter { $0.value.hasPrefix(Self.needsALook) }.keys.sorted()
        print("hand-over guard: \(found.count) functions read the groups; \(open.count) still need a look: \(open)")
    }
}
