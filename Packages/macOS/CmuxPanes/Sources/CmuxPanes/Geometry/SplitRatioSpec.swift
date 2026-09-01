public import CoreGraphics
import Foundation

/// A weight vector written once and applied at any span count (`#cm-67.1`).
///
/// Both the built-in Arrange Splits patterns and the user-defined ones in
/// `cmux.json` are `SplitRatioSpec`s, so there is one span-adaptation rule
/// rather than one per origin. `mainFirst` is literally `"2:1"`; a user's
/// `"1:1:0.5"` runs the same code.
///
/// The vector is validated at init, so a value of this type is always usable:
/// at least two weights, every one finite and greater than zero. Callers that
/// parse untrusted text get `nil` and drop that one entry.
public struct SplitRatioSpec: Equatable, Sendable {
    /// The weights exactly as written, in spatial order.
    public let weights: [CGFloat]

    /// Fails when there are fewer than two weights, or any is non-finite or
    /// not greater than zero. A zero or negative share has no geometry, and
    /// `ratioDividerPlan` rejects the same vectors — this just fails earlier,
    /// where the offending entry can still be named.
    public init?(weights: [CGFloat]) {
        guard weights.count >= 2,
              weights.allSatisfy({ $0.isFinite && $0 > 0 })
        else { return nil }
        self.weights = weights
    }

    /// Parses the `1:1:0.5` notation the Arrange Splits menu already prints as
    /// its ratio hints, so what a user reads in the menu is what they type.
    ///
    /// Every colon-separated field must be a number — an empty field (`"1::2"`,
    /// `"1:1:"`) fails rather than being skipped, because silently dropping a
    /// field would apply a vector the user did not write.
    public init?(_ text: String) {
        let fields = text.split(separator: ":", omittingEmptySubsequences: false)
        var parsed: [CGFloat] = []
        parsed.reserveCapacity(fields.count)
        for field in fields {
            let trimmed = field.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let value = Double(trimmed) else { return nil }
            parsed.append(CGFloat(value))
        }
        self.init(weights: parsed)
    }

    /// The weights for `spanCount` spans, or `nil` below two spans.
    ///
    /// Anchors plus a repeating `weights[1]` **in place**, which makes
    /// `spanCount == weights.count` exactly what was written and preserves
    /// every other weight at higher counts. A head/filler/tail rule would turn
    /// `2:3:1:0.5` into `2:3:3:0.5` at four spans and silently drop the `1`.
    ///
    /// Below the written count the head and tail are kept and the vector is
    /// trimmed from just after the head, so `1:1:0.5` at two spans is `1:0.5`.
    public func ratios(forSpanCount spanCount: Int) -> [CGFloat]? {
        guard spanCount >= 2 else { return nil }
        let written = weights.count
        guard spanCount < written else {
            return [weights[0]]
                + Array(repeating: weights[1], count: spanCount - written + 1)
                + Array(weights[2...])
        }
        return [weights[0]] + Array(weights[(written - spanCount + 1)...])
    }
}
