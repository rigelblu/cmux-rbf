/// The shape an entry of the status list draws, named in its `icon` field.
///
/// The eight names are the file's words, so they are the raw values and are never localized. `nil` on an entry
/// means no icon was named: the entry draws the glyph of the cmux status it extends.
///
/// Encodable only, like ``WorkspaceStatusEntry``: the app's stored copy of the list is written from it.
public enum WorkspaceStatusIcon: String, CaseIterable, Sendable, Encodable {
    case dottedRing = "dotted-ring"
    case ring
    case quarter
    case half
    case threeQuarters = "three-quarters"
    case full
    case check
    case pause = "pause" // (#cm-109.3)
}
