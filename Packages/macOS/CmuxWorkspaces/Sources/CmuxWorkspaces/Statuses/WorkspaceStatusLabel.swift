/// What a caller draws for a status.
///
/// A list from cmux carries no display names, because cmux's names are localized in the app. A caller that draws a
/// row asks its label: `.named` is a word from his file, drawn as it is, and `.cmux` says "draw cmux's own name for
/// this cmux status".
public enum WorkspaceStatusLabel: Equatable, Sendable {
    /// His word, from his file or the stored copy of it; also the raw id a workspace holds, for the greyed row of a
    /// status the list lacks.
    case named(String)
    /// Draw cmux's own localized name for this status.
    case cmux(WorkspaceTaskStatus)
}
