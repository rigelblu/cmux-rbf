import Foundation

/// What `figma.defaultFolder` in a config root says, with the broken cases told
/// apart from "not set", and what `cmux figma folder clear` has to do about it.
///
/// ``JSONConfigStore/value(for:)`` answers the key's default for a value of the wrong
/// type, which is right for Settings and wrong for an agent: an agent that reads a
/// broken setting as "not set" sends the design to Drafts without a word.
/// `cmux figma folder` reads the root with ``JSONConfigStore/strictRoot()`` and builds
/// one of these from it.
public struct FigmaDefaultFolder: Equatable, Sendable {
    /// The four things the key can hold.
    public enum State: Equatable, Sendable {
        /// No `figma` object (or `figma` is `null`), no key, `null`, or text that is empty or only spaces.
        case notSet
        /// A link that passes ``FigmaFolderLink/check(_:)``, as stored.
        case set(FigmaFolderLink)
        /// Text that does not pass the check (the file was edited by hand).
        case refused(FigmaFolderLink.Refusal)
        /// A `figma` that is neither an object nor `null`, or a value at the key that is neither text nor `null`.
        case notText
    }

    /// What `clear` writes.
    public enum ClearAction: Equatable, Sendable {
        /// Nothing: the file keeps its bytes, comments included.
        case nothing
        /// Remove `figma.defaultFolder` (and the `figma` object when that leaves it empty).
        case removeKey
        /// Remove the whole `figma` key: it holds something that is neither an object nor `null`,
        /// so the key cannot be removed from inside it and every read would stay broken.
        case removeFigma
    }

    /// The state the key is in.
    public let state: State

    /// What `clear` has to write: exactly when `defaultFolder` is in the file at all,
    /// whatever it holds, or `figma` is something other than an object or `null`.
    public let clearAction: ClearAction

    /// Reads the state and the clear decision out of a config root. Pure: it reads nothing but `root`.
    ///
    /// - Parameter root: The parsed top-level object of `cmux.json` (an empty root for no file).
    public init(root: [String: Any]) {
        let components = SettingCatalog().figma.defaultFolder.path.components
        let figma = root[components[0]]
        guard let figma, !(figma is NSNull) else {
            state = .notSet
            clearAction = .nothing
            return
        }
        guard let object = figma as? [String: Any] else {
            state = .notText
            clearAction = .removeFigma
            return
        }
        guard let raw = object[components[1]] else {
            state = .notSet
            clearAction = .nothing
            return
        }
        clearAction = .removeKey
        if raw is NSNull {
            state = .notSet
        } else if let text = raw as? String {
            if text.trimmingCharacters(in: FigmaFolderLink.blanks).isEmpty {
                state = .notSet
            } else {
                switch FigmaFolderLink.check(text) {
                case .success(let link): state = .set(link)
                case .failure(let refusal): state = .refused(refusal)
                }
            }
        } else {
            state = .notText
        }
    }
}
