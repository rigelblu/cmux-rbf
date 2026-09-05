import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
private final class MemoryPressureHiddenWebViewDiscardTestDelegate: BrowserHiddenWebViewDiscardManagerDelegate {
    var snapshot: BrowserHiddenWebViewDiscardManager.BlockerSnapshot
    var hiddenAt: Date?
    var webViewInstanceID = UUID()
    var hiddenWebViewDiscardKeepLoaded = false
    var discardRequestCount = 0
    var lastDiscardReason: String?

    init(snapshot: BrowserHiddenWebViewDiscardManager.BlockerSnapshot, hiddenAt: Date?) {
        self.snapshot = snapshot
        self.hiddenAt = hiddenAt
    }

    var hiddenWebViewDiscardSnapshot: BrowserHiddenWebViewDiscardManager.BlockerSnapshot {
        snapshot
    }

    var hiddenWebViewDiscardHiddenAt: Date? {
        hiddenAt
    }

    var hiddenWebViewDiscardWebViewInstanceID: UUID {
        webViewInstanceID
    }

    func hiddenWebViewDiscardManagerDidRequestDiscard(
        _ manager: BrowserHiddenWebViewDiscardManager,
        reason: String
    ) {
        discardRequestCount += 1
        lastDiscardReason = reason
    }

    func hiddenWebViewDiscardManagerPolicyDidChange(
        _ manager: BrowserHiddenWebViewDiscardManager,
        reason: String
    ) {}
}

@MainActor
private func makeMemoryPressureHiddenWebViewDiscardBlockerSnapshot(
    isDesignModeActive: Bool = false
) -> BrowserHiddenWebViewDiscardManager.BlockerSnapshot {
    BrowserHiddenWebViewDiscardManager.BlockerSnapshot(
        isClosing: false,
        isVisibleInUI: false,
        shouldRenderWebView: true,
        hasPendingRemoteNavigation: false,
        hasCurrentURL: true,
        isLoading: false,
        webViewIsLoading: false,
        hasActiveMainFrameProvisionalNavigation: false,
        isDownloading: false,
        activeDownloadCount: 0,
        preferredDeveloperToolsVisible: false,
        isDeveloperToolsVisible: false,
        isElementFullscreenActive: false,
        isReactGrabActive: false,
        isDesignModeActive: isDesignModeActive,
        isVisualAutomationCaptureActive: false,
        isMobileBrowserStreamActive: false,
        hasPopups: false,
        isCapturingMedia: false,
        isPlayingMedia: false
    )
}

@MainActor
private func withMemoryPressureHiddenWebViewDiscardPolicyEnabled(_ body: (UserDefaults) -> Void) {
    let suiteName = "com.cmux.BrowserHiddenWebViewDiscardMemoryPressureTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set(true, forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
    defaults.set(
        BrowserHiddenWebViewDiscardPolicy.defaultHiddenDelay,
        forKey: BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey
    )
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    body(defaults)
}

@MainActor
@Suite(.serialized)
struct BrowserHiddenWebViewDiscardMemoryPressureTests {
    @Test func activeDesignModeBlocksHiddenWebViewDiscard() {
        withMemoryPressureHiddenWebViewDiscardPolicyEnabled { defaults in
            let snapshot = makeMemoryPressureHiddenWebViewDiscardBlockerSnapshot(isDesignModeActive: true)
            let manager = BrowserHiddenWebViewDiscardManager(policyDefaults: defaults)

            #expect(manager.blockers(for: snapshot) == ["design_mode"])
        }
    }

    @Test func systemMemoryPressureRequestsImmediateHiddenWebViewDiscard() {
        withMemoryPressureHiddenWebViewDiscardPolicyEnabled { defaults in
            let now = Date(timeIntervalSince1970: 1_000)
            let snapshot = makeMemoryPressureHiddenWebViewDiscardBlockerSnapshot()
            let manager = BrowserHiddenWebViewDiscardManager(policyDefaults: defaults)
            let delegate = MemoryPressureHiddenWebViewDiscardTestDelegate(
                snapshot: snapshot,
                hiddenAt: now.addingTimeInterval(-10)
            )
            manager.delegate = delegate

            #expect(manager.requestImmediateDiscardIfSafe(reason: "system_memory_pressure", now: now))

            #expect(!manager.hasScheduledDiscard)
            #expect(delegate.discardRequestCount == 1)
            #expect(delegate.lastDiscardReason == "system_memory_pressure")
        }
    }

    @Test func systemMemoryPressureDoesNotDiscardBeforeHiddenStateIsRecorded() {
        withMemoryPressureHiddenWebViewDiscardPolicyEnabled { defaults in
            let now = Date(timeIntervalSince1970: 1_500)
            let snapshot = makeMemoryPressureHiddenWebViewDiscardBlockerSnapshot()
            let manager = BrowserHiddenWebViewDiscardManager(policyDefaults: defaults)
            let delegate = MemoryPressureHiddenWebViewDiscardTestDelegate(
                snapshot: snapshot,
                hiddenAt: nil
            )
            manager.delegate = delegate

            #expect(!manager.requestImmediateDiscardIfSafe(reason: "system_memory_pressure", now: now))

            #expect(manager.hasScheduledDiscard)
            #expect(delegate.discardRequestCount == 0)
            #expect(delegate.lastDiscardReason == nil)
        }
    }

    @Test func systemMemoryPressureDefersImmediateDiscardDuringPostWakeWindow() {
        withMemoryPressureHiddenWebViewDiscardPolicyEnabled { defaults in
            let wakeAt = Date(timeIntervalSince1970: 2_000)
            let pressureAt = wakeAt.addingTimeInterval(1)
            let snapshot = makeMemoryPressureHiddenWebViewDiscardBlockerSnapshot()
            let manager = BrowserHiddenWebViewDiscardManager(policyDefaults: defaults)
            let delegate = MemoryPressureHiddenWebViewDiscardTestDelegate(
                snapshot: snapshot,
                hiddenAt: wakeAt.addingTimeInterval(-7_200)
            )
            manager.delegate = delegate

            manager.noteSystemDidWake(now: wakeAt)
            #expect(!manager.requestImmediateDiscardIfSafe(reason: "system_memory_pressure", now: pressureAt))

            #expect(manager.hasScheduledDiscard)
            #expect(delegate.discardRequestCount == 0)
            #expect(delegate.lastDiscardReason == nil)
        }
    }

    @Test func keepLoadedSuppressesScheduledHiddenWebViewDiscard() {
        withMemoryPressureHiddenWebViewDiscardPolicyEnabled { defaults in
            let now = Date(timeIntervalSince1970: 1_000)
            let snapshot = makeMemoryPressureHiddenWebViewDiscardBlockerSnapshot()
            let manager = BrowserHiddenWebViewDiscardManager(policyDefaults: defaults)
            let delegate = MemoryPressureHiddenWebViewDiscardTestDelegate(
                snapshot: snapshot,
                hiddenAt: now.addingTimeInterval(-10)
            )
            delegate.hiddenWebViewDiscardKeepLoaded = true
            manager.delegate = delegate

            manager.scheduleIfNeeded(reason: "test_hidden", now: now)

            #expect(!manager.hasScheduledDiscard)
            #expect(delegate.discardRequestCount == 0)
        }
    }

    @Test func keepLoadedStillDiscardsOnSystemMemoryPressure() {
        withMemoryPressureHiddenWebViewDiscardPolicyEnabled { defaults in
            let now = Date(timeIntervalSince1970: 1_000)
            let snapshot = makeMemoryPressureHiddenWebViewDiscardBlockerSnapshot()
            let manager = BrowserHiddenWebViewDiscardManager(policyDefaults: defaults)
            let delegate = MemoryPressureHiddenWebViewDiscardTestDelegate(
                snapshot: snapshot,
                hiddenAt: now.addingTimeInterval(-10)
            )
            delegate.hiddenWebViewDiscardKeepLoaded = true
            manager.delegate = delegate

            #expect(manager.requestImmediateDiscardIfSafe(reason: "system_memory_pressure", now: now))

            #expect(!manager.hasScheduledDiscard)
            #expect(delegate.discardRequestCount == 1)
            #expect(delegate.lastDiscardReason == "system_memory_pressure")
        }
    }

    // The keep-loaded flag must never reach the blocker list: `blockers(for:)` gates the
    // emergency memory-pressure discard as well as the timer, so a blocker-shaped exemption
    // would make a kept page permanently unreclaimable. The manager must be given the
    // delegate here — an earlier version of this test compared two snapshots taken from the
    // same object, which is an input compared to itself and survived the mutation.
    @Test func keepLoadedDoesNotAlterBlockers() {
        withMemoryPressureHiddenWebViewDiscardPolicyEnabled { defaults in
            let now = Date(timeIntervalSince1970: 1_000)
            let snapshot = makeMemoryPressureHiddenWebViewDiscardBlockerSnapshot()

            let unkeptDelegate = MemoryPressureHiddenWebViewDiscardTestDelegate(
                snapshot: snapshot,
                hiddenAt: now.addingTimeInterval(-10)
            )
            unkeptDelegate.hiddenWebViewDiscardKeepLoaded = false
            let unkeptManager = BrowserHiddenWebViewDiscardManager(policyDefaults: defaults)
            unkeptManager.delegate = unkeptDelegate

            let keptDelegate = MemoryPressureHiddenWebViewDiscardTestDelegate(
                snapshot: snapshot,
                hiddenAt: now.addingTimeInterval(-10)
            )
            keptDelegate.hiddenWebViewDiscardKeepLoaded = true
            let keptManager = BrowserHiddenWebViewDiscardManager(policyDefaults: defaults)
            keptManager.delegate = keptDelegate

            let unkeptBlockers = unkeptManager.blockers(for: snapshot)
            let keptBlockers = keptManager.blockers(for: snapshot)

            #expect(unkeptBlockers == keptBlockers)
            #expect(!keptBlockers.contains("keep_loaded"))
        }
    }

    @Test func sessionBrowserPanelSnapshotKeepLoadedPersistenceRoundTrip() throws {
        let original = SessionBrowserPanelSnapshot(
            urlString: "https://example.com",
            profileID: UUID(),
            shouldRenderWebView: true,
            pageZoom: 1.0,
            developerToolsVisible: false,
            isMuted: false,
            keepLoaded: true,
            backHistoryURLStrings: nil,
            forwardHistoryURLStrings: nil
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(SessionBrowserPanelSnapshot.self, from: data)
        #expect(decoded.keepLoaded == true)

        let jsonWithoutKey = """
        {
            "urlString": "https://example.com",
            "shouldRenderWebView": true,
            "pageZoom": 1.0,
            "developerToolsVisible": false
        }
        """.data(using: .utf8)!
        let decodedWithoutKey = try decoder.decode(SessionBrowserPanelSnapshot.self, from: jsonWithoutKey)
        #expect(decodedWithoutKey.keepLoaded == false)
    }
}
