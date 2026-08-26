public import Foundation

/// Separate bounded Mac-only persistence for structured restore summaries.
public actor RestartCommandRestoreSummaryRepository {
    private struct StoredFile: Codable {
        let version: Int
        var summaries: [RestartCommandRestoreSummary]
    }

    public static let maximumSummaryCount = 100
    public let fileURL: URL
    private nonisolated(unsafe) let fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public static func defaultFileURL(
        bundleIdentifier: String?,
        appSupportDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        RestartCommandStateRepository.bundleSpecificFileURL(
            name: "restart-command-summaries",
            bundleIdentifier: bundleIdentifier,
            appSupportDirectory: appSupportDirectory,
            fileManager: fileManager
        )
    }

    /// Loads a sorted snapshot. Corrupt and unsupported files are presentation-only loss.
    public func load() -> [RestartCommandRestoreSummary] {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(StoredFile.self, from: data),
              stored.version == 1 else {
            return []
        }
        return Self.sortedAndBounded(stored.summaries)
    }

    @discardableResult
    public func insert(_ summary: RestartCommandRestoreSummary) -> [RestartCommandRestoreSummary] {
        var summaries = load()
        summaries.removeAll { $0.id == summary.id || $0.operationID == summary.operationID }
        summaries.append(summary)
        let next = Self.sortedAndBounded(summaries)
        _ = persist(next)
        return next
    }

    @discardableResult
    public func setRead(_ isRead: Bool, id: UUID) -> [RestartCommandRestoreSummary] {
        var summaries = load()
        guard let index = summaries.firstIndex(where: { $0.id == id }) else { return summaries }
        summaries[index].isRead = isRead
        _ = persist(summaries)
        return summaries
    }

    @discardableResult
    public func markAllRead() -> [RestartCommandRestoreSummary] {
        var summaries = load()
        for index in summaries.indices { summaries[index].isRead = true }
        _ = persist(summaries)
        return summaries
    }

    @discardableResult
    public func remove(id: UUID) -> [RestartCommandRestoreSummary] {
        var summaries = load()
        summaries.removeAll { $0.id == id }
        _ = persist(summaries)
        return summaries
    }

    @discardableResult
    public func clearAll() -> [RestartCommandRestoreSummary] {
        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
        } catch {
            return load()
        }
        return []
    }

    private func persist(_ summaries: [RestartCommandRestoreSummary]) -> Bool {
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(StoredFile(version: 1, summaries: summaries))
                .write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func sortedAndBounded(
        _ summaries: [RestartCommandRestoreSummary]
    ) -> [RestartCommandRestoreSummary] {
        Array(summaries.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }.prefix(maximumSummaryCount))
    }
}
