import Bonsplit
import Foundation

enum CmuxSurfaceTabBarBuiltInAction: String, Codable, Sendable, CaseIterable, Hashable {
    case newWorkspace = "cmux.newWorkspace"
    case newAgentChat = "cmux.newAgentChat"
    case cloudVM = "cmux.cloudvm"
    case mobileConnect = "cmux.mobileconnect"
    case newTerminal = "cmux.newTerminal"
    case newBrowser = "cmux.newBrowser"
    case splitLeft = "cmux.splitLeft"
    case splitUp = "cmux.splitUp"
    case splitRight = "cmux.splitRight"
    case splitDown = "cmux.splitDown"

    init?(configID: String) {
        switch configID {
        case "cmux.newWorkspace", "newWorkspace":
            self = .newWorkspace
        case "cmux.newAgentChat", "cmux.agentChat", "newAgentChat", "new-agent-chat", "agentChat":
            self = .newAgentChat
        case "cmux.cloudvm", "cmux.cloudVM", "cloudVM", "cloudvm",
             "cmux.newCloudVM", "cmux.newCloudVm", "newCloudVM", "newCloudVm",
             "cmux.startCloudVM", "cmux.startCloudVm", "startCloudVM", "startCloudVm":
            self = .cloudVM
        case "cmux.mobileconnect", "cmux.mobileConnect", "mobileConnect", "mobileconnect",
             "cmux.connectPhone", "connectPhone":
            self = .mobileConnect
        case "cmux.newTerminal", "newTerminal":
            self = .newTerminal
        case "cmux.newBrowser", "newBrowser":
            self = .newBrowser
        case "cmux.splitLeft", "splitLeft":
            self = .splitLeft
        case "cmux.splitUp", "splitUp":
            self = .splitUp
        case "cmux.splitRight", "splitRight":
            self = .splitRight
        case "cmux.splitDown", "splitDown":
            self = .splitDown
        default:
            return nil
        }
    }

    var configID: String {
        rawValue
    }

    var defaultIcon: String {
        switch self {
        case .newWorkspace:
            return "plus.square"
        case .newAgentChat:
            return "message"
        case .cloudVM:
            return "cloud"
        case .mobileConnect:
            return "iphone"
        case .newTerminal:
            return "terminal"
        case .newBrowser:
            return "globe"
        case .splitLeft:
            return "rectangle.lefthalf.inset.filled"
        case .splitUp:
            return "rectangle.tophalf.inset.filled"
        case .splitRight:
            return "rectangle.righthalf.inset.filled"
        case .splitDown:
            return "rectangle.bottomhalf.inset.filled"
        }
    }

    var bonsplitAction: BonsplitConfiguration.SplitActionButton.Action? {
        switch self {
        case .newWorkspace, .newAgentChat, .cloudVM, .mobileConnect,
             .splitLeft, .splitUp:
            // Bonsplit cannot express insert-before. Keep Left/Up custom so
            // Workspace can preserve the clicked pane and full direction.
            return nil
        case .splitRight:
            return .splitRight
        case .splitDown:
            return .splitDown
        case .newTerminal:
            return .newTerminal
        case .newBrowser:
            return .newBrowser
        }
    }
}
