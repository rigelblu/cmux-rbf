import Foundation

/// What `set` or `clear` for one directory has to write: one pure plan that the
/// Figma button's menu (Set Folder and Remove Folder) and `cmux figma folder
/// set|clear --dir` both use, so the two writers cannot disagree.
///
/// - **One directory has one entry.** `set` writes the directory's resolved form
///   as the key, and removes any other key that resolves to the same directory.
///   `clear` removes every key whose resolved form is the directory's, and never
///   a parent's.
/// - **Every other entry keeps its raw value,** one that is not text included.
/// - **Setting the link already stored writes nothing,** and neither does a
///   `clear` with no such key.
/// - **A write that leaves no entry removes `figma.folders`.**
///
/// There is no lock across processes: each writer reads `figma.folders`, then
/// writes the whole object, and a write by another process in between is lost.
public enum FigmaFolders {
    /// What the person asked for.
    public enum Change: Equatable, Sendable {
        /// Bind this link to the directory.
        case set(FigmaFolderLink)
        /// Remove the directory's own entry.
        case clear
    }

    /// What to write.
    public enum Plan: Equatable, Sendable {
        /// Leave the file's bytes alone.
        case nothing
        /// Write `figma.folders` as these entries.
        case write(FigmaFolderEntries)
        /// Remove `figma.folders` (and a `figma` object it leaves empty).
        case removeAll
    }

    /// Plans `change` for one directory.
    ///
    /// - Parameters:
    ///   - change: Set a link or clear.
    ///   - resolved: The directory's resolved form (``FigmaFolderPath/Forms/resolved``). Both writers resolve first.
    ///   - entries: `figma.folders` as read now: ``FigmaFolderEntries/empty`` for none or for a value that is not an object.
    ///   - home: What `~` stands for in a key.
    public static func plan(
        _ change: Change,
        directory resolved: String,
        entries: FigmaFolderEntries,
        home: String = FigmaFolderPath.homeDirectory
    ) -> Plan {
        var remaining = entries.entries
        var removedAny = false
        for key in entries.entries.keys {
            guard let forms = FigmaFolderPath.keyForms(key, home: home), forms.resolved == resolved else { continue }
            remaining.removeValue(forKey: key)
            removedAny = true
        }
        switch change {
        case .set(let link):
            remaining[resolved] = .link(link.url)
            let planned = FigmaFolderEntries(remaining)
            return planned == entries ? .nothing : .write(planned)
        case .clear:
            guard removedAny else { return .nothing }
            return remaining.isEmpty ? .removeAll : .write(FigmaFolderEntries(remaining))
        }
    }

    /// What `figma.folders` holds once `plan` is applied to `entries`.
    public static func entries(after plan: Plan, from entries: FigmaFolderEntries) -> FigmaFolderEntries {
        switch plan {
        case .nothing: return entries
        case .write(let written): return written
        case .removeAll: return .empty
        }
    }

    /// Writes `plan` through `store`, the one writer for `figma.folders`.
    public static func apply(_ plan: Plan, to store: JSONConfigStore) async throws {
        let key = SettingCatalog().figma.folders
        switch plan {
        case .nothing: break
        case .write(let entries): try await store.set(entries, for: key)
        case .removeAll: try await store.reset(key)
        }
    }
}
