public import CmuxTerminalCore
internal import CMUXDebugLog
internal import GhosttyKit

extension TerminalSurface {
    /// Captures the current font size and its surface-local ownership state.
    ///
    /// Live Ghostty state is authoritative. When the runtime is unavailable,
    /// the last captured lineage survives hibernation and session restoration.
    ///
    /// - Returns: Current font-size lineage, or nil before a size is known.
    @MainActor
    public func fontSizeLineageSnapshot() -> TerminalFontSizeLineage? {
        guard let runtimeSurface = liveSurfaceForGhosttyAccess(
            reason: "fontSizeLineage.snapshot"
        ) else {
            return lastKnownFontSizeLineage
        }
        guard let runtimePoints = GhosttySurfaceRuntimeProbe.currentSurfaceFontSizePoints(
            runtimeSurface
        ) else {
            return lastKnownFontSizeLineage
        }

        return recordObservedFontSizeLineage(
            runtimePoints: runtimePoints,
            isExplicitOverride: ghostty_surface_font_size_adjusted(runtimeSurface),
            globalFontMagnificationPercent: globalFontMagnificationPercent()
        )
    }

    /// Reconciles observed runtime points with durable surface ownership.
    ///
    /// A live value matching the active mobile fit is temporary and leaves the
    /// pre-fit lineage unchanged. A different live value came from outside the
    /// fitter, so it becomes the new durable base and restore point.
    @MainActor
    func recordObservedFontSizeLineage(
        runtimePoints: Float32,
        isExplicitOverride: Bool,
        globalFontMagnificationPercent: Int
    ) -> TerminalFontSizeLineage? {
        guard runtimePoints.isFinite, runtimePoints > 0 else {
            return lastKnownFontSizeLineage
        }
        if var fitState = mobileViewportFontFitState {
            guard !isExplicitOverride
                    || !fitState.matchesFittedRuntimePointSize(runtimePoints) else {
                return lastKnownFontSizeLineage
            }
            fitState.rebase(to: runtimePoints)
            mobileViewportFontFitState = fitState
        }

        let lineage = TerminalFontSizeLineage(
            basePoints: CmuxSurfaceConfigTemplate.baseFontSize(
                fromRuntimePoints: runtimePoints,
                percent: globalFontMagnificationPercent
            ),
            isExplicitOverride: isExplicitOverride
        )
        recordCurrentFontSizeLineage(lineage)
        return lineage
    }

    /// Records live font-size lineage for hibernation and split inheritance.
    ///
    /// A non-explicit value is retained as the last known split-inheritance
    /// value, while separately recording that this surface must follow current
    /// config when its own runtime is recreated.
    @MainActor
    func recordCurrentFontSizeLineage(_ lineage: TerminalFontSizeLineage) {
        guard lastKnownFontSizeLineage != lineage else { return }
        lastKnownFontSizeLineage = lineage
        onFontSizeLineageChanged?(lineage)
    }

    /// Resolves the Swift-owned template used to create this surface's runtime.
    ///
    /// Initial non-explicit lineage seeds the first native runtime. After a
    /// native lifetime, non-explicit lineage remains available to descendants
    /// but must not seed this surface again because Cmd+0 and ordinary unzoomed
    /// terminals follow the then-current terminal config.
    @MainActor
    func runtimeCreationConfigTemplate() -> CmuxSurfaceConfigTemplate {
        var template = configTemplate ?? CmuxSurfaceConfigTemplate()
        if lastKnownFontSizeLineage?.isExplicitOverride == false,
           runtimeSurfaceGeneration > 0 {
            template.fontSizeLineage = nil
        } else if let lastKnownFontSizeLineage {
            template.fontSizeLineage = lastKnownFontSizeLineage
        }
        return template
    }

    /// Reapplies this surface's font size after the app-wide magnification changes.
    ///
    /// Surfaces that follow config need nothing here — Ghostty's own config
    /// reload already re-seeds them from the scaled `font-size` cmux injects.
    /// A surface the user sized by hand does **not** follow config: Ghostty sets
    /// `font_size_adjusted` on any manual change and then, by design, "we don't
    /// change it on config reload since we assume the user wants a specific
    /// size" (`Surface.zig`). Left alone, such a pane freezes while every
    /// untouched pane scales around it.
    ///
    /// So the pane is rescaled explicitly — by the RATIO between the previous
    /// and current magnification, applied to its live size. Do **not**
    /// "simplify" this into recovering a base and multiplying by the percent:
    /// ``fontSizeLineageSnapshot()`` derives that base by dividing the live size
    /// by the current percent, so after the percent has moved it multiplies
    /// straight back to the size already on screen. That identity pinned the
    /// font at 13.0pt across 170/180/190% and is covered by a regression test.
    ///
    /// The pane keeps the size the user chose *relative* to everything else,
    /// which is what makes per-pane zoom and the app-wide scale compose rather
    /// than compete.
    ///
    /// - Note: This is a one-shot applied at the moment of change, not a
    ///   reconciliation against a stored truth. A surface skipped here (not
    ///   live, mid-fit, or a failed binding action) stays at its old size and
    ///   is not retried, because the caller has already consumed the delta.
    ///
    /// - Parameter ratio: New magnification percent divided by the previous one.
    /// - Returns: `true` when a new size was applied.
    @MainActor
    @discardableResult
    public func reapplyFontSizeForGlobalMagnificationChange(ratio: Double) -> Bool {
        guard ratio.isFinite, ratio > 0, abs(ratio - 1) > 0.0001 else { return false }
        guard let runtimeSurface = liveSurfaceForGhosttyAccess(reason: "globalZoom.scale") else {
            return false
        }
        // Excluded FIRST: a surface under an active mobile viewport fit.
        // `font_size_adjusted` means "someone called set_font_size", NOT "the
        // user sized this by hand" — cmux's own fitter sets it
        // (`TerminalSurface+MobileViewportFit.swift`). Scaling a fitted surface
        // breaks the cell grid the fit exists to hit, and the next viewport
        // resize then sees live != fitted and calls `rebase`, which overwrites
        // the pre-fit base and strands the desktop pane at phone size across
        // relaunch. The fitter reapplies against the current percent itself, so
        // skipping here loses nothing.
        guard mobileViewportFontFitState == nil else {
#if DEBUG
            logDebugEvent("globalZoom.surface skip reason=mobile_viewport_fit")
#endif
            return false
        }
        // Only surfaces Ghostty refuses to resize on config reload need this.
        // A config-following surface was already resized by the reload; forcing
        // a size here would both double-apply and strip its ability to follow
        // future config changes.
        guard ghostty_surface_font_size_adjusted(runtimeSurface) else {
#if DEBUG
            logDebugEvent("globalZoom.surface skip reason=follows_config")
#endif
            return false
        }
        guard let current = GhosttySurfaceRuntimeProbe.currentSurfaceFontSizePoints(runtimeSurface),
              current.isFinite, current > 0 else {
            return false
        }

        guard let scaled = CmuxSurfaceConfigTemplate.runtimePointsScaled(
            current: current,
            byMagnificationRatio: ratio
        ) else { return false }
        let applied = performInternalBindingAction(String(format: "set_font_size:%.3f", scaled))
#if DEBUG
        logDebugEvent(
            "globalZoom.surface scale from=\(current) ratio=\(ratio) to=\(scaled) applied=\(applied)"
        )
#endif
        return applied
    }

    /// Returns the explicit unscaled font override to persist in a session snapshot.
    ///
    /// Nil means the terminal follows the current config and should not pin a
    /// font size across relaunches.
    @MainActor
    public func sessionFontSizeOverrideBasePoints() -> Float32? {
        guard let lineage = fontSizeLineageSnapshot(),
              lineage.isExplicitOverride,
              TerminalFontSizePolicy().acceptsPersistedBasePoints(lineage.basePoints) else {
            return nil
        }
        return lineage.basePoints
    }
}
