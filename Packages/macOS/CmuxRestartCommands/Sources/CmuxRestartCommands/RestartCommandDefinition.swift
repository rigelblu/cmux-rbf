public import Foundation
internal import CryptoKit

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

/// Validation failures surfaced by the dedicated definitions editor and Settings.
public enum RestartCommandDefinitionError: Error, Equatable, Sendable {
    case invalidJSON
    case invalidJSONAtLine(Int)
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
    case unusableBundledResource

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
    public static let approvalDomain = Data("cmux.restart-commands.approval.v1".utf8)
    public static let detectorDomain = Data("cmux.restart-commands.detector.v1".utf8)

    public let definitions: [RestartCommandDefinition]

    public init(definitions: [RestartCommandDefinition]) throws {
        self.definitions = try Self.validatedAndSorted(definitions)
    }

    /// Decodes strict JSON. `$schema` is editor metadata and never enters authority.
    public static func decodeJSON(_ data: Data) throws -> RestartCommandDefinitionSet {
        try validateStrictJSONSyntax(data)
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
        return definitions.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    private static func validateRawDefinitionShape(_ object: [String: Any]) throws {
        guard Set(object.keys).isSubset(of: ["id", "match", "command", "cwd"]),
              Set(object.keys) == ["id", "match", "command", "cwd"] else {
            throw RestartCommandDefinitionError.unknownField
        }
        guard let rawID = object["id"] as? String,
              RestartCommandDefinitionID.isValidSlug(rawID) else {
            throw RestartCommandDefinitionError.invalidJSON
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

private func validateStrictJSONSyntax(_ data: Data) throws {
    var inString = false
    var isEscaped = false
    var lastSignificantChar: UInt8? = nil
    var lastSignificantLine = 1
    var line = 1

    var i = data.startIndex
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
