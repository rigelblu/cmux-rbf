import SwiftUI
import Testing
@testable import CmuxSettingsUI

@Suite
struct WorkspaceColorReorderKeyPolicyTests {
    @Test func arrowKeyFlagsAreNotAChord() {
        // What a hardware arrow press carries, with and without caps lock.
        #expect(WorkspaceColorReorderKeyPolicy.isBareArrow([.numericPad, .function]))
        #expect(WorkspaceColorReorderKeyPolicy.isBareArrow([.capsLock, .numericPad, .function]))
        #expect(WorkspaceColorReorderKeyPolicy.isBareArrow([]))
    }

    @Test(arguments: [EventModifiers.command, .control, .option, .shift])
    func heldModifierIsAChord(modifier: EventModifiers) {
        let bare = WorkspaceColorReorderKeyPolicy.isBareArrow([modifier, .numericPad, .function])
        #expect(bare == false)
    }
}
