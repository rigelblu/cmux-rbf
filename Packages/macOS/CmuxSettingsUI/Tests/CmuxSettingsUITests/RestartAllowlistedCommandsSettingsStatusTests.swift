import Testing
@testable import CmuxSettingsUI

@Suite("Restart allowlisted commands Settings status")
struct RestartAllowlistedCommandsSettingsStatusTests {
    @Test func syntaxErrorLineAppearsOnlyWhenKnown() throws {
        let located = RestartAllowlistedCommandsSettingsStatus.enabledFallback(
            warning: .unusableUserFile(syntaxErrorLine: 42)
        )
        let generic = RestartAllowlistedCommandsSettingsStatus.enabledFallback(
            warning: .unusableUserFile(syntaxErrorLine: nil)
        )

        #expect(try #require(located.warningText).contains("42"))
        #expect(!(try #require(generic.warningText)).contains("42"))
    }
}
