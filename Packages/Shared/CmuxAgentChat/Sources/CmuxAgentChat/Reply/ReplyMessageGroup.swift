import Foundation

/// One agent response: the transcript messages that came from a single
/// model reply.
///
/// A transcript writes one line per *content block*, so one reply arrives
/// as several ``ChatMessage`` values that share nothing at the
/// ``ChatMessage/id`` level. ``ChatMessage/apiMessageID`` is what ties them
/// together, and this type is that tie made explicit.
///
/// It is the unit the Reply panel navigates: `◄ n/N ►` steps one response,
/// never one block. Concatenating across response ids would fuse two
/// replies into one and make a quoted span ambiguous about which reply it
/// belongs to.
public struct ReplyMessageGroup: Identifiable, Sendable, Equatable {
    /// Stable identity for the group.
    ///
    /// The shared ``ChatMessage/apiMessageID`` when the transcript names
    /// one; otherwise the lone constituent message's own id, because a
    /// message the transcript cannot group is a group of one.
    public let id: String

    /// Transcript position of the group's first message.
    ///
    /// Groups sort by this, and it is the cursor for paging older history.
    public let seq: Int

    /// When the group's first message was written.
    public let timestamp: Date

    /// Every constituent message, in transcript order.
    ///
    /// Kept whole rather than reduced to text: the tool runs and thinking
    /// blocks in a reply are part of it, and a later slice renders them.
    public let messages: [ChatMessage]

    /// Creates a group.
    ///
    /// - Parameters:
    ///   - id: Shared response identity, or the lone message's own id.
    ///   - seq: Transcript position of the first constituent.
    ///   - timestamp: When the first constituent was written.
    ///   - messages: Constituents in transcript order.
    public init(id: String, seq: Int, timestamp: Date, messages: [ChatMessage]) {
        self.id = id
        self.seq = seq
        self.timestamp = timestamp
        self.messages = messages
    }

    /// The reply's prose, ready to hand to a markdown renderer.
    ///
    /// Text blocks only, in transcript order, joined as separate
    /// paragraphs — two content blocks were never one paragraph, and
    /// joining them without a break would run the last sentence of one
    /// into the first word of the next.
    public var markdown: String {
        messages
            .compactMap { message in
                guard case let .prose(prose) = message.kind else { return nil }
                return prose.text
            }
            .joined(separator: "\n\n")
    }
}

extension ReplyMessageGroup {
    /// Codex's tag for the narration it writes while working, as opposed to
    /// the reply it finishes with.
    ///
    /// The structural twin of Claude's thinking blocks: interesting, but not
    /// the message. Claude does not tag its lines, so this never matches
    /// there.
    static let commentaryPhase = "commentary"

    /// Groups a transcript window into the replies the Reply panel can
    /// navigate.
    ///
    /// Four rules, each of which changes what the user sees:
    ///
    /// - **Agent messages only.** A user prompt is not a reply, and neither
    ///   is the `tool_result` line the harness writes back as a user turn.
    /// - **Codex `commentary` is dropped.** Codex writes each narration
    ///   entry as its own line with its own id, so keeping them would put a
    ///   dozen entries into one turn's counter and make `◄` walk through
    ///   narration. Claude's equivalent — a thinking block — rides inside
    ///   its reply's group and is dropped by the prose rule below instead.
    /// - **Consecutive runs, not a dictionary.** Order comes free, and two
    ///   replies that somehow reuse an id stay separate rather than fusing.
    ///   A `nil` id never continues a run: the model contract says treat it
    ///   as ungroupable, never as "same group".
    /// - **A group needs prose to exist.** A reply that only called a tool
    ///   has nothing to read and nothing to quote, so stepping to it would
    ///   show an empty panel.
    ///
    /// - Parameter messages: A transcript window in ascending `seq` order.
    /// - Returns: Navigable groups, oldest first.
    public static func groups(from messages: [ChatMessage]) -> [ReplyMessageGroup] {
        let candidates = messages.filter { message in
            message.role == .agent && message.phase != commentaryPhase
        }

        var groups: [ReplyMessageGroup] = []
        var run: [ChatMessage] = []

        func closeRun() {
            guard let first = run.first else { return }
            let hasProse = run.contains { message in
                if case .prose = message.kind { return true }
                return false
            }
            if hasProse {
                groups.append(
                    ReplyMessageGroup(
                        id: first.apiMessageID ?? first.id,
                        seq: first.seq,
                        timestamp: first.timestamp,
                        messages: run
                    )
                )
            }
            run = []
        }

        for message in candidates {
            let continuesRun = message.apiMessageID != nil
                && message.apiMessageID == run.last?.apiMessageID
            if !continuesRun {
                closeRun()
            }
            run.append(message)
        }
        closeRun()

        return groups
    }
}
