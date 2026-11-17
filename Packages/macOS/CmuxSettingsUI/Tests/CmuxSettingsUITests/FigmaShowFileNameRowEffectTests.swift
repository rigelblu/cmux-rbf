import CmuxSettings
import Foundation
import Testing

@testable import CmuxSettingsUI

/// cmux-rbf #cm-73.43: what the "Figma File Name in Header" row's `JSONValueModel<Bool>` does to the
/// file. The row's Toggle calls `model.set(_:)`; here the model writes `figma.showFileNameInHeader`
/// into a real ``JSONConfigStore`` in a temp folder. The Toggle's own binding is not reachable without
/// hosting the view: that leg is Scenario 363, by hand. Waits are polls with a bound.
@MainActor
@Suite struct FigmaShowFileNameRowEffectTests {
    private func withModel(
        seed: String,
        _ body: (JSONValueModel<Bool>, URL) async throws -> Void
    ) async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("figma-show-name-row-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("cmux.json")
        try Data(seed.utf8).write(to: file)
        let model = JSONValueModel(
            store: JSONConfigStore(fileURL: file),
            key: SettingCatalog().figma.showFileNameInHeader,
            errorLog: SettingsErrorLog()
        )
        model.startObserving()
        try await body(model, file)
    }

    private func figmaObject(_ file: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: file),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return root["figma"] as? [String: Any]
    }

    /// Polls `condition` every 10 ms for at most 5 s.
    private func wait(_ condition: () -> Bool) async {
        var spins = 0
        while !condition(), spins < 500 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            spins += 1
        }
    }

    @Test func setFalseWritesTheKeyAndKeepsItsSibling() async throws {
        try await withModel(seed: #"{"figma": {"defaultFolder": "https://www.figma.com/files/team/1/folder/2"}}"#) { model, file in
            #expect(model.current == true, "no key reads the default, on")
            model.set(false)
            await wait { figmaObject(file)?["showFileNameInHeader"] as? Bool == false }
            let figma = try #require(figmaObject(file))
            #expect(figma["showFileNameInHeader"] as? Bool == false, "\(figma)")
            #expect(figma["defaultFolder"] as? String == "https://www.figma.com/files/team/1/folder/2", "\(figma)")
            #expect(model.current == false)
        }
    }

    @Test func setTrueAfterFalseWritesTrue() async throws {
        try await withModel(seed: #"{"figma": {"showFileNameInHeader": false}}"#) { model, file in
            await wait { model.current == false }
            #expect(model.current == false, "the model reads the file's false")
            model.set(true)
            await wait { model.current == true }
            #expect(model.current == true)
            let figma = try #require(figmaObject(file))
            #expect(figma["showFileNameInHeader"] as? Bool != false, "\(figma)")
        }
    }
}
