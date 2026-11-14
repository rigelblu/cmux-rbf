import AppKit
import Foundation

enum ReplyInlineTriggerDecision: Equatable {
    enum Reason: Equatable {
        case commandShift, settingOff, selectionUnchanged, noSelection
        case notAgentPane, offScreen, noGrid, blankSelection
    }

    case ignore(Reason)
    case show(ReplyInlinePassage)
}
