import Foundation
import Testing
@testable import CmuxSettings

/// `reply.labels` — `cm-69.3`'s quick labels.
///
/// Two of the three layers the brief's Scenario A names: the normaliser both
/// writers share, and the catalog key the store falls back to. The third, the
/// `cmux.json` parser writing nothing when the key is absent, lives in the app
/// target and is covered by `ReplyLabelsFileParserTests` in `cmuxTests`.
@Suite("reply.labels")
struct ReplyLabelsCatalogTests {
    private func makeStore() -> (UserDefaultsSettingsStore, SettingCatalog) {
        let suiteName = "cmux.tests.\(UUID().uuidString)"
        let store = UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        return (store, SettingCatalog())
    }

    // MARK: - Normaliser

    /// The case the shared `jsonStringArray` fails: it rejects the whole list
    /// on the first non-string entry.
    @Test func skipsANonStringEntryAndKeepsTheRest() {
        #expect(ReplyCatalogSection.normalizedLabels(["a", 3, "b"]) == ["a", "b"])
    }

    @Test func trimsAndDropsBlankEntries() {
        #expect(ReplyCatalogSection.normalizedLabels(["  a ", "", "   ", "\tb\n"]) == ["a", "b"])
    }

    @Test func keepsOrderAndDuplicates() {
        // Labels are text macros, not tags: two identical labels are two
        // entries, and order decides which three are chips.
        #expect(ReplyCatalogSection.normalizedLabels(["b", "a", "b"]) == ["b", "a", "b"])
    }

    @Test func anEmptyListStaysEmpty() {
        #expect(ReplyCatalogSection.normalizedLabels([]) == [])
    }

    // MARK: - Catalog key

    @Test func nothingStoredReadsTheShippedDefaults() async {
        let (store, catalog) = makeStore()
        #expect(await store.value(for: catalog.reply.labels) == ["lgtm", "why?", "redline"])
    }

    /// Removing every label in Settings stores `[]`. Reading it back must stay
    /// empty — if it fell back, removing your last label would bring two back.
    @Test func aStoredEmptyListReadsEmptyNotTheDefaults() async {
        let (store, catalog) = makeStore()
        await store.set([], for: catalog.reply.labels)
        #expect(await store.value(for: catalog.reply.labels) == [])
    }

    @Test func aStoredListRoundTripsInOrder() async {
        let (store, catalog) = makeStore()
        await store.set(["lgtm", "say why", "redline"], for: catalog.reply.labels)
        #expect(await store.value(for: catalog.reply.labels) == ["lgtm", "say why", "redline"])
    }
}
