import CmuxSettings
import Foundation
import Testing

@testable import CmuxSettingsUI

/// The effects the Figma Default Folder row asks for, applied through a real
/// ``JSONValueModel`` that is observing a ``JSONConfigStore`` in a temp folder: a `write`
/// stores the link and `current` turns to it, a `remove` leaves no `defaultFolder` key
/// (never `""`) and keeps its siblings, and a write that fails leaves `current` where it
/// was and puts one record in the error log. Waits are polls with a bound, never a fixed
/// sleep that a late write could outlast.
@MainActor
@Suite struct FigmaDefaultFolderRowEffectTests {
    private static let link = "https://www.figma.com/files/team/1/folder/2"

    private struct Fixture {
        let model: JSONValueModel<String>
        let errorLog: SettingsErrorLog
        let folder: URL
        var file: URL { folder.appendingPathComponent("cmux.json") }
    }

    private func withModel(
        seed: String? = nil,
        _ body: (Fixture) async throws -> Void
    ) async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("figma-row-effects-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let file = folder.appendingPathComponent("cmux.json")
        if let seed { try Data(seed.utf8).write(to: file) }
        let errorLog = SettingsErrorLog()
        let model = JSONValueModel(
            store: JSONConfigStore(fileURL: file),
            key: SettingCatalog().figma.defaultFolder,
            errorLog: errorLog
        )
        model.startObserving()
        try await body(Fixture(model: model, errorLog: errorLog, folder: folder))
    }

    private func root(_ file: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Polls `condition` every 10 ms for at most 5 s.
    private func wait(_ condition: () -> Bool) async {
        var spins = 0
        while !condition(), spins < 500 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            spins += 1
        }
    }

    @Test func writeStoresTheLinkAndCurrentTurnsToIt() async throws {
        try await withModel { fixture in
            fixture.model.apply(.write(Self.link))
            await wait { fixture.model.current == Self.link }
            #expect(fixture.model.current == Self.link, "the model confirms what the store took")
            let figma = try #require(root(fixture.file)?["figma"] as? [String: Any])
            #expect(figma["defaultFolder"] as? String == Self.link)
            #expect(fixture.errorLog.entries.isEmpty)
        }
    }

    @Test func removeLeavesNoKeyAndNoEmptyString() async throws {
        try await withModel(seed: #"{"figma": {"defaultFolder": "\#(Self.link)"}, "zz_keep": 1}"#) { fixture in
            await wait { fixture.model.current == Self.link }
            fixture.model.apply(.remove)
            await wait { fixture.model.current.isEmpty }
            let object = try #require(root(fixture.file))
            #expect(object["figma"] == nil, "no figma object and no \"defaultFolder\": \"\" is left: \(object)")
            #expect(object["zz_keep"] as? Int == 1)
        }
    }

    @Test func removeKeepsASiblingKeyInTheFigmaObject() async throws {
        try await withModel(
            seed: #"{"figma": {"defaultFolder": "\#(Self.link)", "profile": "p"}, "zz_keep": 1}"#
        ) { fixture in
            await wait { fixture.model.current == Self.link }
            fixture.model.apply(.remove)
            await wait { fixture.model.current.isEmpty }
            let figma = try #require(root(fixture.file)?["figma"] as? [String: Any])
            #expect(figma["defaultFolder"] == nil, "\(figma)")
            #expect(figma["profile"] as? String == "p")
        }
    }

    @Test func aWriteThatFailsLeavesCurrentAndRecordsOneError() async throws {
        try await withModel(seed: #"{"zz_keep": 1}"#) { fixture in
            let before = try Data(contentsOf: fixture.file)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.folder.path)
            fixture.model.apply(.write(Self.link))
            await wait { !fixture.errorLog.entries.isEmpty }
            #expect(fixture.errorLog.entries.count == 1, "\(fixture.errorLog.entries)")
            #expect(fixture.errorLog.entries.first?.keyID == "figma.defaultFolder")
            #expect(fixture.model.current.isEmpty, "current never turns when the write fails")
            #expect(try Data(contentsOf: fixture.file) == before)
        }
    }
}
