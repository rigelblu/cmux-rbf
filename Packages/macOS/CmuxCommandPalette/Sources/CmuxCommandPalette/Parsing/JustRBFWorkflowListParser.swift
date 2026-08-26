/// Parses the complete line protocol emitted by `just-rbf --list`.
public struct JustRBFWorkflowListParser: Sendable {
    /// A reason the complete workflow snapshot was rejected.
    public enum ParseError: Error, Sendable, Equatable {
        /// A non-empty stream did not end in a newline.
        case missingFinalNewline
        /// The stream contained an empty row.
        case blankRow
        /// A row contained more than one literal tab.
        case multipleDescriptionSeparators
        /// A workflow name was not canonical.
        case invalidName(String)
        /// A canonical name appeared more than once.
        case duplicateName(String)
    }

    /// Creates a workflow-list parser.
    public init() {}

    /// Parses one complete stdout snapshot.
    ///
    /// Empty stdout is a valid empty catalog. Every non-empty snapshot must end
    /// in `\n`; each row is a canonical name optionally followed by one literal
    /// tab and an opaque escaped description.
    public func parse(_ stdout: String) throws -> [JustRBFWorkflow] {
        guard !stdout.isEmpty else { return [] }
        guard stdout.last == "\n" else { throw ParseError.missingFinalNewline }

        let body = stdout.dropLast()
        let rows = body.split(separator: "\n", omittingEmptySubsequences: false)
        var names: Set<String> = []
        var workflows: [JustRBFWorkflow] = []
        workflows.reserveCapacity(rows.count)

        for row in rows {
            guard !row.isEmpty else { throw ParseError.blankRow }
            let fields = row.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count <= 2 else { throw ParseError.multipleDescriptionSeparators }

            let name = String(fields[0])
            guard Self.isCanonicalName(name) else { throw ParseError.invalidName(name) }
            guard names.insert(name).inserted else { throw ParseError.duplicateName(name) }

            workflows.append(
                JustRBFWorkflow(
                    name: name,
                    escapedDescription: fields.count == 2 ? String(fields[1]) : nil
                )
            )
        }
        return workflows
    }

    private static func isCanonicalName(_ name: String) -> Bool {
        let segments = name.split(separator: "-", omittingEmptySubsequences: false)
        guard !segments.isEmpty else { return false }
        return segments.allSatisfy { segment in
            !segment.isEmpty && segment.unicodeScalars.allSatisfy { scalar in
                (97...122).contains(scalar.value) || (48...57).contains(scalar.value)
            }
        }
    }
}
