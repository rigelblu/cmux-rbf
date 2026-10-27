import Foundation
import Testing

import CmuxWorkspaces
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression guard: sidebar workspace rows may render a compact manual
/// task-status glyph, but must not bring back automatic status circles or a
/// row-anchored status popover.
///
/// History this guards against repeating: the circles shipped with
/// workspaces-as-todos (#7216), were removed by the full revert (#7761,
/// commit 657248a17), and came back when the feature was restored (#7790,
/// commit 998e7fb23) — pre-existing persisted workspaces restored to the
/// visible/Auto state, so the circles reappeared on every old workspace row.
/// Manual status is now restored intentionally, but automatic status must
/// still stay out of old rows.
///
/// The sidebar row is a SwiftUI shape subtree under a lazy list, so there is
/// no NSView to walk for a mounted-hierarchy assertion; scanning the row's
/// rendering sources is the repo's established guard pattern for "this must
/// not silently return" (see the `#filePath` repo-root scans in
/// `GhosttyConfigTests` / `RemoteShellCWDRelayTests`).
struct SidebarWorkspaceRowStatusGlyphRemovalTests {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // cmuxTests
            .deletingLastPathComponent() // repo root
    }

    /// The files that render sidebar workspace rows. The glyph view itself
    /// legitimately survives for the todo pane header and the status
    /// popover's lane rows — the ban is on the row rendering path.
    private static let rowRenderingSources = [
        "Sources/ContentView.swift",
        "Sources/TabItemView+WorkspaceTodo.swift",
    ]

    /// Identifiers that only exist while the row owns a status popover. The
    /// glyph view itself is allowed, but only through the manual-only policy.
    private static let bannedRowTokens = [
        "SidebarWorkspaceStatusPopover",
        "statusPopoverWorkspaceId",
        "isStatusPopoverPresented",
    ]

    private static func sourceText(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    @Test
    func workspaceRowSourcesRenderNoRowAnchoredStatusPopover() throws {
        for relativePath in Self.rowRenderingSources {
            let source = try Self.sourceText(relativePath)
            for token in Self.bannedRowTokens {
                #expect(
                    !source.contains(token),
                    """
                    \(relativePath) references \(token). Sidebar workspace rows must not \
                    own the status popover or status-popover state; manual row status \
                    may draw only through the manual-only indicator policy.
                    """
                )
            }
        }
    }

    /// The row files under `Sources/Sidebar/` (slots, snapshot refresh
    /// policy, hover reconcilers, …) must not grow a status-glyph reference
    /// either; they are all below the sidebar snapshot boundary.
    @Test
    func sidebarRowSupportSourcesRenderNoRowAnchoredStatusPopover() throws {
        let sidebarDir = Self.repoRoot.appendingPathComponent("Sources/Sidebar")
        let files = try FileManager.default
            .contentsOfDirectory(at: sidebarDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(!files.isEmpty, "Sources/Sidebar contained no Swift files; guard scan is broken.")
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for token in Self.bannedRowTokens {
                #expect(
                    !source.contains(token),
                    "Sources/Sidebar/\(file.lastPathComponent) references \(token); sidebar rows must not own row-anchored status popover state."
                )
            }
        }
    }

    /// The row snapshot must not carry automatic-status glyph fields. Dead
    /// per-row observation wiring is exactly the class of sidebar perf
    /// incident tracked by #2586/#8004; manual status is represented by a
    /// single boolean and the resolved status.
    @Test
    func workspaceSnapshotCarriesNoAutomaticStatusGlyphFields() throws {
        let source = try Self.sourceText("Sources/SidebarWorkspaceSnapshotBuilder.swift")
        for field in ["taskStatusHasOverride", "taskStatusInferred"] {
            #expect(
                !source.contains(field),
                "SidebarWorkspaceSnapshotBuilder.Snapshot regained \(field), an automatic status-glyph field; row status must stay manual-only."
            )
        }
    }

    @MainActor
    @Test
    func workspaceRowIndicatorAllowsManualOrNoneButNotAuto() throws {
        let harness = WorkspaceNoneRowTests()
        let workspace = Workspace()
        workspace.hideTaskStatus()
        let none = harness.cell(harness.model(workspace))
        #expect(!none.statusGlyphButtonForTesting.isHidden, "None must show its mark through the real factory and cell")
        #expect(none.statusGlyphModelForTesting?.isNone == true, "None must replace the detected status glyph")

        workspace.setOwnStatus(try #require(WorkspaceNoneRowTests.list.entry(id: "next")), list: WorkspaceNoneRowTests.list)
        let manual = harness.cell(harness.model(workspace))
        #expect(!manual.statusGlyphButtonForTesting.isHidden)
        #expect(manual.statusGlyphModelForTesting?.name == "Next")
        #expect(manual.statusGlyphModelForTesting?.isNone == false)

        workspace.clearTaskStatusOverride()
        let auto = harness.cell(harness.model(workspace))
        #expect(auto.statusGlyphButtonForTesting.isHidden, "Auto must keep the row's status slot empty")

        workspace.hideTaskStatus()
        let disabled = harness.cell(harness.model(workspace, controls: false))
        #expect(disabled.statusGlyphButtonForTesting.isHidden, "controls off must hide the None mark too")
    }
}
