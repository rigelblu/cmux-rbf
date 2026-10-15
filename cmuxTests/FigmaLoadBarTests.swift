import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Scenario 90: the pure rules that decide what the loading line shows, and when it ends.
@Suite("FigmaLoadBar")
struct FigmaLoadBarTests {

    private let now = Date()

    @Test("phase rule across the 7 specification rows")
    func phaseRuleRows() {
        let deadline: TimeInterval = 22

        // Row 1: not a Figma pane -> hidden
        #expect(
            FigmaLoadBar.phase(
                isFigmaPane: false,
                isLoading: true,
                progress: 0.4,
                editorWait: .notWaiting,
                now: now,
                deadline: deadline
            ) == .hidden
        )

        // Row 2: failed -> hidden
        #expect(
            FigmaLoadBar.phase(
                isFigmaPane: true,
                isLoading: true,
                progress: 0.4,
                editorWait: .failed,
                now: now,
                deadline: deadline
            ) == .hidden
        )

        // Row 3: loading, not waiting -> filling(progress)
        #expect(
            FigmaLoadBar.phase(
                isFigmaPane: true,
                isLoading: true,
                progress: 0.4,
                editorWait: .notWaiting,
                now: now,
                deadline: deadline
            ) == .filling(0.4)
        )

        // Row 4: loading wins over waiting -> filling(progress)
        #expect(
            FigmaLoadBar.phase(
                isFigmaPane: true,
                isLoading: true,
                progress: 0.1,
                editorWait: .waiting(since: now.addingTimeInterval(-1), waitID: 1),
                now: now,
                deadline: deadline
            ) == .filling(0.1)
        )

        // Row 5: waiting within deadline -> sliding
        #expect(
            FigmaLoadBar.phase(
                isFigmaPane: true,
                isLoading: false,
                progress: 1.0,
                editorWait: .waiting(since: now.addingTimeInterval(-1), waitID: 1),
                now: now,
                deadline: deadline
            ) == .sliding
        )

        // Row 6: waiting at/past deadline -> hidden
        #expect(
            FigmaLoadBar.phase(
                isFigmaPane: true,
                isLoading: false,
                progress: 1.0,
                editorWait: .waiting(since: now.addingTimeInterval(-22), waitID: 1),
                now: now,
                deadline: deadline
            ) == .hidden
        )

        // Row 7: not waiting -> hidden
        #expect(
            FigmaLoadBar.phase(
                isFigmaPane: true,
                isLoading: false,
                progress: 1.0,
                editorWait: .notWaiting,
                now: now,
                deadline: deadline
            ) == .hidden
        )
    }

    @Test("waitsForEditor across the 8 specification rows")
    func waitsForEditorRows() {
        // Row 1: /design/ with address bar hidden -> yes
        #expect(
            FigmaLoadBar.waitsForEditor(
                afterLoadOf: URL(string: "https://www.figma.com/design/KEY/a"),
                isOmnibarVisible: false
            )
        )

        // Row 2: /file/ with address bar hidden -> yes
        #expect(
            FigmaLoadBar.waitsForEditor(
                afterLoadOf: URL(string: "https://www.figma.com/file/KEY/a"),
                isOmnibarVisible: false
            )
        )

        // Row 3: /board/ (FigJam) -> no
        #expect(
            !FigmaLoadBar.waitsForEditor(
                afterLoadOf: URL(string: "https://www.figma.com/board/KEY/a"),
                isOmnibarVisible: false
            )
        )

        // Row 4: /slides/ -> no
        #expect(
            !FigmaLoadBar.waitsForEditor(
                afterLoadOf: URL(string: "https://www.figma.com/slides/KEY/a"),
                isOmnibarVisible: false
            )
        )

        // Row 5: /design/ with address bar shown -> no
        #expect(
            !FigmaLoadBar.waitsForEditor(
                afterLoadOf: URL(string: "https://www.figma.com/design/KEY/a"),
                isOmnibarVisible: true
            )
        )

        // Row 6: read view page -> no
        #expect(
            !FigmaLoadBar.waitsForEditor(
                afterLoadOf: URL(fileURLWithPath: "/tmp/cmux-figma-read.html"),
                isOmnibarVisible: false
            )
        )

        // Row 7: recents -> no
        #expect(
            !FigmaLoadBar.waitsForEditor(
                afterLoadOf: URL(string: "https://www.figma.com/files/recent"),
                isOmnibarVisible: false
            )
        )

        // Row 8: login -> no
        #expect(
            !FigmaLoadBar.waitsForEditor(
                afterLoadOf: URL(string: "https://www.figma.com/login"),
                isOmnibarVisible: false
            )
        )
    }

    @Test("isFigmaPane accounts for loadTarget when currentURL is nil")
    func isFigmaPaneWithLoadTarget() {
        let figmaLink = URL(string: "https://www.figma.com/design/KEY/a")
        #expect(FigmaLoadBar.isFigmaPane(address: nil, loadTarget: figmaLink, showsAddressBar: false))
        #expect(!FigmaLoadBar.isFigmaPane(address: nil, loadTarget: nil, showsAddressBar: false))
        #expect(!FigmaLoadBar.isFigmaPane(address: nil, loadTarget: figmaLink, showsAddressBar: true))
    }

    @Test("style respects reduceMotion for sliding segment")
    func styleReduceMotion() {
        #expect(FigmaLoadBar.style(for: .sliding, reduceMotion: false) == .segment)
        #expect(FigmaLoadBar.style(for: .sliding, reduceMotion: true) == .still(opacity: 0.5))
        #expect(FigmaLoadBar.style(for: .filling(0.4), reduceMotion: false) == .fill(0.4))
        #expect(FigmaLoadBar.style(for: .hidden, reduceMotion: false) == .hidden)
    }

    @Test("segmentPosition: at t = 0 the segment's right edge is at 0.9 * width")
    func segmentPositionAtStart() {
        for width: CGFloat in [100, 300, 1000, 1920] {
            let (segment, offset) = FigmaLoadBar.segmentPosition(elapsed: 0, width: width)
            let rightEdge = offset + segment
            let expected = CGFloat(FigmaLoadBar.progressCap) * width
            #expect(abs(rightEdge - expected) < 1.0, "expected right edge at \(expected), got \(rightEdge) for width \(width)")
        }
    }
}
