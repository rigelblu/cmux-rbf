public import Foundation
internal import os

/// Synchronous atomic repository used by lifecycle paths that must finish before termination.
public final class RestartCommandStateRepository: @unchecked Sendable {
    public enum LoadResult: Sendable {
        case missing
        case record(RestartCommandStateRecord)
        case unavailable
    }

    public let fileURL: URL
    private nonisolated(unsafe) let fileManager: FileManager
    private let serializationLock = OSAllocatedUnfairLock(initialState: ())

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public static func defaultFileURL(
        bundleIdentifier: String?,
        appSupportDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        bundleSpecificFileURL(
            name: "restart-commands-state",
            bundleIdentifier: bundleIdentifier,
            appSupportDirectory: appSupportDirectory,
            fileManager: fileManager
        )
    }

    public func load() -> LoadResult {
        serializationLock.withLock { loadUnserialized() }
    }

    @discardableResult
    public func save(_ record: RestartCommandStateRecord) -> Bool {
        serializationLock.withLock { saveUnserialized(record) }
    }

    private func loadUnserialized() -> LoadResult {
        guard fileManager.fileExists(atPath: fileURL.path) else { return .missing }
        guard let data = try? Data(contentsOf: fileURL),
              let record = try? JSONDecoder().decode(RestartCommandStateRecord.self, from: data),
              record.isStructurallyValid else {
            return .unavailable
        }
        return .record(record)
    }

    private func saveUnserialized(_ record: RestartCommandStateRecord) -> Bool {
        guard record.isStructurallyValid else { return false }
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(record).write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func bundleSpecificFileURL(
        name: String,
        bundleIdentifier: String?,
        appSupportDirectory: URL?,
        fileManager: FileManager
    ) -> URL? {
        let base: URL
        if let appSupportDirectory {
            base = appSupportDirectory
        } else if let discovered = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            base = discovered
        } else {
            return nil
        }
        let bundleID = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = bundleID?.isEmpty == false ? bundleID! : "com.cmuxterm.app"
        let safeBundleID = resolved.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
        return base
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("\(name)-\(safeBundleID).json", isDirectory: false)
    }
}
