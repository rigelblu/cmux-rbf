import CmuxSettings
import Foundation
import Testing
@testable import CmuxSettingsUI

@Suite @MainActor
struct WorkspaceColorPreferenceSaveModelTests {
    @Test func pendingSaveKeepsPreviousStateAndRejectsConflictingAction() async {
        let model = WorkspaceColorPreferenceSaveModel()
        let before = WorkspaceColorSettingsSnapshot(palette: ["Teal": "#006B6B"])
        var shown = before
        var writes = 0
        var release: CheckedContinuation<Void, Never>?
        let started = AsyncStream<Void>.makeStream()
        let task = Task { @MainActor in
            await model.save(.visibility(name: "Teal", visible: false), expected: before, using: { _, snapshot in
                writes += 1
                await withCheckedContinuation { continuation in
                    release = continuation
                    started.continuation.yield(())
                }
                var saved = snapshot
                saved.preferences.hiddenNames = ["Teal"]
                return saved
            }, accept: { shown = $0 })
        }
        var events = started.stream.makeAsyncIterator()
        _ = await events.next()
        #expect(model.isSaving)
        #expect(shown == before)
        await model.save(.resetPalette, expected: before, using: { _, snapshot in
            writes += 1
            return snapshot
        }, accept: { shown = $0 })
        #expect(writes == 1)
        release?.resume()
        await task.value
        #expect(!model.isSaving)
        #expect(shown.preferences.hiddenNames == ["Teal"])
        #expect(model.error == nil)
        started.continuation.finish()
    }

    @Test(arguments: [WorkspaceColorSettingsSnapshot.SaveError.stale, .failed])
    func rejectedSaveLeavesPreviousControls(error: WorkspaceColorSettingsSnapshot.SaveError) async {
        let model = WorkspaceColorPreferenceSaveModel()
        let before = WorkspaceColorSettingsSnapshot(palette: ["Teal": "#006B6B"], preferences: .init(hiddenNames: ["Teal"]))
        var shown = before
        await model.save(.resetPalette, expected: before, using: { _, _ in throw error }, accept: { shown = $0 })
        #expect(shown == before)
        #expect(model.error == error)
        #expect(!model.isSaving)
    }
}
