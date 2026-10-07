import CoreGraphics
import Foundation
import Testing

@testable import CmuxFoundation

// The nested planner over random nested windows, every kind of dragged id and pointer position (#cm-106): it must
// not trap, a plan's indexes must be in range, and a header's plan must be among its parent's rows.
@Suite struct SidebarNestedGroupDropFuzzTests {
    private struct Rng: RandomNumberGenerator {
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

    private func randomRows(_ rng: inout Rng, depth: Int, serial: inout Int) -> [DropRow] {
        var rows: [DropRow] = []
        for _ in 0..<Int.random(in: 0...(depth == 0 ? 5 : 3), using: &rng) {
            serial += 1
            if depth < 3, Int.random(in: 0..<10, using: &rng) < 4 {
                let own: String? = Int.random(in: 0..<4, using: &rng) == 0 ? nil : "o\(serial)"
                rows.append(.grp(
                    "G\(serial)", own: own, pinned: Int.random(in: 0..<4, using: &rng) == 0,
                    folded: Int.random(in: 0..<5, using: &rng) == 0,
                    randomRows(&rng, depth: depth + 1, serial: &serial)
                ))
            } else {
                rows.append(.ws("w\(serial)", pinned: Int.random(in: 0..<5, using: &rng) == 0))
            }
        }
        return rows
    }

    @Test func noWindowTrapsAndEveryPlanIsInRange() {
        var tried = 0, planned = 0, nestedWindows = 0
        var failures: [String] = []
        let traceEveryDrop = ProcessInfo.processInfo.environment["CMUX_FUZZ_TRACE"] == "1"
        for seed in 0..<400 {
            var rng = Rng(seed: UInt64(seed))
            var serial = 0
            let rows = randomRows(&rng, depth: 0, serial: &serial)
            let w = NestedDropWindow(rows)
            guard w.groups.contains(where: { $0.parentGroupId != nil }) else { continue }
            nestedWindows += 1
            for _ in 0..<60 {
                let dragged: UUID
                switch Int.random(in: 0..<4, using: &rng) {
                case 0: dragged = w.workspaces.randomElement(using: &rng)?.id ?? UUID()
                case 1: dragged = w.groups.randomElement(using: &rng)?.id ?? UUID()
                case 2: dragged = w.groups.randomElement(using: &rng)?.anchorWorkspaceId ?? UUID()
                default: dragged = UUID()
                }
                var block: Set<UUID> = []
                if Bool.random(using: &rng) {
                    block = Set(w.groups.compactMap { Bool.random(using: &rng) ? $0.anchorWorkspaceId : nil }).union([dragged])
                }
                let y = CGFloat.random(in: -10...(CGFloat(w.rowNames.count) * 30 + 30), using: &rng)
                let x = CGFloat.random(in: 0...240, using: &rng)
                let request = w.request(dragged: dragged, at: CGPoint(x: x, y: y), block: block, foreignIsPinned: Bool.random(using: &rng))
                // A trap leaves no failure to read, so the input of each drop is printed only when asked for: CMUX_FUZZ_TRACE=1.
                if traceEveryDrop { print("FUZZ seed \(seed) dragged \(dragged) at \(x),\(y)") }
                tried += 1
                guard let plan = SidebarWorkspaceReorderDropResolver().plan(for: request) else { continue }
                planned += 1
                switch plan.action {
                case .reorder(let index, _, let group):
                    if index < 0 || index >= max(request.workspaces.count, 1) + request.groups.count {
                        failures.append("seed \(seed): index \(index) out of range, \(request.workspaces.count) workspaces")
                    }
                    if let group, !request.groups.contains(where: { $0.id == group }) { failures.append("seed \(seed): names an unknown group") }
                case .reorderGroup(let index):
                    if index < 0 || index >= request.groups.count { failures.append("seed \(seed): group index \(index) out of range") }
                default:
                    break
                }
            }
        }
        print("fuzz: \(nestedWindows) nested windows, \(tried) drops tried, \(planned) planned")
        #expect(failures.isEmpty, "\(failures.prefix(3))")
        #expect(nestedWindows >= 100)
        #expect(planned >= 1_500)
    }
}
