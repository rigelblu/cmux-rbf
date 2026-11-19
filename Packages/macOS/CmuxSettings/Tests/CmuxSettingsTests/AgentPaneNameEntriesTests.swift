import Foundation
import Testing
@testable import CmuxSettings

/// cm-126.15: `agentPane.names`, what the file holds and what a reader gets from it.
@Suite("AgentPaneNameEntries")
struct AgentPaneNameEntriesTests {
    private static func decode(_ json: String) -> AgentPaneNameEntries? {
        let raw = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
        return AgentPaneNameEntries.decodeFromJSON(raw)
    }

    @Test("text entries are kept and usable")
    func textEntriesAreUsable() {
        let entries = Self.decode(#"{"claude": "wg-still Outie", "*": "Agent Outie"}"#)
        #expect(entries?.usableNames == ["claude": "wg-still Outie", "*": "Agent Outie"])
    }

    @Test("a value that is not text, or is empty once trimmed, is skipped and the others hold")
    func badValuesAreSkippedOthersHold() {
        let entries = Self.decode(#"{"claude": 5, "codex": "  ", "gemini": "", "agy": null, "kimi": ["x"], "grok": "Grok Outie"}"#)
        #expect(entries?.usableNames == ["grok": "Grok Outie"])
        // Each skipped value is still held raw, so a write for one key never deletes another's.
        #expect(entries?.entries.count == 6)
        #expect(entries?.entries["claude"] == .notText(rawJSON: "5"))
    }

    @Test("a key that is empty once trimmed names no agent")
    func emptyKeyIsSkipped() {
        let entries = Self.decode(#"{"": "Nobody", "  ": "Nobody", "claude": "Outie"}"#)
        #expect(entries?.usableNames == ["claude": "Outie"])
    }

    @Test("keys are compared lowercased and trimmed, names are trimmed")
    func keysAreNormalized() {
        let entries = Self.decode(#"{" Claude ": "  Outie  "}"#)
        #expect(entries?.usableNames == ["claude": "Outie"])
    }

    @Test("a names that is not an object gives no entries at all")
    func nonObjectGivesNil() {
        #expect(Self.decode(#"["claude"]"#) == nil)
        #expect(Self.decode(#""claude""#) == nil)
        #expect(Self.decode("5") == nil)
    }

    @Test("an encode and decode round trip keeps every entry")
    func roundTrip() {
        let entries = Self.decode(#"{"claude": "A", "codex": 7}"#)
        let again = AgentPaneNameEntries.decodeFromJSON(entries?.encodeForJSON())
        #expect(again == entries)
    }

    @Test("the catalog registers agentPane.names, and the store reads it from the file")
    func storeReadsTheKeyFromTheFile() throws {
        let key = SettingCatalog().agentPane.names
        #expect(key.id == "agentPane.names")
        #expect(SettingCatalog().all.contains { $0.id == "agentPane.names" })

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agentpane-names-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("cmux.json")
        try Data(#"{"agentPane": {"names": {"claude": "wg-still Outie", "codex": 5}}}"#.utf8).write(to: file)
        let store = JSONConfigStore(fileURL: file)
        #expect(store.snapshotValue(for: key).usableNames == ["claude": "wg-still Outie"])

        let notAnObject = dir.appendingPathComponent("other.json")
        try Data(#"{"agentPane": {"names": "claude"}}"#.utf8).write(to: notAnObject)
        #expect(JSONConfigStore(fileURL: notAnObject).snapshotValue(for: key).usableNames.isEmpty)
    }
}
