import CmuxTerminalCore
import Foundation
import os

struct CodexRenameConfirmation: Equatable, Sendable {
    let name: String
    let threadID: String
}

final class CodexExplicitRenameSubmissionStore: @unchecked Sendable {
    static let shared = CodexExplicitRenameSubmissionStore()

    private struct Submission {
        let normalizedName: String
        let recordedAt: TimeInterval
    }

    private let lock = OSAllocatedUnfairLock(initialState: [UUID: [Submission]]())
    private let validityInterval: TimeInterval = 30

    static func explicitRenameName(in visibleComposerText: String) -> String? {
        guard let commandRange = visibleComposerText.range(
            of: "/rename",
            options: .backwards
        ) else {
            return nil
        }
        let lineStart = visibleComposerText[..<commandRange.lowerBound]
            .lastIndex(of: "\n")
            .map { visibleComposerText.index(after: $0) }
            ?? visibleComposerText.startIndex
        let commandPrefix = visibleComposerText[lineStart..<commandRange.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        guard commandPrefix.isEmpty || ["›", ">", "❯"].contains(commandPrefix) else {
            return nil
        }
        let suffixStart = commandRange.upperBound
        guard suffixStart < visibleComposerText.endIndex,
              visibleComposerText[suffixStart].isWhitespace else {
            return nil
        }
        let name = visibleComposerText[suffixStart...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    func record(surfaceID: UUID, name: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let normalizedName = Self.normalizedName(name)
        guard !normalizedName.isEmpty else { return }
        lock.withLock { submissionsBySurface in
            var submissions = submissionsBySurface[surfaceID, default: []]
                .filter { now - $0.recordedAt <= validityInterval }
            submissions.append(Submission(normalizedName: normalizedName, recordedAt: now))
            submissionsBySurface[surfaceID] = Array(submissions.suffix(4))
        }
    }

    func consumeMatching(
        surfaceID: UUID,
        name: String,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        let normalizedName = Self.normalizedName(name)
        return lock.withLock { submissionsBySurface in
            var submissions = submissionsBySurface[surfaceID, default: []]
                .filter { now - $0.recordedAt <= validityInterval }
            guard let index = submissions.firstIndex(where: {
                $0.normalizedName == normalizedName
            }) else {
                submissionsBySurface[surfaceID] = submissions
                return false
            }
            submissions.remove(at: index)
            if submissions.isEmpty {
                submissionsBySurface.removeValue(forKey: surfaceID)
            } else {
                submissionsBySurface[surfaceID] = submissions
            }
            return true
        }
    }

    private static func normalizedName(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Extracts Codex's dedicated `/rename` confirmation from ANSI-decorated TUI
/// output. The caller also requires a recent user submission observed at the
/// terminal input boundary; automatic name updates render the same cell.
///
/// Emission is deliberately not deduplicated here. A TUI redraw and a genuine
/// second `/rename` to the same name produce identical bytes, so suppressing
/// repeats at this layer would silently swallow the real action. The caller's
/// submission store already consumes one pending submission per confirmation,
/// which drops redraws while letting a fresh rename through.
struct CodexRenameConfirmationDetector {
    private enum EscapeState {
        case text
        case escape
        case csi
        case osc
        case oscEscape
    }

    private static let namePrefix = Array("Session renamed to ".utf8)
    private static let resumeLead = Array(". To resume this session run ".utf8)
    private static let maximumBufferedBytes = 8 * 1024
    private static let retainedTailBytes = 4 * 1024

    private var state: EscapeState = .text
    private var visibleBytes: [UInt8] = []
    /// Incremental marker matches over the visible-byte stream.
    ///
    /// This callback runs on Ghostty's read thread before the renderer mutex is
    /// taken, and `termio/Termio.zig` states the contract: the tee callback "is
    /// expected to be cheap (typically a memcpy into a ring buffer + a wakeup)."
    /// Codex repaints its whole composer on every keystroke, so rescanning the
    /// 8 KB buffer on every chunk — as an earlier revision did — throttles PTY
    /// drain while the user types. Matching incrementally means the buffer is
    /// scanned only while a completed marker awaits extraction.
    private var resumeMatcher = IncrementalByteMatcher(
        needle: CodexRenameConfirmationDetector.resumeLead
    )
    private var namePrefixMatcher = IncrementalByteMatcher(
        needle: CodexRenameConfirmationDetector.namePrefix
    )
    /// Armed when `resumeLead` completes; cleared only once no unconsumed
    /// marker remains in the buffer. The thread ID that extraction also needs
    /// trails the marker and can land in a later chunk, so clearing this on
    /// the first extraction attempt would drop the confirmation permanently.
    private var sawResumeMarker = false
    /// Diagnostic, monotonic: whether `namePrefix` has ever completed. The tee
    /// context logs its first flip, which splits "no rename bytes arrived"
    /// from "bytes arrived but the resume marker never matched".
    private(set) var sawNamePrefixEver = false

    mutating func consume(_ bytes: UnsafeBufferPointer<UInt8>) -> [CodexRenameConfirmation] {
        for byte in bytes {
            consume(byte)
        }
        if visibleBytes.count > Self.maximumBufferedBytes {
            visibleBytes.removeFirst(visibleBytes.count - Self.retainedTailBytes)
        }

        // Nothing can be extracted without the resume marker, and the marker is
        // what makes a confirmation distinguishable from an automatic rename.
        // Ordinary output — including every composer repaint while typing —
        // leaves here without touching the buffer again.
        guard sawResumeMarker else { return [] }

        var confirmations: [CodexRenameConfirmation] = []
        // Anchor each confirmation on the resume marker and then scan *backwards*
        // for the nearest name prefix. Scanning forwards from the first prefix
        // splices an earlier automatic "Session renamed to ..." line into the
        // name, because automatic updates render the same cell and leave no
        // resume hint of their own.
        while let resumeRange = visibleBytes.firstRange(of: Self.resumeLead) {
            guard let (threadRange, threadID) = visibleBytes.firstUUID(
                startingAt: resumeRange.upperBound
            ) else {
                // The thread ID has not fully arrived. Keep the marker armed so
                // the next chunk resumes extraction where this one stopped; if
                // the ID never arrives, the buffer cap eventually trims the
                // marker away and the scan below stops matching.
                return confirmations
            }

            guard let prefixRange = visibleBytes.lastRange(
                    of: Self.namePrefix,
                    endingBefore: resumeRange.lowerBound
                ),
                let name = String(
                    bytes: visibleBytes[prefixRange.upperBound..<resumeRange.lowerBound],
                    encoding: .utf8
                )?.trimmingCharacters(in: .whitespacesAndNewlines),
                !name.isEmpty else {
                visibleBytes.removeSubrange(..<resumeRange.upperBound)
                continue
            }

            confirmations.append(CodexRenameConfirmation(name: name, threadID: threadID))
            visibleBytes.removeSubrange(..<threadRange.upperBound)
        }
        sawResumeMarker = false
        return confirmations
    }

    private mutating func consume(_ byte: UInt8) {
        switch state {
        case .text:
            if byte == 0x1B {
                state = .escape
            } else if byte == 0x09 {
                visibleBytes.append(0x20)
                advanceMarkerMatches(0x20)
            } else if byte >= 0x20, byte != 0x7F {
                visibleBytes.append(byte)
                advanceMarkerMatches(byte)
            }
        case .escape:
            switch byte {
            case 0x5B:
                state = .csi
            case 0x5D:
                state = .osc
            default:
                state = .text
            }
        case .csi:
            if (0x40...0x7E).contains(byte) {
                state = .text
            }
        case .osc:
            if byte == 0x07 {
                state = .text
            } else if byte == 0x1B {
                state = .oscEscape
            }
        case .oscEscape:
            state = byte == 0x5C ? .text : .osc
        }
    }

    private mutating func advanceMarkerMatches(_ byte: UInt8) {
        if resumeMatcher.advance(byte) {
            sawResumeMarker = true
        }
        if namePrefixMatcher.advance(byte) {
            sawNamePrefixEver = true
        }
    }
}

/// Streaming single-needle matcher over a byte sequence.
///
/// On mismatch it restarts and re-tests the byte at position zero, so a
/// needle beginning immediately after a failed partial is still caught. This
/// single retry is sufficient only because each needle's first byte never
/// recurs later in the needle — `.` in `resumeLead`, `S` in `namePrefix` — so
/// no failed partial can conceal a shifted restart, and no failure table is
/// needed.
private struct IncrementalByteMatcher {
    private let needle: [UInt8]
    private var matchLength = 0

    init(needle: [UInt8]) {
        self.needle = needle
    }

    /// Consumes one byte; true when it completes a full needle match.
    mutating func advance(_ byte: UInt8) -> Bool {
        if byte == needle[matchLength] {
            matchLength += 1
        } else {
            matchLength = byte == needle[0] ? 1 : 0
        }
        guard matchLength == needle.count else { return false }
        matchLength = 0
        return true
    }
}

private extension Array where Element == UInt8 {
    func firstRange(of needle: [UInt8], startingAt start: Int = 0) -> Range<Int>? {
        guard !needle.isEmpty, start >= 0, count - start >= needle.count else { return nil }
        let finalStart = count - needle.count
        for candidate in start...finalStart
            where self[candidate..<(candidate + needle.count)].elementsEqual(needle) {
            return candidate..<(candidate + needle.count)
        }
        return nil
    }

    /// The last occurrence of `needle` that ends at or before `limit`.
    func lastRange(of needle: [UInt8], endingBefore limit: Int) -> Range<Int>? {
        guard !needle.isEmpty, limit >= needle.count, limit <= count else { return nil }
        var candidate = limit - needle.count
        while candidate >= 0 {
            if self[candidate..<(candidate + needle.count)].elementsEqual(needle) {
                return candidate..<(candidate + needle.count)
            }
            candidate -= 1
        }
        return nil
    }

    func firstUUID(startingAt start: Int) -> (Range<Int>, String)? {
        let uuidLength = 36
        guard start >= 0, count - start >= uuidLength else { return nil }
        for candidate in start...(count - uuidLength) {
            let range = candidate..<(candidate + uuidLength)
            guard let value = String(bytes: self[range], encoding: .utf8),
                  UUID(uuidString: value) != nil else {
                continue
            }
            return (range, value)
        }
        return nil
    }
}

/// Per-surface state owned by libghostty's serialized PTY read callback.
///
/// SAFETY: libghostty invokes a surface's tee callback serially on that
/// surface's IO read thread. After initialization, only that callback mutates
/// `detectors`; other threads receive copied value identifiers after a match.
final class TerminalOutputTeeContext: @unchecked Sendable {
    private struct DetectorBinding {
        let agentID: String
        var detector: PromptLineTurnDetector
        var forwardedRevision: UInt64 = 0
        var forwardedSubmissionCount: UInt64 = 0
        var confirmationDeadline: ContinuousClock.Instant?
        var unforwardedLocalConfirmations: [PromptLineTurnConfirmation] = []
    }

    /// The latest detector state queued for the notification actor.
    private struct AgentForward: Sendable {
        let agentID: String
        let submissionCount: UInt64
        let revision: UInt64
        let confirmation: PromptLineTurnConfirmation?
        let deadline: ContinuousClock.Instant?
        /// Turns the detector confirmed synchronously at their deadlines, in
        /// identifier order. The notification owner delivers each exactly
        /// once by identifier, so a slow delivery timer cannot lose a
        /// completion and coalescing cannot drop one.
        let locallyConfirmed: [PromptLineTurnConfirmation]
    }

    private struct ForwardQueue {
        var pending: [AgentForward] = []
        var draining = false
    }

    /// Confirmed turns arrive at most once per confirmation delay, so this
    /// cap can only trim a drain task that has been starved for many
    /// seconds; the newest completions win.
    private static let maximumBufferedLocalConfirmations = 8

    let workspaceID: UUID
    let surfaceID: UUID
    private let clock = ContinuousClock()
    private let notificationHandler: PromptTurnNotificationHandler
    private let codexRenameHandler: @Sendable (CodexRenameConfirmation) -> Void
    private var detectors: [DetectorBinding]
    private var codexRenameDetector = CodexRenameConfirmationDetector()
#if DEBUG
    /// Mutated only from the serialized read callback, like `detectors`.
    private var loggedNamePrefixSighting = false
#endif
    private let forwardQueue = OSAllocatedUnfairLock(initialState: ForwardQueue())

    init(
        workspaceID: UUID,
        surfaceID: UUID,
        agentDefinitions: [CmuxTaskManagerCodingAgentDefinition],
        codexRenameHandler: @escaping @Sendable (CodexRenameConfirmation) -> Void = { _ in }
    ) {
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.notificationHandler = PromptTurnNotificationHandler(
            workspaceID: workspaceID,
            surfaceID: surfaceID
        )
        self.codexRenameHandler = codexRenameHandler
        self.detectors = agentDefinitions.compactMap { definition in
            definition.promptTurnDetection.map {
                DetectorBinding(
                    agentID: definition.id,
                    detector: PromptLineTurnDetector(configuration: $0)
                )
            }
        }
    }

    func consume(_ bytes: UnsafeBufferPointer<UInt8>) {
        for confirmation in codexRenameDetector.consume(bytes) {
            codexRenameHandler(confirmation)
        }
#if DEBUG
        // One line, once per surface, from the serialized read callback. This
        // is the diagnostic fork a silent rename needs first: "Session renamed
        // to " was seen (so bytes reached the detector and the parse is where
        // to look) versus nothing arrived at all. The log call is a serial-
        // queue enqueue, safe and cheap on this thread at this frequency.
        if codexRenameDetector.sawNamePrefixEver, !loggedNamePrefixSighting {
            loggedNamePrefixSighting = true
            cmuxDebugLog(
                "codexRename.namePrefixSeen surface=\(surfaceID.uuidString.prefix(8))"
            )
        }
#endif
        let now = clock.now
        for index in detectors.indices {
            if let confirmation = detectors[index].detector.pendingConfirmation,
               let deadline = detectors[index].confirmationDeadline,
               now >= deadline {
                if detectors[index].detector.confirm(confirmation) > 0 {
                    detectors[index].unforwardedLocalConfirmations.append(confirmation)
                }
                detectors[index].confirmationDeadline = nil
            }

            detectors[index].detector.consume(bytes)
            forwardDetectorChangeIfNeeded(at: index, now: now)
        }
    }

    private func forwardDetectorChangeIfNeeded(
        at index: Int,
        now: ContinuousClock.Instant
    ) {
        let revision = detectors[index].detector.confirmationRevision
        let submissionCount = detectors[index].detector.submissionCount
        let locallyConfirmed = detectors[index].unforwardedLocalConfirmations
        guard revision != detectors[index].forwardedRevision ||
            submissionCount != detectors[index].forwardedSubmissionCount ||
            !locallyConfirmed.isEmpty else {
            return
        }
        detectors[index].forwardedRevision = revision
        detectors[index].forwardedSubmissionCount = submissionCount
        detectors[index].unforwardedLocalConfirmations = []

        let confirmation = detectors[index].detector.pendingConfirmation
        let deadline = confirmation.map {
            now.advanced(by: $0.delay)
        }
        detectors[index].confirmationDeadline = deadline
        enqueue(AgentForward(
            agentID: detectors[index].agentID,
            submissionCount: submissionCount,
            revision: revision,
            confirmation: confirmation,
            deadline: deadline,
            locallyConfirmed: locallyConfirmed
        ))
    }

    /// Coalesces to the latest state per agent and keeps at most one drain
    /// task in flight, so sustained PTY output can never fan out unbounded
    /// tasks or queue memory. The single drain task also preserves per-agent
    /// ordering into the notification actor.
    private func enqueue(_ forward: AgentForward) {
        let startDrain = forwardQueue.withLock { state in
            if let existing = state.pending.firstIndex(where: { $0.agentID == forward.agentID }) {
                // Coalesce to the latest state but never drop undelivered
                // local confirmations.
                let merged = (state.pending[existing].locallyConfirmed + forward.locallyConfirmed)
                    .suffix(Self.maximumBufferedLocalConfirmations)
                state.pending[existing] = AgentForward(
                    agentID: forward.agentID,
                    submissionCount: forward.submissionCount,
                    revision: forward.revision,
                    confirmation: forward.confirmation,
                    deadline: forward.deadline,
                    locallyConfirmed: Array(merged)
                )
            } else {
                state.pending.append(forward)
            }
            guard !state.draining else { return false }
            state.draining = true
            return true
        }
        guard startDrain else { return }
        let notificationHandler = notificationHandler
        let forwardQueue = forwardQueue
        Task {
            while true {
                let next: AgentForward? = forwardQueue.withLock { state in
                    guard !state.pending.isEmpty else {
                        state.draining = false
                        return nil
                    }
                    return state.pending.removeFirst()
                }
                guard let next else { return }
                await notificationHandler.update(
                    agentID: next.agentID,
                    submissionCount: next.submissionCount,
                    revision: next.revision,
                    confirmation: next.confirmation,
                    deadline: next.deadline,
                    locallyConfirmed: next.locallyConfirmed
                )
            }
        }
    }
}
