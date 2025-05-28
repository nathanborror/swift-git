import Foundation
import CGit2
import OSLog

private let logger = Logger(subsystem: "Repository", category: "Git")

extension git_merge_analysis_t: @retroactive OptionSet {}
extension git_merge_preference_t: @retroactive OptionSet {}

public protocol GitConflictResolver {
    /// Resolve a conflict in the repository.
    ///
    /// Resolving a conflict requires, at minimum, removing the conflict entries from `index`. For example, ``Index/removeConflictEntries(for:)`` will remove
    /// any conflicting entries.
    ///
    /// If the repository has a working directory, then there will be a _conflict file_ in the working directory that also needs to be cleaned up. Some strategies:
    ///
    /// - Explicitly write the resolved contents to that file in the working directory
    /// - Return `requiresCheckout`, which will tell ``Repository/merge(revspec:resolver:signature:)`` to update the working directory to match the contents of the Index. This is the strategy to use if you fixed the Index by just picking the `ours` or `theirs` conflicting entry.
    ///
    /// - Parameters:
    ///   - conflict: The conflicting index entries.
    ///   - index: The repository index.
    ///   - repository: The repository.
    /// - Returns: A tuple indicating if the conflict was resolved, and if so, whether we need to check out the Index to update the working directory.
    func resolveConflict(_ conflict: Index.ConflictEntry, index: Index, repository: Repository) throws -> (resolved: Bool, requiresCheckout: Bool)
}

/// A value that represents progress towards a goal.
public enum Progress<ProgressType: Sendable, ResultType: Sendable>: Sendable {
    /// Progress towards the goal, storing the progress value.
    case progress(ProgressType)

    /// The goal is completed, storing the resulting goal value.
    case completed(ResultType)
}

/// Representation of a git repository, including all its object contents.
///
/// - note: This class is not thread-safe. Do not use it from more than one thread at the same time.
public final class Repository {
    typealias FetchProgressBlock = (FetchProgress) -> Void
    typealias CloneProgressBlock = (Result<Double, Error>) -> Void

    private let repo: OpaquePointer

    /// If true, this class is the owner of `repo` and should free it on deinit.
    private let isOwner: Bool

    /// The working directory of the repository, or `nil` if this is a bare repository.
    public nonisolated let workingDirectoryURL: URL?

    /// Creates a Git repository at a location.
    /// - Parameters:
    ///   - url: The location to create a Git repository at.
    ///   - bare: Whether the repository should be "bare". A bare repository does not have a corresponding working directory.
    public convenience init(createAt url: URL, bare: Bool = false) throws {
        let repo = try ExecReturn("git_repository_init") { pointer in
            url.withUnsafeFileSystemRepresentation { fileSystemPath in
                "main".withCString { branchNamePointer in
                    var options = git_repository_init_options()
                    git_repository_init_options_init(
                        &options, UInt32(GIT_REPOSITORY_INIT_OPTIONS_VERSION))
                    options.initial_head = branchNamePointer
                    if bare {
                        options.flags = GIT_REPOSITORY_INIT_BARE.rawValue
                    }
                    options.flags |= GIT_REPOSITORY_INIT_MKDIR.rawValue
                    return git_repository_init_ext(&pointer, fileSystemPath, &options)
                }
            }
        }
        self.init(repo: repo, isOwner: true)
    }

    /// Opens a git repository at a specified location.
    /// - Parameter url: The location of the repository to open.
    public convenience init(openAt url: URL) throws {
        let repo = try ExecReturn("git_repository_open") { pointer in
            url.withUnsafeFileSystemRepresentation { fileSystemPath in
                git_repository_open(&pointer, fileSystemPath)
            }
        }
        self.init(repo: repo, isOwner: true)
    }

    init(repo: OpaquePointer, isOwner: Bool) {
        self.repo = repo
        self.isOwner = isOwner
        if let pathPointer = git_repository_workdir(repo),
            let path = String(validatingUTF8: pathPointer)
        {
            self.workingDirectoryURL = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            self.workingDirectoryURL = nil
        }
    }

    deinit {
        if isOwner {
            git_repository_free(repo)
        }
    }

    public static func clone(from remoteURL: URL, to localURL: URL, depth: Int = 0, credentials: Credentials = .default) async throws -> Repository {
        var repository: Repository?
        for try await progress in cloneProgress(from: remoteURL, to: localURL, depth: depth, credentials: credentials) {
            switch progress {
            case .completed(let repo):
                repository = repo
            case .progress:
                break
            }
        }
        return repository!
    }

    /// Clones a repository, reporting progress.
    /// - returns: An `AsyncThrowingStream` that returns intermediate ``FetchProgress`` while fetching and the final ``Repository`` upon completion.
    public static func cloneProgress(from remoteURL: URL, to localURL: URL, depth: Int = 0, credentials: Credentials = .default) -> AsyncThrowingStream<Progress<FetchProgress, Repository>, Error> {
        AsyncThrowingStream<Progress<FetchProgress, Repository>, Error> { continuation in
            let progressCallback: FetchProgressBlock = { progress in
                continuation.yield(.progress(progress))
            }
            let cloneOptions = CloneOptions(
                fetchOptions: FetchOptions(
                    credentials: credentials,
                    depth: depth,
                    progressCallback: progressCallback
                )
            )
            do {
                let repo = try cloneOptions.withOptions { options -> OpaquePointer in
                    var options = options
                    return try ExecReturn("git_clone") { pointer in
                        localURL.withUnsafeFileSystemRepresentation { filePath in
                            git_clone(&pointer, remoteURL.absoluteString, filePath, &options)
                        }
                    }
                }
                continuation.yield(
                    .completed(Repository(repo: repo, isOwner: true)))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    // MARK: - Remotes

    /// Adds a named remote to the repo.
    /// - Parameters:
    ///   - name: The name of the remote. (E.g., `origin`)
    ///   - url: The URL for the remote.
    public func addRemote(_ name: String, url: URL) throws {
        let remote = try ExecReturn("git_remote_create") { pointer in
            git_remote_create(&pointer, repo, name, url.absoluteString)
        }
        git_remote_free(remote)
    }

    /// Deletes the named remote from the repository.
    public func deleteRemote(_ name: String) throws {
        try Exec("git_remote_delete") {
            git_remote_delete(repo, name)
        }
    }

    /// Returns the URL associated with a particular git remote name.
    /// - Parameter remoteName: The name of the remote. (For example, `origin`)
    /// - Returns: If `remoteName` exists, the URL corresponding to the remote. Returns `nil` if `remoteName` does not exist.
    /// - throws: ``GitError`` on any other error.
    public func remoteURL(for remoteName: String) throws -> URL? {
        do {
            let remotePointer = try ExecReturn("git_remote_lookup") { pointer in
                git_remote_lookup(&pointer, repo, remoteName)
            }
            defer {
                git_remote_free(remotePointer)
            }
            if let remoteString = git_remote_url(remotePointer) {
                return URL(string: String(cString: remoteString))
            } else {
                return nil
            }
        } catch let gitError as GitError {
            if gitError.code == GIT_ENOTFOUND.rawValue {
                return nil
            } else {
                throw gitError
            }
        }
    }

    // MARK: - Branches

    /// Creates a branch targeting a specific commit.
    /// - Parameters:
    ///   - name: The name of the branch to create.
    ///   - commitOID: The ``ObjectID`` of the commit to target.
    ///   - force: If true, force create the branch. If false, this operation will fail if a branch named `name` already exists.
    public func createBranch(named name: String, commitOID: ObjectID, force: Bool = false) throws {
        var oid = commitOID.oid
        let commitPointer = try ExecReturn("git_commit_lookup") { pointer in
            git_commit_lookup(&pointer, repo, &oid)
        }
        defer {
            git_object_free(commitPointer)
        }
        let branchPointer = try ExecReturn("git_branch_create") { pointer in
            git_branch_create(&pointer, repo, name, commitPointer, force ? 1 : 0)
        }
        git_reference_free(branchPointer)
    }

    /// Creates a branch targeting a named reference.
    /// - Parameters:
    ///   - name: The name of the branch to create.
    ///   - target: The name of the reference to target.
    ///   - force: If true, force create the branch. If false, this operation will fail if a branch named `name` already exists.
    ///   - setTargetAsUpstream: If true, set `target` as the upstream branch of the newly created branch.
    public func createBranch(named name: String, target: String, force: Bool = false, setTargetAsUpstream: Bool = false) throws {
        let referencePointer = try ExecReturn("git_reference_dwim") { pointer in
            git_reference_dwim(&pointer, repo, target)
        }
        defer {
            git_reference_free(referencePointer)
        }
        let commitPointer = try ExecReturn("git_reference_peel") { pointer in
            git_reference_peel(&pointer, referencePointer, GIT_OBJECT_COMMIT)
        }
        defer {
            git_object_free(commitPointer)
        }
        let branchPointer = try ExecReturn("git_branch_create") { pointer in
            git_branch_create(&pointer, repo, name, commitPointer, force ? 1 : 0)
        }
        defer {
            git_reference_free(branchPointer)
        }
        if setTargetAsUpstream {
            try Exec("git_branch_set_upstream") {
                git_branch_set_upstream(branchPointer, target)
            }
        }
    }

    @discardableResult
    /// Deletes the branch named `name`.
    ///
    /// - note: Unlike the `git branch --delete` command, this method does not check to see if the branch has been merged before deleting; it just deletes.
    ///
    /// - Parameter name: The name of the branch to delete.
    /// - returns The ``ObjectID`` of the commit that the branch pointed to, or nil if no branch named `name` was found.
    /// - throws ``GitError`` on any other error.
    public func deleteBranch(named name: String) throws -> ObjectID? {
        do {
            let branchPointer = try ExecReturn("git_branch_lookup") { pointer in
                git_branch_lookup(&pointer, repo, name, BranchType.all.gitType)
            }
            defer {
                git_reference_free(branchPointer)
            }
            let commitPointer = try ExecReturn("git_reference_peel") { pointer in
                git_reference_peel(&pointer, branchPointer, GIT_OBJECT_COMMIT)
            }
            defer {
                git_object_free(commitPointer)
            }
            let oid = git_commit_id(commitPointer)
            try Exec("git_branch_delete") {
                git_branch_delete(branchPointer)
            }
            return ObjectID(oid)
        } catch let error as GitError {
            if error.code == GIT_ENOTFOUND.rawValue {
                return nil
            } else {
                throw error
            }
        }
    }

    /// Gets all branch names of a specific branch type.
    /// - Parameter type: The type of branch to query for.
    /// - Returns: The current branch names in the repository.
    public func branches(type: BranchType) throws -> [String] {
        let branchIterator = try ExecReturn("git_branch_iterator_new") { pointer in
            git_branch_iterator_new(&pointer, repo, type.gitType)
        }
        defer {
            git_branch_iterator_free(branchIterator)
        }
        var referencePointer: OpaquePointer?
        var type = GIT_BRANCH_ALL
        var result = git_branch_next(&referencePointer, &type, branchIterator)
        var branches: [String] = []
        while result == GIT_OK.rawValue {
            let branchName = String(cString: git_reference_name(referencePointer))
            branches.append(branchName)
            result = git_branch_next(&referencePointer, &type, branchIterator)
        }
        if result == GIT_ITEROVER.rawValue {
            return branches
        } else {
            throw GitError(code: result, apiName: "git_branch_next")
        }
    }

    /// Returns the remote name for a remote tracking branch.
    /// - Parameter branchName: The full branch name
    /// - Returns: The remote name
    public func remoteName(branchName: String) throws -> String {
        var buffer = git_buf()
        try Exec("git_branch_remote_name") {
            git_branch_remote_name(&buffer, repo, branchName)
        }
        return String(cString: buffer.ptr)
    }

    /// Tests if a branch exists in the repository.
    /// - Parameter name: The name of the branch.
    /// - Returns: True if the branch exists, false otherwise.
    public func branchExists(named name: String) throws -> Bool {
        do {
            let branchPointer = try ExecReturn("git_branch_lookup") { pointer in
                git_branch_lookup(&pointer, repo, name, GIT_BRANCH_LOCAL)
            }
            git_reference_free(branchPointer)
            return true
        } catch let error as GitError {
            if error.code == GIT_ENOTFOUND.rawValue {
                return false
            } else {
                throw error
            }
        }
    }

    /// Get the upstream name of a branch.
    ///
    /// Given a local branch, this will return its remote-tracking branch information, as a full reference name, ie. “feature/nice” would become “refs/remote/origin/feature/nice”, depending on that branch’s configuration.
    /// - Parameter branchName: The name of the branch to query.
    /// - Returns: The upstream name of the branch, if it exists.
    /// - throws ``GitError`` if there is no upstream branch.
    public func upstreamName(of branchName: String) throws -> String {
        var buffer = git_buf()
        try Exec("git_branch_upstream_name") {
            git_branch_upstream_name(&buffer, repo, branchName)
        }
        defer {
            git_buf_dispose(&buffer)
        }
        return String(cString: buffer.ptr)
    }

    // MARK: - References

    /// Lookup a reference by name in a repository.
    ///
    /// - Parameter name: The name of the reference. This needs to be the _full name_ of the reference (e.g., `refs/heads/main` instead of `main`).
    /// - Returns: The corresponding ``Reference`` if it exists, or `nil` if a reference named `name` is not found in the repository.
    public func lookupReference(name: String) throws -> Reference? {
        do {
            let referencePointer = try ExecReturn("git_reference_lookup") { pointer in
                git_reference_lookup(&pointer, repo, name)
            }
            return Reference(pointer: referencePointer)
        } catch let error as GitError {
            if error.code == GIT_ENOTFOUND.rawValue {
                return nil
            }
            throw error
        }
    }

    /// Lookup a reference by name and resolve immediately to an ``ObjectID``.
    /// - Parameter referenceLongName: The long name for the reference (e.g. HEAD, refs/heads/master, refs/tags/v0.1.0, ...)
    /// - Returns: The object ID for the reference.
    public func lookupReferenceID(referenceLongName: String) throws -> ObjectID? {
        do {
            return try ExecReturnID("git_reference_name_to_id") { oid in
                git_reference_name_to_id(&oid, repo, referenceLongName)
            }
        } catch let error as GitError {
            if error.code == GIT_ENOTFOUND.rawValue {
                return nil
            }
            throw error
        }
    }

    // MARK: - Managing Data

    /// Loads the data associated with an object ID.
    /// - Parameter objectID: The object ID to load.
    /// - Returns: The data associated with the object ID.
    public func data(for objectID: ObjectID) throws -> Data {
        let blobPointer = try ExecReturn("git_blob_lookup") { pointer in
            var oid = objectID.oid
            return git_blob_lookup(&pointer, repo, &oid)
        }
        defer {
            git_blob_free(blobPointer)
        }
        let size = git_blob_rawsize(blobPointer)
        let data = Data(bytes: git_blob_rawcontent(blobPointer), count: Int(size))
        return data
    }

    /// Adds data to the repository and creates an index entry for it.
    /// - parameter data: The data to add.
    /// - parameter path: The path for the index entry.
    public func addData(_ data: Data, path: String) throws {
        try path.withCString { pathPointer in
            var indexEntry = git_index_entry()
            indexEntry.path = pathPointer
            let now = Date()
            let indexTime = git_index_time(
                seconds: Int32(now.timeIntervalSince1970), nanoseconds: 0)
            indexEntry.ctime = indexTime
            indexEntry.mtime = indexTime
            indexEntry.mode = 0o100644
            let indexPointer = try ExecReturn("git_repository_index") { pointer in
                git_repository_index(&pointer, repo)
            }
            defer {
                git_index_free(indexPointer)
            }
            try data.withUnsafeBytes { bufferPointer in
                try Exec("git_index_add_from_buffer") {
                    git_index_add_from_buffer(
                        indexPointer, &indexEntry, bufferPointer.baseAddress, data.count)
                }
            }
        }
    }

    /// A stream that emits ``FetchProgress`` structs during a fetch and concludes with the name of the default branch of the remote when the fetch is complete.
    public typealias FetchProgressStream = AsyncThrowingStream<Progress<FetchProgress, String?>, Error>

    /// Fetch from a named remote.
    /// - Parameters:
    ///   - remote: The remote to fetch
    ///   - credentials: Credentials to use for the fetch.
    /// - returns: An AsyncThrowingStream that emits the fetch progress. The fetch is not done until this stream finishes yielding values.
    public func fetchProgress(remote: String, pruneOption: FetchPruneOption = .unspecified, depth: Int = 0, credentials: Credentials = .default) -> FetchProgressStream {
        let fetchOptions = FetchOptions(
            credentials: credentials,
            pruneOption: pruneOption,
            depth: depth,
            progressCallback: nil
        )
        let resultStream = FetchProgressStream { continuation in
            Task {
                fetchOptions.progressCallback = { progressResult in
                    continuation.yield(.progress(progressResult))
                }
                do {
                    let remotePointer = try ExecReturn("git_remote_lookup") { pointer in
                        git_remote_lookup(&pointer, repo, remote)
                    }
                    defer {
                        git_remote_free(remotePointer)
                    }
                    if let remoteURL = git_remote_url(remotePointer) {
                        let remoteURLString = String(cString: remoteURL)
                        print("Fetching from \(remoteURLString)")
                    }
                    try Exec("git_remote_fetch") {
                        fetchOptions.withOptions { options in
                            git_remote_fetch(remotePointer, nil, &options, "fetch")
                        }
                    }
                    do {
                        var buffer = git_buf()
                        try Exec("git_remote_default_branch") {
                            git_remote_default_branch(&buffer, remotePointer)
                        }
                        defer {
                            git_buf_free(&buffer)
                        }
                        let defaultBranch = String(cString: buffer.ptr)
                        continuation.yield(.completed(defaultBranch))
                    } catch let error as GitError {
                        if error.code == GIT_ENOTFOUND.rawValue {
                            continuation.yield(.completed(nil))
                        } else {
                            throw error
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
        return resultStream
    }

    /// Creates an `AsyncThrowingStream` that reports on the progress of checking out a reference.
    /// - Parameters:
    ///   - referenceShorthand: The reference to checkout. This can be a shorthand name (e.g., `main`) and git will resolve it using precedence rules to a full reference (`refs/heads/main`).
    ///   - checkoutStrategy: The checkout strategy.
    /// - Returns: An `AsyncThrowingStream` that emits ``CheckoutProgress`` structs reporting on the progress of checkout. Checkout is complete when the stream terminates.
    public func checkoutProgress(referenceShorthand: String, checkoutStrategy: git_checkout_strategy_t = GIT_CHECKOUT_SAFE) -> AsyncThrowingStream<CheckoutProgress, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try checkNormalState()
                    let referencePointer = try ExecReturn("git_reference_dwim") { pointer in
                        git_reference_dwim(&pointer, repo, referenceShorthand)
                    }
                    defer {
                        git_reference_free(referencePointer)
                    }
                    let referenceName = String(cString: git_reference_name(referencePointer))
                    print("Checking out \(referenceName)")
                    let annotatedCommit = try ExecReturn("git_annotated_commit_from_ref") { pointer in
                        git_annotated_commit_from_ref(
                            &pointer, repo, referencePointer)
                    }
                    defer {
                        git_annotated_commit_free(annotatedCommit)
                    }
                    let commitPointer = try ExecReturn("git_commit_lookup") { pointer in
                        git_commit_lookup(
                            &pointer, repo,
                            git_annotated_commit_id(annotatedCommit))
                    }
                    defer {
                        git_commit_free(commitPointer)
                    }
                    let checkoutOptions = CheckoutOptions(checkoutStrategy: checkoutStrategy) {
                        progress in
                        continuation.yield(progress)
                    }
                    try checkoutOptions.withOptions { options in
                        try Exec("git_checkout_tree") {
                            git_checkout_tree(repo, commitPointer, &options)
                        }
                    }

                    let targetRefname = git_reference_name(referencePointer)
                    print("Initial targetRefname: \(targetRefname != nil ? String(cString: targetRefname!) : "nil")")

                    if git_reference_is_remote(referencePointer) != 0 {
                        print("Reference is remote, setting detached HEAD")

                        try Exec("git_repository_set_head_detached_from_annotated") {
                           git_repository_set_head_detached_from_annotated(repo, annotatedCommit)
                       }
                    } else {
                        print("Setting HEAD to: \(String(cString: targetRefname!))")
                        try Exec("git_repository_set_head") {
                            git_repository_set_head(repo, targetRefname)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// The current set of ``StatusEntry`` structs that represent the current status of all items in the repository.
    public var statusEntries: [StatusEntry] {
        get throws {
            var options = git_status_options()
            git_status_options_init(&options, UInt32(GIT_STATUS_OPTIONS_VERSION))
            let statusList = try ExecReturn("git_status_list_new") { pointer in
                git_status_list_new(&pointer, repo, &options)
            }
            defer {
                git_status_list_free(statusList)
            }
            let entryCount = git_status_list_entrycount(statusList)
            let entries = (0..<entryCount).compactMap { index -> StatusEntry? in
                let statusPointer = git_status_byindex(statusList, index)
                guard let status = statusPointer?.pointee else {
                    return nil
                }
                return StatusEntry(status)
            }
            return entries
        }
    }

    /// Possible results from a merge operation.
    public enum MergeResult: Equatable {
        /// We fast-forwarded the current branch to a new commit.
        case fastForward(ObjectID)
        /// We created a merge commit in the current branch.
        case merge(ObjectID)
        /// No action was taken -- the current branch already has all changes from the target branch.
        case none

        public var isFastForward: Bool {
            switch self {
            case .fastForward: return true
            case .merge, .none: return false
            }
        }

        public var isMerge: Bool {
            switch self {
            case .merge: return true
            case .fastForward, .none: return false
            }
        }
    }

    /// Merge a revision into the current branch.
    /// - Parameters:
    ///   - revisionSpecification: The revision to merge. See `man gitrevisions` for details on the syntax.
    ///   - resolver: A ``GitConflictResolver`` to resolve any merge conflicts.
    ///   - signatureBlock: A block that returns a ``Signature`` for the resulting merge commit.
    /// - Returns: A ``MergeResult`` describing the outcome of the merge.
    /// - throws ``GitError`` if the merge could not complete without conflicts.
    public func merge(revisionSpecification: String, resolver: GitConflictResolver? = nil, signature signatureBlock: @autoclosure () throws -> Signature) throws -> MergeResult {
        try checkNormalState()

        let annotatedCommit = try ExecReturn("git_annotated_commit_from_revspec") { pointer in
            git_annotated_commit_from_revspec(
                &pointer, repo, revisionSpecification)
        }
        defer {
            git_annotated_commit_free(annotatedCommit)
        }

        var analysis = GIT_MERGE_ANALYSIS_NONE
        var mergePreference = GIT_MERGE_PREFERENCE_NONE
        var theirHeads: [OpaquePointer?] = [annotatedCommit]
        try Exec("git_merge_analysis") {
            git_merge_analysis(
                &analysis, &mergePreference, repo, &theirHeads, theirHeads.count)
        }
        if analysis.contains(GIT_MERGE_ANALYSIS_FASTFORWARD), let oid = ObjectID(git_annotated_commit_id(annotatedCommit)) {
            // Fast forward
            try fastForward(to: oid, isUnborn: analysis.contains(GIT_MERGE_ANALYSIS_UNBORN))
            return .fastForward(oid)

        } else if analysis.contains(GIT_MERGE_ANALYSIS_NORMAL) {
            // Normal merge
            guard !mergePreference.contains(GIT_MERGE_PREFERENCE_FASTFORWARD_ONLY) else {
                throw GitError(
                    code: Int32(GIT_ERROR_INTERNAL.rawValue),
                    apiName: "git_merge",
                    customMessage: "Fast-forward is preferred, but only a merge is possible"
                )
            }
            let mergeOptions = MergeOptions(
                checkoutOptions: CheckoutOptions(checkoutStrategy: [
                    GIT_CHECKOUT_FORCE, GIT_CHECKOUT_ALLOW_CONFLICTS,
                ]),
                mergeFlags: [],
                fileFlags: GIT_MERGE_FILE_STYLE_DIFF3
            )
            try mergeOptions.withOptions { merge_options, checkout_options in
                try Exec("git_merge") {
                    git_merge(
                        repo, &theirHeads, theirHeads.count, &merge_options,
                        &checkout_options)
                }
            }
            try checkForConflicts(resolver: resolver)
            let signature = try signatureBlock()
            let mergeCommitOID = try commitMerge(
                revspec: revisionSpecification,
                annotatedCommit: annotatedCommit,
                signature: signature
            )
            return .merge(mergeCommitOID)
        }
        return .none
    }

    /// Gets the `ObjectID` associated with `revspec`.
    /// - returns: `nil` if `revspec` doesn't exist
    /// - throws on other git errors.
    private func commitObjectID(revspec: String) throws -> ObjectID? {
        do {
            let commitPointer = try ExecReturn("git_revparse_single") { pointer in
                git_revparse_single(&pointer, repo, revspec)
            }
            defer {
                git_object_free(commitPointer)
            }
            // Assume our object is a commit
            return ObjectID(git_commit_id(commitPointer))
        } catch let error as GitError {
            if error.code == GIT_ENOTFOUND.rawValue {
                return nil
            } else {
                throw error
            }
        }
    }

    public func countCommits(revspec: String) throws -> Int {
        var count = 0
        try enumerateCommits(referenceShorthand: revspec) { _ in
            count += 1
            return true
        }
        return count
    }

    public func commitsAheadBehind(other revspec: String) throws -> (ahead: Int, behind: Int) {
        let headObjectID = try commitObjectID(revspec: "HEAD")
        let otherObjectID = try commitObjectID(revspec: revspec)

        switch (headObjectID, otherObjectID) {
        case (.none, .none):
            return (ahead: 0, behind: 0)
        case (.some, .none):
            return (ahead: try countCommits(revspec: "HEAD"), behind: 0)
        case (.none, .some):
            return (ahead: 0, behind: try countCommits(revspec: revspec))
        case (.some(var headOID), .some(var otherOID)):
            var ahead = 0
            var behind = 0
            try Exec("git_graph_ahead_behind") {
                git_graph_ahead_behind(
                    &ahead, &behind, repo, &headOID.oid, &otherOID.oid)
            }
            return (ahead: ahead, behind: behind)
        }
    }

    public func commitsAheadBehind(sourceReference: Reference?, targetReference: Reference?) throws -> (ahead: Int, behind: Int) {
        let sourceObjectID = try sourceReference?.commit.objectID
        let targetObjectID = try targetReference?.commit.objectID

        switch (sourceObjectID, targetObjectID) {
        case (.none, .none):
            return (ahead: 0, behind: 0)
        case (.some, .none):
            let commits =
                try sourceReference?.name.flatMap { revspec in
                    try countCommits(revspec: revspec)
                } ?? 0
            return (ahead: commits, behind: 0)
        case (.none, .some):
            let commits =
                try targetReference?.name.flatMap { revspec in
                    try countCommits(revspec: revspec)
                } ?? 0
            return (ahead: 0, behind: commits)
        case (.some(var headOID), .some(var otherOID)):
            var ahead = 0
            var behind = 0
            try Exec("git_graph_ahead_behind") {
                git_graph_ahead_behind(
                    &ahead, &behind, repo, &headOID.oid, &otherOID.oid)
            }
            return (ahead: ahead, behind: behind)
        }
    }

    private func commitMerge(revspec: String, annotatedCommit: OpaquePointer, signature: Signature) throws -> ObjectID {
        let indexPointer = try ExecReturn("git_repository_index") { pointer in
            git_repository_index(&pointer, repo)
        }
        defer {
            git_index_free(indexPointer)
        }
        guard let headReference = try head else {
            // TODO: Support merging into an unborn branch
            throw GitError(code: -9, apiName: "git_repository_head")
        }
        let headCommit = try ExecReturn("git_reference_peel") { pointer in
            git_reference_peel(&pointer, headReference.referencePointer, GIT_OBJECT_COMMIT)
        }
        defer {
            git_object_free(headCommit)
        }
        let annotatedCommitObjectPointer = try ExecReturn("git_commit_lookup") { pointer in
            var oid = git_annotated_commit_id(annotatedCommit)!.pointee
            return git_commit_lookup(&pointer, repo, &oid)
        }
        defer {
            git_object_free(annotatedCommitObjectPointer)
        }

        let treeOid = try ExecReturnID("git_index_write_tree") { pointer in
            git_index_write_tree(&pointer, indexPointer)
        }
        let treePointer = try ExecReturn("git_tree_lookup") { pointer in
            var oid = treeOid.oid
            return git_tree_lookup(&pointer, repo, &oid)
        }
        defer {
            git_tree_free(treePointer)
        }

        var parents: [OpaquePointer?] = [headCommit, annotatedCommitObjectPointer]
        let mergeCommitOID = try ExecReturnID("git_commit_create") { pointer in
            git_commit_create(
                &pointer,
                repo,
                git_reference_name(headReference.referencePointer),
                signature.signature,
                signature.signature,
                nil,
                "Merge \(revspec)",
                treePointer,
                parents.count,
                &parents
            )
        }

        try cleanup()

        return mergeCommitOID
    }

    /// Throws an error if the repository is in a non-normal state (e.g., in the middle of a cherry pick or a merge)
    public func checkNormalState() throws {
        try Exec("git_repository_state") {
            git_repository_state(repo)
        }
    }

    /// The current repository state.
    public var repositoryState: git_repository_state_t {
        let code = git_repository_state(repo)
        return git_repository_state_t(UInt32(code))
    }

    /// Cleans up the repository if it's in a non-normal state.
    public func cleanup() throws {
        try Exec("git_repository_state_cleanup") {
            git_repository_state_cleanup(repo)
        }
    }

    public enum ResetType {
        case soft
        case mixed
        case hard

        var reset_type: git_reset_t {
            switch self {
            case .soft:
                return GIT_RESET_SOFT
            case .mixed:
                return GIT_RESET_MIXED
            case .hard:
                return GIT_RESET_HARD
            }
        }
    }

    public func reset(revspec: String, type: ResetType) throws {
        let commitPointer = try ExecReturn("git_revparse_single") { pointer in
            git_revparse_single(&pointer, repo, revspec)
        }
        defer {
            git_object_free(commitPointer)
        }
        try Exec("git_reset") {
            git_reset(repo, commitPointer, type.reset_type, nil)
        }
    }

    public func reset(commitOID: ObjectID, type: ResetType) throws {
        var oid = commitOID.oid
        let commitPointer = try ExecReturn("git_commit_lookup") { pointer in
            git_commit_lookup(&pointer, repo, &oid)
        }
        defer {
            git_object_free(commitPointer)
        }
        try Exec("git_reset") {
            git_reset(repo, commitPointer, type.reset_type, nil)
        }
    }

    /// The index file for this repository.
    public var index: Index {
        get throws {
            let indexPointer = try ExecReturn("git_repository_index") { pointer in
                git_repository_index(&pointer, repo)
            }
            return Index(indexPointer)
        }
    }

    /// Throws ``ConflictError`` if there are conflicts in the current repository.
    public func checkForConflicts(resolver: GitConflictResolver?) throws {
        let index = try index // See if there were conflicts

        if !index.hasConflicts {
            return // No conflicts
        }

        // Try to resolve any conflicts
        var requiresCheckout = false
        for conflict in index.conflicts {
            if let result = try resolver?.resolveConflict(conflict, index: index, repository: self)
            {
                requiresCheckout = result.requiresCheckout || requiresCheckout
            }
        }

        // Make sure conflict resolution succeeded.

        let conflictingPaths = index.conflicts.map(\.path)
        if !conflictingPaths.isEmpty {
            throw ConflictError(conflictingPaths: conflictingPaths)
        }

        if requiresCheckout {
            // The resolver modified the index without modifying the working directory.
            // Do a checkout to make sure the working directory is up-to-date.
            let forceOptions = CheckoutOptions(checkoutStrategy: GIT_CHECKOUT_FORCE)
            try forceOptions.withOptions { options in
                try Exec("git_checkout_index") {
                    git_checkout_index(repo, index.indexPointer, &options)
                }
            }
        }
    }

    private func enumerateConflicts(in indexPointer: OpaquePointer, _ block: (_ ancestor: git_index_entry?, _ ours: git_index_entry?, _ theirs: git_index_entry?) throws -> Void) throws {
        let iteratorPointer = try ExecReturn("git_index_conflict_iterator_new") { pointer in
            git_index_conflict_iterator_new(&pointer, indexPointer)
        }
        defer {
            git_index_conflict_iterator_free(iteratorPointer)
        }

        var ancestor: UnsafePointer<git_index_entry>?
        var ours: UnsafePointer<git_index_entry>?
        var theirs: UnsafePointer<git_index_entry>?

        while git_index_conflict_next(&ancestor, &ours, &theirs, iteratorPointer) == 0 {
            try block(ancestor?.pointee, ours?.pointee, theirs?.pointee)
        }
    }

    private func fastForward(to objectID: ObjectID, isUnborn: Bool) throws {
        let headReference = isUnborn ? try createSymbolicReference(named: "HEAD", targeting: objectID) : try head!
        let targetPointer = try ExecReturn("git_object_lookup") { pointer in
            var oid = objectID.oid
            return git_object_lookup(&pointer, repo, &oid, GIT_OBJECT_COMMIT)
        }
        defer {
            git_object_free(targetPointer)
        }
        try Exec("git_checkout_tree") {
            let checkoutOptions = CheckoutOptions(checkoutStrategy: GIT_CHECKOUT_SAFE)
            return checkoutOptions.withOptions { options in
                git_checkout_tree(repo, targetPointer, &options)
            }
        }
        let newTarget = try ExecReturn("git_reference_set_target") { pointer in
            var oid = objectID.oid
            return git_reference_set_target(&pointer, headReference.referencePointer, &oid, nil)
        }
        git_reference_free(newTarget)
    }

    private func createSymbolicReference(named name: String, targeting objectID: ObjectID) throws -> Reference {
        let symbolicPointer = try ExecReturn("git_reference_lookup") { pointer in
            git_reference_lookup(&pointer, repo, name)
        }
        defer {
            git_reference_free(symbolicPointer)
        }
        let target = git_reference_symbolic_target(symbolicPointer)
        let targetReference = try ExecReturn("git_reference_create") { pointer in
            var oid = objectID.oid
            return git_reference_create(&pointer, repo, target, &oid, 0, nil)
        }
        return Reference(pointer: targetReference)
    }

    /// Returns the reference that HEAD points to, or `nil` if HEAD points to an unborn branch.
    public var head: Reference? {
        get throws {
            do {
                let reference = try ExecReturn("git_repository_head") { pointer in
                    git_repository_head(&pointer, repo)
                }
                return Reference(pointer: reference)
            } catch let error as GitError {
                if error.code == GIT_EUNBORNBRANCH.rawValue {
                    return nil
                }
                throw error
            }
        }
    }

    public func setHead(referenceName: String) throws {
        try Exec("git_repository_set_head") {
            git_repository_set_head(repo, referenceName)
        }
    }

    /// The ``ObjectID`` for the current value of HEAD.
    public var headObjectID: ObjectID? {
        get throws {
            try commitObjectID(revspec: "HEAD")
        }
    }

    /// Returns the `Tree` associated with the `HEAD` commit.
    public var headTree: Tree {
        get throws {
            let treePointer = try ExecReturn("git_revparse_single") { pointer in
                git_revparse_single(&pointer, repo, "HEAD^{tree}")
            }
            return Tree(treePointer)
        }
    }

    /// Returns a `Tree` associated with a specific `Entry`.
    public func lookupTree(for entry: Tree.Entry) throws -> Tree {
        try lookupTree(for: entry.objectID)
    }

    public func lookupTree(for objectID: ObjectID) throws -> Tree {
        let treePointer = try ExecReturn("git_tree_lookup") { pointer in
            var oid = objectID.oid
            return git_tree_lookup(&pointer, repo, &oid)
        }
        return Tree(treePointer)
    }

    public func lookupTree(for refspec: String) throws -> Tree {
        let reference = try ExecReturn("git_reference_dwim") { pointer in
            git_reference_dwim(&pointer, repo, refspec)
        }
        defer {
            git_reference_free(reference)
        }
        let treePointer = try ExecReturn("git_reference_peel") { pointer in
            git_reference_peel(&pointer, reference, GIT_OBJECT_TREE)
        }
        return Tree(treePointer)
    }

    public enum TreeWalkResult: Int32 {
        case skipSubtree = 1
        case `continue` = 0
        case done = -1
    }

    public typealias TreeWalkCallback = (Tree.Entry) -> TreeWalkResult

    public func treeWalk(tree: Tree, traversalMode: git_treewalk_mode = GIT_TREEWALK_PRE, callback: @escaping TreeWalkCallback) throws {
        var callback = callback
        try withUnsafeMutablePointer(to: &callback) { callbackPointer in
            try Exec("git_tree_walk") {
                git_tree_walk(
                    tree.tree, traversalMode, treeWalkCallback, callbackPointer)
            }
        }
    }

    public func treeWalk(tree: Tree? = nil, traversalMode: git_treewalk_mode = GIT_TREEWALK_PRE) -> AsyncThrowingStream<Tree.Entry, Error> {
        AsyncThrowingStream { continuation in
            do {
                let originTree = try (tree ?? (try headTree))
                try treeWalk(
                    tree: originTree,
                    traversalMode: traversalMode,
                    callback: { qualifiedEntry in
                        continuation.yield(qualifiedEntry)
                        return .continue
                    }
                )
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    public func lookupCommit(for id: ObjectID) throws -> Commit {
        var objectID = id.oid
        let commitPointer = try ExecReturn("git_commit_lookup") { pointer in
            git_commit_lookup(&pointer, repo, &objectID)
        }
        return Commit(commitPointer)
    }

    public func add(_ pathspec: String = "*") throws {
        let indexPointer = try ExecReturn("git_repository_index") { pointer in
            git_repository_index(&pointer, repo)
        }
        defer {
            git_index_free(indexPointer)
        }
        var dirPointer = UnsafeMutablePointer<Int8>(mutating: (pathspec as NSString).utf8String)
        var paths = withUnsafeMutablePointer(to: &dirPointer) {
            git_strarray(strings: $0, count: 1)
        }

        try Exec("git_index_add_all") {
            git_index_add_all(indexPointer, &paths, 0, nil, nil)
        }
        try Exec("git_index_write") {
            git_index_write(indexPointer)
        }
    }

    @discardableResult
    public func commit(message: String, signature: Signature) throws -> ObjectID {
        let indexPointer = try ExecReturn("git_repository_index") { pointer in
            git_repository_index(&pointer, repo)
        }
        defer {
            git_index_free(indexPointer)
        }

        var parentCommitPointer: OpaquePointer?
        var referencePointer: OpaquePointer?
        try Exec("git_revparse_ext") {
            let result = git_revparse_ext(
                &parentCommitPointer, &referencePointer, repo, "HEAD")
            // Remap "ENOTFOUND" to "OK" because things work just fine if there is no HEAD commit; it means we're making
            // the first commit in the repo.
            if result == GIT_ENOTFOUND.rawValue {
                return GIT_OK.rawValue
            }
            return result
        }
        if referencePointer != nil {
            git_reference_free(referencePointer)
        }
        defer {
            if parentCommitPointer != nil {
                git_commit_free(parentCommitPointer)
            }
        }

        // Take the contents of the index & write it to the object database as a tree.
        let treeOID = try ExecReturnID("git_index_write_tree") { oid in
            git_index_write_tree(&oid, indexPointer)
        }
        let tree = try lookupTree(for: treeOID)

        return try ExecReturnID("git_commit_create") { commitOID in
            git_commit_create(
                &commitOID,
                repo,
                "HEAD",
                signature.signature,
                signature.signature,
                nil,
                message,
                tree.tree,
                parentCommitPointer != nil ? 1 : 0,
                &parentCommitPointer
            )
        }
    }

    /// Pushes refspecs to a remote, returning an `AsyncThrowingStream` that you can use to track progress.
    /// - Parameters:
    ///   - remoteName: The remote to push to.
    ///   - refspecs: The references to push.
    ///   - credentials: The credentials to use for connect to the remote.
    /// - Returns: An `AsyncThrowingStream` that emits ``PushProgress`` structs for tracking progress.
    public func pushProgress(remoteName: String, refspecs: [String], credentials: Credentials = .default) -> AsyncThrowingStream<PushProgress, Error> {
        let pushOptions = PushOptions(credentials: credentials)
        let stream = AsyncThrowingStream<PushProgress, Error> { continuation in
            pushOptions.progressCallback = { progress in
                continuation.yield(progress)
            }
            do {
                let remotePointer = try ExecReturn("git_remote_lookup") { pointer in
                    git_remote_lookup(&pointer, repo, remoteName)
                }
                defer {
                    git_remote_free(remotePointer)
                }
                var refspecPointers = refspecs.map { pushRefspec in
                    let dirPointer = UnsafeMutablePointer<Int8>(
                        mutating: (pushRefspec as NSString).utf8String)
                    return dirPointer
                }
                let pointerCount = refspecPointers.count
                try refspecPointers.withUnsafeMutableBufferPointer { foo in
                    var paths = git_strarray(strings: foo.baseAddress, count: pointerCount)
                    try Exec("git_remote_push") {
                        pushOptions.withOptions { options in
                            git_remote_push(remotePointer, &paths, &options)
                        }
                    }
                }
                continuation.finish()
                logger.info("Done pushing")
            } catch {
                continuation.finish(throwing: error)
            }
        }
        return stream
    }

    public func push(remoteName: String, refspecs: [String], credentials: Credentials = .default) async throws {
        for try await _ in pushProgress(remoteName: remoteName, refspecs: refspecs, credentials: credentials) {}
    }

    /// Enumerates the commits for a reference.
    /// - Parameters:
    ///   - referenceShorthand: The shorthand name of the reference to enumerate.
    ///   - callback: A callback that receives each commit. Return `false` to stop enumerating commits.
    public func enumerateCommits(referenceShorthand: String, callback: (Commit) -> Bool) throws {
        // TODO: Per the documentation, we should reuse this walker.
        let revwalkPointer = try ExecReturn("git_revwalk_new") { pointer in
            git_revwalk_new(&pointer, repo)
        }
        defer {
            git_revwalk_free(revwalkPointer)
        }
        let commitPointer = try ExecReturn("git_revparse_single") { commitPointer in
            git_revparse_single(&commitPointer, repo, referenceShorthand)
        }
        defer {
            git_commit_free(commitPointer)
        }
        try Exec("git_revwalk_push") {
            let oid = git_commit_id(commitPointer)
            return git_revwalk_push(revwalkPointer, oid)
        }
        var oid = git_oid()
        var walkResult = git_revwalk_next(&oid, revwalkPointer)
        var stop = false
        while walkResult == 0, !stop {
            let historyCommitPointer = try ExecReturn("git_commit_lookup") { historyCommitPointer in
                git_commit_lookup(&historyCommitPointer, repo, &oid)
            }
            stop = !callback(Commit(historyCommitPointer))
            walkResult = git_revwalk_next(&oid, revwalkPointer)
        }
        if walkResult != GIT_ITEROVER.rawValue, !stop {
            throw GitError(code: walkResult, apiName: "git_revwalk_next")
        }
    }

    /// Get the history of changes to the repository.
    /// - Parameter revspec: The starting commit for history.
    /// - Returns: An `AsyncThrowingStream` whose elements are ``Commit`` records starting at `revspec`.
    public func log(revspec: String) -> AsyncThrowingStream<Commit, Error> {
        AsyncThrowingStream { continuation in
            do {
                try enumerateCommits(referenceShorthand: revspec) { commit in
                    continuation.yield(commit)
                    return true
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    public func allCommits(revspec: String) throws -> [Commit] {
        var results: [Commit] = []
        try enumerateCommits(referenceShorthand: revspec) { commit in
            results.append(commit)
            return true
        }
        return results
    }

    public func isCommitReachableFromAnyRemote(commit: Commit) throws -> Bool {
        let remoteOids = try branches(type: .remote).compactMap { branchName -> git_oid? in
            try lookupReference(name: branchName)?.commit.objectID.oid
        }
        return try isCommit(commit, reachableFrom: remoteOids)
    }

    public func isCommit(_ commit: Commit, reachableFrom objectIDs: [ObjectID]) throws -> Bool {
        let oids = objectIDs.map(\.oid)
        return try isCommit(commit, reachableFrom: oids)
    }

    private func isCommit(_ commit: Commit, reachableFrom oids: [git_oid]) throws -> Bool {
        var commitOid = commit.objectID.oid
        let isReachable = git_graph_reachable_from_any(
            repo, &commitOid, oids, oids.count)
        switch isReachable {
        case 1:
            return true
        case 0:
            return false
        default:
            throw GitError(code: isReachable, apiName: "git_graph_reachable_from_any")
        }
    }

    public func diff(_ oldTree: Tree?, _ newTree: Tree?) throws -> Diff {
        let diffPointer = try ExecReturn("git_diff_tree_to_tree") { pointer in
            git_diff_tree_to_tree(
                &pointer, repo, oldTree?.tree, newTree?.tree, nil)
        }
        return Diff(diffPointer)
    }
}

public enum FetchError: Error {

    /// There was an unexpected error: The fetch stream did not complete.
    case unexpectedError
}

extension Repository.FetchProgressStream {

    /// Fetch the entire contents of the stream and return the default branch name for the remote.
    /// - returns: The reference name for default branch for the remote.
    @discardableResult public func fetchAll() async throws -> String? {
        for try await progress in self {
            switch progress {
            case .completed(let branch):
                return branch
            default:
                break
            }
        }
        throw FetchError.unexpectedError
    }
}

extension AsyncThrowingStream {

    /// Waits until the given stream completes.
    public func complete() async throws {
        for try await _ in self {}
    }
}

private func treeWalkCallback(root: UnsafePointer<Int8>?, entryPointer: OpaquePointer?, payload: UnsafeMutableRawPointer?) -> Int32 {
    guard let payload = payload, let entryPointer = entryPointer, let root = root else {
        return Repository.TreeWalkResult.continue.rawValue
    }
    let callbackPointer = payload.assumingMemoryBound(to: Repository.TreeWalkCallback.self)
    let entry = Tree.Entry(entryPointer, root: String(cString: root))
    return callbackPointer.pointee(entry).rawValue
}
