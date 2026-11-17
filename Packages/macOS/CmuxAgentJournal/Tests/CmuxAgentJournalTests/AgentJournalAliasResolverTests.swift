import Foundation
import Testing
@testable import CmuxAgentJournal

@Suite("Alias resolver")
struct AgentJournalAliasResolverTests {
    @Test func resolvesChainsAndFailsClosedOnCycles() {
        let a = UUID().uuidString
        let b = UUID().uuidString
        let c = UUID().uuidString
        var resolver = AgentJournalAliasResolver(surfaces: [a: b])
        resolver.merge(workspaces: [:], surfaces: [b: c])
        #expect(resolver.resolvedSurfaceId(a, isLive: { _ in false }) == c) // cmux-rbf: changed on purpose (#cm-128.19)
        #expect(resolver.resolvedSurfaceId(c, isLive: { _ in false }) == c) // cmux-rbf: changed on purpose (#cm-128.19)
        let unknown = UUID().uuidString
        #expect(resolver.resolvedSurfaceId(unknown, isLive: { _ in false }) == unknown) // cmux-rbf: changed on purpose (#cm-128.19)

        let cyclic = AgentJournalAliasResolver(surfaces: [a: b, b: a])
        #expect(cyclic.resolvedSurfaceId(a, isLive: { _ in false }) == nil) // cmux-rbf: changed on purpose (#cm-128.19)
    }

    @Test func matchesStoreSemantics() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alias-resolver-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AgentJournalStore(
            databaseURL: directory.appendingPathComponent("journal.sqlite3")
        )
        defer { store.close() }
        let old = UUID().uuidString
        let new = UUID().uuidString
        try store.recordRestoreAliases(workspaceAliases: [old: new], surfaceAliases: [old: new])
        let maps = try store.aliasMaps()
        let resolver = AgentJournalAliasResolver(
            workspaces: maps.workspaces,
            surfaces: maps.surfaces
        )
        let storeWorkspace = try store.resolvedWorkspaceId(old)
        let storeSurface = try store.resolvedSurfaceId(old)
        #expect(resolver.resolvedWorkspaceId(old) == storeWorkspace)
        #expect(resolver.resolvedSurfaceId(old, isLive: { _ in false }) == storeSurface) // cmux-rbf: changed on purpose (#cm-128.19)
    }

    // (cm-128.19) Live-first: an alias is followed only while the id it starts from is not live.
    @Test func oldIdStaysWhenItIsLive() {
        let old = UUID().uuidString
        let new = UUID().uuidString
        let resolver = AgentJournalAliasResolver(surfaces: [old: new])
        #expect(resolver.resolvedSurfaceId(old, isLive: { $0 == old }) == old)
    }

    @Test func oldIdFollowsItsAliasWhenItIsNotLive() {
        let old = UUID().uuidString
        let new = UUID().uuidString
        let resolver = AgentJournalAliasResolver(surfaces: [old: new])
        #expect(resolver.resolvedSurfaceId(old, isLive: { _ in false }) == new)
    }

    @Test func chainStopsAtTheFirstLiveHop() {
        let a = UUID().uuidString
        let b = UUID().uuidString
        let c = UUID().uuidString
        let resolver = AgentJournalAliasResolver(surfaces: [a: b, b: c])
        #expect(resolver.resolvedSurfaceId(a, isLive: { $0 == b }) == b)
    }

    @Test func aCycleFailsClosedUnlessAnIdOnItIsLive() {
        let a = UUID().uuidString
        let b = UUID().uuidString
        let resolver = AgentJournalAliasResolver(surfaces: [a: b, b: a])
        #expect(resolver.resolvedSurfaceId(a, isLive: { _ in false }) == nil)
        // A live id in the cycle stops the walk before the cap, so it resolves to itself.
        #expect(resolver.resolvedSurfaceId(a, isLive: { $0 == a }) == a)
        // Starting on the dead side, the walk follows the alias and stops at the live id.
        #expect(resolver.resolvedSurfaceId(a, isLive: { $0 == b }) == b)
    }

    @Test func idWithNoAliasResolvesToItselfWithoutAskingLiveness() {
        let alone = UUID().uuidString
        let other = UUID().uuidString
        let resolver = AgentJournalAliasResolver(surfaces: [other: UUID().uuidString])
        var asked = 0
        let resolved = resolver.resolvedSurfaceId(alone, isLive: { _ in asked += 1; return true })
        #expect(resolved == alone)
        #expect(asked == 0)
    }
}
