import Foundation

// cmux-rbf #cm-73.16: the durable record contains only Figma's link, view and name.
struct SessionFigmaFileSnapshot: Codable, Equatable, Sendable {
    var link: String
    var view: String
    var name: String
}
