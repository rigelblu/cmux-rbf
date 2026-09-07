import Foundation
import Testing

/// The one recogniser of a Figma file link, compiled into the CLI and the app.
@Suite("FigmaFileLink")
struct FigmaFileLinkTests {

    private func isFile(_ raw: String) -> Bool { FigmaFileLink.isFileLink(URL(string: raw)!) }
    private func isEditor(_ raw: String) -> Bool { FigmaFileLink.isEditorLink(URL(string: raw)!) }

    @Test("an https link to each of the four file kinds is a file link")
    func acceptsTheFourKinds() {
        for kind in ["design", "file", "board", "slides"] {
            let raw = "https://www.figma.com/\(kind)/KEY/slug"
            #expect(isFile(raw), "\(kind)")
            #expect(isEditor(raw), "\(kind)")
        }
    }

    @Test("the editor link takes figma.com and www.figma.com, and the read view's host is not one")
    func editorHostsExcludeTheReadView() {
        #expect(isEditor("https://figma.com/design/KEY/slug"))
        #expect(isEditor("https://www.figma.com/design/KEY/slug"))
        #expect(!isEditor("https://embed.figma.com/design/KEY/slug"))
        #expect(isFile("https://embed.figma.com/design/KEY/slug"))
    }

    @Test("a link that is not https is not a file link")
    func refusesEverySchemeButHTTPS() {
        for raw in [
            "http://www.figma.com/design/KEY/slug",
            "file://www.figma.com/design/KEY/slug",
            "javascript://www.figma.com/design/KEY/slug"
        ] {
            #expect(!isFile(raw), "\(raw)")
            #expect(!isEditor(raw), "\(raw)")
        }
    }

    @Test("a path holding `..` is not a file link, however it is written")
    func refusesDotDot() {
        for raw in [
            "https://www.figma.com/design/../community",
            "https://www.figma.com/design/KEY/..",
            "https://www.figma.com/design/%2e%2e/community",
            "https://www.figma.com/design/%2E%2E%2Fcommunity"
        ] {
            #expect(!isFile(raw), "\(raw)")
            #expect(!isEditor(raw), "\(raw)")
        }
    }

    @Test("a path holding a backslash is not a file link, typed or encoded")
    func refusesBackslash() {
        // A browser reads `\` as `/` in an https path, so `..\` is `../`.
        for raw in [
            "https://www.figma.com/design/..\\community",
            "https://www.figma.com/design/%2e%2e%5Ccommunity",
            "https://www.figma.com/design/..%5Ccommunity",
            "https://www.figma.com/design/KEY/a%5cb"
        ] {
            #expect(!isFile(raw), "\(raw)")
            #expect(!isEditor(raw), "\(raw)")
        }
    }

    @Test("a link with a port, a user name or a password is not a file link")
    func refusesPortAndCredentials() {
        for raw in [
            "https://www.figma.com:443/design/KEY/slug",
            "https://www.figma.com:8443/design/KEY/slug",
            "https://embed.figma.com:443/design/KEY/slug",
            "https://user@www.figma.com/design/KEY/slug",
            "https://user:pw@www.figma.com/design/KEY/slug",
            "https://:pw@www.figma.com/design/KEY/slug",
            // Foundation reports no port for these two, and the address built keeps the text.
            "https://www.figma.com:9223372036854775808/design/KEY/slug?node-id=1-2",
            "https://www.figma.com:/design/KEY/slug"
        ] {
            #expect(!isFile(raw), "\(raw)")
            #expect(!isEditor(raw), "\(raw)")
        }
    }

    @Test("a name that merely contains two dots is still a file link")
    func keepsDotsInsideAName() {
        #expect(isFile("https://www.figma.com/design/KEY/a..b"))
    }

    @Test("lookalike hosts and other Figma pages are not file links")
    func refusesLookalikes() {
        for raw in [
            "https://notfigma.com/design/KEY/slug",
            "https://www.figma.com.example.com/design/KEY/slug",
            "https://www.figma.com@example.com/design/KEY/slug",
            "https://www.figma.com/files/recent",
            "https://www.figma.com/community/file/123",
            "https://www.figma.com/proto/KEY/slug"
        ] {
            #expect(!isFile(raw), "\(raw)")
        }
    }
}
