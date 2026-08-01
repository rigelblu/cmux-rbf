import Foundation

/// Command-palette identity derived from a raw workspace palette name.
///
/// Lifted from `ContentView.commandPaletteWorkspaceColorCommandID`, where it was
/// `private` on an 8000-line SwiftUI view and therefore untestable.
///
/// It was first landed as a *copy*, leaving the private original still shipping — so
/// the suites asserting ID stability guarded a function nothing called, and would have
/// stayed green through any change to the real one. Both call sites now use this type
/// and the private copy is gone; keep it that way, or the tests below stop meaning
/// anything.
///
/// This is why custom palette names must be minted monotonically: the ID is a pure
/// function of the raw name, so recycling `Custom N` recycles the command ID, and any
/// `cmux.json` `actions` override keyed by it silently retargets its title, subtitle,
/// keywords, and palette visibility onto a different color.
public enum WorkspaceColorCommandIdentity {
    /// FNV-1a over the raw palette name. Stable across launches and processes.
    public static func commandID(forPaletteName name: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "palette.workspaceColor.\(String(hash, radix: 16))"
    }
}
