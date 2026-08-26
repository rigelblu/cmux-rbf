import Foundation
import Testing
@testable import CmuxRestartCommands

@Suite("Restart process evidence")
struct RestartCommandProcessEvidenceTests {
    private let decoder = RestartCommandProcessEvidenceDecoder()

    @Test func preservesArgumentPositionsAndTargetEnvironment() throws {
        let bytes = kernProcArgs(
            argv: ["/opt/bin/hunk", "diff", "--stat"],
            environment: [Data("OTHER=value".utf8), Data("JJUI_CONFIG_DIR=/tmp/jjui-brief".utf8)]
        )
        let decoded = try #require(decoder.decode(bytes, environmentKeys: ["JJUI_CONFIG_DIR"]))
        #expect(decoded.arguments == ["/opt/bin/hunk", "diff", "--stat"])
        #expect(decoded.environment["JJUI_CONFIG_DIR"] == .present("/tmp/jjui-brief"))
    }

    @Test func completeMissingEnvironmentIsAbsent() throws {
        let decoded = try #require(decoder.decode(
            kernProcArgs(argv: ["jjui"], environment: [Data("OTHER=value".utf8)]),
            environmentKeys: ["JJUI_CONFIG_DIR"]
        ))
        #expect(decoded.environment["JJUI_CONFIG_DIR"] == .absent)
    }

    @Test func duplicateOrInvalidTargetIsUnavailable() throws {
        let duplicate = try #require(decoder.decode(
            kernProcArgs(
                argv: ["jjui"],
                environment: [
                    Data("JJUI_CONFIG_DIR=/one".utf8),
                    Data("JJUI_CONFIG_DIR=/two".utf8),
                ]
            ),
            environmentKeys: ["JJUI_CONFIG_DIR"]
        ))
        #expect(duplicate.environment["JJUI_CONFIG_DIR"] == .unavailable)

        var invalid = Data("JJUI_CONFIG_DIR=".utf8)
        invalid.append(contentsOf: [0xFF, 0xFE])
        let invalidValue = try #require(decoder.decode(
            kernProcArgs(argv: ["jjui"], environment: [invalid]),
            environmentKeys: ["JJUI_CONFIG_DIR"]
        ))
        #expect(invalidValue.environment["JJUI_CONFIG_DIR"] == .unavailable)
    }

    @Test func unrelatedInvalidUTF8DoesNotPoisonAbsence() throws {
        var unrelated = Data("OTHER=".utf8)
        unrelated.append(0xFF)
        let decoded = try #require(decoder.decode(
            kernProcArgs(argv: ["jjui"], environment: [unrelated]),
            environmentKeys: ["JJUI_CONFIG_DIR"]
        ))
        #expect(decoded.environment["JJUI_CONFIG_DIR"] == .absent)
    }

    @Test func malformedArgvAndTruncationFailClosed() {
        var invalidArg = Data([0xFF])
        #expect(decoder.decode(
            kernProcArgs(argvData: [invalidArg], environment: []),
            environmentKeys: ["JJUI_CONFIG_DIR"]
        ) == nil)

        var truncated = kernProcArgs(argv: ["jjui"], environment: [])
        truncated.removeLast()
        truncated.append(contentsOf: Data("JJUI_CONFIG_DIR=/tmp/brief".utf8))
        #expect(decoder.decode(truncated, environmentKeys: ["JJUI_CONFIG_DIR"])?.environment["JJUI_CONFIG_DIR"] == .unavailable)

        var truncatedAfterCompleteEntry = kernProcArgs(
            argv: ["jjui"],
            environment: [Data("OTHER=value".utf8)]
        )
        truncatedAfterCompleteEntry.removeLast()
        #expect(
            decoder.decode(
                truncatedAfterCompleteEntry,
                environmentKeys: ["JJUI_CONFIG_DIR"]
            )?.environment["JJUI_CONFIG_DIR"] == .unavailable
        )
        invalidArg.removeAll()
    }

    private func kernProcArgs(argv: [String], environment: [Data]) -> [UInt8] {
        kernProcArgs(argvData: argv.map { Data($0.utf8) }, environment: environment)
    }

    private func kernProcArgs(argvData: [Data], environment: [Data]) -> [UInt8] {
        var bytes: [UInt8] = []
        var argc = Int32(argvData.count).littleEndian
        withUnsafeBytes(of: &argc) { bytes.append(contentsOf: $0) }
        bytes.append(contentsOf: Data("/usr/bin/executable".utf8))
        bytes.append(0)
        bytes.append(0)
        for argument in argvData {
            bytes.append(contentsOf: argument)
            bytes.append(0)
        }
        for entry in environment {
            bytes.append(contentsOf: entry)
            bytes.append(0)
        }
        bytes.append(0)
        return bytes
    }
}
