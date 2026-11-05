import Foundation
import Testing
@testable import CmuxSettings

/// `FigmaFolderPath`: the two forms of a directory (cm-73.42, Design data steps 1 and 2).
@Suite("FigmaFolderPath")
struct FigmaFolderPathTests {

    static let home = "/Users/probe"

    @Test("the shell form expands ~, drops . and .. by their text, and drops a trailing /")
    func shellFormTextRules() {
        let cases: [(String, String)] = [
            ("/x/a/", "/x/a"),
            ("/x/./a", "/x/a"),
            ("/x/b/../a", "/x/a"),
            ("/x//a", "/x/a"),
            ("~/proj", "/Users/probe/proj"),
            ("~", "/Users/probe"),
            ("/", "/"),
            ("/..", "/"),
            ("/x/../..", "/")
        ]
        for (input, expected) in cases {
            #expect(FigmaFolderPath.shellForm(input, home: Self.home) == expected, "\(input)")
        }
    }

    @Test("a relative path is taken from the base, as the shell does")
    func shellFormRelative() {
        #expect(FigmaFolderPath.shellForm("..", relativeTo: "/x/a/b", home: Self.home) == "/x/a")
        #expect(FigmaFolderPath.shellForm(".", relativeTo: "/x/a/b", home: Self.home) == "/x/a/b")
        #expect(FigmaFolderPath.shellForm("./nope", relativeTo: "/x/a", home: Self.home) == "/x/a/nope")
    }

    @Test("the resolved form follows symlinks, keeps /private, and keeps the text of a path that does not exist")
    func resolvedFormRules() throws {
        let root = try FigmaFolderChoiceTests.scratch()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: "\(root)/real", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: "\(root)/ln", withDestinationPath: "\(root)/real")
        #expect(FigmaFolderPath.resolvedForm("\(root)/ln") == "\(root)/real")
        #expect(FigmaFolderPath.resolvedForm("\(root)/gone/deeper") == "\(root)/gone/deeper")
        // macOS's /tmp is a link to /private/tmp, and the resolved form is the real one.
        #expect(FigmaFolderPath.resolvedForm("/tmp") == "/private/tmp")
    }

    @Test("a key that is neither absolute nor ~/ has no forms")
    func keyForms() {
        #expect(FigmaFolderPath.keyForms("/x/a", home: Self.home)?.shell == "/x/a")
        #expect(FigmaFolderPath.keyForms("~/proj", home: Self.home)?.shell == "/Users/probe/proj")
        #expect(FigmaFolderPath.keyForms("proj", home: Self.home) == nil)
        #expect(FigmaFolderPath.keyForms("", home: Self.home) == nil)
        #expect(FigmaFolderPath.keyForms("./x", home: Self.home) == nil)
    }

    @Test("the command's shell form is $PWD only when $PWD is absolute and resolves to the working directory")
    func cliForms() throws {
        let root = try FigmaFolderChoiceTests.scratch()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: "\(root)/real/inner", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(root)/other", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: "\(root)/ln", withDestinationPath: "\(root)/real")

        let cwd = "\(root)/real/inner"
        let through = FigmaFolderPath.cliForms(pwd: "\(root)/ln/inner", cwd: cwd)
        #expect(through.shell == "\(root)/ln/inner")
        #expect(through.resolved == cwd)

        for pwd in [nil, "", "relative/path", "\(root)/other", "\(root)/gone"] as [String?] {
            let forms = FigmaFolderPath.cliForms(pwd: pwd, cwd: cwd)
            #expect(forms.shell == cwd, "pwd = \(String(describing: pwd))")
            #expect(forms.resolved == cwd, "pwd = \(String(describing: pwd))")
        }
    }
}
