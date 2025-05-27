import Foundation
import CGit2

/// Represents an error from an internal CGit2 API call.
public struct GitError: Error, CustomStringConvertible, LocalizedError, Sendable {
    /// The numeric error code from the Git API.
    public let code: Int32

    /// The name of the API that returned the error.
    public let apiName: String

    /// A human-readable error message.
    public let message: String

    /// Initializer. Must be called on the same thread as the API call that generated the error to properly get the error message.
    init(code: Int32, apiName: String, customMessage: String? = nil) {
        self.code = code
        self.apiName = apiName
        if let lastErrorPointer = git_error_last() {
            self.message =
                customMessage ?? String(validatingUTF8: lastErrorPointer.pointee.message)
                ?? "invalid message"
        } else if code == GIT_ERROR_OS.rawValue {
            self.message =
                customMessage ?? String(validatingUTF8: strerror(errno)) ?? "invalid message"
        } else {
            self.message = customMessage ?? "Unknown"
        }
    }

    public var description: String {
        "Error \(code) calling \(apiName): \(message)"
    }

    public var errorDescription: String? {
        description
    }
}
