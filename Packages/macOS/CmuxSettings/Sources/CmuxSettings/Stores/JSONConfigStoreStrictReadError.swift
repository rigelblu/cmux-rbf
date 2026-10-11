import Foundation

/// Why ``JSONConfigStore/strictRoot()`` could not read the config file.
public enum JSONConfigStoreStrictReadError: Error, Equatable, Sendable {
    /// The file exists and the system would not open it. `reason` is the system's.
    case unreadable(reason: String)
    /// The file opened but is not JSON (comments allowed), or its top level is not an object.
    case notValidJSON
}
