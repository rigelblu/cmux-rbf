import CryptoKit
import Foundation

/// Correlates one Claude permission with its Feed request across hook processes.
struct ClaudePendingPermission: Codable, Equatable {
    let toolName: String
    let inputFingerprint: String
    let requestId: String
    let agentId: String?

    /// The fingerprint a permission and its tool's completion are paired by (cm-128.1). Claude's `AskUserQuestion` completion
    /// repeats the `questions` of its request and adds `answers` and `annotations`, so that tool is paired on `questions` alone.
    /// Every other tool is paired on its whole input. Both sides call this, so they cannot drift.
    static func fingerprint(toolName: String, input: Any) -> String? {
        if toolName == "AskUserQuestion", let object = input as? [String: Any], let questions = object["questions"] {
            return fingerprint(questions)
        }
        return fingerprint(input)
    }

    private static func fingerprint(_ input: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .fragmentsAllowed]) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
