import Foundation
import Testing
@testable import CmuxSettings

/// `FigmaFolderChoice`: which Figma folder answers for a directory. The rule is
/// one ordered rule and a wrong answer files a design in the wrong folder, with
/// nothing to say so. One test per row of the rule's table (cm-73.42, Scenario
/// 370); the rows are numbered as that scenario numbers them.
@Suite("FigmaFolderChoice")
struct FigmaFolderChoiceTests {

    // MARK: - Fixtures

    static let linkA = "https://www.figma.com/files/team/764866853003674551/folder/643299150"
    static let linkB = "https://www.figma.com/files/team/1/folder/2"
    static let linkC = "https://www.figma.com/files/team/5/folder/6"
    static let noTeam = "https://www.figma.com/files/folder/9"
    static let home = "/Users/probe"

    static func link(_ text: String) -> FigmaFolderLink {
        guard case .success(let link) = FigmaFolderLink.check(text) else {
            fatalError("fixture link does not pass: \(text)")
        }
        return link
    }

    static func entries(_ pairs: KeyValuePairs<String, FigmaFolderEntries.Entry>) -> FigmaFolderEntries {
        var map: [String: FigmaFolderEntries.Entry] = [:]
        for (key, value) in pairs { map[key] = value }
        return FigmaFolderEntries(map)
    }

    /// The directory's two forms when it is a plain path with no symlink in it.
    static func plain(_ path: String) -> FigmaFolderPath.Forms {
        FigmaFolderPath.Forms(shell: path, resolved: path)
    }

    static func answer(
        _ directory: FigmaFolderPath.Forms?,
        _ entries: FigmaFolderEntries,
        defaultFolder: String = linkA
    ) -> FigmaFolderChoice {
        FigmaFolderChoice.answer(forms: directory, entries: entries, defaultFolder: defaultFolder, home: home)
    }

    static func folder(_ url: String, from key: String) -> FigmaFolderChoice {
        .folder(link(url), from: .directory(key))
    }

    /// A temp folder with its symlinks resolved, so a test's expected paths are real ones.
    static func scratch() throws -> String {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("figma-choice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return FigmaFolderPath.resolvedForm(base.path)
    }

    // MARK: - Rows 1 to 4: which key matches, and whole path parts

    @Test("row 1: a key equal to the directory answers")
    func row1KeyEqualsDirectory() {
        let result = Self.answer(Self.plain("/x/a"), Self.entries(["/x/a": .link(Self.linkB)]))
        #expect(result == Self.folder(Self.linkB, from: "/x/a"))
    }

    @Test("row 2: a key that holds the directory answers")
    func row2KeyHoldsDirectory() {
        let result = Self.answer(Self.plain("/x/a/inner"), Self.entries(["/x/a": .link(Self.linkB)]))
        #expect(result == Self.folder(Self.linkB, from: "/x/a"))
    }

    @Test("row 3: /x/a does not answer for /x/ab, whole path parts only")
    func row3WholePathParts() {
        let result = Self.answer(Self.plain("/x/ab"), Self.entries(["/x/a": .link(Self.linkB)]))
        #expect(result == .folder(Self.link(Self.linkA), from: .default))
    }

    @Test("row 4: with /x and /x/a set, /x/a answers for /x/a/inner")
    func row4NearestKeyWins() {
        let entries = Self.entries(["/x": .link(Self.linkC), "/x/a": .link(Self.linkB)])
        let result = Self.answer(Self.plain("/x/a/inner"), entries)
        #expect(result == Self.folder(Self.linkB, from: "/x/a"))
    }

    @Test("row 4: of a chain of keys, each deeper than the last, the deepest answers, whatever order they sit in")
    func row4NearestOfAChain() {
        // A rule that took the first match would answer with whichever key the dictionary lists
        // first. Each length of chain is a different dictionary, so a different listing order.
        for depth in 2...9 {
            var key = ""
            var map: [String: FigmaFolderEntries.Entry] = [:]
            for level in 0..<depth {
                key += "/d\(level)"
                map[key] = .link(level == depth - 1 ? Self.linkB : Self.linkC)
            }
            let result = Self.answer(Self.plain(key + "/inner/deeper"), FigmaFolderEntries(map))
            #expect(result == Self.folder(Self.linkB, from: key), "depth \(depth)")
        }
    }

    // MARK: - Row 5: the answer never depends on the file's key order

    @Test("row 5: two keys with one path give the same answer, whichever the file lists first")
    func row5TieBreakIsKeyText() {
        // `/x/p/../b` and `/x/b` are the same directory once the shell's dots are dropped,
        // so both match at the same distance. The key whose text sorts first answers.
        for index in 0..<12 {
            let dotted = "/x/p\(index)/../b"
            let plain = "/x/b"
            let expectedKey = min(dotted, plain)
            let expectedLink = expectedKey == dotted ? Self.linkB : Self.linkC
            let one = Self.entries([dotted: .link(Self.linkB), plain: .link(Self.linkC)])
            let other = Self.entries([plain: .link(Self.linkC), dotted: .link(Self.linkB)])
            #expect(Self.answer(Self.plain("/x/b/inner"), one) == Self.folder(expectedLink, from: expectedKey))
            #expect(Self.answer(Self.plain("/x/b/inner"), other) == Self.folder(expectedLink, from: expectedKey))
        }
    }

    @Test("row 5: two symlinks to one folder, matched on its resolved form, give the one that sorts first")
    func row5SymlinkTie() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: "\(root)/real/inner", withIntermediateDirectories: true)
        var entries: [String: FigmaFolderEntries.Entry] = [:]
        var firstSorted: String?
        for index in 0..<10 {
            let name = "\(root)/ln\(index)"
            try FileManager.default.createSymbolicLink(atPath: name, withDestinationPath: "\(root)/real")
            entries[name] = .link(index.isMultiple(of: 2) ? Self.linkB : Self.linkC)
            firstSorted = min(firstSorted ?? name, name)
        }
        let forms = FigmaFolderPath.Forms(shell: "\(root)/elsewhere", resolved: "\(root)/real/inner")
        let result = Self.answer(forms, FigmaFolderEntries(entries))
        guard case .folder(_, from: .directory(let key)) = result else {
            Issue.record("expected a folder, got \(result)")
            return
        }
        #expect(key == firstSorted)
    }

    // MARK: - Row 6: ~ and relative keys

    @Test("row 6: a ~/ key matches the expanded path; a relative key never matches")
    func row6HomeAndRelativeKeys() {
        let tilde = Self.answer(
            Self.plain("/Users/probe/proj/inner"),
            Self.entries(["~/proj": .link(Self.linkB)])
        )
        #expect(tilde == Self.folder(Self.linkB, from: "/Users/probe/proj"))
        let relative = Self.answer(
            Self.plain("/Users/probe/proj/inner"),
            Self.entries(["proj": .link(Self.linkB), "probe/proj": .link(Self.linkB), "": .link(Self.linkB)])
        )
        #expect(relative == .folder(Self.link(Self.linkA), from: .default))
    }

    // MARK: - Row 7: symlinks

    @Test("row 7: a symlinked directory matches the key of its target, and the reverse")
    func row7SymlinkBothWays() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: "\(root)/real/inner", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: "\(root)/ln", withDestinationPath: "\(root)/real")

        let throughLink = FigmaFolderPath.forms(of: "\(root)/ln/inner", home: Self.home)
        #expect(throughLink.shell == "\(root)/ln/inner")
        #expect(throughLink.resolved == "\(root)/real/inner")
        let forward = Self.answer(throughLink, Self.entries(["\(root)/real": .link(Self.linkB)]))
        #expect(forward == Self.folder(Self.linkB, from: "\(root)/real"))

        let real = FigmaFolderPath.forms(of: "\(root)/real/inner", home: Self.home)
        let reverse = Self.answer(real, Self.entries(["\(root)/ln": .link(Self.linkB)]))
        #expect(reverse == Self.folder(Self.linkB, from: "\(root)/ln"))
    }

    // MARK: - Row 8: a broken answer is never skipped

    @Test("row 8: a matched key with no team is refused from that key, parent and default both usable")
    func row8RefusalIsNotSkipped() {
        let entries = Self.entries(["/x": .link(Self.linkC), "/x/a": .link(Self.noTeam)])
        let result = Self.answer(Self.plain("/x/a/inner"), entries)
        #expect(result == .refused(.noTeam, from: .directory("/x/a")))
    }

    @Test("row 8: a matched key that is not a folder link is refused as such")
    func row8NotAFolderLink() {
        let entries = Self.entries(["/x/a": .link("https://example.com/files/team/1/folder/2")])
        #expect(Self.answer(Self.plain("/x/a"), entries) == .refused(.notAFolderLink, from: .directory("/x/a")))
    }

    // MARK: - Rows 9 and 10: the default

    @Test("row 9: no match gives the default, from the default")
    func row9NoMatchGivesDefault() {
        let result = Self.answer(Self.plain("/y/b"), Self.entries(["/x/a": .link(Self.linkB)]))
        #expect(result == .folder(Self.link(Self.linkA), from: .default))
    }

    @Test("row 9: no match and no default gives none")
    func row9NoMatchNoDefault() {
        let result = Self.answer(Self.plain("/y/b"), Self.entries(["/x/a": .link(Self.linkB)]), defaultFolder: "")
        #expect(result == .none)
    }

    @Test("row 9: a default that is refused is reported from the default")
    func row9RefusedDefault() {
        let result = Self.answer(Self.plain("/y/b"), .empty, defaultFolder: Self.noTeam)
        #expect(result == .refused(.noTeam, from: .default))
    }

    @Test("row 10: no directory (a remote workspace) gives the default")
    func row10NilDirectoryGivesDefault() {
        let result = Self.answer(nil, Self.entries(["/": .link(Self.linkB)]))
        #expect(result == .folder(Self.link(Self.linkA), from: .default))
    }

    // MARK: - Row 11: a value that is not text

    @Test("row 11: a matched value that is not text gives notText, in the lenient form")
    func row11NotTextLenient() {
        let entries = Self.entries(["/x/a": .notText(rawJSON: "7"), "/x": .link(Self.linkC)])
        #expect(Self.answer(Self.plain("/x/a/inner"), entries) == .notText(from: .directory("/x/a")))
    }

    @Test("row 11: a matched value that is not text gives notText, in the strict form")
    func row11NotTextStrict() {
        let root: [String: Any] = ["figma": ["folders": ["/x/a": 7, "/x": Self.linkC], "defaultFolder": Self.linkA]]
        let result = FigmaFolderChoice.strict(root: root, forms: Self.plain("/x/a/inner"), home: Self.home)
        #expect(result == .success(.notText(from: .directory("/x/a"))))
    }

    @Test("row 11: figma.folders that is not an object is reported by the strict form")
    func row11FoldersNotObjectStrict() {
        for folders in [5, "text", [1, 2], true] as [Any] {
            let root: [String: Any] = ["figma": ["folders": folders, "defaultFolder": Self.linkA]]
            let result = FigmaFolderChoice.strict(root: root, forms: Self.plain("/x/a"), home: Self.home)
            #expect(result == .failure(.foldersNotObject), "folders = \(folders)")
        }
    }

    @Test("row 11: figma.folders that is not an object reads as no entries in the lenient form")
    func row11FoldersNotObjectLenient() {
        for folders in [5, "text", [1, 2], true] as [Any] {
            let decoded = FigmaFolderEntries.decodeFromJSON(folders)
            #expect(decoded == nil, "folders = \(folders)")
            let result = Self.answer(Self.plain("/x/a"), decoded ?? .empty)
            #expect(result == .folder(Self.link(Self.linkA), from: .default), "folders = \(folders)")
        }
    }

    @Test("row 11: null or absent figma.folders is no entries in the strict form")
    func row11NullFoldersStrict() {
        let withNull: [String: Any] = ["figma": ["folders": NSNull(), "defaultFolder": Self.linkA]]
        let absent: [String: Any] = ["figma": ["defaultFolder": Self.linkA]]
        for root in [withNull, absent] {
            let result = FigmaFolderChoice.strict(root: root, forms: Self.plain("/x/a"), home: Self.home)
            #expect(result == .success(.folder(Self.link(Self.linkA), from: .default)))
        }
    }

    // MARK: - Row 12: /

    @Test("row 12: / as a key answers for every directory, and loses to any longer key")
    func row12RootKey() {
        let rootOnly = Self.entries(["/": .link(Self.linkB)])
        #expect(Self.answer(Self.plain("/x/a/inner"), rootOnly) == Self.folder(Self.linkB, from: "/"))
        #expect(Self.answer(Self.plain("/"), rootOnly) == Self.folder(Self.linkB, from: "/"))
        let both = Self.entries(["/": .link(Self.linkB), "/x": .link(Self.linkC)])
        #expect(Self.answer(Self.plain("/x/a"), both) == Self.folder(Self.linkC, from: "/x"))
    }

    // MARK: - Row 13: the shell form

    @Test("row 13: a path through a symlink answers by its shell form; with only the resolved form it gives the default")
    func row13ShellForm() {
        let entries = Self.entries(["/x/a": .link(Self.linkB)])
        let throughLink = FigmaFolderPath.Forms(shell: "/x/a/out/inner", resolved: "/x/b/inner")
        #expect(Self.answer(throughLink, entries) == Self.folder(Self.linkB, from: "/x/a"))
        let resolvedOnly = Self.plain("/x/b/inner")
        #expect(Self.answer(resolvedOnly, entries) == .folder(Self.link(Self.linkA), from: .default))
    }

    // MARK: - Row 14: one bad value hides nothing

    @Test("row 14: a value that is not text under one key hides no other entry, strict and lenient")
    func row14OneBadValueHidesNothing() throws {
        let json = #"{"/x/a": "\#(Self.linkB)", "/x/z": 7}"#
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let decoded = try #require(FigmaFolderEntries.decodeFromJSON(object))
        #expect(decoded.entries["/x/z"] == .notText(rawJSON: "7"))
        #expect(Self.answer(Self.plain("/x/a/inner"), decoded) == Self.folder(Self.linkB, from: "/x/a"))

        let root: [String: Any] = ["figma": ["folders": object, "defaultFolder": Self.linkA]]
        let strict = FigmaFolderChoice.strict(root: root, forms: Self.plain("/x/a/inner"), home: Self.home)
        #expect(strict == .success(Self.folder(Self.linkB, from: "/x/a")))

        // The entry that is not text comes back as it was read.
        let written = try #require(decoded.encodeForJSON() as? [String: Any])
        #expect(written["/x/z"] as? Int == 7)
        #expect(written["/x/a"] as? String == Self.linkB)
    }

    @Test("row 14: every kind of value that is not text is kept raw")
    func row14RawKinds() throws {
        let json = #"{"a": null, "b": 7, "c": true, "d": [1, "x"], "e": {"k": "v"}, "f": 1.5}"#
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let decoded = try #require(FigmaFolderEntries.decodeFromJSON(object))
        #expect(decoded.entries.count == 6)
        for entry in decoded.entries.values {
            guard case .notText = entry else {
                Issue.record("expected notText, got \(entry)")
                continue
            }
        }
        let written = try #require(decoded.encodeForJSON() as? NSDictionary)
        #expect(written == (object as? NSDictionary))
    }

    // MARK: - Row 15: nearest across the two forms

    @Test("row 15: the nearer key answers whichever form it matched in")
    func row15NearestAcrossForms() {
        let entries = Self.entries(["/x/a": .link(Self.linkB), "/x/b": .link(Self.linkC)])
        // /x/a matches the shell form 3 parts away; /x/b matches the resolved form 1 part away.
        let nearer = FigmaFolderPath.Forms(shell: "/x/a/1/2/3", resolved: "/x/b/1")
        #expect(Self.answer(nearer, entries) == Self.folder(Self.linkC, from: "/x/b"))
    }

    @Test("row 15: at equal distance the key that matched the shell form answers")
    func row15EqualDistanceShellWins() {
        let entries = Self.entries(["/x/a": .link(Self.linkB), "/x/b": .link(Self.linkC)])
        let tied = FigmaFolderPath.Forms(shell: "/x/a/1/2", resolved: "/x/b/1/2")
        #expect(Self.answer(tied, entries) == Self.folder(Self.linkB, from: "/x/a"))
    }

    @Test("row 15: a longer key is nearer than a shorter one in the same form, by parts between")
    func row15PartsBetweenNotKeyLength() {
        // /x/aaaa has more parts than /y but is not nearer to /x/aaaa/1/2/3 in text length terms:
        // what counts is the parts between the key and the directory.
        let entries = Self.entries(["/x": .link(Self.linkC), "/x/aaaa": .link(Self.linkB)])
        #expect(Self.answer(Self.plain("/x/aaaa/1/2/3"), entries) == Self.folder(Self.linkB, from: "/x/aaaa"))
        // Across forms, the key with the longer path is farther when its directory is deeper.
        let across = Self.entries(["/p/q/r": .link(Self.linkB), "/s": .link(Self.linkC)])
        let forms = FigmaFolderPath.Forms(shell: "/p/q/r/1/2/3/4", resolved: "/s/1")
        #expect(Self.answer(forms, across) == Self.folder(Self.linkC, from: "/s"))
    }
}
