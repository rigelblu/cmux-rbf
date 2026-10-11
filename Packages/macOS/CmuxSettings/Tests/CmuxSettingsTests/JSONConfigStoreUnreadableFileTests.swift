import Foundation
import Testing
@testable import CmuxSettings

// cm-119.1: a save through the store must never replace a cmux.json it cannot
// read. Every test makes its own temp directory and never touches the user's
// real ~/.config/cmux/cmux.json.

/// The longest a test waits on a file-watcher signal. A bound only: a passing
/// run returns as soon as the signal arrives.
private let signalBound: Double = 15

/// An object that is never closed: the probe's file.
private let brokenJSON = #"{ "sidebar": { "width": 240 }, "figma": "#
private let validJSON = #"{"sidebar":{"width":240}}"#
private let socketPasswordKey = JSONKey<String>(id: "automation.socketPassword", defaultValue: "")

private struct Fixture {
    let dir: URL
    let fileURL: URL
    let store: JSONConfigStore

    func remove() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }
}

/// Writes `initial` (when given) before the store exists, so the store's file
/// watcher does not hold an event for the setup write.
private func makeFixture(_ initial: Data? = nil) throws -> Fixture {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("cmux-settings-unreadable-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fileURL = dir.appendingPathComponent("cmux.json", isDirectory: false)
    if let initial { try initial.write(to: fileURL) }
    return Fixture(dir: dir, fileURL: fileURL, store: JSONConfigStore(fileURL: fileURL))
}

private func makeFixture(_ initial: String) throws -> Fixture {
    try makeFixture(Data(initial.utf8))
}

private enum ParseFailure: Error { case notAnObject }

private func parsedRoot(at url: URL) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    guard let root = object as? [String: Any] else { throw ParseFailure.notAnObject }
    return root
}

private func socketPassword(in root: [String: Any]) -> String? {
    (root["automation"] as? [String: Any])?["socketPassword"] as? String
}

private func sidebarWidth(in root: [String: Any]) -> Int? {
    ((root["sidebar"] as? [String: Any])?["width"] as? NSNumber)?.intValue
}

private func permissions(of url: URL) throws -> Int? {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
}

/// What the system says for a file in the wrong format at this path.
private func fileSentence(for url: URL) -> String {
    CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path]).localizedDescription
}

/// Runs one `set` and returns what it threw. Records an issue and returns nil
/// when it threw nothing, so a store that does not refuse fails here and not
/// later on a comparison. `do`/`catch` and not the value `#expect(throws:)`
/// returns, which older toolchains do not have.
private func errorFromSave(
    on store: JSONConfigStore,
    sourceLocation: SourceLocation = #_sourceLocation
) async -> (any Error)? {
    do {
        try await store.set("x", for: socketPasswordKey)
        Issue.record("set did not throw", sourceLocation: sourceLocation)
        return nil
    } catch {
        return error
    }
}

/// Waits for the first signal on `stream`; false when the bound passes first.
private func waitForSignal(_ stream: AsyncStream<Void>) async -> Bool {
    await withTimeout(seconds: signalBound) {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next() != nil
    }
}

struct UnreadableFile: Sendable, CustomTestStringConvertible {
    let label: String
    let bytes: Data
    /// Mode `000`: the file is valid but the owner may not open it.
    var denyAllAccess = false
    /// The cause is Foundation's JSON syntax error (`NSCocoaErrorDomain` 3840).
    var causeIsJSONSyntaxError = false

    var testDescription: String { label }

    static let kinds: [UnreadableFile] = [
        UnreadableFile(label: "array", bytes: Data("[1, 2]".utf8)),
        UnreadableFile(label: "string", bytes: Data(#""text""#.utf8)),
        UnreadableFile(label: "unclosed comment", bytes: Data("{ /* never closed".utf8)),
        UnreadableFile(label: "line break only", bytes: Data("\n".utf8)),
        UnreadableFile(label: "not UTF-8, no byte-order mark", bytes: Data([0xC3, 0x28])),
        UnreadableFile(label: "UTF-16 mark, then one stray byte", bytes: Data([0xFF, 0xFE, 0x7B])),
        UnreadableFile(label: "valid, mode 000", bytes: Data(validJSON.utf8), denyAllAccess: true),
    ]

    /// The parse failures of the expected-results table, plus mode `000`.
    static let sentenceKinds: [UnreadableFile] = [
        UnreadableFile(label: "cut off mid-object", bytes: Data(brokenJSON.utf8), causeIsJSONSyntaxError: true),
        UnreadableFile(label: "missing quote", bytes: Data(#"{ "a": 1, b": 2 }"#.utf8), causeIsJSONSyntaxError: true),
        UnreadableFile(label: "array", bytes: Data("[1, 2]".utf8)),
        UnreadableFile(label: "string", bytes: Data(#""text""#.utf8), causeIsJSONSyntaxError: true),
        UnreadableFile(label: "spaces and a line break", bytes: Data("  \n".utf8), causeIsJSONSyntaxError: true),
        UnreadableFile(label: "unclosed comment", bytes: Data("{ /* never closed".utf8)),
        UnreadableFile(label: "not UTF-8, no byte-order mark", bytes: Data([0xC3, 0x28])),
        UnreadableFile(label: "UTF-16 mark, then one stray byte", bytes: Data([0xFF, 0xFE, 0x7B])),
        UnreadableFile(label: "valid, mode 000", bytes: Data(validJSON.utf8), denyAllAccess: true),
    ]
}

enum RetargetedTo: String, Sendable, CaseIterable, CustomTestStringConvertible {
    case missingFile
    case zeroByteFile

    var testDescription: String { rawValue }
}

@Suite("JSONConfigStore unreadable file")
struct JSONConfigStoreUnreadableFileTests {

    // MARK: - A save on a file that cannot be read is refused

    /// Scenario 2.
    @Test func setAfterReadIsRefused() async throws {
        let fixture = try makeFixture(brokenJSON)
        defer { fixture.remove() }
        let store = fixture.store

        let before = await store.value(for: socketPasswordKey)
        await #expect(throws: (any Error).self) { try await store.set("x", for: socketPasswordKey) }

        #expect(try Data(contentsOf: fixture.fileURL) == Data(brokenJSON.utf8))
        #expect(await store.value(for: socketPasswordKey) == before)
    }

    /// Scenario 3.
    @Test func setAfterStreamValueIsRefused() async throws {
        let fixture = try makeFixture(brokenJSON)
        defer { fixture.remove() }
        let store = fixture.store

        let first = await withTimeout(seconds: signalBound) {
            var iterator = store.values(for: socketPasswordKey).makeAsyncIterator()
            return await iterator.next()
        }
        #expect(first == "")
        await #expect(throws: (any Error).self) { try await store.set("x", for: socketPasswordKey) }

        #expect(try Data(contentsOf: fixture.fileURL) == Data(brokenJSON.utf8))
    }

    /// Scenario 4.
    @Test func resetAfterReadIsRefused() async throws {
        let fixture = try makeFixture(brokenJSON)
        defer { fixture.remove() }
        let store = fixture.store

        _ = await store.value(for: socketPasswordKey)
        await #expect(throws: (any Error).self) { try await store.reset(socketPasswordKey) }

        #expect(try Data(contentsOf: fixture.fileURL) == Data(brokenJSON.utf8))
    }

    /// Scenario 5. The running app's case: valid file, a typo saved from an
    /// editor, the watcher fires, subscribers read again, then a setting changes.
    @Test func setAfterObservedBreakIsRefused() async throws {
        let fixture = try makeFixture(#"{"automation":{"socketPassword":"before"}}"#)
        defer { fixture.remove() }
        let store = fixture.store

        let (ready, readyContinuation) = AsyncStream<Void>.makeStream()
        let (brokenSeen, brokenSeenContinuation) = AsyncStream<Void>.makeStream()
        let observer = Task {
            for await value in store.values(for: socketPasswordKey) {
                if value == "before" { readyContinuation.yield() }
                if value == "" {
                    brokenSeenContinuation.yield()
                    break
                }
            }
        }
        #expect(await waitForSignal(ready), "the observer never saw the first value")

        let writer = retouchingWriter(payload: brokenJSON, fileURL: fixture.fileURL)
        let sawBroken = await waitForSignal(brokenSeen)
        writer.cancel()
        await writer.value
        observer.cancel()
        await observer.value
        #expect(sawBroken, "the stream never yielded the default after the file broke")

        // Read right before the save so the store has read the broken file
        // whatever a late file event did to its cache.
        _ = await store.value(for: socketPasswordKey)
        await #expect(throws: (any Error).self) { try await store.set("x", for: socketPasswordKey) }

        #expect(try Data(contentsOf: fixture.fileURL) == Data(brokenJSON.utf8))
    }

    /// Scenario 6. The case that separates a write that always reads the file
    /// from one that trusts a valid cache: valid cache, broken file, no event handled.
    ///
    /// The file holds a value for the key, so the read after the refusal also
    /// shows that a refused save changes nothing the store remembers (R16): it
    /// still returns that value, not the default. Added after the code review.
    @Test func setAfterUnobservedBreakIsRefused() async throws {
        let fixture = try makeFixture(#"{"automation":{"socketPassword":"before"},"sidebar":{"width":240}}"#)
        defer { fixture.remove() }
        let store = fixture.store

        #expect(await store.value(for: socketPasswordKey) == "before")
        try Data(brokenJSON.utf8).write(to: fixture.fileURL)
        await #expect(throws: (any Error).self) { try await store.set("x", for: socketPasswordKey) }

        #expect(try Data(contentsOf: fixture.fileURL) == Data(brokenJSON.utf8))
        #expect(await store.value(for: socketPasswordKey) == "before")
    }

    /// Scenario 7. The two calls `DevWindowDisplayDefault.migrateLegacyFileIfNeeded`
    /// makes, with its error swallowed. A control on those calls, not coverage of
    /// the function.
    @Test func launchMigrationCallsLeaveTheFile() async throws {
        let fixture = try makeFixture(brokenJSON)
        defer { fixture.remove() }
        let store = fixture.store
        let key = SettingCatalog().app.devWindowDisplay

        _ = await store.value(for: key)
        try? await store.set("LG HDR 4K", for: key)

        #expect(try Data(contentsOf: fixture.fileURL) == Data(brokenJSON.utf8))
    }

    /// Scenario 8. The loop of `ResetSection.swift`: `resetInJSON` on every key.
    @Test func resetAllLoopLeavesTheFile() async throws {
        let fixture = try makeFixture(brokenJSON)
        defer { fixture.remove() }
        let store = fixture.store

        _ = await store.value(for: socketPasswordKey)
        for key in SettingCatalog().all {
            await key.resetInJSON(store)
        }

        #expect(try Data(contentsOf: fixture.fileURL) == Data(brokenJSON.utf8))
    }

    /// Scenario 9.
    @Test(arguments: UnreadableFile.kinds)
    func everyKindOfUnreadableFileIsRefused(_ file: UnreadableFile) async throws {
        let fixture = try makeFixture(file.bytes)
        defer { fixture.remove() }
        let store = fixture.store
        if file.denyAllAccess {
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.fileURL.path)
        }
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.fileURL.path)
        }

        _ = await store.value(for: socketPasswordKey)
        await #expect(throws: (any Error).self) { try await store.set("x", for: socketPasswordKey) }

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.fileURL.path)
        #expect(try Data(contentsOf: fixture.fileURL) == file.bytes)
    }

    /// Scenario 25. A control: the store already refuses with no read first.
    @Test func setWithNoReadFirstIsRefused() async throws {
        let fixture = try makeFixture(brokenJSON)
        defer { fixture.remove() }
        let store = fixture.store

        await #expect(throws: (any Error).self) { try await store.set("x", for: socketPasswordKey) }

        #expect(try Data(contentsOf: fixture.fileURL) == Data(brokenJSON.utf8))
    }

    // MARK: - The save works again

    /// Scenario 10.
    @Test func saveWorksAgainAfterTheFileIsFixed() async throws {
        let fixture = try makeFixture(brokenJSON)
        defer { fixture.remove() }
        let store = fixture.store

        _ = await store.value(for: socketPasswordKey)
        await #expect(throws: (any Error).self) { try await store.set("x", for: socketPasswordKey) }

        try Data(validJSON.utf8).write(to: fixture.fileURL)
        try await store.set("x", for: socketPasswordKey)

        let root = try parsedRoot(at: fixture.fileURL)
        #expect(sidebarWidth(in: root) == 240)
        #expect(socketPassword(in: root) == "x")
    }

    // MARK: - A valid, empty or missing file still saves

    /// Scenario 12. A control; its proof is a mutation.
    @Test func validFileSavesAndKeepsItsKeysAndMode() async throws {
        let fixture = try makeFixture(validJSON)
        defer { fixture.remove() }
        let store = fixture.store
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.fileURL.path)

        _ = await store.value(for: socketPasswordKey)
        try await store.set("x", for: socketPasswordKey)

        let root = try parsedRoot(at: fixture.fileURL)
        #expect(sidebarWidth(in: root) == 240)
        #expect(socketPassword(in: root) == "x")
        #expect(try permissions(of: fixture.fileURL) == 0o600)
    }

    /// Scenario 13. A control: zero bytes is an empty settings file, not a broken one.
    @Test func emptyFileIsNotRefused() async throws {
        let fixture = try makeFixture(Data())
        defer { fixture.remove() }
        let store = fixture.store

        _ = await store.value(for: socketPasswordKey)
        try await store.set("x", for: socketPasswordKey)

        let root = try parsedRoot(at: fixture.fileURL)
        #expect(Set(root.keys) == ["automation"])
        #expect(socketPassword(in: root) == "x")
    }

    /// Scenario 21 (R21). A valid edit another program made that the store was
    /// not told about is kept.
    @Test func saveKeepsAnUnseenEditFromAnotherWriter() async throws {
        let fixture = try makeFixture(validJSON)
        defer { fixture.remove() }
        let store = fixture.store

        _ = await store.value(for: socketPasswordKey)
        try Data(#"{"sidebar":{"width":300},"added":true}"#.utf8).write(to: fixture.fileURL)
        try await store.set("x", for: socketPasswordKey)

        let root = try parsedRoot(at: fixture.fileURL)
        #expect(sidebarWidth(in: root) == 300)
        #expect(root["added"] as? Bool == true)
        #expect(socketPassword(in: root) == "x")
    }

    // MARK: - The mode of the file

    /// Scenario 11.
    @Test func createdFileIsOwnerOnly() async throws {
        // (a) No file, and a store that has read nothing.
        let plain = try makeFixture()
        defer { plain.remove() }
        try await plain.store.set("x", for: socketPasswordKey)

        #expect(try permissions(of: plain.fileURL) == 0o600)
        let plainRoot = try parsedRoot(at: plain.fileURL)
        #expect(Set(plainRoot.keys) == ["automation"])
        #expect(socketPassword(in: plainRoot) == "x")

        // (b) cmux.json is a symlink to a target that does not exist yet.
        let linked = try makeFixture()
        defer { linked.remove() }
        let targetURL = linked.dir.appendingPathComponent("target.json", isDirectory: false)
        let linkURL = linked.dir.appendingPathComponent("linked-cmux.json", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
        let linkStore = JSONConfigStore(fileURL: linkURL)
        try await linkStore.set("x", for: socketPasswordKey)

        #expect(try permissions(of: targetURL) == 0o600)
        let targetRoot = try parsedRoot(at: targetURL)
        #expect(socketPassword(in: targetRoot) == "x")
        let linkType = try FileManager.default.attributesOfItem(atPath: linkURL.path)[.type] as? FileAttributeType
        #expect(linkType == .typeSymbolicLink)
    }

    /// Scenario 14. A control: a file that exists keeps its mode. `0640`, because
    /// `0644` is also what a new file gets.
    @Test func existingFileKeepsItsMode() async throws {
        let fixture = try makeFixture(validJSON)
        defer { fixture.remove() }
        let store = fixture.store
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: fixture.fileURL.path)

        try await store.set("x", for: socketPasswordKey)

        #expect(try permissions(of: fixture.fileURL) == 0o640)
    }

    // MARK: - The sentence, the path and the cause

    /// Scenario 16.
    @Test(arguments: UnreadableFile.sentenceKinds)
    func refusalReadsAsTheSystemFileSentence(_ file: UnreadableFile) async throws {
        let fixture = try makeFixture(file.bytes)
        defer { fixture.remove() }
        let store = fixture.store
        if file.denyAllAccess {
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.fileURL.path)
        }
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.fileURL.path)
        }

        _ = await store.value(for: socketPasswordKey)
        let thrown = await errorFromSave(on: store)
        let refusal = try #require(thrown)
        let nsError = refusal as NSError
        let cause = nsError.userInfo[NSUnderlyingErrorKey]
        print("cm-119 sentence [\(file.label)]: \(refusal.localizedDescription)")
        print("cm-119 cause [\(file.label)]: \(String(describing: cause ?? "none"))")

        if file.denyAllAccess {
            // Here the store rethrows the system's own read error, unwrapped: it
            // already names the file, so there is no wrapper path to compare and
            // the cause is the system's POSIX error. What is true is that the
            // description is exactly what reading the file gives, and that the
            // code is the system's "no permission".
            var expected = ""
            do { _ = try Data(contentsOf: fixture.fileURL) } catch { expected = error.localizedDescription }
            #expect(!expected.isEmpty)
            #expect(refusal.localizedDescription == expected)
            #expect(nsError.domain == NSCocoaErrorDomain)
            #expect(nsError.code == CocoaError.fileReadNoPermission.rawValue)
        } else {
            #expect(refusal.localizedDescription == fileSentence(for: fixture.fileURL))
            #expect(nsError.userInfo[NSFilePathErrorKey] as? String == fixture.fileURL.path)
            // The cause is attached. Its text is printed above for cm-119.2 and
            // is not compared: it is debug text and changes with the system.
            #expect(cause != nil)
            if file.causeIsJSONSyntaxError, let cause = cause as? NSError {
                #expect(cause.domain == NSCocoaErrorDomain)
                #expect(cause.code == 3840)
            } else if file.causeIsJSONSyntaxError {
                Issue.record("the cause of a JSON syntax error is not an NSError")
            }
        }
    }

    /// Added after the code review (R13). `cmux.json` is a symlink
    /// to a differently named file that cannot be read: the save is refused, the
    /// target keeps its bytes, the link stays a link, and the error names the
    /// file that was read, not the link.
    @Test func refusalThroughASymlinkNamesTheTarget() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let targetURL = fixture.dir.appendingPathComponent("dotfiles-settings.json", isDirectory: false)
        let linkURL = fixture.dir.appendingPathComponent("linked-cmux.json", isDirectory: false)
        try Data(brokenJSON.utf8).write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
        let store = JSONConfigStore(fileURL: linkURL)
        let resolvedTarget = targetURL.resolvingSymlinksInPath()

        _ = await store.value(for: socketPasswordKey)
        let thrown = await errorFromSave(on: store)
        let refusal = try #require(thrown)

        #expect(try Data(contentsOf: targetURL) == Data(brokenJSON.utf8))
        let linkType = try FileManager.default.attributesOfItem(atPath: linkURL.path)[.type] as? FileAttributeType
        #expect(linkType == .typeSymbolicLink)
        #expect((refusal as NSError).userInfo[NSFilePathErrorKey] as? String == resolvedTarget.path)
        #expect(refusal.localizedDescription == fileSentence(for: resolvedTarget))
    }

    // MARK: - The rule for a missing or empty file (R22, R26, R27)

    /// Scenario 22 (R22). A control that pins Tom's decision. Its proof is a
    /// mutation: without the missing-or-empty rule this fails on the sidebar check.
    @Test func saveOverAnUnseenEmptiedFileKeepsTheRememberedSettings() async throws {
        let fixture = try makeFixture(validJSON)
        defer { fixture.remove() }
        let store = fixture.store

        _ = await store.value(for: socketPasswordKey)
        try Data().write(to: fixture.fileURL)
        try await store.set("x", for: socketPasswordKey)

        let root = try parsedRoot(at: fixture.fileURL)
        #expect(sidebarWidth(in: root) == 240)
        #expect(socketPassword(in: root) == "x")
    }

    /// Scenario 23 (R22). The same, for a file another program deleted.
    @Test func saveOverAnUnseenDeletedFileKeepsTheRememberedSettings() async throws {
        let fixture = try makeFixture(validJSON)
        defer { fixture.remove() }
        let store = fixture.store

        _ = await store.value(for: socketPasswordKey)
        try FileManager.default.removeItem(at: fixture.fileURL)
        try await store.set("x", for: socketPasswordKey)

        let root = try parsedRoot(at: fixture.fileURL)
        #expect(sidebarWidth(in: root) == 240)
        #expect(socketPassword(in: root) == "x")
        // The store created the file, so it owns the mode.
        #expect(try permissions(of: fixture.fileURL) == 0o600)
    }

    /// Scenario 27 (R26). A real, deliberate `{}` is believed.
    @Test func saveOverAnUnseenEmptyObjectIsBelieved() async throws {
        let fixture = try makeFixture(validJSON)
        defer { fixture.remove() }
        let store = fixture.store

        _ = await store.value(for: socketPasswordKey)
        try Data("{}".utf8).write(to: fixture.fileURL)
        try await store.set("x", for: socketPasswordKey)

        let root = try parsedRoot(at: fixture.fileURL)
        #expect(Set(root.keys) == ["automation"])
        #expect(socketPassword(in: root) == "x")
    }

    /// Scenario 28 (R27). A control: once the store has been told the file was
    /// deleted, a save writes a one-key file. No one-line change to the rule
    /// makes this fail; it guards against a rule that remembers across a reload.
    @Test func saveAfterAnObservedDeletionWritesOneKey() async throws {
        let fixture = try makeFixture(#"{"automation":{"socketPassword":"before"},"sidebar":{"width":240}}"#)
        defer { fixture.remove() }
        let store = fixture.store

        let (ready, readyContinuation) = AsyncStream<Void>.makeStream()
        let (deletionSeen, deletionSeenContinuation) = AsyncStream<Void>.makeStream()
        let observer = Task {
            for await value in store.values(for: socketPasswordKey) {
                if value == "before" { readyContinuation.yield() }
                if value == "" {
                    deletionSeenContinuation.yield()
                    break
                }
            }
        }
        #expect(await waitForSignal(ready), "the observer never saw the first value")

        try FileManager.default.removeItem(at: fixture.fileURL)
        let sawDeletion = await waitForSignal(deletionSeen)
        observer.cancel()
        await observer.value
        #expect(sawDeletion, "the stream never yielded the default after the file was deleted")

        _ = await store.value(for: socketPasswordKey)
        try await store.set("x", for: socketPasswordKey)

        let root = try parsedRoot(at: fixture.fileURL)
        #expect(Set(root.keys) == ["automation"])
        #expect(socketPassword(in: root) == "x")
    }

    /// Scenario 29. A control that pins the same-path term of the rule: a link
    /// retargeted to a missing or zero-byte file does not get the old target's
    /// settings. Its proof is a mutation: with `cacheValid` in place of
    /// `cacheIsCurrent(for: writeURL.path)` in the rule, it fails.
    @Test(arguments: RetargetedTo.allCases)
    func retargetedLinkDoesNotCarryTheOldTargetsSettings(_ retargetedTo: RetargetedTo) async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let targetA = fixture.dir.appendingPathComponent("a.json", isDirectory: false)
        let targetB = fixture.dir.appendingPathComponent("b.json", isDirectory: false)
        let linkURL = fixture.dir.appendingPathComponent("linked-cmux.json", isDirectory: false)
        try Data(validJSON.utf8).write(to: targetA)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetA)
        let store = JSONConfigStore(fileURL: linkURL)

        _ = await store.value(for: socketPasswordKey)
        try FileManager.default.removeItem(at: linkURL)
        if retargetedTo == .zeroByteFile { try Data().write(to: targetB) }
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetB)
        try await store.set("x", for: socketPasswordKey)

        let rootB = try parsedRoot(at: targetB)
        #expect(Set(rootB.keys) == ["automation"])
        #expect(socketPassword(in: rootB) == "x")
        #expect(try Data(contentsOf: targetA) == Data(validJSON.utf8))
        let linkType = try FileManager.default.attributesOfItem(atPath: linkURL.path)[.type] as? FileAttributeType
        #expect(linkType == .typeSymbolicLink)
    }
}
