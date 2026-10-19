import Bonsplit
import CmuxAgentChat
import Foundation

/// The conversation and file to which a board-layout command is allowed to refer.
struct FigmaBoardLayoutBinding: Equatable {
    struct Conversation: Hashable {
        let panelID: UUID
        let kind: ChatAgentKind
        let sessionID: String
    }
    struct LastOpen: Equatable {
        let panelID: UUID
        let fileKey: String
    }
    let conversation: Conversation
    let fileKey: String
    var orientation: BoardLayoutOrientation

    func matches(conversation: Conversation, panelID: UUID, currentFileKey: String?, lastOpen: LastOpen?) -> Bool {
        self.conversation == conversation && currentFileKey == fileKey
            && lastOpen == LastOpen(panelID: panelID, fileKey: fileKey)
    }
}
