// `public`, not plain `import`: this package builds with internal-imports-by-
// default, so a plain import makes `Bundle` internal and the `resolved(base:
// bundle:assetExists:)` overload below cannot be public.
public import Foundation

/// Resolves the per-channel name of a runtime app-icon asset.
///
/// **Why this exists.** `ASSETCATALOG_COMPILER_APPICON_NAME` selects which
/// `AppIcon*.appiconset` becomes the *bundle* icon, and that is all it does. The
/// Dock icon is set from code at runtime — `NSApplication.applicationIconImage`,
/// plus the dock tile plugin, plus the Settings picker preview — and every one of
/// those looked up the literal names `AppIconLight` / `AppIconDark`. Those are
/// separate imagesets with no per-channel variants, so a channel could ship a
/// correct bundle icon and still show upstream's art in the Dock.
///
/// That is exactly what happened: `cmux RBF` shipped with `AppIcon-RBF` as its
/// bundle icon — correct in Finder, correct in Spotlight — while the Dock, the
/// app switcher, and Settings all drew upstream's plain icon, because the build
/// setting has no reach into a hardcoded string. It was invisible in tagged DEV
/// builds, since nobody compares two *installed* apps in the Dock until a
/// side-by-side channel exists. Same trap class as the Sparkle-suppression and
/// dock-tile-id findings: a build setting that appears to control something the
/// app controls at runtime.
///
/// **The channel is not a new input.** `CFBundleIconName` already carries it —
/// the build setting writes it, so it reads `AppIcon-RBF` in the RBF build,
/// `AppIcon-Debug` in a tagged build, `AppIcon` upstream. Deriving the suffix
/// from it means no new build setting, no flavor enum to keep in sync, and
/// `-Debug` / `-Nightly` get the same treatment for free the moment someone
/// draws those variants.
public enum ChannelAppIconName {
    /// The channel suffix implied by a bundle's `CFBundleIconName`.
    ///
    /// `"AppIcon-RBF"` → `"-RBF"`, `"AppIcon"` → `""`, anything not starting
    /// with `AppIcon` → `""` (unknown shape: prefer upstream's art over guessing).
    public static func channelSuffix(bundleIconName: String?) -> String {
        guard let raw = bundleIconName?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.hasPrefix("AppIcon")
        else { return "" }
        return String(raw.dropFirst("AppIcon".count))
    }

    /// The asset name to load for `base` in this channel.
    ///
    /// Falls back to `base` when the channel has no variant drawn, so adding a
    /// channel never breaks its icon — it just looks like upstream until someone
    /// supplies the art. `assetExists` is injected so this stays a pure function
    /// and can be tested without an asset catalog.
    public static func resolved(
        base: String,
        bundleIconName: String?,
        assetExists: (String) -> Bool
    ) -> String {
        let suffix = channelSuffix(bundleIconName: bundleIconName)
        guard !suffix.isEmpty else { return base }
        let candidate = base + suffix
        return assetExists(candidate) ? candidate : base
    }

    /// Convenience for the common case: read `CFBundleIconName` from `bundle`
    /// and probe the same bundle for the variant.
    ///
    /// In-app callers pass `Bundle.main`. Anything running **outside** the app's
    /// process must pass the enclosing app bundle instead, because its own
    /// `Bundle.main` is the host process. The one such caller today — the dock
    /// tile plugin, loaded into Dock — does not use this overload at all: it
    /// links no Cmux package and re-derives the suffix by hand in
    /// `Sources/AppIconDockTilePlugin.swift`, which states why. If that plugin
    /// ever gains the dependency, delete the copy there and call this with the
    /// enclosing bundle.
    public static func resolved(
        base: String,
        bundle: Bundle,
        assetExists: (String) -> Bool
    ) -> String {
        resolved(
            base: base,
            bundleIconName: bundle.object(forInfoDictionaryKey: "CFBundleIconName") as? String,
            assetExists: assetExists
        )
    }
}
