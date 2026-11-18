// cmux-rbf (#cm-73.46, #cm-73.44): Scenarios 258 and 300, the decision as a table.
import CoreGraphics
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("FigmaPreviewRefit")
struct FigmaPreviewRefitTests {
    typealias Refit = FigmaPreviewRefit

    private static let size = CGSize(width: 800, height: 600)
    private static let board = Refit.Report(path: "/design/KEY/slug", player: false, drawn: true)

    /// A drawn still board on a showing preview, at the size it last loaded at.
    private func decide(
        _ trigger: Refit.Trigger = .size,
        remembered: CGSize? = size,
        now: CGSize = size,
        isPreview: Bool = true,
        isShowing: Bool = true,
        motion: FigmaMotionState = .still,
        isLoading: Bool = false,
        report: Refit.Report? = board,
        inFlight: Bool = false,
        sinceFinish: Duration? = nil,
        fullscreen: Refit.Fullscreen = .none,
        sizeRule: Refit.SizeRule = .settled
    ) -> Refit.Decision {
        Refit.decide(
            trigger: trigger, remembered: remembered, now: now, isPreview: isPreview,
            isShowing: isShowing, motion: motion, isLoading: isLoading,
            lastReport: report, refitInFlight: inFlight, sinceFinish: sinceFinish,
            fullscreen: fullscreen, sizeRule: sizeRule
        )
    }

    // MARK: Scenario 258: the size rule

    @Test func ninetenthsOfAPointOffInEitherDirectionIsTheSame() {
        for delta in [CGFloat(0.9), -0.9] {
            #expect(decide(now: CGSize(width: 800 + delta, height: 600 + delta)) == .skip(.same))
        }
    }

    @Test func onePointOffInWidthAloneMoves() {
        #expect(decide(now: CGSize(width: 801, height: 600)) == .move(.differs))
        #expect(decide(now: CGSize(width: 799, height: 600)) == .move(.differs))
    }

    @Test func onePointOffInHeightAloneMoves() {
        #expect(decide(now: CGSize(width: 800, height: 601)) == .move(.differs))
        #expect(decide(now: CGSize(width: 800, height: 599)) == .move(.differs))
    }

    // MARK: Scenario 258: the guards, for a size change

    @Test func loadingMovesNothing() {
        let off = CGSize(width: 900, height: 600)
        #expect(decide(now: off, isLoading: true) == .skip(.loading))
    }

    @Test func aPaneNotOnScreenMovesNothingForASizeChange() {
        let off = CGSize(width: 900, height: 600)
        #expect(decide(now: off, isShowing: false) == .skip(.hidden))
    }

    @Test func theEditorMovesNothing() {
        let off = CGSize(width: 900, height: 600)
        for trigger in [Refit.Trigger.size, .key, .cli] {
            #expect(decide(trigger, now: off, isPreview: false) == .skip(.editor))
        }
    }

    @Test func aPlayerShowingMovesNothing() {
        let off = CGSize(width: 900, height: 600)
        for motion in [FigmaMotionState.playing, .frozen, .paused] {
            #expect(decide(now: off, motion: motion) == .skip(.player), "\(motion)")
        }
    }

    @Test func aFigJamBoardADeckOrAnErrorPageIsNotABoard() {
        let off = CGSize(width: 900, height: 600)
        for path in ["/board/KEY/slug", "/slides/KEY/slug", "/login", "/error"] {
            let report = Refit.Report(path: path, player: false, drawn: true)
            #expect(decide(now: off, report: report) == .skip(.notboard), "\(path)")
        }
    }

    @Test func noRememberedSizeMeansAFirstLoadAndNothingMoves() {
        let off = CGSize(width: 900, height: 600)
        #expect(decide(remembered: nil, now: off) == .skip(.unloaded))
    }

    // MARK: Scenario 300: the same decision for `.key` and `.cli`

    @Test func keyAndCliMoveADrawnStillBoardAtTheRememberedSize() {
        #expect(decide(.size) == .skip(.same))
        #expect(decide(.key) == .move(.asked))
        #expect(decide(.cli) == .move(.asked))
    }

    @Test func keyAndCliWhileLoadingMoveNothing() {
        for trigger in [Refit.Trigger.key, .cli] {
            #expect(decide(trigger, isLoading: true) == .skip(.loading), "\(trigger.rawValue)")
        }
    }

    @Test func keyAndCliOnThePlayerMoveNothing() {
        for trigger in [Refit.Trigger.key, .cli] {
            #expect(decide(trigger, motion: .playing) == .skip(.player), "\(trigger.rawValue)")
            let proto = Refit.Report(path: "/proto/KEY/slug", player: true, drawn: true)
            #expect(decide(trigger, report: proto) == .skip(.player), "\(trigger.rawValue)")
        }
    }

    @Test func keyAndCliOnANonBoardMoveNothing() {
        let deck = Refit.Report(path: "/slides/KEY/slug", player: false, drawn: true)
        for trigger in [Refit.Trigger.key, .cli] {
            #expect(decide(trigger, report: deck) == .skip(.notboard), "\(trigger.rawValue)")
        }
    }

    @Test func keyAndCliOnAFirstLoadMoveNothing() {
        for trigger in [Refit.Trigger.key, .cli] {
            #expect(decide(trigger, remembered: nil) == .skip(.unloaded), "\(trigger.rawValue)")
        }
    }

    @Test func aHiddenPreviewIsMovedByCliAndNotBySize() {
        let off = CGSize(width: 900, height: 600)
        #expect(decide(.cli, isShowing: false) == .move(.asked))
        #expect(decide(.size, now: off, isShowing: false) == .skip(.hidden))
    }

    @Test func aReFitInFlightAnswersRedrawingForEveryTrigger() {
        let off = CGSize(width: 900, height: 600)
        for trigger in [Refit.Trigger.size, .key, .cli] {
            #expect(decide(trigger, now: off, inFlight: true) == .skip(.redrawing), "\(trigger.rawValue)")
            // The panel holds no report once it has sent `refit`, so in flight beats "no report".
            #expect(decide(trigger, now: off, report: nil, inFlight: true) == .skip(.redrawing), "\(trigger.rawValue)")
        }
    }

    // MARK: Scenario 300: decided from the kept report's path, not from `drawn`

    @Test func noKeptReportIsLoadingNotABoardRefusal() {
        for trigger in [Refit.Trigger.size, .key, .cli] {
            let off = CGSize(width: 900, height: 600)
            #expect(decide(trigger, now: off, report: nil) == .skip(.loading), "\(trigger.rawValue)")
        }
    }

    @Test func aDesignOrFilePathNotYetDrawnIsLoading() {
        for path in ["/design/KEY/slug", "/file/KEY/slug"] {
            let undrawn = Refit.Report(path: path, player: false, drawn: false)
            for trigger in [Refit.Trigger.key, .cli] {
                #expect(decide(trigger, report: undrawn) == .skip(.loading), "\(trigger.rawValue) \(path)")
            }
        }
    }

    @Test func aProtoPathIsThePlayerAndAnyOtherPathIsNotABoard() {
        let proto = Refit.Report(path: "/proto/KEY/slug", player: true, drawn: false)
        #expect(decide(.cli, report: proto) == .skip(.player))
        for path in ["/board/KEY", "/slides/KEY", "/login", "/", ""] {
            let other = Refit.Report(path: path, player: false, drawn: false)
            #expect(decide(.cli, report: other) == .skip(.notboard), "\(path)")
        }
    }

    // MARK: Scenario 300: Figma's top frame reports /embed/interstitial first in every load (probe-base, 2026-10-30)

    @Test func aReportOnTheInterstitialPathIsLoadingForEveryTriggerDrawnOrNot() {
        let off = CGSize(width: 900, height: 600)
        for drawn in [false, true] {
            for path in ["/embed/interstitial", "/embed/interstitial/KEY"] {
                let report = Refit.Report(path: path, player: false, drawn: drawn)
                for trigger in [Refit.Trigger.size, .key, .cli] {
                    let decision = decide(trigger, now: off, report: report)
                    #expect(decision == .skip(.loading), "\(trigger.rawValue) \(path) drawn \(drawn)")
                    #expect(Refit.answer(for: decision) == .fitsItself(.loading), "never the Log in refusal: \(trigger.rawValue) \(path)")
                }
            }
        }
    }

    // MARK: The Log in tell: an interstitial that has stood 10 s after cmux's page finished is Figma's Log in page

    @Test func theInterstitialIsLoadingUntilItHasStoodTenSecondsThenItIsNotABoardForEveryTrigger() {
        let off = CGSize(width: 900, height: 600)
        for drawn in [false, true] {
            let report = Refit.Report(path: "/embed/interstitial", player: false, drawn: drawn)
            for trigger in [Refit.Trigger.size, .key, .cli] {
                for since in [Duration?.none, .zero, .milliseconds(9_900)] {
                    #expect(decide(trigger, now: off, report: report, sinceFinish: since) == .skip(.loading),
                            "\(trigger.rawValue) drawn \(drawn) after \(String(describing: since)) is still loading")
                }
                for since in [Duration.seconds(10), .seconds(60)] {
                    let decision = decide(trigger, now: off, report: report, sinceFinish: since)
                    #expect(decision == .skip(.notboard), "\(trigger.rawValue) drawn \(drawn) after \(since)")
                }
            }
            #expect(Refit.answer(for: decide(.cli, now: off, report: report, sinceFinish: .seconds(10))) == .refused(.notboard),
                    "fit prints the Log in refusal")
        }
    }

    @Test func theTenSecondTurnChangesNoOtherRule() {
        let off = CGSize(width: 900, height: 600)
        let late = Duration.seconds(30)
        #expect(decide(.size, now: off, sinceFinish: late) == .move(.differs), "a drawn board is untouched by the time since finish")
        #expect(decide(.cli, report: nil, sinceFinish: late) == .skip(.loading), "no report is loading however late")
        #expect(decide(.cli, isLoading: true, report: Refit.Report(path: "/embed/interstitial", player: false, drawn: false), sinceFinish: late)
                == .skip(.loading), "a load in progress still wins")
        #expect(decide(.cli, isPreview: false, report: Refit.Report(path: "/embed/interstitial", player: false, drawn: false), sinceFinish: late)
                == .skip(.editor), "the editor still wins")
    }

    @Test func anyOtherPathThatIsNotABoardIsStillNotABoard() {
        for path in ["/embed", "/embed/other", "/login", "/embedded/interstitial"] {
            let report = Refit.Report(path: path, player: false, drawn: false)
            #expect(decide(.cli, report: report) == .skip(.notboard), "\(path)")
        }
    }

    // MARK: Scenario 300: the answer `fit` gets

    @Test func onlyNotboardIsRefusedAndEveryOtherSkipFitsItself() {
        #expect(Refit.answer(for: .move(.asked)) == .moved)
        #expect(Refit.answer(for: .move(.differs)) == .moved)
        #expect(Refit.answer(for: .skip(.notboard)) == .refused(.notboard))
        for reason in [Refit.Reason.loading, .player, .unloaded, .redrawing, .hidden, .same, .editor] {
            #expect(Refit.answer(for: .skip(reason)) == .fitsItself(reason), "\(reason.rawValue)")
        }
    }

    @Test func aSnapshotReportIsExactlyWhatTheSnapshotCarries() {
        let drawn: [String: Any] = ["state": "still", "report": ["path": "/design/K/s", "player": false, "drawn": true]]
        #expect(Refit.Report(snapshot: drawn) == Refit.Report(path: "/design/K/s", player: false, drawn: true))
        let withDoc: [String: Any] = ["state": "still", "report": ["path": "/design/K/s", "player": false, "drawn": true, "doc": 1793474311079.5]]
        #expect(Refit.Report(snapshot: withDoc) == Refit.Report(path: "/design/K/s", player: false, drawn: true, doc: 1793474311079.5))
        #expect(Refit.Report(snapshot: drawn)?.doc == nil, "no doc in the report is no doc, not zero")
        #expect(Refit.Report(snapshot: ["state": "still", "report": NSNull()]) == nil)
        #expect(Refit.Report(snapshot: ["state": "still"]) == nil)
    }
    // MARK: cm-73.52: a full screen Figma's own page asked for

    @Test func aFullScreenFigmaPutThereItselfMovesNothingForAnyTrigger() {
        let off = CGSize(width: 900, height: 600)
        for trigger in [Refit.Trigger.size, .key, .cli] {
            #expect(decide(trigger, now: off, fullscreen: .page) == .skip(.fullscreen), "\(trigger.rawValue)")
        }
    }

    @Test func cmuxsOwnFullScreenAndNoFullScreenDecideAsBefore() {
        let off = CGSize(width: 900, height: 600)
        for fullscreen in [Refit.Fullscreen.none, .cmux] {
            #expect(decide(.size, now: off, fullscreen: fullscreen) == .move(.differs), "\(fullscreen)")
            #expect(decide(.key, fullscreen: fullscreen) == .move(.asked), "\(fullscreen)")
            #expect(decide(.cli, fullscreen: fullscreen) == .move(.asked), "\(fullscreen)")
        }
    }

    @Test func theFullScreenSkipSitsRightAfterTheEditorAndLoadingGuards() {
        let off = CGSize(width: 900, height: 600)
        #expect(decide(now: off, isPreview: false, fullscreen: .page) == .skip(.editor))
        #expect(decide(now: off, isLoading: true, fullscreen: .page) == .skip(.loading))
        #expect(decide(now: off, inFlight: true, fullscreen: .page) == .skip(.fullscreen), "a redraw running doesn't hide it")
        #expect(decide(now: off, isShowing: false, fullscreen: .page) == .skip(.fullscreen))
        #expect(decide(now: off, motion: .playing, fullscreen: .page) == .skip(.fullscreen))
        let deck = Refit.Report(path: "/slides/KEY/slug", player: false, drawn: true)
        #expect(decide(now: off, report: deck, fullscreen: .page) == .skip(.fullscreen), "even a page that is no board")
    }

    @Test func fitIsRefusedByNameWhileFigmasOwnFullScreenHoldsThePane() {
        #expect(Refit.answer(for: .skip(.fullscreen)) == .refused(.fullscreen))
        #expect(Refit.answer(for: .skip(.redrawing)) == .fitsItself(.redrawing))
        #expect(Refit.answer(for: .move(.asked)) == .moved)
        #expect(Refit.Reason.fullscreen.rawValue == "fullscreen", "the app puts this in data.reason, and the CLI reads it")
    }

    @Test func aFullScreenIsFigmasOwnUnlessCmuxAskedForIt() {
        #expect(Refit.Fullscreen(isActive: false, cmuxOwns: false) == .none)
        #expect(Refit.Fullscreen(isActive: false, cmuxOwns: true) == .none, "a flag left over from nothing is not a full screen")
        #expect(Refit.Fullscreen(isActive: true, cmuxOwns: true) == .cmux)
        #expect(Refit.Fullscreen(isActive: true, cmuxOwns: false) == .page)
    }

    // MARK: cm-73.52: the re-check at a re-fit's end moves only past 2 pt

    @Test func theRecheckIgnoresFigmasOnePointSettleAndTwoPointsExactly() {
        for delta in [CGFloat(1), -1, 2, -2] {
            #expect(decide(now: CGSize(width: 800 + delta, height: 600), sizeRule: .recheck) == .skip(.same), "width \(delta)")
            #expect(decide(now: CGSize(width: 800, height: 600 + delta), sizeRule: .recheck) == .skip(.same), "height \(delta)")
        }
    }

    @Test func theRecheckMovesFromMoreThanTwoPointsInEitherDirection() {
        for delta in [CGFloat(2.5), -2.5, 3, 300, -300] {
            #expect(decide(now: CGSize(width: 800 + delta, height: 600), sizeRule: .recheck) == .move(.differs), "width \(delta)")
            #expect(decide(now: CGSize(width: 800, height: 600 + delta), sizeRule: .recheck) == .move(.differs), "height \(delta)")
        }
    }

    @Test func theOrdinaryRuleStillMovesAtOnePoint() {
        #expect(decide(now: CGSize(width: 801, height: 600), sizeRule: .settled) == .move(.differs))
        #expect(Refit.recheckThreshold == 2)
    }
}
