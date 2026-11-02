/// Presentation for a semantic event, evaluated only after lifecycle reconciliation.
public struct AgentJournalNotification: Codable, Sendable, Equatable {
    /// Localized notification title.
    public var title: String
    /// Agent and optional session title before the notification kind is appended.
    public var sourceTitle: String?
    /// Localized notification subtitle.
    public var subtitle: String
    /// Notification body, supplied by the adapter.
    public var body: String
    /// Existing notification policy category wire value.
    public var category: String
    /// Optional producer handle for clearing this exact notification.
    public var correlationKey: String?

    /// Creates a candidate; this value alone never authorizes delivery.
    /// - Parameters:
    ///   - title: Localized title.
    ///   - subtitle: Localized subtitle.
    ///   - body: Presentation body.
    ///   - category: Existing notification preference category.
    ///   - correlationKey: Optional producer dismissal handle.
    ///   - sourceTitle: Optional agent/session title before appending a kind.
    public init(title: String, subtitle: String, body: String, category: String,
                correlationKey: String? = nil, sourceTitle: String? = nil) {
        self.title = title
        self.sourceTitle = sourceTitle
        self.subtitle = subtitle
        self.body = body
        self.category = category
        self.correlationKey = correlationKey
    }
}
