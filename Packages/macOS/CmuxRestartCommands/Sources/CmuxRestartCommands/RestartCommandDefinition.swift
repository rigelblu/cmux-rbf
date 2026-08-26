public import Foundation
internal import CryptoKit

/// Stable identifiers for commands cmux may restart after restoring a pane.
public enum RestartCommandDefinitionID: String, Codable, CaseIterable, Sendable {
    case jjui
    case jjuiBrief = "jjui-brief"
    case hunk

    /// The canonical order used for normalization and presentation.
    public static let canonicalOrder: [RestartCommandDefinitionID] = [
        .jjui,
        .jjuiBrief,
        .hunk,
    ]

    /// App-owned display name. It is intentionally excluded from approval authority.
    public var displayName: String { rawValue }
}

/// A targeted environment condition used only while observing a live process.
public struct RestartCommandEnvironmentPredicate: Codable, Equatable, Sendable {
    /// Required state of the environment key.
    public enum State: String, Codable, Sendable {
        case absent
        case present
    }

    public let state: State
    public let normalizedFinalComponent: String?

    public init(state: State, normalizedFinalComponent: String? = nil) {
        self.state = state
        self.normalizedFinalComponent = normalizedFinalComponent
    }
}

/// Typed process evidence a restart definition requires.
public struct RestartCommandMatchDefinition: Codable, Equatable, Sendable {
    public let executable: String
    public let argumentTailPrefix: [String]?
    public let environment: [String: RestartCommandEnvironmentPredicate]?

    public init(
        executable: String,
        argumentTailPrefix: [String]? = nil,
        environment: [String: RestartCommandEnvironmentPredicate]? = nil
    ) {
        self.executable = executable
        self.argumentTailPrefix = argumentTailPrefix
        self.environment = environment
    }
}

/// The working-directory policy for a canonical restart command.
public enum RestartCommandWorkingDirectoryPolicy: String, Codable, Sendable {
    case saved
}

/// One editable definition whose behavior becomes authority only after global approval.
public struct RestartCommandDefinition: Codable, Equatable, Sendable {
    public let id: RestartCommandDefinitionID
    public let match: RestartCommandMatchDefinition
    public let command: String
    public let cwd: RestartCommandWorkingDirectoryPolicy

    public init(
        id: RestartCommandDefinitionID,
        match: RestartCommandMatchDefinition,
        command: String,
        cwd: RestartCommandWorkingDirectoryPolicy
    ) {
        self.id = id
        self.match = match
        self.command = command
        self.cwd = cwd
    }
}

/// Validation failures surfaced by the dedicated definitions editor and Settings.
public enum RestartCommandDefinitionError: Error, Equatable, Sendable {
    case invalidJSON
    case invalidTopLevelObject
    case unknownField
    case unsupportedVersion
    case incompleteDefinitionSet
    case duplicateDefinition
    case emptyExecutable
    case invalidArgumentPrefix
    case invalidEnvironmentPredicate
    case emptyCommand
    case unsafeCommand
    case commandTooLong

    /// Stable user-facing validation copy for the Settings inline error slot.
    public var localizedMessage: String {
        switch self {
        case .commandTooLong:
            return String(
                localized: "settings.terminal.restartCommands.validation.commandTooLong",
                defaultValue: "Command must be 1,000 UTF-8 bytes or fewer."
            )
        default:
            return String(
                localized: "settings.terminal.restartCommands.validation.invalidDefinitions",
                defaultValue: "Fix all three command definitions before re-enabling."
            )
        }
    }
}

/// A complete, normalized three-command definition set.
public struct RestartCommandDefinitionSet: Equatable, Sendable {
    public static let schemaVersion = 1
    public static let maximumCommandUTF8Bytes = 1_000
    public static let approvalDomain = Data("cmux.restart-commands.approval.v1".utf8)
    public static let detectorDomain = Data("cmux.restart-commands.detector.v1".utf8)

    public let definitions: [RestartCommandDefinition]

    public init(definitions: [RestartCommandDefinition]) throws {
        self.definitions = try Self.validatedAndSorted(definitions)
    }

    /// The three app-owned definitions used when no editable file exists.
    public static let appDefaults: RestartCommandDefinitionSet = try! RestartCommandDefinitionSet(
        definitions: [
            RestartCommandDefinition(
                id: .jjui,
                match: RestartCommandMatchDefinition(
                    executable: "jjui",
                    environment: [
                        "JJUI_CONFIG_DIR": RestartCommandEnvironmentPredicate(state: .absent),
                    ]
                ),
                command: "jjui",
                cwd: .saved
            ),
            RestartCommandDefinition(
                id: .jjuiBrief,
                match: RestartCommandMatchDefinition(
                    executable: "jjui",
                    environment: [
                        "JJUI_CONFIG_DIR": RestartCommandEnvironmentPredicate(
                            state: .present,
                            normalizedFinalComponent: "jjui-brief"
                        ),
                    ]
                ),
                command: "jjui-brief",
                cwd: .saved
            ),
            RestartCommandDefinition(
                id: .hunk,
                match: RestartCommandMatchDefinition(
                    executable: "hunk",
                    argumentTailPrefix: ["diff"]
                ),
                command: "hunk",
                cwd: .saved
            ),
        ]
    )

    /// Decodes strict JSON. `$schema` is editor metadata and never enters authority.
    public static func decodeJSON(_ data: Data) throws -> RestartCommandDefinitionSet {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw RestartCommandDefinitionError.invalidJSON
        }
        guard let root = object as? [String: Any] else {
            throw RestartCommandDefinitionError.invalidTopLevelObject
        }
        guard Set(root.keys).isSubset(of: ["$schema", "version", "definitions"]) else {
            throw RestartCommandDefinitionError.unknownField
        }
        guard (root["version"] as? NSNumber)?.intValue == schemaVersion else {
            throw RestartCommandDefinitionError.unsupportedVersion
        }
        guard let rawDefinitions = root["definitions"] as? [[String: Any]] else {
            throw RestartCommandDefinitionError.incompleteDefinitionSet
        }
        for rawDefinition in rawDefinitions {
            try validateRawDefinitionShape(rawDefinition)
        }

        struct FilePayload: Decodable {
            let version: Int
            let definitions: [RestartCommandDefinition]
        }
        do {
            let payload = try JSONDecoder().decode(FilePayload.self, from: data)
            guard payload.version == schemaVersion else {
                throw RestartCommandDefinitionError.unsupportedVersion
            }
            return try RestartCommandDefinitionSet(definitions: payload.definitions)
        } catch let error as RestartCommandDefinitionError {
            throw error
        } catch {
            throw RestartCommandDefinitionError.invalidJSON
        }
    }

    /// Fixed-key canonical JSON bytes used only as digest input.
    public var canonicalData: Data {
        let objects: [[String: Any]] = definitions.map { definition in
            var match: [String: Any] = ["executable": definition.match.executable]
            if let argumentTailPrefix = definition.match.argumentTailPrefix {
                match["argumentTailPrefix"] = argumentTailPrefix
            }
            if let environment = definition.match.environment {
                match["environment"] = Dictionary(uniqueKeysWithValues: environment.keys.sorted().map { key in
                    let predicate = environment[key]!
                    var object: [String: Any] = ["state": predicate.state.rawValue]
                    if let component = predicate.normalizedFinalComponent {
                        object["normalizedFinalComponent"] = component
                    }
                    return (key, object)
                })
            }
            return [
                "command": definition.command,
                "cwd": definition.cwd.rawValue,
                "id": definition.id.rawValue,
                "match": match,
            ]
        }
        let object: [String: Any] = [
            "definitions": objects,
            "version": Self.schemaVersion,
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// Digest covering every approved matcher and launch field.
    public var approvalDigest: String {
        Self.domainDigest(domain: Self.approvalDomain, payload: canonicalData)
    }

    /// Finds a definition by its stable id.
    public func definition(id: RestartCommandDefinitionID) -> RestartCommandDefinition? {
        definitions.first { $0.id == id }
    }

    /// Digest covering only matching behavior, so command-only edits retain saved bindings.
    public func detectorFingerprint(for id: RestartCommandDefinitionID) -> String? {
        guard let definition = definition(id: id) else { return nil }
        var object: [String: Any] = [
            "id": definition.id.rawValue,
            "executable": definition.match.executable,
        ]
        if let prefix = definition.match.argumentTailPrefix {
            object["argumentTailPrefix"] = prefix
        }
        if let environment = definition.match.environment {
            object["environment"] = Dictionary(uniqueKeysWithValues: environment.keys.sorted().map { key in
                let predicate = environment[key]!
                var value: [String: Any] = ["state": predicate.state.rawValue]
                if let component = predicate.normalizedFinalComponent {
                    value["normalizedFinalComponent"] = component
                }
                return (key, value)
            })
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return Self.domainDigest(domain: Self.detectorDomain, payload: data)
    }

    /// Pretty JSON defaults materialized only when the editable file is missing.
    public func editableDefaultsData(schemaFileName: String = "restart-commands.schema.json") -> Data {
        let source = """
        {
          "$schema": "./\(schemaFileName)",
          "version": 1,
          "definitions": [
            {
              "id": "jjui",
              "match": {
                "executable": "jjui",
                "environment": {
                  "JJUI_CONFIG_DIR": { "state": "absent" }
                }
              },
              "command": "jjui",
              "cwd": "saved"
            },
            {
              "id": "jjui-brief",
              "match": {
                "executable": "jjui",
                "environment": {
                  "JJUI_CONFIG_DIR": {
                    "state": "present",
                    "normalizedFinalComponent": "jjui-brief"
                  }
                }
              },
              "command": "jjui-brief",
              "cwd": "saved"
            },
            {
              "id": "hunk",
              "match": {
                "executable": "hunk",
                "argumentTailPrefix": ["diff"]
              },
              "command": "hunk",
              "cwd": "saved"
            }
          ]
        }
        """
        return Data((source + "\n").utf8)
    }

    /// Lower-case SHA-256 for exact persisted bytes or other receipt payloads.
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func domainDigest(domain: Data, payload: Data) -> String {
        var data = domain
        data.append(0)
        data.append(payload)
        return sha256Hex(data)
    }

    private static func validatedAndSorted(
        _ definitions: [RestartCommandDefinition]
    ) throws -> [RestartCommandDefinition] {
        guard definitions.count == RestartCommandDefinitionID.allCases.count else {
            throw RestartCommandDefinitionError.incompleteDefinitionSet
        }
        let ids = definitions.map(\.id)
        guard Set(ids).count == ids.count else {
            throw RestartCommandDefinitionError.duplicateDefinition
        }
        guard Set(ids) == Set(RestartCommandDefinitionID.allCases) else {
            throw RestartCommandDefinitionError.incompleteDefinitionSet
        }
        for definition in definitions {
            guard !definition.match.executable.isEmpty,
                  (definition.match.executable as NSString).lastPathComponent == definition.match.executable else {
                throw RestartCommandDefinitionError.emptyExecutable
            }
            if let prefix = definition.match.argumentTailPrefix,
               prefix.isEmpty || prefix.contains(where: \.isEmpty) {
                throw RestartCommandDefinitionError.invalidArgumentPrefix
            }
            if let environment = definition.match.environment {
                guard !environment.isEmpty,
                      environment.keys.allSatisfy({ $0 == "JJUI_CONFIG_DIR" }) else {
                    throw RestartCommandDefinitionError.invalidEnvironmentPredicate
                }
                for predicate in environment.values {
                    switch predicate.state {
                    case .absent:
                        guard predicate.normalizedFinalComponent == nil else {
                            throw RestartCommandDefinitionError.invalidEnvironmentPredicate
                        }
                    case .present:
                        guard let component = predicate.normalizedFinalComponent,
                              !component.isEmpty,
                              (component as NSString).lastPathComponent == component else {
                            throw RestartCommandDefinitionError.invalidEnvironmentPredicate
                        }
                    }
                }
            }
            guard !definition.command.isEmpty else {
                throw RestartCommandDefinitionError.emptyCommand
            }
            guard RestartCommandGrammar.isSafeSingleCommand(definition.command) else {
                throw RestartCommandDefinitionError.unsafeCommand
            }
            guard definition.command.utf8.count <= maximumCommandUTF8Bytes else {
                throw RestartCommandDefinitionError.commandTooLong
            }
        }
        let order = Dictionary(uniqueKeysWithValues: RestartCommandDefinitionID.canonicalOrder.enumerated().map {
            ($0.element, $0.offset)
        })
        return definitions.sorted { order[$0.id, default: .max] < order[$1.id, default: .max] }
    }

    private static func validateRawDefinitionShape(_ object: [String: Any]) throws {
        guard Set(object.keys).isSubset(of: ["id", "match", "command", "cwd"]),
              Set(object.keys) == ["id", "match", "command", "cwd"] else {
            throw RestartCommandDefinitionError.unknownField
        }
        guard let match = object["match"] as? [String: Any],
              Set(match.keys).isSubset(of: ["executable", "argumentTailPrefix", "environment"]),
              match["executable"] != nil else {
            throw RestartCommandDefinitionError.unknownField
        }
        if let environment = match["environment"] as? [String: Any] {
            guard Set(environment.keys).isSubset(of: ["JJUI_CONFIG_DIR"]) else {
                throw RestartCommandDefinitionError.unknownField
            }
            for value in environment.values {
                guard let predicate = value as? [String: Any],
                      Set(predicate.keys).isSubset(of: ["state", "normalizedFinalComponent"]),
                      predicate["state"] != nil else {
                    throw RestartCommandDefinitionError.unknownField
                }
            }
        } else if match["environment"] != nil {
            throw RestartCommandDefinitionError.invalidEnvironmentPredicate
        }
    }
}

private enum RestartCommandGrammar {
    /// Shell text is typed into an interactive prompt, so definitions must be
    /// one expansion-free command. Quoting and escaping ordinary arguments is
    /// allowed; control operators, substitutions, globbing, control bytes,
    /// and leading/trailing whitespace are not.
    static func isSafeSingleCommand(_ command: String) -> Bool {
        guard command == command.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else {
            return false
        }

        let scalars = command.unicodeScalars
        var index = scalars.startIndex
        var quote: UnicodeScalar?
        var isAtTokenStart = true

        while index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar.value < 0x20 || scalar.value == 0x7f {
                return false
            }
            if quote == "'" {
                if scalar == "'" { quote = nil }
                index = scalars.index(after: index)
                continue
            }
            if quote == "\"" {
                if scalar == "\\" {
                    let next = scalars.index(after: index)
                    guard next < scalars.endIndex,
                          scalars[next].value >= 0x20,
                          scalars[next].value != 0x7f else {
                        return false
                    }
                    index = scalars.index(after: next)
                    continue
                }
                if scalar == "\"" {
                    quote = nil
                } else if scalar == "$" || scalar == "`" || scalar == "!" {
                    return false
                }
                index = scalars.index(after: index)
                continue
            }
            if scalar == "\\" {
                let next = scalars.index(after: index)
                guard next < scalars.endIndex,
                      scalars[next].value >= 0x20,
                      scalars[next].value != 0x7f else {
                    return false
                }
                isAtTokenStart = false
                index = scalars.index(after: next)
                continue
            }
            if scalar == "'" || scalar == "\"" {
                quote = scalar
                isAtTokenStart = false
            } else if scalar == " " {
                isAtTokenStart = true
            } else if scalar == "$" || scalar == "`" || scalar == "!" ||
                        scalar == "*" || scalar == "?" || scalar == "[" ||
                        scalar == "{" || scalar == "}" || scalar == ";" ||
                        scalar == "|" || scalar == "&" || scalar == "<" ||
                        scalar == ">" || scalar == "(" || scalar == ")" {
                return false
            } else if isAtTokenStart && (scalar == "~" || scalar == "=") {
                return false
            } else {
                isAtTokenStart = false
            }
            index = scalars.index(after: index)
        }
        return quote == nil && !isAtTokenStart
    }
}
