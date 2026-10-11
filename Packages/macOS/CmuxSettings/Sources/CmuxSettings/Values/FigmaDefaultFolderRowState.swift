import Foundation

/// The `Figma Default Folder` Settings row's state and every decision it makes, apart from
/// drawing it.
///
/// The row lives in `CmuxSettingsUI`, whose tests `make test` does not run, so the decisions
/// are here, where `cmuxTests` runs them as sequences.
///
/// **"Stored" is always what the settings model reports, passed in on every call; this
/// struct never keeps its own idea of it.** A save does not move ``synced``: it asks for a
/// write and waits for ``storedChanged(to:isFocused:)`` to say the store took it. So a
/// failed write never shows the set sentence or the Open link, and an outside change is
/// never undone by a save the person did not mean.
public struct FigmaDefaultFolderRowState: Equatable, Sendable {

    /// A save the row refused, and the text it refused. The refusal holds only while the
    /// field still holds that text; changing the field ends it.
    struct Refused: Equatable, Sendable {
        /// The text the field held when it was refused.
        let draft: String
        /// Why it was refused.
        let reason: FigmaFolderLink.Refusal
    }

    /// Which sentence the row's one subtitle reads. The warning mark of the four refusals is
    /// put on by the view, so it is not part of any translated string.
    public enum Subtitle: Equatable, Sendable {
        /// Nothing is stored (or only spaces).
        case notSet
        /// A folder link is stored; `folderId` is its folder id.
        case set(folderId: String)
        /// The stored link has no team in it (the file was edited by hand).
        case storedNoTeam
        /// The stored text is not a folder link (the file was edited by hand).
        case storedNotAFolder
        /// The text in the field was refused because its link has no team in it.
        case notSavedNoTeam
        /// The text in the field was refused because it is not a folder link.
        case notSavedNotAFolder
    }

    /// What a save asks the model to do.
    public enum Effect: Equatable, Sendable {
        /// Nothing to write.
        case none
        /// Store this trimmed link.
        case write(String)
        /// Remove the key.
        case remove
    }

    /// The field's text. The view binds the text field to it.
    public var draft: String

    /// The stored text the field was last set from, or, once the person has typed and an
    /// outside change arrives, the stored text at that moment (see
    /// ``storedChanged(to:isFocused:)``). Only the person typing can make ``draft`` differ
    /// from it, so `draft == synced` always means "nothing was typed since".
    private var synced: String

    /// The refused save the subtitle is still speaking for, if any.
    private var refused: Refused?

    /// A row for a store that holds `stored`.
    ///
    /// - Parameter stored: What the settings model currently reports.
    public init(stored: String) {
        draft = stored
        synced = stored
    }

    /// Whether the field holds text the person typed that nothing has settled yet. The row
    /// uses it to save when it goes away.
    public var hasUnsavedDraft: Bool { draft != synced }

    /// One save: Return, leaving the field, or the row going away.
    ///
    /// - Parameter stored: What the settings model currently reports.
    /// - Returns: The write to ask for. ``Effect/none`` when nothing was typed, and in
    ///   particular **never a write for an untouched field**: an outside `clear` that
    ///   arrived while the caret sat in it must not be undone by clicking away.
    public mutating func commit(stored: String) -> Effect {
        if draft == synced {
            if stored != synced {
                draft = stored
                synced = stored
                refused = nil
            }
            return .none
        }
        let trimmed = draft.trimmingCharacters(in: FigmaFolderLink.blanks)
        if trimmed.isEmpty {
            draft = ""
            refused = nil
            if stored.isEmpty {
                synced = ""
                return .none
            }
            return .remove
        }
        switch FigmaFolderLink.check(trimmed) {
        case .success(let link):
            draft = link.url
            refused = nil
            if link.url == stored {
                synced = stored
                return .none
            }
            return .write(link.url)
        case .failure(let reason):
            refused = Refused(draft: draft, reason: reason)
            return .none
        }
    }

    /// The stored text changed: an outside edit, or our own write landing.
    ///
    /// The field takes it when it has no caret, or already holds it (our write landing).
    /// Otherwise the draft is not replaced: a draft being typed is never overwritten.
    ///
    /// When the draft is not replaced and the person **has typed** (`draft != synced`),
    /// the baseline moves to the new stored text. Otherwise stored A, typed `x`, an outside
    /// change to B, and typing A again would read as "nothing typed" (`draft == synced`),
    /// and Return would flip the field to B without writing the A the person typed. An
    /// untouched field keeps its baseline, so it still catches up without writing when
    /// the caret leaves.
    ///
    /// - Parameters:
    ///   - new: What the settings model now reports.
    ///   - isFocused: Whether the field has the caret.
    public mutating func storedChanged(to new: String, isFocused: Bool) {
        guard !isFocused || draft == new else {
            if draft != synced { synced = new }
            return
        }
        draft = new
        synced = new
        refused = nil
    }

    /// The one subtitle. A refusal speaks while the field still holds the refused text;
    /// otherwise it describes what is stored, whatever the field holds.
    ///
    /// - Parameter stored: What the settings model currently reports.
    /// - Returns: The sentence to show: a refusal while its text is in the field, else the
    ///   state of `stored`.
    public func subtitle(stored: String) -> Subtitle {
        if let refused, refused.draft == draft {
            switch refused.reason {
            case .noTeam: return .notSavedNoTeam
            case .notAFolderLink: return .notSavedNotAFolder
            }
        }
        if Self.isBlank(stored) { return .notSet }
        switch FigmaFolderLink.check(stored) {
        case .success(let link): return .set(folderId: link.projectId)
        case .failure(.noTeam): return .storedNoTeam
        case .failure(.notAFolderLink): return .storedNotAFolder
        }
    }

    /// The address **Open Folder in Figma** opens, or `nil` when it must not show: it shows
    /// only when the field holds the stored link and that link passes, so it never opens
    /// something other than what the field shows or what is stored.
    ///
    /// - Parameter stored: What the settings model currently reports.
    /// - Returns: The trimmed stored link to open, or `nil` when the link must stay hidden.
    public func openLink(stored: String) -> URL? {
        guard draft == stored, case .success(let link) = FigmaFolderLink.check(stored) else { return nil }
        return URL(string: link.url)
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: FigmaFolderLink.blanks).isEmpty
    }
}
