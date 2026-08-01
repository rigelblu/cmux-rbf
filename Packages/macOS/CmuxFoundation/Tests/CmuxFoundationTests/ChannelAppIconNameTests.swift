import Testing

@testable import CmuxFoundation

/// The bug these pin: `cmux RBF` shipped with the correct *bundle* icon and
/// upstream's icon in the Dock, because the Dock image is chosen at runtime from
/// a hardcoded asset name that no build setting reaches.
@Suite("ChannelAppIconName")
struct ChannelAppIconNameTests {
    @Test("derives the channel suffix from CFBundleIconName")
    func suffixes() {
        #expect(ChannelAppIconName.channelSuffix(bundleIconName: "AppIcon-RBF") == "-RBF")
        #expect(ChannelAppIconName.channelSuffix(bundleIconName: "AppIcon-Debug") == "-Debug")
        #expect(ChannelAppIconName.channelSuffix(bundleIconName: "AppIcon-Nightly") == "-Nightly")
        // Upstream: no suffix, so nothing about its lookup changes.
        #expect(ChannelAppIconName.channelSuffix(bundleIconName: "AppIcon") == "")
        #expect(ChannelAppIconName.channelSuffix(bundleIconName: nil) == "")
        #expect(ChannelAppIconName.channelSuffix(bundleIconName: "  AppIcon-RBF  ") == "-RBF")
        // Unrecognised shape: prefer upstream's art over guessing at a suffix.
        #expect(ChannelAppIconName.channelSuffix(bundleIconName: "SomethingElse") == "")
    }

    @Test("resolves to the channel variant when its art exists")
    func resolvesWhenPresent() {
        let name = ChannelAppIconName.resolved(
            base: "AppIconLight",
            bundleIconName: "AppIcon-RBF",
            assetExists: { $0 == "AppIconLight-RBF" }
        )
        #expect(name == "AppIconLight-RBF")
    }

    /// The regression itself: before the fix this *was* the only behaviour, so a
    /// channel with art drawn still got upstream's icon.
    @Test("falls back to the base name when the channel has no art drawn")
    func fallsBackWhenAbsent() {
        let name = ChannelAppIconName.resolved(
            base: "AppIconDark",
            bundleIconName: "AppIcon-Nightly",
            assetExists: { _ in false }
        )
        #expect(name == "AppIconDark")
    }

    /// Adding a channel must never *break* an icon — worst case it looks like
    /// upstream until someone supplies the art.
    @Test("upstream never probes for a variant")
    func upstreamUnchanged() {
        var probed: [String] = []
        let name = ChannelAppIconName.resolved(
            base: "AppIconLight",
            bundleIconName: "AppIcon",
            assetExists: { probed.append($0); return true }
        )
        #expect(name == "AppIconLight")
        #expect(probed.isEmpty, "upstream should short-circuit, not probe the catalog")
    }
}
