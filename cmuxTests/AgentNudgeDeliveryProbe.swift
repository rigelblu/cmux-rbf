@testable import CmuxNotifications
import Foundation
import os
import UserNotifications
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class AgentNudgeDeliveryProbe {
    var delivered: [(notification: TerminalNotification, effects: TerminalNotificationPolicyEffects)] = []
    var suppressed: [TerminalNotification] = []
    var forwarded: [UUID] = []
    let nativeRequestIDs = OSAllocatedUnfairLock(initialState: [String]())
    let authorization = OSAllocatedUnfairLock<NativeNotificationDeliveryHooks.AuthorizationCompletion?>(initialState: nil)
}

/// Models a native add accepted before its completion and delivered late.
final class AgentNudgeCallingCenter: UserNotificationCenterCalling, @unchecked Sendable {
    var delegate: (any UNUserNotificationCenterDelegate)?
    private struct State {
        var adds: [String] = []
        var notificationIDs: [String] = []
        var survivors: Set<String> = []
        var removals = 0
        var deliveryEvents: [String] = []
        var completion: (@Sendable ((any Error)?) -> Void)?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    let forbiddenFeedback = OSAllocatedUnfairLock(initialState: 0)
    var hasHeldAdd: Bool { state.withLock { $0.completion != nil } }
    var addedIDs: [String] { state.withLock { $0.adds } }
    var addedNotificationIDs: [String] { state.withLock { $0.notificationIDs } }
    var survivingIDs: Set<String> { state.withLock { $0.survivors } }
    var removalCount: Int { state.withLock { $0.removals } }
    var deliveryEvents: [String] { state.withLock { $0.deliveryEvents } }
    func seedDelivered(_ identifier: String) {
        _ = state.withLock { $0.survivors.insert(identifier) }
    }
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {}
    func getNotificationCategories(completionHandler: @escaping @Sendable (Set<UNNotificationCategory>) -> Void) {
        completionHandler([])
    }
    func getNotificationSettings(completionHandler: @escaping @Sendable (UNNotificationSettings) -> Void) {}
    func requestAuthorization(options: UNAuthorizationOptions,
                              completionHandler: @escaping @Sendable (Bool, (any Error)?) -> Void) {
        completionHandler(true, nil)
    }
    func add(_ request: UNNotificationRequest,
             withCompletionHandler completionHandler: (@Sendable ((any Error)?) -> Void)?) {
        state.withLock {
            $0.adds.append(request.identifier)
            $0.notificationIDs.append(request.content.userInfo["notificationId"] as? String ?? "")
            $0.deliveryEvents.append("add:\(request.identifier)")
            $0.survivors.insert(request.identifier)
            $0.completion = completionHandler
        }
    }
    func releaseAdd(fails: Bool) {
        let completion = state.withLock { value in
            defer { value.completion = nil }
            // Exercise a completion arriving after the first read cleanup.
            if !fails { value.survivors.formUnion(value.adds) }
            return value.completion
        }
        completion?(fails ? NSError(domain: "NudgeHeldAdd", code: 1) : nil)
    }
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) { remove(identifiers, event: "removeDelivered") }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) { remove(identifiers, event: "removePending") }
    private func remove(_ identifiers: [String], event: String) {
        state.withLock {
            $0.removals += 1
            $0.deliveryEvents.append(contentsOf: identifiers.map { "\(event):\($0)" })
            $0.survivors.subtract(identifiers)
        }
    }
}
