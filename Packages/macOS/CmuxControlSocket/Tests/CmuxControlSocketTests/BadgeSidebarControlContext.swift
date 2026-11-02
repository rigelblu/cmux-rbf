import Foundation
@testable import CmuxControlSocket

@MainActor
final class BadgeSidebarControlContext: ControlCommandContext {
    var snapshot: ControlExtensionSidebarSnapshot?

    func controlExtensionSidebarSnapshot(routing: ControlRoutingSelectors) -> ControlExtensionSidebarSnapshot? {
        snapshot
    }
}
