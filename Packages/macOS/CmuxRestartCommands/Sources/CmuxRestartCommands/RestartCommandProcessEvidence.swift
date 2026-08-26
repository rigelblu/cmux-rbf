internal import Foundation

/// Tri-state environment evidence. Unreadable evidence is never treated as absence.
public enum RestartCommandEnvironmentEvidence: Equatable, Sendable {
    case present(String)
    case absent
    case unavailable
}

/// Position-preserving process evidence used by the allowlist matcher.
public struct RestartCommandProcessEvidence: Equatable, Sendable {
    public let arguments: [String]
    public let environment: [String: RestartCommandEnvironmentEvidence]

    public init(
        arguments: [String],
        environment: [String: RestartCommandEnvironmentEvidence]
    ) {
        self.arguments = arguments
        self.environment = environment
    }
}

/// Strict decoder for the raw `KERN_PROCARGS2` byte layout.
public struct RestartCommandProcessEvidenceDecoder: Sendable {
    public init() {}

    /// Decodes argv and only the named environment keys.
    ///
    /// Relevant malformed or duplicate environment entries become `.unavailable`;
    /// unrelated non-UTF-8 values do not poison a provably absent target key.
    public func decode(
        _ bytes: [UInt8],
        environmentKeys: Set<String>
    ) -> RestartCommandProcessEvidence? {
        let integerSize = MemoryLayout<Int32>.size
        guard bytes.count > integerSize else { return nil }

        var argcRaw: Int32 = 0
        withUnsafeMutableBytes(of: &argcRaw) { rawBuffer in
            rawBuffer.copyBytes(from: bytes.prefix(integerSize))
        }
        let argc = Int(Int32(littleEndian: argcRaw))
        guard argc > 0, argc <= 4_096 else { return nil }

        var index = integerSize
        guard consumeTerminatedString(in: bytes, index: &index) != nil else { return nil }
        while index < bytes.count, bytes[index] == 0 { index += 1 }

        var arguments: [String] = []
        arguments.reserveCapacity(argc)
        for _ in 0..<argc {
            guard let raw = consumeTerminatedString(in: bytes, index: &index),
                  let argument = String(bytes: raw, encoding: .utf8) else {
                return nil
            }
            arguments.append(argument)
        }
        guard arguments.count == argc else { return nil }

        let keyBytes = Dictionary(uniqueKeysWithValues: environmentKeys.map {
            ($0, Array(($0 + "=").utf8))
        })
        var values = Dictionary(uniqueKeysWithValues: environmentKeys.map {
            ($0, RestartCommandEnvironmentEvidence.absent)
        })
        var seenKeys: Set<String> = []
        var structurallyComplete = true

        while index < bytes.count {
            while index < bytes.count, bytes[index] == 0 { index += 1 }
            guard index < bytes.count else { break }
            guard let raw = consumeTerminatedString(in: bytes, index: &index) else {
                structurallyComplete = false
                break
            }
            for key in environmentKeys {
                guard let prefix = keyBytes[key], raw.starts(with: prefix) else { continue }
                if !seenKeys.insert(key).inserted {
                    values[key] = .unavailable
                    continue
                }
                let rawValue = raw.dropFirst(prefix.count)
                guard let value = String(bytes: rawValue, encoding: .utf8) else {
                    values[key] = .unavailable
                    continue
                }
                values[key] = .present(value)
            }
        }

        if !structurallyComplete {
            for key in environmentKeys where !seenKeys.contains(key) {
                values[key] = .unavailable
            }
        }
        return RestartCommandProcessEvidence(arguments: arguments, environment: values)
    }

    private func consumeTerminatedString(
        in bytes: [UInt8],
        index: inout Int
    ) -> ArraySlice<UInt8>? {
        guard index < bytes.count else { return nil }
        let start = index
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        guard index < bytes.count else { return nil }
        let value = bytes[start..<index]
        index += 1
        return value
    }
}

/// The one unambiguous definition matched by a foreground process.
public struct RestartCommandMatch: Equatable, Sendable {
    public let definitionID: RestartCommandDefinitionID
    public let detectorFingerprint: String

    public init(definitionID: RestartCommandDefinitionID, detectorFingerprint: String) {
        self.definitionID = definitionID
        self.detectorFingerprint = detectorFingerprint
    }
}

/// Pure matcher for normalized restart definitions.
public struct RestartCommandMatcher: Sendable {
    private let definitions: RestartCommandDefinitionSet

    public init(definitions: RestartCommandDefinitionSet) {
        self.definitions = definitions
    }

    /// Returns a match only when exactly one definition accepts the evidence.
    public func match(_ evidence: RestartCommandProcessEvidence) -> RestartCommandMatch? {
        let matchingDefinitions = definitions.definitions.filter { definition in
            self.matches(definition, evidence: evidence)
        }
        guard matchingDefinitions.count == 1,
              let definition = matchingDefinitions.first,
              let fingerprint = definitions.detectorFingerprint(for: definition.id) else {
            return nil
        }
        return RestartCommandMatch(
            definitionID: definition.id,
            detectorFingerprint: fingerprint
        )
    }

    private func matches(
        _ definition: RestartCommandDefinition,
        evidence: RestartCommandProcessEvidence
    ) -> Bool {
        guard let executable = evidence.arguments.first,
              (executable as NSString).lastPathComponent == definition.match.executable else {
            return false
        }
        if let prefix = definition.match.argumentTailPrefix {
            let tail = Array(evidence.arguments.dropFirst())
            guard tail.count >= prefix.count,
                  Array(tail.prefix(prefix.count)) == prefix else {
                return false
            }
        }
        if let predicates = definition.match.environment {
            for (key, predicate) in predicates {
                let observed = evidence.environment[key] ?? .unavailable
                switch (predicate.state, observed) {
                case (.absent, .absent):
                    continue
                case (.present, .present(let value)):
                    guard let expected = predicate.normalizedFinalComponent,
                          normalizedFinalComponent(value) == expected else {
                        return false
                    }
                default:
                    return false
                }
            }
        }
        return true
    }

    private func normalizedFinalComponent(_ value: String) -> String? {
        guard !value.isEmpty else { return nil }
        let normalized = (value as NSString).standardizingPath
        let component = (normalized as NSString).lastPathComponent
        return component.isEmpty ? nil : component
    }
}
