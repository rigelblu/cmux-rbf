public import Foundation
internal import CryptoKit
internal import CoreFoundation

/// Stable identifiers for commands cmux may restart after restoring a pane.
public struct RestartCommandDefinitionID: RawRepresentable, Codable, Equatable, Hashable, Sendable, Comparable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String

    public static func isValidSlug(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 32 else { return false }
        let utf8 = value.utf8
        guard let first = utf8.first else { return false }
        let isFirstValid = (first >= UInt8(ascii: "a") && first <= UInt8(ascii: "z")) ||
                           (first >= UInt8(ascii: "0") && first <= UInt8(ascii: "9"))
        guard isFirstValid else { return false }

        for byte in utf8.dropFirst() {
            let isValid = (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")) ||
                          (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) ||
                          byte == UInt8(ascii: "-")
            guard isValid else { return false }
        }
        return true
    }

    public init?(rawValue: String) {
        guard Self.isValidSlug(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        guard let id = RestartCommandDefinitionID(rawValue: value) else {
            fatalError("Invalid restart command definition id: \(value)")
        }
        self = id
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let id = RestartCommandDefinitionID(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid restart command definition id: \(raw)"
            )
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
    public var displayName: String { rawValue }

    public static func < (lhs: RestartCommandDefinitionID, rhs: RestartCommandDefinitionID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

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

public struct RestartCommandDefinitionProblem: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case unknownField
        case missingField
        case invalidValue
        case repeatedID
    }

    public let kind: Kind
    public let line: Int
    public let field: String?

    public init(kind: Kind, line: Int, field: String? = nil) {
        self.kind = kind
        self.line = line
        self.field = field
    }
}

/// Validation failures surfaced by the dedicated definitions editor and Settings.
public enum RestartCommandDefinitionError: Error, Equatable, Sendable {
    case invalidJSON
    case invalidJSONAtLine(Int)
    case invalidTopLevelObject
    case unknownField
    /// A required field is absent from its enclosing object.
    case missingField
    /// A definition identifier is not a valid stable slug.
    case invalidDefinitionID
    /// A definition's `match` value is not an object.
    case invalidMatch
    case unsupportedVersion
    case incompleteDefinitionSet
    case duplicateDefinition
    case emptyExecutable
    case invalidArgumentPrefix
    case invalidEnvironmentPredicate
    case emptyCommand
    case unsafeCommand
    case commandTooLong
    case unusableBundledResource
    case invalidDefinition(RestartCommandDefinitionProblem)

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
                defaultValue: "Your definitions file couldn’t be used. Shipped definitions are running; custom definitions aren’t."
            )
        }
    }
}

/// Shipped restart command definitions loaded from the app bundle resource.
public enum BundledRestartCommandDefinitions {
    public static func load() throws -> RestartCommandDefinitionSet {
        try load(bundle: .module)
    }

    public static func load(bundle: Bundle) throws -> RestartCommandDefinitionSet {
        guard let url = bundle.url(forResource: "default-restart-commands", withExtension: "json") else {
            throw RestartCommandDefinitionError.unusableBundledResource
        }
        let data = try Data(contentsOf: url)
        return try RestartCommandDefinitionSet.decodeJSON(data)
    }
}

/// A complete, normalized restart command definition set.
public struct RestartCommandDefinitionSet: Equatable, Sendable {
    public static let minimumDefinitionCount = 1
    public static let maximumDefinitionCount = 32
    public static let schemaVersion = 1
    public static let maximumCommandUTF8Bytes = 1_000
    public static let environmentNamePattern = "^[A-Za-z_][A-Za-z0-9_]*$"
    public static let maximumEnvironmentPredicateCount = 4
    public static let pathComponentPattern = "^[^/]+$"
    public static let approvalDomain = Data("cmux.restart-commands.approval.v1".utf8)
    public static let detectorDomain = Data("cmux.restart-commands.detector.v1".utf8)

    public let definitions: [RestartCommandDefinition]

    public init(definitions: [RestartCommandDefinition]) throws {
        self.definitions = try Self.validatedAndSorted(definitions)
    }

    /// Decodes strict JSON. `$schema` is editor metadata and never enters authority.
    public static func decodeJSON(_ data: Data) throws -> RestartCommandDefinitionSet {
        let sourcePositions = try validateStrictJSONSyntax(data)
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw RestartCommandDefinitionError.invalidJSON
        }
        guard let root = object as? [String: Any] else {
            throw RestartCommandDefinitionError.invalidTopLevelObject
        }

        var failures: [RestartCommandValidationFailure] = []
        let rootKeys = Set(root.keys)
        for key in rootKeys.subtracting(["$schema", "version", "definitions"]) {
            failures.append(.unknownField(path: [.key(key)], field: key))
        }

        if let version = root["version"] {
            if !isSchemaVersion(version) {
                failures.append(.invalidValue(
                    path: [.key("version")],
                    field: "version",
                    reason: .unsupportedVersion
                ))
            }
        } else {
            failures.append(.missingField(path: [], field: "version"))
        }

        var decodedDefinitions: [(index: Int, definition: RestartCommandDefinition)] = []
        if let rawDefinitions = root["definitions"] as? [Any] {
            if rawDefinitions.count < minimumDefinitionCount || rawDefinitions.count > maximumDefinitionCount {
                failures.append(.invalidValue(
                    path: [.key("definitions")],
                    field: "definitions",
                    reason: .incompleteDefinitionSet
                ))
            }
            for (index, rawDefinition) in rawDefinitions.enumerated() {
                let path: RestartCommandJSONPath = [.key("definitions"), .index(index)]
                guard let object = rawDefinition as? [String: Any] else {
                    failures.append(.invalidValue(
                        path: path,
                        field: "definitions",
                        reason: .incompleteDefinitionSet
                    ))
                    continue
                }
                let result = decodeDefinition(object, at: path)
                failures.append(contentsOf: result.failures)
                if let definition = result.definition {
                    decodedDefinitions.append((index, definition))
                }
            }
        } else if root["definitions"] != nil {
            failures.append(.invalidValue(
                path: [.key("definitions")],
                field: "definitions",
                reason: .incompleteDefinitionSet
            ))
        } else {
            failures.append(.missingField(path: [], field: "definitions"))
        }

        var firstIndexByID: [RestartCommandDefinitionID: Int] = [:]
        for decoded in decodedDefinitions {
            if firstIndexByID.updateValue(decoded.index, forKey: decoded.definition.id) != nil {
                failures.append(.repeatedID(path: [
                    .key("definitions"), .index(decoded.index), .key("id")
                ]))
            }
        }

        if !failures.isEmpty {
            if let located = failures.compactMap({ failure -> (RestartCommandValidationFailure, RestartCommandSourcePosition)? in
                guard let position = sourcePositions[failure.path] else { return nil }
                return (failure, position)
            }).min(by: { lhs, rhs in
                lhs.1.line != rhs.1.line ? lhs.1.line < rhs.1.line : lhs.1.column < rhs.1.column
            }) {
                throw RestartCommandDefinitionError.invalidDefinition(
                    RestartCommandDefinitionProblem(
                        kind: located.0.kind,
                        line: located.1.line,
                        field: located.0.field
                    )
                )
            }
            throw failures[0].reason
        }

        return try RestartCommandDefinitionSet(definitions: decodedDefinitions.map(\.definition))
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
        var lines: [String] = [
            "{",
            "  \"$schema\": \"./\(schemaFileName)\",",
            "  \"version\": 1,",
            "  \"definitions\": ["
        ]
        for (index, def) in definitions.enumerated() {
            let isLast = index == definitions.count - 1
            lines.append("    {")
            lines.append("      \"id\": \"\(def.id.rawValue)\",")
            let hasArgs = def.match.argumentTailPrefix != nil
            let hasEnv = def.match.environment != nil
            let hasExtraMatch = hasArgs || hasEnv
            lines.append("      \"match\": {")
            lines.append("        \"executable\": \"\(def.match.executable)\"\(hasExtraMatch ? "," : "")")
            if let args = def.match.argumentTailPrefix {
                let joinedArgs = args.map { "\"\($0)\"" }.joined(separator: ", ")
                lines.append("        \"argumentTailPrefix\": [\(joinedArgs)]\(hasEnv ? "," : "")")
            }
            if let env = def.match.environment {
                lines.append("        \"environment\": {")
                let sortedKeys = env.keys.sorted()
                for (envIndex, key) in sortedKeys.enumerated() {
                    let pred = env[key]!
                    let envLast = envIndex == sortedKeys.count - 1
                    lines.append("          \"\(key)\": {")
                    if let comp = pred.normalizedFinalComponent {
                        lines.append("            \"normalizedFinalComponent\": \"\(comp)\",")
                        lines.append("            \"state\": \"\(pred.state.rawValue)\"")
                    } else {
                        lines.append("            \"state\": \"\(pred.state.rawValue)\"")
                    }
                    lines.append("          }\(envLast ? "" : ",")")
                }
                lines.append("        }")
            }
            lines.append("      },")
            lines.append("      \"command\": \"\(def.command)\",")
            lines.append("      \"cwd\": \"\(def.cwd.rawValue)\"")
            lines.append("    }\(isLast ? "" : ",")")
        }
        lines.append("  ]")
        lines.append("}\n")
        return Data(lines.joined(separator: "\n").utf8)
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
        guard !definitions.isEmpty, definitions.count <= maximumDefinitionCount else {
            throw RestartCommandDefinitionError.incompleteDefinitionSet
        }
        let ids = definitions.map(\.id)
        guard Set(ids).count == ids.count else {
            throw RestartCommandDefinitionError.duplicateDefinition
        }
        for (index, definition) in definitions.enumerated() {
            if let failure = definitionFailures(
                definition,
                at: [.key("definitions"), .index(index)]
            ).first {
                throw failure.reason
            }
        }
        return definitions.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    /// Decodes and validates one raw definition object.
    private static func decodeDefinition(
        _ object: [String: Any],
        at path: RestartCommandJSONPath
    ) -> (definition: RestartCommandDefinition?, failures: [RestartCommandValidationFailure]) {
        var failures: [RestartCommandValidationFailure] = []
        let allowedKeys: Set<String> = ["id", "match", "command", "cwd"]
        let objectKeys = Set(object.keys)
        for key in objectKeys.subtracting(allowedKeys) {
            failures.append(.unknownField(path: path + [.key(key)], field: key))
        }
        for key in ["id", "match", "command", "cwd"] where object[key] == nil {
            failures.append(.missingField(path: path, field: key))
        }

        var id: RestartCommandDefinitionID?
        if let rawID = object["id"] {
            if let value = rawID as? String,
               let decoded = RestartCommandDefinitionID(rawValue: value) {
                id = decoded
            } else {
                failures.append(.invalidValue(
                    path: path + [.key("id")],
                    field: "id",
                    reason: .invalidDefinitionID
                ))
            }
        }

        var match: RestartCommandMatchDefinition?
        if let rawMatch = object["match"] {
            if let value = rawMatch as? [String: Any] {
                let result = decodeMatch(value, at: path + [.key("match")])
                match = result.match
                failures.append(contentsOf: result.failures)
            } else {
                failures.append(.invalidValue(
                    path: path + [.key("match")],
                    field: "match",
                    reason: .invalidMatch
                ))
            }
        }

        var command: String?
        if let rawCommand = object["command"] {
            if let value = rawCommand as? String {
                command = value
            } else {
                failures.append(.invalidValue(
                    path: path + [.key("command")],
                    field: "command",
                    reason: .invalidJSON
                ))
            }
        }

        var cwd: RestartCommandWorkingDirectoryPolicy?
        if let rawCWD = object["cwd"] {
            if let value = rawCWD as? String,
               let decoded = RestartCommandWorkingDirectoryPolicy(rawValue: value) {
                cwd = decoded
            } else {
                failures.append(.invalidValue(
                    path: path + [.key("cwd")],
                    field: "cwd",
                    reason: .invalidJSON
                ))
            }
        }

        guard let id, let match, let command, let cwd else {
            return (nil, failures)
        }
        let definition = RestartCommandDefinition(id: id, match: match, command: command, cwd: cwd)
        failures.append(contentsOf: definitionFailures(definition, at: path))
        return failures.isEmpty ? (definition, []) : (nil, failures)
    }

    private static func decodeMatch(
        _ object: [String: Any],
        at path: RestartCommandJSONPath
    ) -> (match: RestartCommandMatchDefinition?, failures: [RestartCommandValidationFailure]) {
        var failures: [RestartCommandValidationFailure] = []
        let allowedKeys: Set<String> = ["executable", "argumentTailPrefix", "environment"]
        for key in Set(object.keys).subtracting(allowedKeys) {
            failures.append(.unknownField(path: path + [.key(key)], field: key))
        }
        if object["executable"] == nil {
            failures.append(.missingField(path: path, field: "executable"))
        }

        var executable: String?
        if let rawExecutable = object["executable"] {
            if let value = rawExecutable as? String {
                executable = value
            } else {
                failures.append(.invalidValue(
                    path: path + [.key("executable")],
                    field: "executable",
                    reason: .emptyExecutable
                ))
            }
        }

        var argumentTailPrefix: [String]?
        if let rawPrefix = object["argumentTailPrefix"] {
            if let values = rawPrefix as? [Any] {
                var decoded: [String] = []
                for (index, rawValue) in values.enumerated() {
                    if let value = rawValue as? String {
                        decoded.append(value)
                    } else {
                        failures.append(.invalidValue(
                            path: path + [.key("argumentTailPrefix"), .index(index)],
                            field: "argumentTailPrefix",
                            reason: .invalidArgumentPrefix
                        ))
                    }
                }
                if decoded.count == values.count {
                    argumentTailPrefix = decoded
                }
            } else {
                failures.append(.invalidValue(
                    path: path + [.key("argumentTailPrefix")],
                    field: "argumentTailPrefix",
                    reason: .invalidArgumentPrefix
                ))
            }
        }

        var environment: [String: RestartCommandEnvironmentPredicate]?
        if let rawEnvironment = object["environment"] {
            if let values = rawEnvironment as? [String: Any] {
                var decoded: [String: RestartCommandEnvironmentPredicate] = [:]
                for key in values.keys.sorted() {
                    let predicatePath = path + [.key("environment"), .key(key)]
                    guard let predicateObject = values[key] as? [String: Any] else {
                        failures.append(.invalidValue(
                            path: predicatePath,
                            field: key,
                            reason: .invalidEnvironmentPredicate
                        ))
                        continue
                    }
                    let result = decodePredicate(predicateObject, at: predicatePath)
                    failures.append(contentsOf: result.failures)
                    if let predicate = result.predicate {
                        decoded[key] = predicate
                    }
                }
                if decoded.count == values.count {
                    environment = decoded
                }
            } else {
                failures.append(.invalidValue(
                    path: path + [.key("environment")],
                    field: "environment",
                    reason: .invalidEnvironmentPredicate
                ))
            }
        }

        guard let executable else { return (nil, failures) }
        return (
            RestartCommandMatchDefinition(
                executable: executable,
                argumentTailPrefix: argumentTailPrefix,
                environment: environment
            ),
            failures
        )
    }

    private static func decodePredicate(
        _ object: [String: Any],
        at path: RestartCommandJSONPath
    ) -> (predicate: RestartCommandEnvironmentPredicate?, failures: [RestartCommandValidationFailure]) {
        var failures: [RestartCommandValidationFailure] = []
        let allowedKeys: Set<String> = ["state", "normalizedFinalComponent"]
        for key in Set(object.keys).subtracting(allowedKeys) {
            failures.append(.unknownField(path: path + [.key(key)], field: key))
        }
        if object["state"] == nil {
            failures.append(.missingField(path: path, field: "state"))
        }

        var state: RestartCommandEnvironmentPredicate.State?
        if let rawState = object["state"] {
            if let value = rawState as? String,
               let decoded = RestartCommandEnvironmentPredicate.State(rawValue: value) {
                state = decoded
            } else {
                failures.append(.invalidValue(
                    path: path + [.key("state")],
                    field: "state",
                    reason: .invalidEnvironmentPredicate
                ))
            }
        }

        var normalizedFinalComponent: String?
        if let rawComponent = object["normalizedFinalComponent"] {
            if let value = rawComponent as? String {
                normalizedFinalComponent = value
            } else {
                failures.append(.invalidValue(
                    path: path + [.key("normalizedFinalComponent")],
                    field: "normalizedFinalComponent",
                    reason: .invalidEnvironmentPredicate
                ))
            }
        }

        if state == .absent, object.keys.contains("normalizedFinalComponent") {
            failures.append(.invalidValue(
                path: path + [.key("normalizedFinalComponent")],
                field: "normalizedFinalComponent",
                reason: .invalidEnvironmentPredicate
            ))
        }

        guard let state else { return (nil, failures) }
        let predicate = RestartCommandEnvironmentPredicate(
            state: state,
            normalizedFinalComponent: normalizedFinalComponent
        )
        return failures.isEmpty ? (predicate, []) : (nil, failures)
    }

    private static func definitionFailures(
        _ definition: RestartCommandDefinition,
        at path: RestartCommandJSONPath
    ) -> [RestartCommandValidationFailure] {
        var failures: [RestartCommandValidationFailure] = []
        let matchPath = path + [.key("match")]
        let executablePath = matchPath + [.key("executable")]
        if !isValidPathComponent(definition.match.executable) {
            failures.append(.invalidValue(
                path: executablePath,
                field: "executable",
                reason: .emptyExecutable
            ))
        }

        if let prefix = definition.match.argumentTailPrefix {
            let prefixPath = matchPath + [.key("argumentTailPrefix")]
            if prefix.isEmpty {
                failures.append(.invalidValue(
                    path: prefixPath,
                    field: "argumentTailPrefix",
                    reason: .invalidArgumentPrefix
                ))
            }
            for (index, value) in prefix.enumerated() where value.isEmpty {
                failures.append(.invalidValue(
                    path: prefixPath + [.index(index)],
                    field: "argumentTailPrefix",
                    reason: .invalidArgumentPrefix
                ))
            }
        }

        if let environment = definition.match.environment {
            let environmentPath = matchPath + [.key("environment")]
            if environment.isEmpty || environment.count > maximumEnvironmentPredicateCount {
                failures.append(.invalidValue(
                    path: environmentPath,
                    field: "environment",
                    reason: .invalidEnvironmentPredicate
                ))
            }
            for key in environment.keys.sorted() {
                let predicatePath = environmentPath + [.key(key)]
                if key.range(of: environmentNamePattern, options: .regularExpression) == nil {
                    failures.append(.invalidValue(
                        path: predicatePath,
                        field: "environment",
                        reason: .invalidEnvironmentPredicate
                    ))
                }
                guard let predicate = environment[key] else { continue }
                switch predicate.state {
                case .absent:
                    if predicate.normalizedFinalComponent != nil {
                        failures.append(.invalidValue(
                            path: predicatePath + [.key("normalizedFinalComponent")],
                            field: "normalizedFinalComponent",
                            reason: .invalidEnvironmentPredicate
                        ))
                    }
                case .present:
                    guard let component = predicate.normalizedFinalComponent else {
                        failures.append(.missingField(
                            path: predicatePath,
                            field: "normalizedFinalComponent",
                            reason: .invalidEnvironmentPredicate
                        ))
                        continue
                    }
                    if !isValidPathComponent(component) {
                        failures.append(.invalidValue(
                            path: predicatePath + [.key("normalizedFinalComponent")],
                            field: "normalizedFinalComponent",
                            reason: .invalidEnvironmentPredicate
                        ))
                    }
                }
            }
        }

        let commandPath = path + [.key("command")]
        if definition.command.isEmpty {
            failures.append(.invalidValue(path: commandPath, field: "command", reason: .emptyCommand))
        } else if !RestartCommandGrammar.isSafeSingleCommand(definition.command) {
            failures.append(.invalidValue(path: commandPath, field: "command", reason: .unsafeCommand))
        } else if definition.command.utf8.count > maximumCommandUTF8Bytes {
            failures.append(.invalidValue(path: commandPath, field: "command", reason: .commandTooLong))
        }
        return failures
    }

    private static func isSchemaVersion(_ value: Any) -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return false
        }
        return number.doubleValue == Double(schemaVersion)
    }

    private static func isValidPathComponent(_ value: String) -> Bool {
        value.range(of: pathComponentPattern, options: .regularExpression) != nil
    }
}

private enum RestartCommandJSONPathComponent: Hashable, Sendable {
    case key(String)
    case index(Int)
}

private typealias RestartCommandJSONPath = [RestartCommandJSONPathComponent]

private struct RestartCommandSourcePosition: Equatable, Sendable {
    let line: Int
    let column: Int
}

private struct RestartCommandValidationFailure: Sendable {
    let kind: RestartCommandDefinitionProblem.Kind
    let path: RestartCommandJSONPath
    let field: String?
    let reason: RestartCommandDefinitionError

    static func unknownField(
        path: RestartCommandJSONPath,
        field: String
    ) -> RestartCommandValidationFailure {
        RestartCommandValidationFailure(
            kind: .unknownField,
            path: path,
            field: field,
            reason: .unknownField
        )
    }

    static func missingField(
        path: RestartCommandJSONPath,
        field: String,
        reason: RestartCommandDefinitionError = .missingField
    ) -> RestartCommandValidationFailure {
        RestartCommandValidationFailure(
            kind: .missingField,
            path: path,
            field: field,
            reason: reason
        )
    }

    static func invalidValue(
        path: RestartCommandJSONPath,
        field: String,
        reason: RestartCommandDefinitionError
    ) -> RestartCommandValidationFailure {
        RestartCommandValidationFailure(
            kind: .invalidValue,
            path: path,
            field: field,
            reason: reason
        )
    }

    static func repeatedID(path: RestartCommandJSONPath) -> RestartCommandValidationFailure {
        RestartCommandValidationFailure(
            kind: .repeatedID,
            path: path,
            field: nil,
            reason: .duplicateDefinition
        )
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

private func validateStrictJSONSyntax(
    _ data: Data
) throws -> [RestartCommandJSONPath: RestartCommandSourcePosition] {
    try validateStrictJSONLexicalSyntax(data)
    var scanner = RestartCommandStructuralScanner(data: data)
    return try scanner.scan()
}

private func indexAfterLeadingByteOrderMark(
    in data: Data,
    from index: Data.Index
) -> Data.Index {
    guard data.distance(from: index, to: data.endIndex) >= 3,
          data[index] == 0xEF,
          data[data.index(after: index)] == 0xBB,
          data[data.index(index, offsetBy: 2)] == 0xBF else {
        return index
    }
    return data.index(index, offsetBy: 3)
}

private func validateStrictJSONLexicalSyntax(_ data: Data) throws {
    var inString = false
    var isEscaped = false
    var lastSignificantChar: UInt8? = nil
    var lastSignificantLine = 1
    var line = 1

    var i = indexAfterLeadingByteOrderMark(in: data, from: data.startIndex)
    while i < data.endIndex {
        let byte = data[i]

        if inString {
            if isEscaped {
                isEscaped = false
            } else if byte == UInt8(ascii: "\\") {
                isEscaped = true
            } else if byte == UInt8(ascii: "\"") {
                inString = false
                lastSignificantChar = UInt8(ascii: "\"")
                lastSignificantLine = line
            } else if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") {
                throw RestartCommandDefinitionError.invalidJSONAtLine(line)
            }
            i = data.index(after: i)
            continue
        }

        switch byte {
        case UInt8(ascii: "\""):
            inString = true
            lastSignificantChar = UInt8(ascii: "\"")
            lastSignificantLine = line
        case UInt8(ascii: " "), UInt8(ascii: "\t"):
            break
        case UInt8(ascii: "\r"):
            let next = data.index(after: i)
            if next == data.endIndex || data[next] != UInt8(ascii: "\n") {
                line += 1
            }
        case UInt8(ascii: "\n"):
            line += 1
        case UInt8(ascii: "/"):
            throw RestartCommandDefinitionError.invalidJSONAtLine(line)
        case UInt8(ascii: ","):
            if lastSignificantChar == UInt8(ascii: ",") ||
                lastSignificantChar == UInt8(ascii: "{") ||
                lastSignificantChar == UInt8(ascii: "[") ||
                lastSignificantChar == nil {
                throw RestartCommandDefinitionError.invalidJSONAtLine(line)
            }
            lastSignificantChar = UInt8(ascii: ",")
            lastSignificantLine = line
        case UInt8(ascii: "}"), UInt8(ascii: "]"):
            if lastSignificantChar == UInt8(ascii: ",") {
                throw RestartCommandDefinitionError.invalidJSONAtLine(lastSignificantLine)
            }
            lastSignificantChar = byte
            lastSignificantLine = line
        default:
            lastSignificantChar = byte
            lastSignificantLine = line
        }
        i = data.index(after: i)
    }

    if inString {
        throw RestartCommandDefinitionError.invalidJSONAtLine(line)
    }
}

private struct RestartCommandStructuralScanner {
    private static let maximumContainerDepth = 64

    let data: Data
    var index: Data.Index
    var line = 1
    var column = 1
    var positions: [RestartCommandJSONPath: RestartCommandSourcePosition] = [:]

    init(data: Data) {
        self.data = data
        index = data.startIndex
    }

    mutating func scan() throws -> [RestartCommandJSONPath: RestartCommandSourcePosition] {
        index = indexAfterLeadingByteOrderMark(in: data, from: index)
        skipWhitespace()
        guard index < data.endIndex else {
            throw RestartCommandDefinitionError.invalidJSONAtLine(line)
        }
        positions[[]] = position
        try scanValue(at: [], containerDepth: 0)
        skipWhitespace()
        guard index == data.endIndex else {
            throw RestartCommandDefinitionError.invalidJSONAtLine(line)
        }
        return positions
    }

    private var position: RestartCommandSourcePosition {
        RestartCommandSourcePosition(line: line, column: column)
    }

    private mutating func scanValue(
        at path: RestartCommandJSONPath,
        containerDepth: Int
    ) throws {
        guard index < data.endIndex else {
            throw RestartCommandDefinitionError.invalidJSONAtLine(line)
        }
        switch data[index] {
        case UInt8(ascii: "{"):
            guard containerDepth < Self.maximumContainerDepth else {
                throw RestartCommandDefinitionError.invalidJSONAtLine(line)
            }
            try scanObject(at: path, containerDepth: containerDepth + 1)
        case UInt8(ascii: "["):
            guard containerDepth < Self.maximumContainerDepth else {
                throw RestartCommandDefinitionError.invalidJSONAtLine(line)
            }
            try scanArray(at: path, containerDepth: containerDepth + 1)
        case UInt8(ascii: "\""):
            _ = try scanString()
        default:
            try scanScalar()
        }
    }

    private mutating func scanObject(
        at path: RestartCommandJSONPath,
        containerDepth: Int
    ) throws {
        consumeByte()
        skipWhitespace()
        if consumeIf(UInt8(ascii: "}")) { return }

        var keys: Set<String> = []
        while true {
            guard index < data.endIndex, data[index] == UInt8(ascii: "\"") else {
                throw RestartCommandDefinitionError.invalidJSONAtLine(line)
            }
            let keyPosition = position
            let key = try scanString()
            if !keys.insert(key).inserted {
                throw RestartCommandDefinitionError.invalidJSONAtLine(keyPosition.line)
            }
            let memberPath = path + [.key(key)]
            positions[memberPath] = keyPosition

            skipWhitespace()
            guard consumeIf(UInt8(ascii: ":")) else {
                throw RestartCommandDefinitionError.invalidJSONAtLine(line)
            }
            skipWhitespace()
            try scanValue(at: memberPath, containerDepth: containerDepth)
            skipWhitespace()
            if consumeIf(UInt8(ascii: "}")) { return }
            guard consumeIf(UInt8(ascii: ",")) else {
                throw RestartCommandDefinitionError.invalidJSONAtLine(line)
            }
            skipWhitespace()
        }
    }

    private mutating func scanArray(
        at path: RestartCommandJSONPath,
        containerDepth: Int
    ) throws {
        consumeByte()
        skipWhitespace()
        if consumeIf(UInt8(ascii: "]")) { return }

        var elementIndex = 0
        while true {
            let elementPath = path + [.index(elementIndex)]
            positions[elementPath] = position
            try scanValue(at: elementPath, containerDepth: containerDepth)
            elementIndex += 1
            skipWhitespace()
            if consumeIf(UInt8(ascii: "]")) { return }
            guard consumeIf(UInt8(ascii: ",")) else {
                throw RestartCommandDefinitionError.invalidJSONAtLine(line)
            }
            skipWhitespace()
        }
    }

    private mutating func scanString() throws -> String {
        let start = index
        consumeByte()
        var escaped = false
        while index < data.endIndex {
            let byte = data[index]
            consumeByte()
            if escaped {
                escaped = false
            } else if byte == UInt8(ascii: "\\") {
                escaped = true
            } else if byte == UInt8(ascii: "\"") {
                let token = data.subdata(in: start..<index)
                guard let value = try? JSONSerialization.jsonObject(
                    with: token,
                    options: [.fragmentsAllowed]
                ) as? String else {
                    throw RestartCommandDefinitionError.invalidJSONAtLine(line)
                }
                return value
            }
        }
        throw RestartCommandDefinitionError.invalidJSONAtLine(line)
    }

    private mutating func scanScalar() throws {
        let start = index
        while index < data.endIndex {
            let byte = data[index]
            if byte == UInt8(ascii: ",") || byte == UInt8(ascii: "]") ||
                byte == UInt8(ascii: "}") || isWhitespace(byte) {
                break
            }
            consumeByte()
        }
        guard index != start else {
            throw RestartCommandDefinitionError.invalidJSONAtLine(line)
        }
    }

    private mutating func skipWhitespace() {
        while index < data.endIndex, isWhitespace(data[index]) {
            consumeByte()
        }
    }

    private func isWhitespace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") ||
            byte == UInt8(ascii: "\r") || byte == UInt8(ascii: "\n")
    }

    @discardableResult
    private mutating func consumeIf(_ byte: UInt8) -> Bool {
        guard index < data.endIndex, data[index] == byte else { return false }
        consumeByte()
        return true
    }

    private mutating func consumeByte() {
        let byte = data[index]
        let next = data.index(after: index)
        if byte == UInt8(ascii: "\r") {
            if next < data.endIndex, data[next] == UInt8(ascii: "\n") {
                column += 1
            } else {
                line += 1
                column = 1
            }
        } else if byte == UInt8(ascii: "\n") {
            line += 1
            column = 1
        } else {
            column += 1
        }
        index = next
    }
}
