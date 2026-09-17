import Foundation
import Testing
@testable import CmuxRestartCommands

@Suite("Restart command state")
struct RestartCommandStateTests {
    @Test func defaultsAreEnabledWithoutHistoricalReceipts() throws {
        let shipped = try BundledRestartCommandDefinitions.load()
        let record = RestartCommandStateRecord.enabledDefaults(
            definitionDigest: shipped.approvalDigest,
            at: 100
        )
        #expect(record.isStructurallyValid)
        #expect(record.primaryReceipt == nil)
        #expect(record.manualBackupReceipt == nil)
        #expect(record.automaticallyConsumedIdentities.isEmpty)
        #expect(RestartCommandAuthority.effectiveState(
            record: record,
            bundledDefinitions: shipped,
            userFileObservation: .missing
        ) == .enabledAppDefaults)
    }

    @Test func receiptReplacementBoundsConsumedIdentities() throws {
        let shipped = try BundledRestartCommandDefinitions.load()
        let a = identity("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", .autosave)
        let b = identity("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", .pendingTermination)
        let c = identity("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC", .autosave)
        var record = RestartCommandStateRecord.enabledDefaults(
            definitionDigest: shipped.approvalDigest,
            at: 100
        )
        record.register(receipt(a, byte: "a"), source: .automaticPrimary)
        record.register(receipt(b, byte: "b"), source: .manualBackup)
        let consumedA = record.consumeAutomatically(a)
        let consumedB = record.consumeAutomatically(b)
        #expect(consumedA)
        #expect(consumedB)
        record.register(receipt(c, byte: "c"), source: .automaticPrimary)
        #expect(record.automaticallyConsumedIdentities == [b])
        #expect(record.automaticallyConsumedIdentities.count <= 2)
    }

    @Test func modeTransitionsConsumeCurrentReceiptsAndManualRemainsReusable() throws {
        let shipped = try BundledRestartCommandDefinitions.load()
        let identity = identity("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", .autosave)
        let receipt = receipt(identity, byte: "slot")
        var record = RestartCommandStateRecord.enabledDefaults(
            definitionDigest: shipped.approvalDigest,
            at: 100
        )
        record.register(receipt, source: .automaticPrimary)
        record.register(receipt, source: .manualBackup)

        record.setEnabled(
            false,
            definitionsAreAppDefaults: true,
            definitionDigest: shipped.approvalDigest,
            at: 200
        )
        #expect(record.mode == .disabledByUser)
        #expect(record.automaticallyConsumedIdentities == [identity])
        #expect(record.matchingReceipt(source: .manualBackup, identity: identity, fileDigest: receipt.fileDigest) != nil)
    }

    @Test func corruptOrMismatchedStateFailsClosed() throws {
        let shipped = try BundledRestartCommandDefinitions.load()
        var record = RestartCommandStateRecord.enabledDefaults(
            definitionDigest: shipped.approvalDigest,
            at: 100
        )
        record.version = 99
        #expect(!record.isStructurallyValid)
        #expect(RestartCommandAuthority.effectiveState(
            record: record,
            bundledDefinitions: shipped,
            userFileObservation: .missing
        ) == .disabledStateUnavailable)

        let edited = try RestartCommandDefinitionSet(definitions: shipped.definitions.map {
            guard $0.id == "jjui" else { return $0 }
            return RestartCommandDefinition(id: $0.id, match: $0.match, command: "jjui --new", cwd: $0.cwd)
        })
        let snapshot = RestartCommandDefinitionSnapshot(
            revision: 1,
            source: .editableFile,
            sourceIdentity: "different",
            definitions: edited
        )
        #expect(RestartCommandAuthority.effectiveState(
            record: RestartCommandStateRecord.enabledDefaults(
                definitionDigest: shipped.approvalDigest,
                at: 100
            ),
            bundledDefinitions: shipped,
            userFileObservation: .snapshot(snapshot)
        ) == .enabledFallback(.validUserDefinitionsChanged))
    }

    @Test func summariesGroupAndBoundWithoutSensitiveFields() throws {
        let refusals: [RestartCommandRestoreRefusal] = [
            .init(definitionID: "hunk", reason: .missingWorkingDirectory),
            .init(definitionID: "hunk", reason: .missingWorkingDirectory),
            .init(definitionID: "jjui", reason: .detectorChanged),
            .init(definitionID: "jjui-brief", reason: .definitionsNeedApproval),
            .init(definitionID: "hunk", reason: .paneBecameRemote),
            .init(definitionID: nil, reason: .invalidBinding),
            .init(definitionID: "jjui", reason: .ineligibleSnapshot),
        ]
        let summary = try #require(RestartCommandRestoreSummary.make(
            operationID: UUID(),
            refusals: refusals,
            createdAt: Date(timeIntervalSince1970: 100)
        ))
        #expect(summary.rows.count == 5)
        #expect(summary.rows.first?.paneCount == 2)
        #expect(summary.overflowCount == 1)
        let encoded = try JSONEncoder().encode(summary)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.contains("/Users/"))
        #expect(!text.contains("hunk diff"))
        #expect(!text.contains("JJUI_CONFIG_DIR"))
    }

    private func identity(_ uuid: String, _ kind: RestartCommandCaptureKind) -> RestartCommandSnapshotIdentity {
        RestartCommandSnapshotIdentity(rootGenerationID: UUID(uuidString: uuid)!, captureKind: kind)
    }

    private func receipt(_ identity: RestartCommandSnapshotIdentity, byte: String) -> RestartCommandSnapshotReceipt {
        RestartCommandSnapshotReceipt(
            identity: identity,
            fileDigest: RestartCommandDefinitionSet.sha256Hex(Data(byte.utf8))
        )
    }
}
