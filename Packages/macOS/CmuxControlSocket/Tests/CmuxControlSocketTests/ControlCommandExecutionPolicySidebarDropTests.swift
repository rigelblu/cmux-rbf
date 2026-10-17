import Testing
@testable import CmuxControlSocket

struct ControlCommandExecutionPolicySidebarDropTests {
    @Test func debugSidebarDropReachesTheWorkerSwitch() {
        let policy = ControlCommandExecutionPolicy(forMethod: "debug.sidebar.drop")
#if DEBUG
        #expect(policy == .socketWorker(mainThreadCallable: false))
#else
        #expect(policy == .mainActor)
#endif
    }
}
