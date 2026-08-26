public import Foundation
internal import os

/// Whether one immutable definition snapshot came from the app or the editable file.
public enum RestartCommandDefinitionSource: Equatable, Sendable {
    case appDefaults
    case editableFile
}

/// One complete definition read used by planning and authorization.
public struct RestartCommandDefinitionSnapshot: Equatable, Sendable {
    public let revision: UInt64
    public let source: RestartCommandDefinitionSource
    public let sourceIdentity: String
    public let definitions: RestartCommandDefinitionSet

    public init(
        revision: UInt64,
        source: RestartCommandDefinitionSource,
        sourceIdentity: String,
        definitions: RestartCommandDefinitionSet
    ) {
        self.revision = revision
        self.source = source
        self.sourceIdentity = sourceIdentity
        self.definitions = definitions
    }
}

/// Result of one synchronous, complete definition-source read.
public enum RestartCommandDefinitionRead: Equatable, Sendable {
    case snapshot(RestartCommandDefinitionSnapshot)
    case invalid(RestartCommandDefinitionError)
    case unavailable
}

/// Dedicated primary-global JSON repository. It never reads or writes shared `cmux.json`.
public final class RestartCommandDefinitionsRepository: @unchecked Sendable {
    private struct RevisionState {
        var revision: UInt64 = 0
        var sourceIdentity: String?
    }

    public let definitionsFileURL: URL
    public let schemaFileURL: URL
    private nonisolated(unsafe) let fileManager: FileManager
    private let revisionState = OSAllocatedUnfairLock(initialState: RevisionState())

    public init(
        definitionsFileURL: URL,
        schemaFileURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.definitionsFileURL = definitionsFileURL
        self.schemaFileURL = schemaFileURL
            ?? definitionsFileURL.deletingLastPathComponent()
                .appendingPathComponent("restart-commands.schema.json", isDirectory: false)
        self.fileManager = fileManager
    }

    /// Resolves the standard primary-global definitions path.
    public static func defaultDefinitionsFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent(".config/cmux", isDirectory: true)
            .appendingPathComponent("restart-commands.json", isDirectory: false)
    }

    /// Reads one complete source snapshot or a fail-closed error.
    public func read() -> RestartCommandDefinitionRead {
        if !fileManager.fileExists(atPath: definitionsFileURL.path) {
            let identity = "compiled-default-v1:\(RestartCommandDefinitionSet.appDefaults.approvalDigest)"
            return .snapshot(snapshot(
                source: .appDefaults,
                sourceIdentity: identity,
                definitions: .appDefaults
            ))
        }
        guard let data = try? Data(contentsOf: definitionsFileURL) else {
            return .unavailable
        }
        let sourceIdentity = RestartCommandDefinitionSet.sha256Hex(data)
        do {
            let definitions = try RestartCommandDefinitionSet.decodeJSON(data)
            return .snapshot(snapshot(
                source: .editableFile,
                sourceIdentity: sourceIdentity,
                definitions: definitions
            ))
        } catch let error as RestartCommandDefinitionError {
            _ = revision(for: sourceIdentity)
            return .invalid(error)
        } catch {
            _ = revision(for: sourceIdentity)
            return .invalid(.invalidJSON)
        }
    }

    /// Refreshes the adjacent schema and creates defaults only when the editable file is absent.
    @discardableResult
    public func materializeForEditing(schemaData: Data) -> Bool {
        do {
            let directory = definitionsFileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try schemaData.write(to: schemaFileURL, options: .atomic)
            if !fileManager.fileExists(atPath: definitionsFileURL.path) {
                try RestartCommandDefinitionSet.appDefaults
                    .editableDefaultsData(schemaFileName: schemaFileURL.lastPathComponent)
                    .write(to: definitionsFileURL, options: .atomic)
            }
            return true
        } catch {
            return false
        }
    }

    private func snapshot(
        source: RestartCommandDefinitionSource,
        sourceIdentity: String,
        definitions: RestartCommandDefinitionSet
    ) -> RestartCommandDefinitionSnapshot {
        RestartCommandDefinitionSnapshot(
            revision: revision(for: sourceIdentity),
            source: source,
            sourceIdentity: sourceIdentity,
            definitions: definitions
        )
    }

    private func revision(for sourceIdentity: String) -> UInt64 {
        revisionState.withLock { state in
            if state.sourceIdentity != sourceIdentity {
                state.revision &+= 1
                state.sourceIdentity = sourceIdentity
            }
            return state.revision
        }
    }
}
