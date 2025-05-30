import Foundation
import CGit2
import OSLog

private let logger = Logger(subsystem: "Repository", category: "Git")

/// Representation of a git repository, including all its object contents.
/// This class is not thread-safe. Do not use it from more than one thread at the same time.
public actor Repository {
    typealias FetchProgressBlock = (FetchProgress) -> Void
    typealias CloneProgressBlock = (Result<Double, Error>) -> Void

    private let repo: OpaquePointer
    private let isOwner: Bool

    public nonisolated let workingDirectoryURL: URL?

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

    public init(create url: URL, bare: Bool = false) throws {
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

    public init(open url: URL) throws {
        let repo = try ExecReturn("git_repository_open") { pointer in
            url.withUnsafeFileSystemRepresentation { fileSystemPath in
                git_repository_open(&pointer, fileSystemPath)
            }
        }
        self.init(repo: repo, isOwner: true)
    }

    deinit {
        if isOwner {
            git_repository_free(repo)
        }
    }

    public static func clone(_ remote: URL, into local: URL, depth: Int = 0, credentials: Credentials = .default) async throws -> Repository {
        var repository: Repository?
        for try await progress in cloneProgress(from: remote, to: local, depth: depth, credentials: credentials) {
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

    public func remoteAdd(_ name: String, url: URL) throws {
        let remote = try ExecReturn("git_remote_create") { pointer in
            git_remote_create(&pointer, repo, name, url.absoluteString)
        }
        git_remote_free(remote)
    }

    public func remoteRemove(_ name: String) throws {
        try Exec("git_remote_delete") {
            git_remote_delete(repo, name)
        }
    }

    public func remoteURL(_ name: String) throws -> URL? {
        do {
            let remotePointer = try ExecReturn("git_remote_lookup") { pointer in
                git_remote_lookup(&pointer, repo, name)
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

    public func branchCreate(_ name: String, commitID: ObjectID, force: Bool = false) throws {
        var id = commitID.id
        let commitPointer = try ExecReturn("git_commit_lookup") { pointer in
            git_commit_lookup(&pointer, repo, &id)
        }
        defer {
            git_object_free(commitPointer)
        }
        let branchPointer = try ExecReturn("git_branch_create") { pointer in
            git_branch_create(&pointer, repo, name, commitPointer, force ? 1 : 0)
        }
        git_reference_free(branchPointer)
    }

    public func branchCreate(_ name: String, target: String, force: Bool = false, setTargetAsUpstream: Bool = false) throws {
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

    public func branchDelete(_ name: String) throws -> ObjectID? {
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
            let id = git_commit_id(commitPointer)
            try Exec("git_branch_delete") {
                git_branch_delete(branchPointer)
            }
            return ObjectID(id)
        } catch let error as GitError {
            if error.code == GIT_ENOTFOUND.rawValue {
                return nil
            } else {
                throw error
            }
        }
    }

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

    public func branchRemoteName(_ name: String) throws -> String {
        var buffer = git_buf()
        try Exec("git_branch_remote_name") {
            git_branch_remote_name(&buffer, repo, name)
        }
        return String(cString: buffer.ptr)
    }

    public func branchExists(_ name: String) throws -> Bool {
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

    public func branchUpstreamName(_ name: String) throws -> String {
        var buffer = git_buf()
        try Exec("git_branch_upstream_name") {
            git_branch_upstream_name(&buffer, repo, name)
        }
        defer {
            git_buf_dispose(&buffer)
        }
        return String(cString: buffer.ptr)
    }

    // MARK: - Commits

    public func commits(_ revision: String) throws -> [Commit] {
        var results: [Commit] = []
        try commitsEnumerated(revision) { commit in
            results.append(commit)
            return true
        }
        return results
    }

    public func commitsEnumerated(_ revision: String, callback: (Commit) -> Bool) throws {
        // TODO: Per the documentation, we should reuse this walker.
        let revwalkPointer = try ExecReturn("git_revwalk_new") { pointer in
            git_revwalk_new(&pointer, repo)
        }
        defer {
            git_revwalk_free(revwalkPointer)
        }
        let commitPointer = try ExecReturn("git_revparse_single") { commitPointer in
            git_revparse_single(&commitPointer, repo, revision)
        }
        defer {
            git_commit_free(commitPointer)
        }
        try Exec("git_revwalk_push") {
            let id = git_commit_id(commitPointer)
            return git_revwalk_push(revwalkPointer, id)
        }
        var id = git_oid()
        var walkResult = git_revwalk_next(&id, revwalkPointer)
        var stop = false
        while walkResult == 0, !stop {
            let historyCommitPointer = try ExecReturn("git_commit_lookup") { historyCommitPointer in
                git_commit_lookup(&historyCommitPointer, repo, &id)
            }
            stop = !callback(Commit(historyCommitPointer))
            walkResult = git_revwalk_next(&id, revwalkPointer)
        }
        if walkResult != GIT_ITEROVER.rawValue, !stop {
            throw GitError(code: walkResult, apiName: "git_revwalk_next")
        }
    }

    public func commit(_ id: ObjectID) throws -> Commit {
        var objectID = id.id
        let commitPointer = try ExecReturn("git_commit_lookup") { pointer in
            git_commit_lookup(&pointer, repo, &objectID)
        }
        return Commit(commitPointer)
    }

    public func commitID(_ revision: String) throws -> ObjectID? {
        do {
            let commitPointer = try ExecReturn("git_revparse_single") { pointer in
                git_revparse_single(&pointer, repo, revision)
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

    public func commitCreate(message: String, signature: Signature) throws -> ObjectID {
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
        let treeID = try ExecReturnID("git_index_write_tree") { id in
            git_index_write_tree(&id, indexPointer)
        }
        let tree = try treeLookup(treeID)

        return try ExecReturnID("git_commit_create") { commitID in
            git_commit_create(
                &commitID,
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

    public func commitCount(_ revision: String) throws -> Int {
        var count = 0
        try commitsEnumerated(revision) { _ in
            count += 1
            return true
        }
        return count
    }

    public func commitsAheadBehind(_ revision: String) throws -> (ahead: Int, behind: Int) {
        let headObjectID = try commitID("HEAD")
        let otherObjectID = try commitID(revision)

        switch (headObjectID, otherObjectID) {
        case (.none, .none):
            return (ahead: 0, behind: 0)
        case (.some, .none):
            return (ahead: try commitCount("HEAD"), behind: 0)
        case (.none, .some):
            return (ahead: 0, behind: try commitCount(revision))
        case (.some(var headID), .some(var otherID)):
            var ahead = 0
            var behind = 0
            try Exec("git_graph_ahead_behind") {
                git_graph_ahead_behind(&ahead, &behind, repo, &headID.id, &otherID.id)
            }
            return (ahead: ahead, behind: behind)
        }
    }

    public func commitsAheadBehind(source: Reference?, target: Reference?) throws -> (ahead: Int, behind: Int) {
        let sourceObjectID = try source?.commit.objectID
        let targetObjectID = try target?.commit.objectID

        switch (sourceObjectID, targetObjectID) {
        case (.none, .none):
            return (ahead: 0, behind: 0)
        case (.some, .none):
            let commits =
                try source?.name.flatMap { revision in
                    try commitCount(revision)
                } ?? 0
            return (ahead: commits, behind: 0)
        case (.none, .some):
            let commits =
                try target?.name.flatMap { revision in
                    try commitCount(revision)
                } ?? 0
            return (ahead: 0, behind: commits)
        case (.some(var headID), .some(var otherID)):
            var ahead = 0
            var behind = 0
            try Exec("git_graph_ahead_behind") {
                git_graph_ahead_behind(&ahead, &behind, repo, &headID.id, &otherID.id)
            }
            return (ahead: ahead, behind: behind)
        }
    }

    public func commitMerge(_ revision: String, annotatedCommit: OpaquePointer, signature: Signature) throws -> ObjectID {
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
            var id = git_annotated_commit_id(annotatedCommit)!.pointee
            return git_commit_lookup(&pointer, repo, &id)
        }
        defer {
            git_object_free(annotatedCommitObjectPointer)
        }

        let treeOid = try ExecReturnID("git_index_write_tree") { pointer in
            git_index_write_tree(&pointer, indexPointer)
        }
        let treePointer = try ExecReturn("git_tree_lookup") { pointer in
            var id = treeOid.id
            return git_tree_lookup(&pointer, repo, &id)
        }
        defer {
            git_tree_free(treePointer)
        }

        var parents: [OpaquePointer?] = [headCommit, annotatedCommitObjectPointer]
        let mergeCommitID = try ExecReturnID("git_commit_create") { pointer in
            git_commit_create(
                &pointer,
                repo,
                git_reference_name(headReference.referencePointer),
                signature.signature,
                signature.signature,
                nil,
                "Merge \(revision)",
                treePointer,
                parents.count,
                &parents
            )
        }

        try cleanup()

        return mergeCommitID
    }

    public func isCommitReachableFromAnyRemote(_ commit: Commit) throws -> Bool {
        let remoteIDs = try branches(type: .remote).compactMap { (branch) -> git_oid? in
            try referenceLookupID(branch)?.id
        }
        return try isCommit(commit, reachableFrom: remoteIDs)
    }

    public func isCommit(_ commit: Commit, reachableFrom objectIDs: [ObjectID]) throws -> Bool {
        let ids = objectIDs.map(\.id)
        return try isCommit(commit, reachableFrom: ids)
    }

    public func isCommit(_ commit: Commit, reachableFrom ids: [git_oid]) throws -> Bool {
        var commitID = commit.objectID.id
        let isReachable = git_graph_reachable_from_any(repo, &commitID, ids, ids.count)
        switch isReachable {
        case 1: return true
        case 0: return false
        default: throw GitError(code: isReachable, apiName: "git_graph_reachable_from_any")
        }
    }

    // MARK: - References

    public func referenceLookup(_ name: String) throws -> Reference? {
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

    public func referenceLookupID(_ name: String) throws -> ObjectID? {
        do {
            return try ExecReturnID("git_reference_name_to_id") { id in
                git_reference_name_to_id(&id, repo, name)
            }
        } catch let error as GitError {
            if error.code == GIT_ENOTFOUND.rawValue {
                return nil
            }
            throw error
        }
    }

    // MARK: - Trees

    public typealias TreeWalkCallback = (Tree.Entry) -> TreeWalkResult

    public enum TreeWalkResult: Int32 {
        case skipSubtree = 1
        case `continue` = 0
        case done = -1
    }

    public var treeHead: Tree {
        get throws {
            let treePointer = try ExecReturn("git_revparse_single") { pointer in
                git_revparse_single(&pointer, repo, "HEAD^{tree}")
            }
            return Tree(treePointer)
        }
    }

    public func treeLookup(_ objectID: ObjectID) throws -> Tree {
        let treePointer = try ExecReturn("git_tree_lookup") { pointer in
            var id = objectID.id
            return git_tree_lookup(&pointer, repo, &id)
        }
        return Tree(treePointer)
    }

    public func treeLookup(_ reference: String) throws -> Tree {
        let reference = try ExecReturn("git_reference_dwim") { pointer in
            git_reference_dwim(&pointer, repo, reference)
        }
        defer {
            git_reference_free(reference)
        }
        let treePointer = try ExecReturn("git_reference_peel") { pointer in
            git_reference_peel(&pointer, reference, GIT_OBJECT_TREE)
        }
        return Tree(treePointer)
    }

    public func treeWalk(_ tree: Tree, traversalMode: git_treewalk_mode = GIT_TREEWALK_PRE, callback: @escaping TreeWalkCallback) throws {
        var callback = callback
        try withUnsafeMutablePointer(to: &callback) { callbackPointer in
            try Exec("git_tree_walk") {
                git_tree_walk(tree.tree, traversalMode, treeWalkCallback, callbackPointer)
            }
        }
    }

    public func treeWalk(_ tree: Tree? = nil, traversalMode: git_treewalk_mode = GIT_TREEWALK_PRE) -> AsyncThrowingStream<Tree.Entry, Error> {
        AsyncThrowingStream { continuation in
            do {
                let originTree = try (tree ?? (try treeHead))
                try treeWalk(originTree,
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

    // MARK: - Managing Data

    public func data(_ id: ObjectID) throws -> Data {
        let blobPointer = try ExecReturn("git_blob_lookup") { pointer in
            var id = id.id
            return git_blob_lookup(&pointer, repo, &id)
        }
        defer {
            git_blob_free(blobPointer)
        }
        let size = git_blob_rawsize(blobPointer)
        let data = Data(bytes: git_blob_rawcontent(blobPointer), count: Int(size))
        return data
    }

    public func dataAdd(_ data: Data, path: String) throws {
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

    public typealias FetchProgressStream = AsyncThrowingStream<Progress<FetchProgress, String?>, Error>

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

    public enum MergeResult: Equatable, Sendable {
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

    public func merge(_ revision: String, resolver: GitConflictResolver? = nil, signature signatureBlock: @autoclosure () throws -> Signature) throws -> MergeResult {
        try checkNormalState()

        let annotatedCommit = try ExecReturn("git_annotated_commit_from_revspec") { pointer in
            git_annotated_commit_from_revspec(
                &pointer, repo, revision)
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
        if analysis.contains(GIT_MERGE_ANALYSIS_FASTFORWARD), let id = ObjectID(git_annotated_commit_id(annotatedCommit)) {
            // Fast forward
            try fastForward(to: id, isUnborn: analysis.contains(GIT_MERGE_ANALYSIS_UNBORN))
            return .fastForward(id)

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
            try conflictCheck(resolver: resolver)
            let signature = try signatureBlock()
            let mergeCommitID = try commitMerge(revision, annotatedCommit: annotatedCommit, signature: signature)
            return .merge(mergeCommitID)
        }
        return .none
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

    public func reset(_ revspec: String, type: ResetType) throws {
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

    public func reset(commitID: ObjectID, type: ResetType) throws {
        var id = commitID.id
        let commitPointer = try ExecReturn("git_commit_lookup") { pointer in
            git_commit_lookup(&pointer, repo, &id)
        }
        defer {
            git_object_free(commitPointer)
        }
        try Exec("git_reset") {
            git_reset(repo, commitPointer, type.reset_type, nil)
        }
    }

    public var index: Index {
        get throws {
            let indexPointer = try ExecReturn("git_repository_index") { pointer in
                git_repository_index(&pointer, repo)
            }
            return Index(indexPointer)
        }
    }

    public func conflictCheck(resolver: GitConflictResolver?) throws {
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

    public func conflictEnumerate(in indexPointer: OpaquePointer, _ block: (_ ancestor: git_index_entry?, _ ours: git_index_entry?, _ theirs: git_index_entry?) throws -> Void) throws {
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

    public func fastForward(to objectID: ObjectID, isUnborn: Bool) throws {
        let headReference = isUnborn ? try createSymbolicReference(named: "HEAD", targeting: objectID) : try head!
        let targetPointer = try ExecReturn("git_object_lookup") { pointer in
            var id = objectID.id
            return git_object_lookup(&pointer, repo, &id, GIT_OBJECT_COMMIT)
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
            var id = objectID.id
            return git_reference_set_target(&pointer, headReference.referencePointer, &id, nil)
        }
        git_reference_free(newTarget)
    }

    public func createSymbolicReference(named name: String, targeting objectID: ObjectID) throws -> Reference {
        let symbolicPointer = try ExecReturn("git_reference_lookup") { pointer in
            git_reference_lookup(&pointer, repo, name)
        }
        defer {
            git_reference_free(symbolicPointer)
        }
        let target = git_reference_symbolic_target(symbolicPointer)
        let targetReference = try ExecReturn("git_reference_create") { pointer in
            var id = objectID.id
            return git_reference_create(&pointer, repo, target, &id, 0, nil)
        }
        return Reference(pointer: targetReference)
    }

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

    public var headObjectID: ObjectID? {
        get throws {
            try commitID("HEAD")
        }
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

    /// Get the history of changes to the repository.
    /// - Parameter revspec: The starting commit for history.
    /// - Returns: An `AsyncThrowingStream` whose elements are ``Commit`` records starting at `revspec`.
    public func log(revision: String) -> AsyncThrowingStream<Commit, Error> {
        AsyncThrowingStream { continuation in
            do {
                try commitsEnumerated(revision) { commit in
                    continuation.yield(commit)
                    return true
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
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
