import AppKit

// cmux-rbf #cm-73.16: bundle resources, never a path supplied by a saved file.
@MainActor
enum FigmaKindIcon {
    // Keep this kind list aligned with FigmaFileLink.kindPrefixes in CLI/FigmaFileLink.swift.
    static func kind(for link: URL) -> FigmaNewFileLink.Kind? {
        switch link.pathComponents.dropFirst().first {
        case "design", "file": return .design
        case "board": return .board
        case "slides": return .slides
        default: return nil
        }
    }

    // Decode each shipped image at most once per process, including across menu builds.
    private static let designImage = load("design")
    private static let boardImage = load("figjam")
    private static let slidesImage = load("slides")

    static func image(for kind: FigmaNewFileLink.Kind) -> NSImage? {
        switch kind {
        case .design: return designImage
        case .board: return boardImage
        case .slides: return slidesImage
        }
    }

    private static func load(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: "FigmaKind-\(name)", withExtension: "svg"),
              let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { return nil }
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = false
        return image
    }
}
