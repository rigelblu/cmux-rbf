import Foundation
import Testing
@testable import CmuxSettings

/// `FigmaFolders.plan`: what `set` or `clear` for one directory writes. The
/// menu's two actions and the command both go through it (cm-73.42, Scenario 371).
@Suite("FigmaFoldersPlan")
struct FigmaFoldersPlanTests {

    static let linkA = FigmaFolderChoiceTests.linkA
    static let linkB = FigmaFolderChoiceTests.linkB
    static let linkC = FigmaFolderChoiceTests.linkC
    static let home = FigmaFolderChoiceTests.home

    static func link(_ text: String) -> FigmaFolderLink { FigmaFolderChoiceTests.link(text) }

    static func plan(
        _ change: FigmaFolders.Change,
        _ directory: String,
        _ entries: KeyValuePairs<String, FigmaFolderEntries.Entry>
    ) -> FigmaFolders.Plan {
        FigmaFolders.plan(
            change,
            directory: directory,
            entries: FigmaFolderChoiceTests.entries(entries),
            home: home
        )
    }

    static func written(_ pairs: KeyValuePairs<String, FigmaFolderEntries.Entry>) -> FigmaFolders.Plan {
        .write(FigmaFolderChoiceTests.entries(pairs))
    }

    // MARK: - set

    @Test("set adds the key with the trimmed link and keeps every other entry")
    func setAddsAndKeepsOthers() {
        let result = Self.plan(
            .set(Self.link("  \(Self.linkB)?fuid=1  ")),
            "/x/a",
            ["/x/b": .link(Self.linkC), "/x/z": .notText(rawJSON: "7")]
        )
        #expect(result == Self.written([
            "/x/a": .link(Self.linkB),
            "/x/b": .link(Self.linkC),
            "/x/z": .notText(rawJSON: "7")
        ]))
    }

    @Test("set writes over a value there that is broken or not text")
    func setWritesOverBrokenValue() {
        let over = Self.plan(.set(Self.link(Self.linkB)), "/x/a", ["/x/a": .link(Self.noTeamText)])
        #expect(over == Self.written(["/x/a": .link(Self.linkB)]))
        let notText = Self.plan(.set(Self.link(Self.linkB)), "/x/a", ["/x/a": .notText(rawJSON: "null")])
        #expect(notText == Self.written(["/x/a": .link(Self.linkB)]))
    }

    static let noTeamText = FigmaFolderChoiceTests.noTeam

    @Test("set over a figma.folders that is not an object writes a fresh object")
    func setOverNonObject() {
        let entries = FigmaFolderEntries.decodeFromJSON(5) ?? .empty
        let result = FigmaFolders.plan(
            .set(Self.link(Self.linkB)),
            directory: "/x/a",
            entries: entries,
            home: Self.home
        )
        #expect(result == Self.written(["/x/a": .link(Self.linkB)]))
    }

    @Test("set of the link already stored plans nothing")
    func setOfStoredLinkPlansNothing() {
        let result = Self.plan(.set(Self.link(Self.linkB)), "/x/a", ["/x/a": .link(Self.linkB), "/x/b": .link(Self.linkC)])
        #expect(result == .nothing)
    }

    @Test("set of the link already stored still removes a second key for the same directory")
    func setOfStoredLinkWithDuplicateKey() {
        let result = Self.plan(
            .set(Self.link(Self.linkB)),
            "/x/a",
            ["/x/a": .link(Self.linkB), "/x/q/../a": .link(Self.linkC)]
        )
        #expect(result == Self.written(["/x/a": .link(Self.linkB)]))
    }

    // MARK: - clear

    @Test("clear removes that key only, never a parent's")
    func clearRemovesThatKeyOnly() {
        let result = Self.plan(.clear, "/x/a", ["/x/a": .link(Self.linkB), "/x": .link(Self.linkC)])
        #expect(result == Self.written(["/x": .link(Self.linkC)]))
    }

    @Test("clear of the last key removes figma.folders")
    func clearLastKey() {
        let result = Self.plan(.clear, "/x/a", ["/x/a": .link(Self.linkB)])
        #expect(result == .removeAll)
    }

    @Test("clear with no such key plans nothing")
    func clearWithNoKey() {
        #expect(Self.plan(.clear, "/x/a", ["/x": .link(Self.linkC)]) == .nothing)
        #expect(Self.plan(.clear, "/x/a", [:]) == .nothing)
    }

    @Test("clear removes every key that resolves to the directory, not a longer or shorter one")
    func clearRemovesAllSpellingsOfOneDirectory() {
        let result = Self.plan(
            .clear,
            "/x/a",
            ["/x/a": .link(Self.linkB), "/x/q/../a": .link(Self.linkC), "/x/a/inner": .link(Self.linkA)]
        )
        #expect(result == Self.written(["/x/a/inner": .link(Self.linkA)]))
    }

    // MARK: - two spellings of one directory

    @Test("a symlink spelling and the resolved path plan the same key, and set removes the hand-written symlink key")
    func symlinkSpellingsPlanOneKey() throws {
        let root = try FigmaFolderChoiceTests.scratch()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: "\(root)/a", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: "\(root)/ln-a", withDestinationPath: "\(root)/a")

        let throughLink = FigmaFolderPath.forms(of: "\(root)/ln-a", home: Self.home)
        let direct = FigmaFolderPath.forms(of: "\(root)/a", home: Self.home)
        #expect(throughLink.resolved == direct.resolved)

        let entries = FigmaFolderChoiceTests.entries(["\(root)/ln-a": .link(Self.linkC)])
        let viaLink = FigmaFolders.plan(.set(Self.link(Self.linkB)), directory: throughLink.resolved, entries: entries, home: Self.home)
        let viaPath = FigmaFolders.plan(.set(Self.link(Self.linkB)), directory: direct.resolved, entries: entries, home: Self.home)
        #expect(viaLink == viaPath)
        #expect(viaLink == Self.written(["\(root)/a": .link(Self.linkB)]))

        let cleared = FigmaFolders.plan(.clear, directory: direct.resolved, entries: entries, home: Self.home)
        #expect(cleared == .removeAll)
    }

    // MARK: - another directory's entry that is not text survives

    @Test("another directory's entry that is not text survives a set and a clear for this one, same JSON value")
    func entryThatIsNotTextSurvives() throws {
        let object = try JSONSerialization.jsonObject(
            with: Data(#"{"/x/z": {"k": [1, null, "v"]}, "/x/y": null, "/x/a": "\#(Self.linkC)"}"#.utf8)
        )
        let entries = try #require(FigmaFolderEntries.decodeFromJSON(object))

        for change in [FigmaFolders.Change.set(Self.link(Self.linkB)), .clear] {
            let plan = FigmaFolders.plan(change, directory: "/x/a", entries: entries, home: Self.home)
            let after = FigmaFolders.entries(after: plan, from: entries)
            let json = try #require(after.encodeForJSON() as? NSDictionary)
            let original = try #require(object as? NSDictionary)
            #expect(json["/x/z"] as? NSDictionary == original["/x/z"] as? NSDictionary, "\(change)")
            #expect(json["/x/y"] is NSNull, "\(change)")
        }
    }

    // MARK: - the write, through a real store

    @Test("apply writes siblings of figma.folders untouched, and removes figma.folders for the last key")
    func applyThroughStore() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("figma-plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("cmux.json")
        try Data(#"{"zz_keep": {"b": 2}, "figma": {"defaultFolder": "\#(Self.linkA)", "showFileNameInHeader": false}}"#.utf8)
            .write(to: file)
        let store = JSONConfigStore(fileURL: file)

        let setPlan = Self.plan(.set(Self.link(Self.linkB)), "/x/a", [:])
        try await FigmaFolders.apply(setPlan, to: store)
        var root = try store.strictRoot()
        let figma = try #require(root["figma"] as? [String: Any])
        #expect((figma["folders"] as? [String: Any])?["/x/a"] as? String == Self.linkB)
        #expect(figma["defaultFolder"] as? String == Self.linkA)
        #expect(figma["showFileNameInHeader"] as? Bool == false)
        #expect((root["zz_keep"] as? [String: Any])?["b"] as? Int == 2)

        try await FigmaFolders.apply(.removeAll, to: store)
        root = try store.strictRoot()
        let after = try #require(root["figma"] as? [String: Any])
        #expect(after["folders"] == nil)
        #expect(after["defaultFolder"] as? String == Self.linkA)
        #expect(after["showFileNameInHeader"] as? Bool == false)
    }

    @Test("apply writes a fresh object over a figma.folders that is not an object")
    func applyOverNonObject() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("figma-plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("cmux.json")
        try Data(#"{"figma": {"folders": 5, "defaultFolder": "\#(Self.linkA)"}}"#.utf8).write(to: file)
        let store = JSONConfigStore(fileURL: file)

        try await FigmaFolders.apply(Self.plan(.set(Self.link(Self.linkB)), "/x/a", [:]), to: store)
        let figma = try #require(try store.strictRoot()["figma"] as? [String: Any])
        #expect((figma["folders"] as? [String: Any])?["/x/a"] as? String == Self.linkB)
        #expect(figma["defaultFolder"] as? String == Self.linkA)
    }
}
