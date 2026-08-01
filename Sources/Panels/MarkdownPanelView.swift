import AppKit
import CmuxFoundation
import SwiftUI
import WebKit

/// SwiftUI view that renders a MarkdownPanel's content in a WKWebView using
/// marked.js + github-markdown-css + highlight.js.
///
/// We render through a web view (rather than the previous MarkdownUI path)
/// so that:
///   - Native browser text selection works across the entire document
///     (Cmd+A / drag-select span paragraphs, headings, code blocks, etc.).
///     MarkdownUI rendered each block as an isolated SwiftUI `Text`, which
///     made it impossible to select more than one block at a time.
///   - Rendering uses GitHub's actual markdown CSS, so tables, task lists,
///     nested lists, blockquotes, and code blocks look identical to what
///     users see on github.com.
///   - We can copy the rendered HTML straight from the same source the user
///     is reading.
struct MarkdownPanelView: View {
    @ObservedObject var panel: MarkdownPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    @State private var focusFlashOpacity: Double = 0.0
    @State private var focusFlashAnimationGeneration: Int = 0
    @State private var copyConfirmation: CopyConfirmation? = nil
    @State private var copyConfirmationGeneration: Int = 0
    @AppStorage(FilePreviewWordWrapSettings.key) private var fileEditorWordWrap = FilePreviewWordWrapSettings.defaultEnabled
    /// The theme this viewer renders with. Derived from the panel's own
    /// `backgroundStyle`, not from a global setting, so one viewer can be solid
    /// while another stays on the terminal — and so the typography popover's
    /// per-viewer edits take effect here.
    private var markdownTheme: MarkdownWebTheme {
        MarkdownWebTheme.resolve(
            backgroundColor: themeBackgroundColor,
            style: panel.backgroundStyle
        )
    }

    private enum CopyConfirmation: Equatable {
        case markdown
        case html

        var label: String {
            switch self {
            case .markdown:
                return String(localized: "markdown.copyConfirm.markdown", defaultValue: "Copied as Markdown")
            case .html:
                return String(localized: "markdown.copyConfirm.html", defaultValue: "Copied as HTML")
            }
        }
    }

    var body: some View {
        Group {
            if panel.isFileUnavailable {
                fileUnavailableView
            } else {
                markdownContentView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(contentBackgroundColor)
        .overlay {
            WorkspaceAttentionFlashRingView(opacity: focusFlashOpacity)
        }
        .onChange(of: panel.focusFlashToken) {
            triggerFocusFlashAnimation()
        }
        .environment(\.colorScheme, themeColorScheme)
    }

    // MARK: - Content

    private var markdownContentView: some View {
        VStack(alignment: .leading, spacing: 0) {
            filePathHeader

            Divider()

            markdownBody
        }
    }

    @ViewBuilder
    private var markdownBody: some View {
        // Resolved once per body evaluation, not per read. `markdownTheme` is a
        // computed property and was read twice here plus once through
        // `rendererBackgroundColor`, and each resolve runs three
        // `markdownThemeOverlay` binary searches — 18 blend+luminance iterations
        // apiece. That is ~162 colour operations per pass on a view that
        // re-evaluates on every MarkdownPanel publish: content live-reload,
        // isDirty, displayMode, focus flash.
        let theme = markdownTheme
        let canvas = MarkdownBackgroundStyle.colourBehindPage(
            theme: theme,
            panelContent: appearance.contentBackgroundColor
        )
        ZStack {
            MarkdownWebRenderer(
                markdown: panel.content,
                theme: theme,
                backgroundColor: canvas,
                panelId: panel.id,
                workspaceId: panel.workspaceId,
                filePath: panel.filePath,
                fontSize: panel.effectiveFontSize,
                fontFamily: panel.fontFamily,
                maxContentWidth: panel.maxContentWidth,
                session: panel.rendererSession,
                onRequestPanelFocus: onRequestPanelFocus
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The canvas sits directly behind the web view, and only here.
            //
            // This is what closes the resize flash: a relayout moves the
            // container before the web view repaints, so whatever is behind the
            // page shows through for that moment — and it must not be a
            // different colour from the page. Scoped to this branch rather than
            // the whole panel because `markdown.background` is about the
            // *rendered page*: painting it panel-wide also repainted the file
            // header and the raw-text editor container, which still take
            // terminal colours, giving a two-tone panel in text mode — and on a
            // transparent/blurred window it replaced a `.clear` header with an
            // opaque one, so the blur stopped showing through.
            //
            // Inside `.opacity` on purpose: in text mode it fades out with the
            // web view instead of sitting behind the editor.
            .background(Color(nsColor: canvas))
            .opacity(panel.displayMode == .preview ? 1 : 0)
            .allowsHitTesting(panel.displayMode == .preview)
            .accessibilityHidden(panel.displayMode != .preview)

            if panel.displayMode == .text {
                FilePreviewTextEditor(
                    panel: panel,
                    isVisibleInUI: isVisibleInUI,
                    themeBackgroundColor: appearance.contentBackgroundColor,
                    themeForegroundColor: themeForegroundColor,
                    drawsBackground: appearance.drawsContentBackground,
                    wordWrap: fileEditorWordWrap
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var filePathHeader: some View {
        PanelFilePathHeader(
            iconSystemName: panel.displayIcon ?? "doc.richtext",
            filePath: panel.filePath,
            foregroundColor: themeForegroundColor
        ) {
            if panel.displayMode == .text {
                PanelHeaderIconButton(
                    systemName: "arrow.counterclockwise",
                    label: String(localized: "markdown.toolbar.revert", defaultValue: "Revert"),
                    isDisabled: !panel.isDirty,
                    action: { panel.loadTextContent() }
                )

                PanelHeaderIconButton(
                    systemName: "square.and.arrow.down",
                    label: String(localized: "markdown.toolbar.save", defaultValue: "Save"),
                    isDisabled: !panel.isDirty || panel.isSaving,
                    action: { panel.saveTextContent() }
                )
            }
            if panel.displayMode == .preview {
                MarkdownTypographyControl(panel: panel)
            }
            markdownModeButton
            MarkdownPanelToolbar(
                confirmation: copyConfirmation?.label,
                onCopyMarkdown: { copyAsMarkdown() },
                onCopyHTML: { copyAsHTML() }
            )
            FileExternalOpenMenu(
                fileURL: URL(fileURLWithPath: panel.filePath),
                isDisabled: panel.isFileUnavailable
            )
        }
    }

    private var markdownModeButton: some View {
        switch panel.displayMode {
        case .preview:
            PanelHeaderIconButton(
                systemName: "doc.plaintext",
                label: String(localized: "markdown.mode.showTextEdit", defaultValue: "Show TextEdit"),
                action: { panel.setDisplayMode(.text) }
            )
        case .text:
            PanelHeaderIconButton(
                systemName: "eye",
                label: String(localized: "markdown.mode.showPreview", defaultValue: "Show Preview"),
                action: { panel.setDisplayMode(.preview) }
            )
        }
    }

    private var fileUnavailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.questionmark")
                .cmuxFont(size: 40)
                .foregroundColor(.secondary)
            Text(String(localized: "markdown.fileUnavailable.title", defaultValue: "File unavailable"))
                .cmuxFont(.headline)
                .foregroundColor(.primary)
            Text(panel.filePath)
                .cmuxFont(size: 12, design: .monospaced)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            Text(String(localized: "markdown.fileUnavailable.message", defaultValue: "The file may have been moved or deleted."))
                .cmuxFont(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Theme

    /// The panel's own container colour — header, chrome, and the raw-text
    /// editor behind it.
    ///
    /// Deliberately the *terminal's* colour, not the chosen canvas. It briefly
    /// followed the canvas to close the resize flash, which also repainted the
    /// file header and the text-edit container: a `solid` viewer switched to
    /// text mode showed a white header above a terminal-coloured editor, and on
    /// a transparent window an opaque header replaced one that had let the
    /// blur through. The canvas now sits directly behind the web view in
    /// `markdownBody` instead, which closes the flash without owning the panel.
    private var contentBackgroundColor: Color {
        Color(nsColor: appearance.contentBackgroundColor)
    }

    private var themeBackgroundColor: NSColor {
        appearance.backgroundColor
    }

    private var themeForegroundColor: NSColor {
        appearance.foregroundColor
    }

    private var themeColorScheme: ColorScheme {
        themeBackgroundColor.isLightColor ? .light : .dark
    }

    // MARK: - Copy actions

    private func copyAsMarkdown() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(panel.content, forType: .string)
        flashCopyConfirmation(.markdown)
    }

    private func copyAsHTML() {
        Task { @MainActor in
            guard let html = await panel.rendererSession.renderedHTML(markdown: panel.content) else { return }
            let text = await panel.rendererSession.renderedText() ?? panel.content
            let pb = NSPasteboard.general
            pb.clearContents()
            // public.html for rich-text-aware targets (Notes, Mail, Pages, ...)
            // and a plain-text fallback so plain editors still receive content.
            pb.setString(html, forType: .html)
            pb.setString(text, forType: .string)
            flashCopyConfirmation(.html)
        }
    }

    private func flashCopyConfirmation(_ kind: CopyConfirmation) {
        copyConfirmationGeneration &+= 1
        let generation = copyConfirmationGeneration
        copyConfirmation = kind
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard copyConfirmationGeneration == generation else { return }
            if copyConfirmation == kind {
                copyConfirmation = nil
            }
        }
    }

    // MARK: - Focus Flash

    private func triggerFocusFlashAnimation() {
        focusFlashAnimationGeneration &+= 1
        let generation = focusFlashAnimationGeneration
        focusFlashOpacity = FocusFlashPattern.values.first ?? 0

        for segment in FocusFlashPattern.segments {
            DispatchQueue.main.asyncAfter(deadline: .now() + segment.delay) {
                guard focusFlashAnimationGeneration == generation else { return }
                withAnimation(focusFlashAnimation(for: segment.curve, duration: segment.duration)) {
                    focusFlashOpacity = segment.targetOpacity
                }
            }
        }
    }

    private func focusFlashAnimation(for curve: FocusFlashCurve, duration: TimeInterval) -> Animation {
        switch curve {
        case .easeIn:
            return .easeIn(duration: duration)
        case .easeOut:
            return .easeOut(duration: duration)
        }
    }
}

// MARK: - Toolbar

private struct MarkdownPanelToolbar: View {
    let confirmation: String?
    let onCopyMarkdown: () -> Void
    let onCopyHTML: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let confirmation {
                Text(confirmation)
                    .cmuxFont(size: 11, weight: .medium)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .transition(.opacity)
            }

            toolbarButton(
                title: String(localized: "markdown.toolbar.copyMarkdown", defaultValue: "Copy as Markdown"),
                systemImage: "doc.on.doc",
                action: onCopyMarkdown
            )
            toolbarButton(
                title: String(localized: "markdown.toolbar.copyHTML", defaultValue: "Copy as HTML"),
                systemImage: "chevron.left.forwardslash.chevron.right",
                action: onCopyHTML
            )
        }
        .animation(.easeOut(duration: 0.15), value: confirmation)
    }

    private func toolbarButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        PanelHeaderIconButton(
            systemName: systemImage,
            label: title,
            action: action
        )
    }
}
