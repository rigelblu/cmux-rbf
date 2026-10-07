import CoreGraphics
import Foundation
import Testing

@testable import CmuxFoundation

// A window with no nested group plans every drop exactly as v0.31.0 does (#cm-106). `FrozenV0_31_0DropResolver` is
// the v0.31.0 resolver, byte for byte but for its name; the planner is compared with it on the 36 positions another
// session measured at the base release and on random flat windows.

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct SidebarFlatDropEqualsBaseTests {
    private func equal(_ w: NestedDropWindow, _ request: SidebarWorkspaceReorderDropRequest) -> Bool {
        SidebarWorkspaceReorderDropResolver().plan(for: request) == FrozenV0_31_0DropResolver().plan(for: request)
    }

    /// The README's fixtures: `L1 | A[a1 a2] | B[b1 b2] | L2`, folded and not, and header-only variants, with every
    /// row's upper half, lower half and bottom edge on both halves of the sidebar, for each kind of dragged row.
    @Test func measuredPositionsPlanAsTheBaseResolverDoes() {
        let windows: [NestedDropWindow] = [
            NestedDropWindow([.ws("L1"), .grp("A", own: "a0", [.ws("a1"), .ws("a2")]), .grp("B", own: "b0", [.ws("b1"), .ws("b2")]), .ws("L2")]),
            NestedDropWindow([.ws("L1"), .grp("A", own: "a0", [.ws("a1"), .ws("a2")]), .grp("B", own: "b0", folded: true, [.ws("b1"), .ws("b2")]), .ws("L2")]),
            NestedDropWindow([.ws("L1"), .grp("A", own: "a0", [.ws("a1"), .ws("a2")]), .grp("B", own: "b0", []), .ws("L2")]),
            NestedDropWindow([.ws("L1"), .grp("A", own: "a0", [.ws("a1"), .ws("a2")]), .grp("B", own: nil, []), .ws("L2")]),
            NestedDropWindow([.grp("A", own: "a0", pinned: true, [.ws("a1", pinned: true), .ws("a2")]), .ws("L1", pinned: true), .ws("L2"), .grp("B", own: "b0", [.ws("b1")])]),
        ]
        var compared = 0
        var withPlan = 0
        for w in windows {
            var draggedIds = w.workspaces.map(\.id) + w.groups.filter(\.isEmpty).map(\.id)
            draggedIds.append(UUID())
            for dragged in draggedIds {
                for row in w.rowNames {
                    for zone in [DropZone.upper, .lower, .bottomEdge] {
                        for half in [DropHalf.left, .right] {
                            let request = w.request(dragged: dragged, at: w.point(row, zone, half), foreignIsPinned: false)
                            compared += 1
                            if SidebarWorkspaceReorderDropResolver().plan(for: request) != nil { withPlan += 1 }
                            #expect(equal(w, request), "dragged \(dragged) at \(row) \(zone) \(half)")
                        }
                    }
                }
                for half in [DropHalf.left, .right] {
                    compared += 1
                    #expect(equal(w, w.request(dragged: dragged, at: w.belowAll(half), foreignIsPinned: true)))
                }
            }
        }
        print("flat equals base, measured fixtures: \(compared) positions compared, \(withPlan) with a plan")
        #expect(compared > 1_500)
        #expect(withPlan > 500)
    }

    private func randomFlatWindow(_ rng: inout SeededGenerator) -> NestedDropWindow {
        var rows: [DropRow] = []
        var serial = 0
        func name(_ prefix: String) -> String {
            serial += 1
            return "\(prefix)\(serial)"
        }
        for _ in 0..<Int.random(in: 2...7, using: &rng) {
            if Int.random(in: 0..<10, using: &rng) < 4 {
                let own: String? = Int.random(in: 0..<5, using: &rng) == 0 ? nil : name("o")
                let members = own == nil ? 0 : Int.random(in: 0...3, using: &rng)
                rows.append(.grp(
                    name("G"), own: own, pinned: Int.random(in: 0..<4, using: &rng) == 0,
                    folded: Int.random(in: 0..<4, using: &rng) == 0,
                    (0..<members).map { _ in .ws(name("m"), pinned: false) }
                ))
            } else {
                rows.append(.ws(name("w"), pinned: Int.random(in: 0..<5, using: &rng) == 0))
            }
        }
        return NestedDropWindow(rows)
    }

    @Test func randomFlatWindowsPlanAsTheBaseResolverDoes() {
        var compared = 0
        var withPlan = 0
        var kinds: [String: Int] = [:]
        for seed in 0..<60 {
            var rng = SeededGenerator(seed: UInt64(seed))
            let w = randomFlatWindow(&rng)
            for _ in 0..<80 {
                let kindRoll = Int.random(in: 0..<10, using: &rng)
                let dragged: UUID
                let kind: String
                if kindRoll < 5, let ws = w.workspaces.randomElement(using: &rng) {
                    dragged = ws.id
                    kind = w.groups.contains { $0.anchorWorkspaceId == ws.id } ? "header with workspace" : "workspace"
                } else if kindRoll < 8, let empty = w.groups.filter(\.isEmpty).randomElement(using: &rng) {
                    dragged = empty.id
                    kind = "header with none"
                } else {
                    dragged = UUID()
                    kind = "from another window"
                }
                let y = CGFloat.random(in: -10...(CGFloat(w.rowNames.count) * 30 + 20), using: &rng)
                let x = CGFloat.random(in: 0...240, using: &rng)
                var block: Set<UUID> = []
                if kind == "workspace", Bool.random(using: &rng) {
                    block = Set(w.workspaces.filter { w.groups.map(\.anchorWorkspaceId).contains($0.id) == false }.prefix(3).map(\.id))
                    block.insert(dragged)
                }
                let request = w.request(dragged: dragged, at: CGPoint(x: x, y: y), block: block, foreignIsPinned: Bool.random(using: &rng))
                compared += 1
                kinds[kind, default: 0] += 1
                if SidebarWorkspaceReorderDropResolver().plan(for: request) != nil { withPlan += 1 }
                #expect(equal(w, request), "seed \(seed) \(kind) at \(x),\(y)")
            }
        }
        print("flat equals base, random: \(compared) drops compared, \(withPlan) with a plan, by kind \(kinds.sorted { $0.key < $1.key })")
        #expect(compared == 60 * 80)
        #expect(withPlan > 1_000)
        #expect(kinds.count == 4)
    }
}
