import Testing
import AppKit
import CmuxBrowser
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// cmux-rbf (#cm-143): WebKit's element full screen saves the slot's constraints and re-activates them when it ends.
// An overlay freed in between is a message to a freed object, so the slot keeps it, hidden, until WebKit has put the web view back.
@MainActor
@Suite(.serialized)
struct BrowserSlotFullscreenOverlayDeferralTests {
    /// The four overlays the slot hosts, each with how to set it, clear it, and find its view.
    @MainActor
    enum Kind: String, CaseIterable, CustomTestStringConvertible {
        case search, designComposer, omnibarSuggestions, figmaLoadBar
        var testDescription: String { rawValue }

        /// The composer's smallest buildable controller: the one `BrowserDesignModeScreenshotEvaluatorTests` builds, never installed on a web view.
        static func makeDesignController() -> BrowserDesignModeController {
            BrowserDesignModeController(
                surfaceID: UUID(),
                script: BrowserDesignModeScript(),
                promptFormatter: BrowserDesignModePromptFormatter(),
                artifactStore: BrowserDesignModeArtifactStore(directory: URL.temporaryDirectory),
                javaScriptEvaluator: BrowserDesignModeJavaScriptEvaluator(),
                screenshotEvaluator: BrowserDesignModeScreenshotEvaluator(),
                canEnable: { true },
                clipboardWriter: { _ in true },
                onActivityChanged: {}
            )
        }

        func set(on slot: WindowBrowserSlotView, controller: BrowserDesignModeController, generation: Int = 1) {
            let panelId = UUID()
            switch self {
            case .search:
                slot.setSearchOverlay(BrowserPortalSearchOverlayConfiguration(
                    panelId: panelId, searchState: BrowserSearchState(), focusRequestGeneration: 0,
                    canApplyFocusRequest: { _ in false }, onNext: {}, onPrevious: {}, onClose: {}, onFieldDidFocus: {}
                ))
            case .designComposer:
                slot.setDesignComposer(BrowserPortalDesignComposerConfiguration(panelId: panelId, controller: controller))
            case .omnibarSuggestions:
                slot.setOmnibarSuggestions(BrowserPortalOmnibarSuggestionsConfiguration(
                    panelId: panelId, popupFrame: CGRect(x: 0, y: 0, width: 100, height: 40), colorScheme: .light,
                    engineName: "test", items: [], selectedIndex: 0, isLoadingRemoteSuggestions: false,
                    searchSuggestionsEnabled: false, onCommit: { _ in }, onHighlight: { _ in }
                ))
            case .figmaLoadBar:
                slot.setFigmaLoadBar(FigmaLoadBarConfiguration(panelId: panelId, phase: .filling(0.4), generation: generation))
            }
        }

        func clear(on slot: WindowBrowserSlotView) {
            switch self {
            case .search: slot.setSearchOverlay(nil)
            case .designComposer: slot.setDesignComposer(nil)
            case .omnibarSuggestions: slot.setOmnibarSuggestions(nil)
            case .figmaLoadBar: slot.setFigmaLoadBar(nil)
            }
        }

        /// Every subview of the slot that is this kind's overlay.
        func views(in slot: WindowBrowserSlotView) -> [NSView] {
            slot.subviews.filter { view in
                switch self {
                case .search: return NSStringFromClass(type(of: view)).contains("BrowserSearchOverlay")
                case .designComposer: return view is BrowserDesignModeComposerHostingView
                case .omnibarSuggestions: return view is BrowserPortalOmnibarSuggestionsHostingView
                case .figmaLoadBar: return view is FigmaLoadBarHostingView
                }
            }
        }
    }

    private func makeSlot() -> WindowBrowserSlotView {
        WindowBrowserSlotView(frame: NSRect(x: 0, y: 0, width: 260, height: 160))
    }

    @Test(arguments: Kind.allCases)
    func anOverlayRemovedWhileHeldStaysHiddenAndAlive(kind: Kind) throws {
        let slot = makeSlot()
        let controller = Kind.makeDesignController()
        slot.overlayHoldProbeForTesting = { true }
        kind.set(on: slot, controller: controller)
        weak var weakView = try #require(kind.views(in: slot).first)

        kind.clear(on: slot)

        let view = try #require(weakView)
        #expect(view.superview === slot)
        #expect(view.isHidden)
        #expect(kind.views(in: slot).count == 1)
    }

    @Test(arguments: Kind.allCases)
    func aDeferredOverlayIsRemovedAndFreedOnceWebKitReleasesTheSlot(kind: Kind) throws {
        let slot = makeSlot()
        let controller = Kind.makeDesignController()
        var held = true
        slot.overlayHoldProbeForTesting = { held }
        weak var weakView: NSView?
        autoreleasepool {
            kind.set(on: slot, controller: controller)
            weakView = kind.views(in: slot).first
            kind.clear(on: slot)
        }
        #expect(weakView != nil)

        slot.flushDeferredOverlayRemovals(reason: "test-still-held")
        #expect(weakView?.superview === slot, "a flush while WebKit still holds the slot must keep the overlay")

        held = false
        autoreleasepool { slot.flushDeferredOverlayRemovals(reason: "test-released") }
        #expect(kind.views(in: slot).isEmpty)
        #expect(weakView == nil)
    }

    @Test(arguments: Kind.allCases)
    func settingTheOverlayAgainWhileItsRemovalIsQueuedReusesIt(kind: Kind) throws {
        let slot = makeSlot()
        let controller = Kind.makeDesignController()
        slot.overlayHoldProbeForTesting = { true }
        kind.set(on: slot, controller: controller, generation: 1)
        let first = try #require(kind.views(in: slot).first)
        kind.clear(on: slot)
        #expect(first.isHidden)

        kind.set(on: slot, controller: controller, generation: 2)

        let views = kind.views(in: slot)
        #expect(views.count == 1)
        #expect(views.first === first)
        #expect(!first.isHidden)
        slot.overlayHoldProbeForTesting = { false }
        slot.flushDeferredOverlayRemovals(reason: "test-reuse")
        #expect(kind.views(in: slot).count == 1, "a revived overlay must not be removed by the flush")
    }

    @Test(arguments: Kind.allCases)
    func anOverlayRemovedWhileNotHeldIsRemovedAtOnce(kind: Kind) throws {
        let slot = makeSlot()
        let controller = Kind.makeDesignController()
        slot.overlayHoldProbeForTesting = { false }
        weak var weakView: NSView?
        autoreleasepool {
            kind.set(on: slot, controller: controller)
            weakView = kind.views(in: slot).first
            kind.clear(on: slot)
        }
        #expect(kind.views(in: slot).isEmpty)
        #expect(weakView == nil)
    }

    @Test func aPlaceholderInTheSlotCountsAsHeldAndItsDepartureFlushes() async throws {
        // The placeholder half of `isHeldByWebKitFullscreen`, with no seam: WebKit's own placeholder class, as full screen
        // leaves it in the slot. The other half (`cmuxIsManagedByExternalFullscreenWindow`) reads `WKWebView.fullscreenState`,
        // which a test cannot set, so it is not covered here.
        let placeholderType = try #require(NSClassFromString("WKFullScreenPlaceholderView") as? NSView.Type)
        let slot = makeSlot()
        let host = NSView(frame: slot.bounds) // a slot in a hierarchy, as the portal keeps it
        host.addSubview(slot)
        #expect(!slot.isHeldByWebKitFullscreen)
        let placeholder = placeholderType.init(frame: slot.bounds)
        slot.addSubview(placeholder)
        #expect(slot.isHeldByWebKitFullscreen)

        Kind.figmaLoadBar.set(on: slot, controller: Kind.makeDesignController())
        Kind.figmaLoadBar.clear(on: slot)
        #expect(Kind.figmaLoadBar.views(in: slot).count == 1)

        placeholder.removeFromSuperview()
        #expect(!slot.isHeldByWebKitFullscreen)
        for _ in 0..<20 where !Kind.figmaLoadBar.views(in: slot).isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(Kind.figmaLoadBar.views(in: slot).isEmpty)
    }

    // The slot is freed while it still holds WebKit's placeholder and a queued removal (close-surface on a full-screen
    // Figma preview). Its dealloc removes its subviews, which runs willRemoveSubview on an object that is already
    // deallocating; forming a weak reference to it there is fatal.
    @Test func aSlotFreedWhileHeldWithAQueuedRemovalDoesNotTrap() throws {
        let placeholderType = try #require(NSClassFromString("WKFullScreenPlaceholderView") as? NSView.Type)
        weak var weakSlot: WindowBrowserSlotView?
        autoreleasepool {
            let slot = makeSlot()
            slot.addSubview(placeholderType.init(frame: slot.bounds))
            Kind.figmaLoadBar.set(on: slot, controller: Kind.makeDesignController())
            Kind.figmaLoadBar.clear(on: slot)
            weakSlot = slot
        }
        #expect(weakSlot == nil)
    }

    // A deferred removal resigns a first responder inside the overlay, so focus never moves to the next key view. This guards the end state only:
    // with the resign removed it still passes in a unit-test window, where AppKit resigns a hidden first responder itself (measured, #cm-143).
    @Test func deferringAnOverlayThatHoldsFocusResignsItWithoutMovingFocus() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        defer { window.orderOut(nil) }
        let slot = makeSlot()
        window.contentView?.addSubview(slot)
        let other = NSTextField(frame: NSRect(x: 0, y: 170, width: 80, height: 20))
        window.contentView?.addSubview(other)
        window.orderFrontRegardless() // a window on screen, with a next key view for AppKit to hand focus to
        slot.overlayHoldProbeForTesting = { true }
        Kind.figmaLoadBar.set(on: slot, controller: Kind.makeDesignController())
        let overlay = try #require(Kind.figmaLoadBar.views(in: slot).first)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 20))
        overlay.addSubview(field)
        field.nextKeyView = other
        other.nextKeyView = field
        #expect(window.makeFirstResponder(field))
        let editor = try #require(window.firstResponder as? NSView)
        #expect(editor === field || editor.isDescendant(of: field))

        Kind.figmaLoadBar.clear(on: slot)

        #expect(overlay.isHidden)
        #expect(window.firstResponder !== other && !((window.firstResponder as? NSView)?.isDescendant(of: other) ?? false), "focus must not move to the next key view")
        #expect(window.firstResponder === window, "focus must be resigned, not handed to the next key view")
    }
}
