import Foundation
import CGit2

/// A structure to report on fetching progress.
public struct FetchProgress: Equatable, Sendable {
    public let receivedObjects: Int
    public let indexedObjects: Int
    public let totalObjects: Int
    public let receivedBytes: Int

    public init(receivedObjects: Int, indexedObject: Int, totalObjects: Int, receivedBytes: Int) {
        self.receivedObjects = receivedObjects
        self.indexedObjects = indexedObject
        self.totalObjects = totalObjects
        self.receivedBytes = receivedBytes
    }

    init(_ indexerProgress: git_indexer_progress) {
        self.receivedObjects = Int(indexerProgress.received_objects)
        self.indexedObjects = Int(indexerProgress.indexed_objects)
        self.totalObjects = Int(indexerProgress.total_objects)
        self.receivedBytes = Int(indexerProgress.received_bytes)
    }
}

public enum FetchPruneOption: Sendable {
    case unspecified
    case prune
    case noPrune
}

final class FetchOptions: CustomStringConvertible {
    init(
        credentials: Credentials = .default,
        pruneOption: FetchPruneOption = .unspecified,
        progressCallback: Repository.FetchProgressBlock? = nil
    ) {
        self.credentials = credentials
        self.pruneOption = pruneOption
        self.progressCallback = progressCallback
    }

    var credentials: Credentials
    var pruneOption: FetchPruneOption
    var progressCallback: Repository.FetchProgressBlock?

    var description: String {
        "FetchOptions Credentials = \(credentials), progressCallback \(progressCallback != nil ? "is not nil" : "is nil")"
    }

    func toPointer() -> UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    static func fromPointer(_ pointer: UnsafeMutableRawPointer) -> FetchOptions {
        Unmanaged<FetchOptions>.fromOpaque(UnsafeRawPointer(pointer)).takeUnretainedValue()
    }

    func withOptions<T>(closure: (inout git_fetch_options) throws -> T) rethrows -> T {
        var options = git_fetch_options()
        git_fetch_options_init(&options, UInt32(GIT_FETCH_OPTIONS_VERSION))
        switch pruneOption {
        case .unspecified:
            options.prune = GIT_FETCH_PRUNE_UNSPECIFIED
        case .prune:
            options.prune = GIT_FETCH_PRUNE
        case .noPrune:
            options.prune = GIT_FETCH_NO_PRUNE
        }
        if progressCallback != nil {
            options.callbacks.transfer_progress = fetchProgress
        }
        options.callbacks.payload = toPointer()
        options.callbacks.credentials = credentialsCallback
        return try closure(&options)
    }
}

private func fetchProgress(
    progressPointer: UnsafePointer<git_indexer_progress>?, payload: UnsafeMutableRawPointer?
)
    -> Int32
{
    guard let payload = payload else {
        return 0
    }

    let fetchOptions = FetchOptions.fromPointer(payload)
    if let progress = progressPointer?.pointee {
        fetchOptions.progressCallback?(FetchProgress(progress))
    }
    return 0
}
