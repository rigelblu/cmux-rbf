import Foundation
import Testing
import CmuxRestartCommands

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Restart allowlisted commands")
struct RestartAllowlistedCommandTests {
    @Test func matcherAndObservation() throws {
        let shipped = try BundledRestartCommandDefinitions.load()
        let workspaceID = UUID()
        let identity = RestartCommandSnapshotIdentity(
            rootGenerationID: UUID(),
            captureKind: .pendingTermination
        )
        let panels = [RestartCommandPanelKey(
            workspaceID: workspaceID,
            panelID: UUID()
        ), RestartCommandPanelKey(
            workspaceID: workspaceID,
            panelID: UUID()
        ), RestartCommandPanelKey(
            workspaceID: workspaceID,
            panelID: UUID()
        )]
        let processes = [
            Self.process(pid: 101, tty: 11),
            Self.process(pid: 102, tty: 12),
            Self.process(pid: 103, tty: 13),
        ]
        let processBytes: [Int: [UInt8]] = [
            101: Self.kernProcArgs(arguments: ["/opt/homebrew/bin/jjui"], environment: []),
            102: Self.kernProcArgs(
                arguments: ["/Users/example/bin/jjui"],
                environment: ["JJUI_CONFIG_DIR=/Users/example/.config/jjui-brief/"]
            ),
            103: Self.kernProcArgs(
                arguments: ["/usr/local/bin/hunk", "diff", "--color=always"],
                environment: []
            ),
        ]
        let snapshot = CmuxTopProcessSnapshot(
            processes: processes,
            sampledAt: Date(timeIntervalSince1970: 100),
            includesProcessDetails: true
        )

        let bindings = ProcessDetectedResumeIndexes.restartCommandBindings(
            processSnapshot: snapshot,
            panelTTYDevices: [panels[0]: 11, panels[1]: 12, panels[2]: 13],
            context: RestartCommandCaptureContext(identity: identity, definitions: shipped),
            capturedAt: 100,
            processBytes: { processBytes[$0] }
        )

        #expect(bindings[panels[0]]?.definitionID == "jjui")
        #expect(bindings[panels[1]]?.definitionID == "jjui-brief")
        #expect(bindings[panels[2]]?.definitionID == "hunk")
        #expect(Set(bindings.values.map { $0.snapshotGenerationID }) == [identity.rootGenerationID])

        let ambiguous = CmuxTopProcessSnapshot(
            processes: [Self.process(pid: 201, tty: 21), Self.process(pid: 202, tty: 21)],
            sampledAt: Date(timeIntervalSince1970: 100),
            includesProcessDetails: true
        )
        let ambiguousPanel = RestartCommandPanelKey(workspaceID: workspaceID, panelID: UUID())
        let noBinding = ProcessDetectedResumeIndexes.restartCommandBindings(
            processSnapshot: ambiguous,
            panelTTYDevices: [ambiguousPanel: 21],
            context: RestartCommandCaptureContext(identity: identity, definitions: shipped),
            capturedAt: 100,
            processBytes: { _ in
                Self.kernProcArgs(arguments: ["jjui"], environment: [])
            }
        )
        #expect(noBinding.isEmpty)
    }

    @Test func configCoexistence() throws {
        let shipped = try BundledRestartCommandDefinitions.load()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-restart-config-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sharedConfig = root.appendingPathComponent("cmux.json")
        let originalSharedBytes = Data("{\"terminal\":\"unchanged\"}\n".utf8)
        try originalSharedBytes.write(to: sharedConfig)
        let definitionsURL = root.appendingPathComponent("restart-commands.json")
        let repository = RestartCommandDefinitionsRepository(definitionsFileURL: definitionsURL)

        #expect(
            RestartCommandDefinitionsRepository.defaultDefinitionsFileURL(homeDirectory: root)
                .lastPathComponent == "restart-commands.json"
        )
        #expect(repository.materializeForEditing(
            shippedDefinitions: shipped,
            schemaData: Data("{}".utf8)
        ))
        #expect(try Data(contentsOf: sharedConfig) == originalSharedBytes)
        #expect(FileManager.default.fileExists(atPath: definitionsURL.path))
        guard case .snapshot(let snapshot) = repository.read() else {
            Issue.record("Materialized restart definitions were not readable")
            return
        }
        #expect(snapshot.definitions == shipped)
        #expect(snapshot.definitions.definitions.map(\.id.rawValue) == ["hunk", "jjui", "jjui-brief"])

        let commented = definitionsURL
            .deletingLastPathComponent()
            .appendingPathComponent("commented.json")
        try Data(
            #"""
            { "version": 1, // comments are not regular JSON
              "definitions": [] }
            """#.utf8
        ).write(to: commented)
        #expect(throws: RestartCommandDefinitionError.invalidJSONAtLine(1)) {
            try RestartCommandDefinitionSet.decodeJSON(Data(contentsOf: commented))
        }
    }

    private static func process(pid: Int, tty: Int64) -> CmuxTopProcessInfo {
        CmuxTopProcessInfo(
            pid: pid,
            parentPID: 1,
            name: "test",
            path: nil,
            ttyDevice: tty,
            cmuxWorkspaceID: nil,
            cmuxSurfaceID: nil,
            cmuxAttributionReason: nil,
            processGroupID: pid,
            terminalProcessGroupID: pid,
            cpuPercent: 0,
            residentBytes: 1,
            virtualBytes: 1,
            threadCount: 1
        )
    }

    private static func kernProcArgs(
        arguments: [String],
        environment: [String]
    ) -> [UInt8] {
        var argc = Int32(arguments.count).littleEndian
        var bytes = withUnsafeBytes(of: &argc) { Array($0) }
        bytes += Array("/test/executable".utf8) + [0, 0]
        for argument in arguments {
            bytes += Array(argument.utf8) + [0]
        }
        for entry in environment {
            bytes += Array(entry.utf8) + [0]
        }
        bytes.append(0)
        return bytes
    }
}
