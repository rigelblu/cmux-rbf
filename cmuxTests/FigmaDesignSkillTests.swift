import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct FigmaDesignSkillTests {
    // Scenario 152: ownership only; filesystem cases follow in piece 2.
    @Test func ownership() {
        func decision(_ exists: Bool = true, folderLink: Bool = false, fileLink: Bool = false, text: String? = nil) -> FigmaDesignSkill.InstallDecision {
            FigmaDesignSkill.decision(folderExists: exists, folderIsSymlink: folderLink, fileIsSymlink: fileLink, existingDocument: text)
        }
        let managed = "---\nname: design-in-figma-pane\n---\n" + FigmaDesignSkill.markerPrefix + ". old version -->\nOld steps"
        #expect(decision(false) == .write)
        #expect(decision(text: managed) == .write)
        #expect(decision() == .skip)
        #expect(decision(text: "my own skill") == .skip)
        #expect(decision(folderLink: true, text: managed) == .skip)
        #expect(decision(fileLink: true, text: managed) == .skip)
        #expect(decision(text: "---\n---\nMy skill\n" + FigmaDesignSkill.markerPrefix) == .skip)
    }
    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for agent in [".claude", ".agents"] { try FileManager.default.createDirectory(at: url.appendingPathComponent(agent), withIntermediateDirectories: true) }
        return url
    }
    private func skill(_ home: URL, _ root: String) -> URL {
        home.appendingPathComponent(root + "/design-in-figma-pane/SKILL.md")
    }
    @Test func bundledDocument() throws {
        let expected = #"""
---
name: design-in-figma-pane
description: Put a design from this conversation into a new Figma file in the person's cmux Figma folder, start a new design there, or re-lay the boards of the Figma file you opened, and show it in a cmux Figma pane. Run only when the person types /design-in-figma-pane or $design-in-figma-pane, picks "Put Design into Figma" or "Ask Agent to Design in Figma" in cmux's Figma button menu, or cmux types it after the person flips Figma or picks a board layout in Design Focus.
disable-model-invocation: true
---
<!-- cmux-managed-skill: design-in-figma-pane. cmux rewrites this file at every launch. Delete this line to keep your own copy. -->

# Design in a cmux Figma pane

The words after the command say which job:
- `put`: put the latest design in this conversation into Figma
- `new`: design in Figma from the start
- `layout vertical` or `layout horizontal`: re-lay the boards of the Figma file you last opened in this conversation (see "Re-lay the boards")

With no word, or any other word, ask "new or put?" and do nothing else until the person answers. `layout` with no second word, or with a second word other than `vertical` or `horizontal`, counts as any other word.

## 1. Know what to draw
- `put`: take the latest design in this conversation: a sketch, a wireframe, or a screen described in words. If there is none, say so and stop. Make no file.
- `new`: design what this conversation is about. If that isn't clear, ask what to design, and wait for the answer.

## 2. Find the folder
Run `cmux figma folder`.
- It prints `projectId` and `planKey`: before you make the file, tell the person in one line which Figma folder it goes to, from the `directory` line, then go on without waiting. For a path, say "New file goes to the Figma folder set for <path>." For `default`, or when there is no `directory` line, say "New file goes to your default Figma folder."
- It prints "No default Figma folder": make no file, in Drafts or anywhere. Ask the person to choose a folder from cmux's Figma button menu, "Choose Figma Folder…", or with `cmux figma folder set '<folder-url>'`. Then stop.
- It exits with an error: show its message and stop.

## 3. Make a new file
With your Figma MCP tools, create a new Figma Design file, passing `planKey` and `projectId` exactly as printed. Name it after the design. Always a new file: never draw in a file that is already open. If you have no Figma MCP tools, or Figma says you are signed out, say so and stop. If creating the file fails in any other way, show the error and stop. Never retry without `projectId`: that makes the file in Drafts.

## 4. Show it
Run `cmux figma open '<the new file's link>'`. Its answer ends with `orientation=vertical` or `orientation=horizontal`: the shape of the pane the file landed in. If the answer has no `orientation=`, take `vertical`.
If the pane shows Figma's "Log in to Figma to view this file", the file needs sign-in: ask the person to press Log in once in that pane. Every Figma pane then stays signed in until Figma signs them out.

## 5. Draw the design in that file
Draw it with your Figma MCP tools in the file you just made, by its file key. Draw in no other file. Lay its boards out for the orientation step 4 gave: `vertical`, one column, top to bottom; `horizontal`, one row, left to right. Then run `cmux figma fit --surface <the surface cmux figma open printed>`. If it fails, say so in one line and stop; switch or focus nothing. When a frame you drew has motion, point at it with `cmux figma goto <node> --motion`; it opens frozen on its first state with play/pause and still-view controls on the preview. Use `--play` only to show it running.

## Re-lay the boards
For `layout vertical` and `layout horizontal` only; steps 1 to 5 don't apply.
- Take the Figma file you last opened in this conversation with `cmux figma open`. If you opened none, say so and stop.
- With your Figma MCP tools, move that file's top-level boards into one column, top to bottom (`vertical`), or one row, left to right (`horizontal`), keeping their order. Leave the first board where it is and line the rest up after it. Change nothing inside a board, add nothing, delete nothing, and make no new file. Then run `cmux figma fit --surface <the surface cmux figma open printed>`. If it fails, say so in one line and stop; switch or focus nothing.
- If you have no Figma MCP tools, or Figma says you are signed out, say so and stop.
"""#
        #expect(try #require(FigmaDesignSkill.document()) == expected + "\n")
    }
    @Test func plainInstallAndManagedRefresh() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let document = try #require(FigmaDesignSkill.document())
        let results = FigmaDesignSkill.install(home: home)
        #expect(results.count == 2)
        #expect(results.filter { if case .written = $0 { true } else { false } }.count == 2)
        for root in [".claude/skills", ".agents/skills"] {
            let file = skill(home, root)
            #expect(try String(contentsOf: file, encoding: .utf8) == document)
            try ("---\nname: design-in-figma-pane\n---\n" + FigmaDesignSkill.markerPrefix + ". old -->\nold").write(to: file, atomically: true, encoding: .utf8)
        }
        _ = FigmaDesignSkill.install(home: home)
        for root in [".claude/skills", ".agents/skills"] {
            #expect(try String(contentsOf: skill(home, root), encoding: .utf8) == document)
        }
    }
    @Test func userCopiesAndSymlinksAreUntouched() throws {
        let fm = FileManager.default
        for shape in ["own", "folderLink", "fileLink", "emptyFolder"] {
            let home = try temporaryHome(); defer { try? fm.removeItem(at: home) }
            let outside = home.appendingPathComponent("outside")
            try fm.createDirectory(at: outside, withIntermediateDirectories: true)
            let original = "---\n---\n" + FigmaDesignSkill.markerPrefix + ". own target -->\nkeep"
            try original.write(to: outside.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            for root in [".claude/skills", ".agents/skills"] {
                let file = skill(home, root), dir = file.deletingLastPathComponent()
                try fm.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
                if shape == "folderLink" {
                    try fm.createSymbolicLink(at: dir, withDestinationURL: outside)
                } else {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    if shape == "fileLink" { try fm.createSymbolicLink(at: file, withDestinationURL: outside.appendingPathComponent("SKILL.md")) }
                    if shape == "own" { try "user's skill".write(to: file, atomically: true, encoding: .utf8) }
                }
            }
            let results = FigmaDesignSkill.install(home: home)
            #expect(results.filter { if case .kept = $0 { true } else { false } }.count == 2)
            for root in [".claude/skills", ".agents/skills"] {
                let file = skill(home, root)
                if shape == "emptyFolder" { #expect(!fm.fileExists(atPath: file.path)) }
                else { #expect(try String(contentsOf: file, encoding: .utf8) == (shape == "own" ? "user's skill" : original)) }
                if shape == "folderLink" { #expect(try fm.destinationOfSymbolicLink(atPath: file.deletingLastPathComponent().path) == outside.path) }
                if shape == "fileLink" { #expect(try fm.destinationOfSymbolicLink(atPath: file.path) == outside.appendingPathComponent("SKILL.md").path) }
            }
            #expect(try String(contentsOf: outside.appendingPathComponent("SKILL.md"), encoding: .utf8) == original)
        }
    }
    @Test func tomsLinkedRootsWriteOnce() throws {
        let fm = FileManager.default, home = try temporaryHome()
        defer { try? fm.removeItem(at: home) }
        let d = home.appendingPathComponent("dotfiles")
        try fm.createDirectory(at: d.appendingPathComponent("skills"), withIntermediateDirectories: true)
        try fm.removeItem(at: home.appendingPathComponent(".agents"))
        try fm.createSymbolicLink(at: home.appendingPathComponent(".agents"), withDestinationURL: d)
        try fm.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: home.appendingPathComponent("middle"), withDestinationURL: d.appendingPathComponent("skills"))
        try fm.createSymbolicLink(at: home.appendingPathComponent(".claude/skills"), withDestinationURL: home.appendingPathComponent("middle"))
        let results = FigmaDesignSkill.install(home: home)
        #expect(results.filter { if case .written = $0 { true } else { false } }.count == 1)
        #expect(try String(contentsOf: skill(home, ".agents/skills"), encoding: .utf8) == FigmaDesignSkill.document())
    }
    @Test func readOnlyAndTestHost() throws {
        let fm = FileManager.default, home = try temporaryHome()
        defer { try? fm.removeItem(at: home) }
        for root in [".claude/skills", ".agents/skills"] { try fm.createDirectory(at: home.appendingPathComponent(root), withIntermediateDirectories: true) }
        for root in [".claude/skills", ".agents/skills"] { try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: home.appendingPathComponent(root).path) }
        let results = FigmaDesignSkill.install(home: home)
        for root in [".claude/skills", ".agents/skills"] { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.appendingPathComponent(root).path) }
        #expect(results.filter { if case .refused = $0 { true } else { false } }.count == 2)
        #expect(FigmaDesignSkill.installAtLaunch(home: home, environment: ["XCTestConfigurationFilePath": "test"]).isEmpty)
        for root in [".claude/skills", ".agents/skills"] { #expect(!fm.fileExists(atPath: skill(home, root).path)) }
        #expect(FigmaDesignSkill.installAtLaunch(home: home, environment: [:]).count == 2)
    }

    @Test func identicalBytesAreNotRewritten() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        _ = FigmaDesignSkill.install(home: home)
        let file = skill(home, ".claude/skills")
        let timestamp = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: file.path)
        let results = FigmaDesignSkill.install(home: home)
        #expect(!results.contains { if case .written = $0 { true } else { false } })
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date == timestamp)
    }
    @Test func absentAgentsDoNotCreateHomes() throws {
        let fm = FileManager.default, home = try temporaryHome()
        defer { try? fm.removeItem(at: home) }
        for agent in [".claude", ".agents"] { try fm.removeItem(at: home.appendingPathComponent(agent)) }
        _ = FigmaDesignSkill.install(home: home)
        #expect(!fm.fileExists(atPath: home.appendingPathComponent(".claude").path))
        #expect(!fm.fileExists(atPath: home.appendingPathComponent(".agents").path))
        try fm.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        _ = FigmaDesignSkill.install(home: home)
        #expect(fm.fileExists(atPath: skill(home, ".agents/skills").path))
        #expect(!fm.fileExists(atPath: home.appendingPathComponent(".claude").path))
    }
    @MainActor @Test func launchWorkRunsOffMainThread() async throws {
        let task = FigmaDesignSkill.installAtLaunchInBackground(home: FileManager.default.temporaryDirectory, environment: [:]) { _, _ in
            [.kept(URL(fileURLWithPath: Thread.isMainThread ? "/main" : "/background"))]
        }
        #expect(await task.value == [.kept(URL(fileURLWithPath: "/background"))])
    }

}
