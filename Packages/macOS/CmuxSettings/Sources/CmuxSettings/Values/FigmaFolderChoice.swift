import Foundation

/// Which Figma folder answers for a directory: one pure rule, run by the Figma
/// button's menu and by `cmux figma folder`, so a design lands in the same
/// folder whichever one made it.
///
/// A wrong answer files a design in the wrong folder and nothing says so, so the
/// rule is one ordered rule and the first step that answers is the answer:
///
/// 1. **The directory's two forms** (``FigmaFolderPath``): the shell form and the resolved form.
/// 2. **Each key's two forms,** made the same way. A key that is neither absolute nor `~/…` never matches.
/// 3. **The matches.** A key matches when its written form's path parts are the first parts of the
///    directory's shell form, or its resolved form's are the first parts of the directory's resolved
///    form: equal, or the directory is inside it. Whole parts: `/x/a` does not match `/x/ab`. `/`
///    matches everything.
/// 4. **The nearest match answers:** the fewest path parts between the key and the directory, in the
///    form that matched. On a tie a match on the shell form wins, then the key whose text sorts first,
///    so the answer never depends on the order of the file's keys.
/// 5. **What it holds.** A link that passes ``FigmaFolderLink/check(_:)`` is the folder, "from" that
///    key as written with `~` expanded. A link that fails is that refusal, from that key. A value that
///    is not text is ``notText(from:)``. **Steps 4 and 5 never fall through** to a farther match or to
///    the default: a broken entry written for this directory must not quietly send designs elsewhere.
/// 6. **No match:** `figma.defaultFolder` answers, "from the default". With nothing there, ``none``.
public enum FigmaFolderChoice: Equatable, Sendable {
    /// Where an answer came from.
    public enum Source: Equatable, Sendable {
        /// This key of `figma.folders`, as written, with a leading `~` expanded.
        case directory(String)
        /// `figma.defaultFolder`.
        case `default`
    }

    /// Why the strict read cannot answer at all.
    public enum StrictFailure: Error, Equatable, Sendable {
        /// `figma.folders` is neither an object nor `null`.
        case foldersNotObject
    }

    /// A folder that passes the link check.
    case folder(FigmaFolderLink, from: Source)
    /// A link that does not pass.
    case refused(FigmaFolderLink.Refusal, from: Source)
    /// A value that is not text.
    case notText(from: Source)
    /// No entry matches and the default is not set.
    case none

    /// Answers from decoded entries and the default's state.
    ///
    /// - Parameters:
    ///   - forms: The directory's two forms, or `nil` for a directory that has none (a remote
    ///     workspace), which gets the default.
    ///   - entries: What ``FigmaFolderEntries`` decoded from `figma.folders`.
    ///   - defaultState: `figma.defaultFolder`'s state.
    ///   - home: What `~` stands for in a key.
    public static func answer(
        forms: FigmaFolderPath.Forms?,
        entries: FigmaFolderEntries,
        defaultState: FigmaDefaultFolder.State,
        home: String = FigmaFolderPath.homeDirectory
    ) -> FigmaFolderChoice {
        if let forms, let match = nearest(to: forms, in: entries, home: home) {
            switch match.entry {
            case .link(let text):
                switch FigmaFolderLink.check(text) {
                case .success(let link): return .folder(link, from: .directory(match.from))
                case .failure(let refusal): return .refused(refusal, from: .directory(match.from))
                }
            case .notText:
                return .notText(from: .directory(match.from))
            }
        }
        switch defaultState {
        case .notSet: return .none
        case .set(let link): return .folder(link, from: .default)
        case .refused(let refusal): return .refused(refusal, from: .default)
        case .notText: return .notText(from: .default)
        }
    }

    /// The lenient form, for a reader that has only the store's `snapshotValue`s
    /// (the Figma button's menu): the default as the text the store gave.
    public static func answer(
        forms: FigmaFolderPath.Forms?,
        entries: FigmaFolderEntries,
        defaultFolder: String,
        home: String = FigmaFolderPath.homeDirectory
    ) -> FigmaFolderChoice {
        let components = SettingCatalog().figma.defaultFolder.path.components
        let root: [String: Any] = [components[0]: [components[1]: defaultFolder]]
        return answer(
            forms: forms,
            entries: entries,
            defaultState: FigmaDefaultFolder(root: root).state,
            home: home
        )
    }

    /// What answers when no directory has an entry: the default, as the text the store gave. For a
    /// reader with no directory to ask about, and for tests that need only the default.
    public static func defaultOnly(_ defaultFolder: String?) -> FigmaFolderChoice {
        answer(forms: nil, entries: .empty, defaultFolder: defaultFolder ?? "")
    }

    /// The strict form, for a reader of ``JSONConfigStore/strictRoot()`` (the command).
    /// It also reports a `figma.folders` that is neither an object nor `null`.
    public static func strict(
        root: [String: Any],
        forms: FigmaFolderPath.Forms?,
        home: String = FigmaFolderPath.homeDirectory
    ) -> Result<FigmaFolderChoice, StrictFailure> {
        switch strictEntries(root: root) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let entries):
            return .success(answer(
                forms: forms,
                entries: entries,
                defaultState: FigmaDefaultFolder(root: root).state,
                home: home
            ))
        }
    }

    /// The entries of `figma.folders` in a strictly read root: none for an absent key or `null`.
    public static func strictEntries(root: [String: Any]) -> Result<FigmaFolderEntries, StrictFailure> {
        let components = SettingCatalog().figma.folders.path.components
        guard let figma = root[components[0]] as? [String: Any],
              let folders = figma[components[1]],
              !(folders is NSNull)
        else { return .success(.empty) }
        guard let decoded = FigmaFolderEntries.decodeFromJSON(folders) else {
            return .failure(.foldersNotObject)
        }
        return .success(decoded)
    }

    // MARK: - Matching

    private struct Match {
        let from: String
        let key: String
        let entry: FigmaFolderEntries.Entry
        let distance: Int
        let viaShell: Bool

        /// Whether `self` answers before `other`: nearer, then the shell form, then the key's text.
        func precedes(_ other: Match) -> Bool {
            if distance != other.distance { return distance < other.distance }
            if viaShell != other.viaShell { return viaShell }
            return key < other.key
        }
    }

    private static func nearest(
        to forms: FigmaFolderPath.Forms,
        in entries: FigmaFolderEntries,
        home: String
    ) -> Match? {
        let shellParts = FigmaFolderPath.parts(of: forms.shell)
        let resolvedParts = FigmaFolderPath.parts(of: forms.resolved)
        var best: Match?
        for (key, entry) in entries.entries {
            guard let keyForms = FigmaFolderPath.keyForms(key, home: home) else { continue }
            let written = FigmaFolderPath.parts(of: keyForms.shell)
            let resolved = FigmaFolderPath.parts(of: keyForms.resolved)
            var distance: Int?
            var viaShell = false
            if isPrefix(written, of: shellParts) {
                distance = shellParts.count - written.count
                viaShell = true
            }
            if isPrefix(resolved, of: resolvedParts) {
                let found = resolvedParts.count - resolved.count
                if distance == nil || found < distance! {
                    distance = found
                    viaShell = false
                }
            }
            guard let distance else { continue }
            let candidate = Match(
                from: FigmaFolderPath.expandingHome(key, home: home),
                key: key,
                entry: entry,
                distance: distance,
                viaShell: viaShell
            )
            if best == nil || candidate.precedes(best!) { best = candidate }
        }
        return best
    }

    private static func isPrefix(_ prefix: [String], of parts: [String]) -> Bool {
        prefix.count <= parts.count && parts.starts(with: prefix)
    }
}
