import CmuxSettings
import Foundation

// cmux-rbf #cm-73.16: create through Figma's folder-scoped links.
struct FigmaNewFileLink {
    enum Kind: String, CaseIterable { case design, board, slides }

    static func address(kind: Kind, folder: String?) -> URL? {
        guard let folder, case .success(let checked) = FigmaFolderLink.check(folder) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.figma.com"
        components.path = "/\(kind.rawValue)/new"
        components.queryItems = [
            URLQueryItem(name: "folder_id", value: checked.projectId),
            URLQueryItem(name: "team_id", value: String(checked.planKey.dropFirst("team::".count)))
        ]
        return components.url
    }
}
