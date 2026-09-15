import AppKit
import Foundation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `#cm-93`: typing mid-text in the Reply paste preview must keep the caret
/// where it was put, not move it to the end after the first keystroke.
@MainActor
@Suite("Reply preview editor caret", .serialized)
struct ReplyPreviewEditorCaretTests {
    /// What one mark with no note serializes to.
    private static let preview = "1.\n> \"bullet\""

    @Test("typing mid-text keeps the caret after what was typed", arguments: [false, true])
    func typingMidTextKeepsCaret(alreadyEdited: Bool) throws {
        let hosted = try Hosted(text: Self.preview, edited: alreadyEdited)
        defer { hosted.close() }

        // Just after `>` on the quote line.
        hosted.textView.setSelectedRange(NSRange(location: 4, length: 0))
        hosted.type("9")
        hosted.type("9")

        #expect(hosted.textView.string == "1.\n>99 \"bullet\"")
        #expect(hosted.textView.selectedRange() == NSRange(location: 6, length: 0))
        #expect(hosted.edits.count == 2)
    }

    @Test("a re-render with the same text leaves the caret where it was")
    func sameTextRerenderKeepsCaret() throws {
        let hosted = try Hosted(text: Self.preview, edited: true)
        defer { hosted.close() }

        hosted.textView.setSelectedRange(NSRange(location: 4, length: 0))
        hosted.type("9")
        // The growing newest reply re-renders the panel without changing the
        // typed text (`restoreTypedPreview()` writes the same string back).
        hosted.rerender()

        #expect(hosted.textView.string == "1.\n>9 \"bullet\"")
        #expect(hosted.textView.selectedRange() == NSRange(location: 5, length: 0))
    }

    @Test("stepping to a reply with other text shows that text and records no edit")
    func steppingToOtherTextReplacesTheBox() throws {
        let hosted = try Hosted(text: Self.preview, edited: false)
        defer { hosted.close() }

        // `#cm-90`: `restoreTypedPreview()` swaps in the next reply's typed
        // text while the box stays open.
        let otherReply = "1.\n> \"other\" typed"
        hosted.step(to: otherReply)

        #expect(hosted.textView.string == otherReply)
        #expect(hosted.edits.count == 0)

        // Typing after the step edits the new reply's text, caret in place.
        hosted.textView.setSelectedRange(NSRange(location: 4, length: 0))
        hosted.type("x")

        #expect(hosted.textView.string == "1.\n>x \"other\" typed")
        #expect(hosted.textView.selectedRange() == NSRange(location: 5, length: 0))
        #expect(hosted.edits.count == 1)
    }

    @Test("two keystrokes before the panel re-renders both land, caret after them")
    func keystrokesBeforeRerenderBothLand() throws {
        let hosted = try Hosted(text: Self.preview, edited: false)
        defer { hosted.close() }

        hosted.textView.setSelectedRange(NSRange(location: 4, length: 0))
        // Key repeat or fast typing: no run-loop turn between the two.
        hosted.textView.insertText("a", replacementRange: hosted.textView.selectedRange())
        hosted.textView.insertText("b", replacementRange: hosted.textView.selectedRange())
        hosted.settle()

        #expect(hosted.textView.string == "1.\n>ab \"bullet\"")
        #expect(hosted.textView.selectedRange() == NSRange(location: 6, length: 0))
    }

    @Test("a keystroke and a backspace before the panel re-renders leave the text as it was")
    func keystrokeThenBackspaceBeforeRerenderStaysDeleted() throws {
        let hosted = try Hosted(text: Self.preview, edited: false)
        defer { hosted.close() }

        hosted.textView.setSelectedRange(NSRange(location: 4, length: 0))
        // No run-loop turn between them: the backspace brings the box back to
        // the text the panel last rendered, and must still be reported.
        hosted.textView.insertText("a", replacementRange: hosted.textView.selectedRange())
        hosted.textView.deleteBackward(nil)
        hosted.settle()

        #expect(hosted.textView.string == Self.preview)
        #expect(hosted.textView.selectedRange() == NSRange(location: 4, length: 0))
        #expect(hosted.reportedText == Self.preview)
    }

    @Test("a multi-character insert and a backspace mid-text keep the caret in place")
    func insertAndBackspaceKeepCaret() throws {
        let hosted = try Hosted(text: Self.preview, edited: false)
        defer { hosted.close() }

        hosted.textView.setSelectedRange(NSRange(location: 4, length: 0))
        // A paste arrives as one insert of several characters. The real
        // pasteboard is left alone so the test never clobbers the clipboard.
        hosted.type("word")
        #expect(hosted.textView.string == "1.\n>word \"bullet\"")
        #expect(hosted.textView.selectedRange() == NSRange(location: 8, length: 0))

        hosted.backspace()
        #expect(hosted.textView.string == "1.\n>wor \"bullet\"")
        #expect(hosted.textView.selectedRange() == NSRange(location: 7, length: 0))

        hosted.type("k")
        #expect(hosted.textView.string == "1.\n>work \"bullet\"")
        #expect(hosted.textView.selectedRange() == NSRange(location: 8, length: 0))
    }
}

@MainActor
private final class EditLog {
    var count = 0
    var lastText: String?
}

@MainActor
private final class Hosted {
    let hostingView: NSHostingView<ReplyPreviewEditorHost>
    let window: NSWindow
    let textView: NSTextView
    let edits = EditLog()
    /// What the panel holds now: the last reported edit, or the text it opened with.
    var reportedText: String { edits.lastText ?? initialText }
    private let initialText: String
    private let initialEdited: Bool
    private var refreshToken = 0
    private var steppedText: String?

    init(text: String, edited: Bool) throws {
        initialText = text
        initialEdited = edited
        hostingView = NSHostingView(rootView: ReplyPreviewEditorHost(
            text: text, edited: edited, refreshToken: 0, steppedText: nil, edits: edits
        ))
        hostingView.frame = NSRect(x: 0, y: 0, width: 360, height: 160)
        window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        Self.spin()
        // `TextEditor` has no created-callback, so find its text view.
        textView = try #require(Self.firstTextView(in: hostingView))
        #expect(window.makeFirstResponder(textView))
    }

    func type(_ characters: String) {
        textView.insertText(characters, replacementRange: textView.selectedRange())
        Self.spin()
    }

    func backspace() {
        textView.deleteBackward(nil)
        Self.spin()
    }

    /// Let SwiftUI apply whatever is pending.
    func settle() {
        Self.spin()
    }

    func rerender() {
        refreshToken += 1
        apply()
    }

    func step(to text: String) {
        steppedText = text
        apply()
    }

    func close() {
        window.contentView = nil
        window.close()
    }

    private func apply() {
        hostingView.rootView = ReplyPreviewEditorHost(
            text: initialText,
            edited: initialEdited,
            refreshToken: refreshToken,
            steppedText: steppedText,
            edits: edits
        )
        hostingView.layoutSubtreeIfNeeded()
        Self.spin()
    }

    /// SwiftUI applies state changes on a later run-loop pass.
    private static func spin() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private static func firstTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews {
            if let found = firstTextView(in: subview) { return found }
        }
        return nil
    }
}

/// Holds the preview's text and edited flag the way `ReplyPanelView` does, so
/// each keystroke re-renders the editor and, on the first edit, the label.
@MainActor
private struct ReplyPreviewEditorHost: View {
    let refreshToken: Int
    /// Set when the test steps to another reply, like `restoreTypedPreview()`.
    let steppedText: String?
    let edits: EditLog
    @State private var text: String?
    @State private var edited: Bool

    init(text: String, edited: Bool, refreshToken: Int, steppedText: String?, edits: EditLog) {
        self.refreshToken = refreshToken
        self.steppedText = steppedText
        self.edits = edits
        _text = State(initialValue: text)
        _edited = State(initialValue: edited)
    }

    var body: some View {
        VStack {
            Text(edited ? "Discard edits" : "Collapse")
            Text("render \(refreshToken)")
            if let text {
                ReplyPreviewEditor(text: text) { typed in
                    self.text = typed
                    edited = true
                    edits.count += 1
                    edits.lastText = typed
                }
            }
        }
        .onChange(of: steppedText) { stepped in
            if let stepped { text = stepped }
        }
    }
}
