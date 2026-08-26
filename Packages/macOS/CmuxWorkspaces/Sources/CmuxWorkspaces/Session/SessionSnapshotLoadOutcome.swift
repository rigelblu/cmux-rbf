public import Foundation

/// Result of inspecting a snapshot file on disk.
public enum SessionSnapshotLoadOutcome<SnapshotValue: SessionSnapshotRepresenting>: Sendable {
    /// A usable snapshot and the exact bytes from which it was decoded.
    /// Keeping them together lets authorization bind to one filesystem read.
    case loaded(snapshot: SnapshotValue, data: Data)
    /// No snapshot file on disk: a genuinely clean state.
    case missing
    /// A snapshot file exists but cannot be restored (unreadable data,
    /// decode failure, schema version drift, or an anomalous empty
    /// window list; empty states remove the file instead of writing it).
    case unusable
}
