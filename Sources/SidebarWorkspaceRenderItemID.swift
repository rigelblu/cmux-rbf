import Foundation

/// Stable, allocation-free identity for a `SidebarWorkspaceRenderItem`.
///
/// `ForEach` gathers row identifiers on every list diff, so the id must be
/// cheap to create and hash. Keep the discriminator as a byte so SwiftUI's
/// per-scroll list diff avoids enum-payload hash/equality witnesses.
struct SidebarWorkspaceRenderItemID: Hashable {
    private static let colorSentinel = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    private let kind: UInt8
    private let uuid: UUID
    private let colorKey: UInt32

    static func group(_ uuid: UUID) -> Self {
        Self(kind: 1, uuid: uuid, colorKey: 0)
    }

    static func workspace(_ uuid: UUID) -> Self {
        Self(kind: 2, uuid: uuid, colorKey: 0)
    }

    static func colorSection(_ id: SidebarWorkspaceColorSectionID) -> Self {
        let body = id.normalizedHex.dropFirst()
        let rgb = UInt32(body, radix: 16) ?? 0
        let tier: UInt32 = id.pinTier == .pinned ? 1 : 0
        return Self(kind: 3, uuid: colorSentinel, colorKey: (rgb << 1) | tier)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.kind == rhs.kind, lhs.colorKey == rhs.colorKey else { return false }
        return lhs.kind == 3 || lhs.uuid == rhs.uuid
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(colorKey)
        if kind != 3 { hasher.combine(uuid) }
    }
}
