import Foundation

struct CLIError: Error, CustomStringConvertible {
    enum SocketFailureKind: Equatable {
        case pathMissing
        case pathInspectionFailed
        case pathTypeConflict
        case pathOwnershipConflict
        case startupTimeout
    }

    let message: String
    let exitCode: Int32
    /// Structured v2 protocol error code when the failure came from a v2 error response.
    let v2Code: String?
    /// Whether this error was decoded directly from a socket v2 error response.
    /// Local CLI sentinels may reuse ``v2Code`` for their own exit-status contract.
    let isStructuredProtocolResponse: Bool
    /// Whether the v2 error's data marked the failure as retryable (for example a
    /// `busy` answer while the app's process scan settles), so callers can wait
    /// and retry structurally instead of parsing display text.
    let v2Retryable: Bool
    /// Cloud VM backend error code (e.g. "vm_create_failed") passed through the
    /// v2 error's data payload, so callers can make idempotency decisions
    /// structurally instead of parsing display text.
    let vmBackendCode: String?
    /// HTTP status from the Cloud VM backend, when the app forwarded an HTTP
    /// failure through the local v2 socket.
    let vmBackendHTTPStatus: Int?
    let socketFailureKind: SocketFailureKind?
    /// cmux-rbf (#cm-73.44): the `reason` the app put in a v2 error's data, so `fit` can tell a pane that shows
    /// no board from any other failure without reading display text.
    let v2Reason: String?

    init(
        message: String,
        exitCode: Int32 = 1,
        v2Code: String? = nil,
        isStructuredProtocolResponse: Bool = false,
        v2Retryable: Bool = false,
        vmBackendCode: String? = nil,
        vmBackendHTTPStatus: Int? = nil,
        socketFailureKind: SocketFailureKind? = nil,
        v2Reason: String? = nil
    ) {
        self.message = message
        self.exitCode = exitCode
        self.v2Code = v2Code
        self.isStructuredProtocolResponse = isStructuredProtocolResponse
        self.v2Retryable = v2Retryable
        self.vmBackendCode = vmBackendCode
        self.vmBackendHTTPStatus = vmBackendHTTPStatus
        self.socketFailureKind = socketFailureKind
        self.v2Reason = v2Reason
    }

    var description: String { message }
}
