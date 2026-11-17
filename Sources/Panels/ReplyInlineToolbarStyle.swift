import AppKit

/// The color styling of the Reply inline toolbar (`cm-136.8`).
///
/// Each color answer depends on:
/// - `fill`: appearance (`.light` | `.dark`) and state (`.rest` | `.hover` | `.pressed`)
/// - `edge`: appearance and Increase Contrast (`on` | `off`)
/// - `label`: appearance
public enum ReplyInlineToolbarStyle: Sendable, Equatable {
    public enum Appearance: Sendable, Equatable {
        case light
        case dark
    }

    public enum State: Sendable, Equatable {
        case rest
        case hover
        case pressed
    }

    public struct RGB: Sendable, Equatable {
        public let r: UInt8
        public let g: UInt8
        public let b: UInt8

        public var hex: String {
            String(format: "#%02X%02X%02X", r, g, b)
        }

        public init(r: UInt8, g: UInt8, b: UInt8) {
            self.r = r
            self.g = g
            self.b = b
        }

        public var nsColor: NSColor {
            NSColor(srgbRed: CGFloat(r) / 255.0, green: CGFloat(g) / 255.0, blue: CGFloat(b) / 255.0, alpha: 1.0)
        }

        public var relativeLuminance: Double {
            func channel(_ c: UInt8) -> Double {
                let v = Double(c) / 255.0
                return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
        }

        public func contrastRatio(with other: RGB) -> Double {
            let l1 = self.relativeLuminance
            let l2 = other.relativeLuminance
            let hi = max(l1, l2)
            let lo = min(l1, l2)
            return (hi + 0.05) / (lo + 0.05)
        }
    }

    public static func fill(for appearance: Appearance, state: State) -> RGB {
        switch (appearance, state) {
        case (.light, .rest):
            RGB(r: 227, g: 227, b: 232)
        case (.light, .hover):
            RGB(r: 211, g: 211, b: 216)
        case (.light, .pressed):
            RGB(r: 196, g: 196, b: 201)
        case (.dark, .rest):
            RGB(r: 74, g: 82, b: 76)
        case (.dark, .hover):
            RGB(r: 88, g: 95, b: 88)
        case (.dark, .pressed):
            RGB(r: 101, g: 107, b: 101)
        }
    }

    public static func edge(for appearance: Appearance, increaseContrast: Bool = false) -> RGB {
        switch (appearance, increaseContrast) {
        case (.light, false):
            RGB(r: 140, g: 140, b: 148)
        case (.light, true):
            RGB(r: 32, g: 32, b: 36)
        case (.dark, false):
            RGB(r: 126, g: 135, b: 129)
        case (.dark, true):
            RGB(r: 244, g: 241, b: 232)
        }
    }

    public static func label(for appearance: Appearance) -> RGB {
        switch appearance {
        case .light:
            RGB(r: 32, g: 32, b: 36)
        case .dark:
            RGB(r: 244, g: 241, b: 232)
        }
    }

    public static func fillColor(for appearance: Appearance, state: State) -> NSColor {
        fill(for: appearance, state: state).nsColor
    }

    public static func edgeColor(for appearance: Appearance, increaseContrast: Bool = false) -> NSColor {
        edge(for: appearance, increaseContrast: increaseContrast).nsColor
    }

    public static func labelColor(for appearance: Appearance) -> NSColor {
        label(for: appearance).nsColor
    }
}
