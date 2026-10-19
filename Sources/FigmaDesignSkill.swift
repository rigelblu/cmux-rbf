import Foundation

// cmux-rbf #cm-73.17: ownership decision, independent of the user's home.
struct FigmaDesignSkill {
    static let markerPrefix = "<!-- cmux-managed-skill: design-in-figma-pane"
    enum InstallDecision: Equatable { case write, skip }
    static func decision(folderExists: Bool, folderIsSymlink: Bool, fileIsSymlink: Bool, existingDocument: String?) -> InstallDecision {
        guard !folderIsSymlink, !fileIsSymlink else { return .skip }
        guard folderExists else { return .write }
        guard let existingDocument else { return .skip }
        let lines = existingDocument.components(separatedBy: "\n")
        guard lines.first == "---",
              let end = lines.dropFirst().firstIndex(of: "---"),
              lines.indices.contains(end + 1),
              lines[end + 1].hasPrefix(markerPrefix) else { return .skip }
        return .write
    }
    enum InstallResult: Sendable, Equatable { case written(URL), kept(URL), refused(URL) }

    static func document(bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "design-in-figma-pane", withExtension: "md") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static func install(home: URL, fileManager: FileManager = .default, bundle: Bundle = .main) -> [InstallResult] {
        var visited: Set<String> = []
        var results: [InstallResult] = []
        let markdown = document(bundle: bundle)
        for relativeRoot in [".claude/skills", ".agents/skills"] {
            let root = home.appendingPathComponent(relativeRoot).resolvingSymlinksInPath().standardizedFileURL
            // URL equality includes a trailing directory slash; path identity does not.
            guard visited.insert(root.path).inserted else { continue }
            let folder = root.appendingPathComponent("design-in-figma-pane")
            let file = folder.appendingPathComponent("SKILL.md")
            let agentHomes = relativeRoot == ".claude/skills" ? [".claude"] : [".agents", ".codex"]
            let hasAgentHome = agentHomes.contains { name in
                var isDirectory: ObjCBool = false
                return fileManager.fileExists(atPath: home.appendingPathComponent(name).path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
            guard hasAgentHome else { results.append(.kept(file)); continue }
            let folderAttributes = try? fileManager.attributesOfItem(atPath: folder.path)
            let fileAttributes = try? fileManager.attributesOfItem(atPath: file.path)
            let folderLink = folderAttributes?[.type] as? FileAttributeType == .typeSymbolicLink
            let fileLink = fileAttributes?[.type] as? FileAttributeType == .typeSymbolicLink
            // Do not even read a same-named symlink; root/ancestor links are allowed.
            let existing = folderLink || fileLink ? nil : try? String(contentsOf: file, encoding: .utf8)
            guard decision(folderExists: folderAttributes != nil, folderIsSymlink: folderLink, fileIsSymlink: fileLink, existingDocument: existing) == .write else {
                results.append(.kept(file))
                continue
            }
            guard let markdown else { results.append(.refused(file)); continue }
            let bytes = Data(markdown.utf8)
            if (try? Data(contentsOf: file)) == bytes {
                results.append(.kept(file))
                continue
            }
            do {
                try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
                guard fileManager.isWritableFile(atPath: root.path) else { results.append(.refused(file)); continue }
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                guard fileManager.isWritableFile(atPath: folder.path) else { results.append(.refused(file)); continue }
                try bytes.write(to: file, options: .atomic)
                results.append(.written(file))
            } catch {
                results.append(.refused(file))
            }
        }
        return results
    }

    static func installAtLaunch(home: URL, environment: [String: String], fileManager: FileManager = .default, bundle: Bundle = .main) -> [InstallResult] {
        guard environment["XCTestConfigurationFilePath"] == nil else { return [] }
        return install(home: home, fileManager: fileManager, bundle: bundle)
    }

    static func installAtLaunchInBackground(
        home: URL,
        environment: [String: String],
        onRefusal: @escaping @Sendable (URL) -> Void = { _ in },
        worker: @escaping @Sendable (URL, [String: String]) -> [InstallResult] = { home, environment in
            installAtLaunch(home: home, environment: environment)
        }
    ) -> Task<[InstallResult], Never> {
        Task.detached(priority: .utility) {
            let results = worker(home, environment)
            for result in results {
                if case .refused(let url) = result { onRefusal(url) }
            }
            return results
        }
    }

}
