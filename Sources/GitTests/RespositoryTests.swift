import Foundation
import Testing

@testable import Git
@testable import GitInit

@Suite("Repository Tests")
struct RepositoryTests {

    init() {
        GitInit()
    }

    @Test("Create Bare Repository")
    func testCreateBareRepository() async throws {
        let location = FileManager.default.temporaryDirectory.appendingPathComponent("testCreateBareRepository.git")
        let repository = try Repository(create: location, bare: true)
        let url = repository.workingDirectoryURL
        #expect(url == nil)
    }

    @Test("Create Non-Bare Repository")
    func testCreateNonBareRepository() async throws {
        let location = FileManager.default.temporaryDirectory.appendingPathComponent("testCreateNonBareRepository.git")
        let repository = try Repository(create: location, bare: false)
        let url = repository.workingDirectoryURL
        #expect(url != nil)
    }

    @Test("Open Repository")
    func testOpenRepository() async throws {
        let location = FileManager.default.temporaryDirectory.appendingPathComponent("testOpenRepository")
        defer {
            try? FileManager.default.removeItem(at: location)
        }
        #expect(throws: GitError.self) {
            try Repository(open: location)
        }
        _ = try Repository(create: location, bare: false)
        let openedRepository = try Repository(open: location)
        #expect(openedRepository.workingDirectoryURL?.standardizedFileURL == location.standardizedFileURL)
    }

    @Test("Basic Clone")
    func testBasicClone() async throws {
        let location = FileManager.default.temporaryDirectory.appendingPathComponent("testBasicClone")
        defer {
            try? FileManager.default.removeItem(at: location)
        }
        let repository = try await Repository.clone(
            URL(string: "https://github.com/bdewey/jubliant-happiness")!, into: location
        )
        #expect(repository.workingDirectoryURL != nil)
        print("Cloned to \(repository.workingDirectoryURL?.absoluteString ?? "nil")")
    }

    @Test("Basic Shallow Clone")
    func testBasicShallowClone() async throws {
        let location = FileManager.default.temporaryDirectory.appendingPathComponent("testBasicShallowClone")
        defer {
            try? FileManager.default.removeItem(at: location)
        }
        let repository = try await Repository.clone(
            URL(string: "https://github.com/bdewey/jubliant-happiness")!, into: location, depth: 1
        )
        let commits = try await repository.commits("HEAD")
        #expect(commits.count == 1)
    }

    @Test("Fetch Fast Forward")
    func testFetchFastForward() async throws {
        let location = FileManager.default.temporaryDirectory.appendingPathComponent("testFetchFastForward")
        defer {
            try? FileManager.default.removeItem(at: location)
        }
        let repository = try Repository(create: location, bare: false)
        try await repository.remoteAdd("origin", url: URL(string: "https://github.com/bdewey/jubliant-happiness")!)
        let progressStream = await repository.fetchProgress(remote: "origin")
        for try await progress in progressStream {
            print("Fetch progress: \(progress)")
        }
        let result = try await repository.merge("origin/main",
            signature: Signature(name: "John Q. Tester", email: "tester@me.com")
        )
        #expect(result.isFastForward)
        let (ahead, behind) = try await repository.commitsAheadBehind("origin/main")
        #expect(ahead == 0)
        #expect(behind == 0)
        let expectedFilePath = repository.workingDirectoryURL!.appendingPathComponent("Package.swift").path
        print("Looking for file at \(expectedFilePath)")
        #expect(FileManager.default.fileExists(atPath: expectedFilePath))
    }

    @Test("Add & Remove Remote")
    func testAddAndRemoveRemote() async throws {
        let location = FileManager.default.temporaryDirectory.appendingPathComponent("testAddAndRemoveRemote")
        defer {
            try? FileManager.default.removeItem(at: location)
        }
        let repository = try Repository(create: location, bare: false)
        try await repository.remoteAdd("origin", url: URL(string: "https://github.com/bdewey/jubliant-happiness")!)
        try await repository.fetchProgress(remote: "origin").complete()
        for try await progress in await repository.checkoutProgress(referenceShorthand: "origin/main") {
            print(progress)
        }
        try await repository.checkNormalState()
        let statusEntries = try await repository.statusEntries
        #expect(statusEntries.isEmpty)

        let expectedFilePath = repository.workingDirectoryURL!.appendingPathComponent("Package.swift").path
        #expect(FileManager.default.fileExists(atPath: expectedFilePath))

        try await repository.remoteRemove("origin")
    }

    @Test("Fetch Non-Conflicting Changes")
    func testFetchNonConflictingChanges() async throws {
        let location = FileManager.default.temporaryDirectory.appendingPathComponent("testFetchNonConflictingChanges")
        defer {
            try? FileManager.default.removeItem(at: location)
        }
        let repository = try Repository(create: location, bare: false)
        try "Local file\n".write(
            to: repository.workingDirectoryURL!.appendingPathComponent("local.txt"),
            atomically: true,
            encoding: .utf8
        )
        try await repository.add("local.txt")
        let commitTime = Date()
        let _ = try await repository.commitCreate(
            message: "Local commit",
            signature: Signature(name: "John Q. Tester", email: "tester@me.com", time: commitTime)
        )

        // TODO: Fix this because it was using accuracy of 1
        //let timeFromRepo = try repository.head!.commit.commitTime
        //#expect(commitTime.timeIntervalSince1970 == timeFromRepo.timeIntervalSince1970)

        try await repository.remoteAdd("origin", url: URL(string: "https://github.com/bdewey/jubliant-happiness")!)
        try await repository.fetchProgress(remote: "origin").complete()
        var (ahead, behind) = try await repository.commitsAheadBehind("origin/main")
        #expect(ahead == 1)
        #expect(behind == 1)
        let result = try await repository.merge("origin/main",
            signature: Signature(name: "John Q. Tester", email: "tester@me.com")
        )
        #expect(result.isMerge)
        try await repository.checkNormalState()
        (ahead, behind) = try await repository.commitsAheadBehind("origin/main")
        #expect(ahead == 2)
        #expect(behind == 0)
        let expectedFilePath = repository.workingDirectoryURL!.appendingPathComponent("Package.swift").path
        print("Looking for file at \(expectedFilePath)")
        #expect(FileManager.default.fileExists(atPath: expectedFilePath))
        try "Another file\n".write(
            to: repository.workingDirectoryURL!.appendingPathComponent("another.txt"),
            atomically: true,
            encoding: .utf8
        )
        try await repository.add("*")
        let _ = try await repository.commitCreate(
            message: "Moving ahead of remote",
            signature: Signature(name: "John Q. Tester", email: "tester@me.com")
        )
        (ahead, behind) = try await repository.commitsAheadBehind("origin/main")
        #expect(ahead == 3)
        #expect(behind == 0)
    }

    @Test("Clone With Progress")
    func testCloneWithProgress() async throws {
        let location = FileManager.default.temporaryDirectory.appendingPathComponent("testCloneWithProgress")
        defer {
            try? FileManager.default.removeItem(at: location)
        }
        var repository: Repository!
        for try await progress in Repository.cloneProgress(
            from: URL(string: "https://github.com/bdewey/SpacedRepetitionScheduler")!,
            to: location
        ) {
            switch progress {
            case .progress(let progress):
                print("Clone progress: \(progress)")
            case .completed(let repo):
                repository = repo
            }
        }
        #expect(repository.workingDirectoryURL != nil)
        print("Cloned to \(repository.workingDirectoryURL?.absoluteString ?? "nil")")
        var commitCount = 0
        for try await commit in await repository.log(revision: "HEAD") {
            print("\(commit)")
            commitCount += 1
        }
        #expect(commitCount == 12)
    }

    @Test("Tree Enumeration")
    func testTreeEnumeration() async throws {
        let location = FileManager.default.temporaryDirectory.appendingPathComponent("testTreeEnumeration")
        defer { try? FileManager.default.removeItem(at: location) }
        let repository = try await Repository.clone(
            URL(string: "https://github.com/bdewey/SpacedRepetitionScheduler")!, into: location
        )
        let tree = try await repository.treeHead
        for try await qualfiedEntry in await repository.treeWalk(tree) {
            print(qualfiedEntry)
        }
    }

    @Test("Get Data From Entry")
    func testGetDataFromEntry() async throws {
        let location = FileManager.default.temporaryDirectory.appendingPathComponent("testGetDataFromEntry")
        defer { try? FileManager.default.removeItem(at: location) }
        let repository = try await Repository.clone(
            URL(string: "https://github.com/bdewey/SpacedRepetitionScheduler")!, into: location
        )
        let entries = await repository.treeWalk()
        guard let gitIgnoreEntry = try await entries.first(where: { $0.name == ".gitignore" }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try await repository.data(gitIgnoreEntry.objectID)
        let string = String(data: data, encoding: .utf8)!
        print(string)
    }

    @Test("Add Content To Repository")
    func testAddContentToRepository() async throws {
        let location = FileManager.default.temporaryDirectory.appendingPathComponent("testAddContentToRepository")
        defer {
            try? FileManager.default.removeItem(at: location)
        }
        let repository = try Repository(create: location, bare: false)
        let testText = "This is some sample text.\n"
        try testText.write(
            to: repository.workingDirectoryURL!.appendingPathComponent("test.txt"),
            atomically: true,
            encoding: .utf8
        )
        try await repository.add()
        print(repository.workingDirectoryURL!.absoluteString)
    }

    @Test("Simple Commits")
    func testSimpleCommits() async throws {
        let location = FileManager.default.temporaryDirectory.appendingPathComponent("testSimpleCommits")
        let signature = try Signature(name: "Brian Dewey", email: "bdewey@gmail.com")
        defer {
            try? FileManager.default.removeItem(at: location)
        }
        let repository = try Repository(create: location, bare: false)
        print("Working directory: \(repository.workingDirectoryURL!.standardizedFileURL.path)")
        let testText = "This is some sample text.\n"
        try testText.write(
            to: repository.workingDirectoryURL!.appendingPathComponent("test.txt"),
            atomically: true,
            encoding: .utf8
        )
        try await repository.add()
        let firstCommitID = try await repository.commitCreate(message: "First commit", signature: signature)
        print("First commit: \(firstCommitID)")
        try "Hello, world\n".write(
            to: repository.workingDirectoryURL!.appendingPathComponent("hello.txt"),
            atomically: true,
            encoding: .utf8
        )
        try await repository.add()
        let secondCommitID = try await repository.commitCreate(message: "Second commit", signature: signature)
        print("Second commit: \(secondCommitID)")

        let firstDiff = try await repository.diff(nil, try repository.commit(firstCommitID).tree)
        #expect(firstDiff.count == 1)
    }

    @Test("Commits Ahead Behind")
    func testCommitsAheadBehind() async throws {
        let location = FileManager.default.temporaryDirectory.appendingPathComponent("testCommitsAheadBehind")
        defer {
            try? FileManager.default.removeItem(at: location)
        }
        let clientURL = location.appendingPathComponent("client")
        try? FileManager.default.createDirectory(at: clientURL, withIntermediateDirectories: true)
        let serverURL = location.appendingPathComponent("server")
        try? FileManager.default.createDirectory(at: serverURL, withIntermediateDirectories: true)
        let clientRepository = try Repository(create: clientURL)
        let serverRepository = try Repository(create: serverURL)
        try await clientRepository.remoteAdd("origin", url: serverURL)
        try await clientRepository.fetchProgress(remote: "origin").complete()
        let initialTuple = try await clientRepository.commitsAheadBehind("origin/main")
        #expect(initialTuple.ahead == 0)
        #expect(initialTuple.behind == 0)

        // Commit some stuff to `server` and fetch it
        try "test1\n".write(to: serverURL.appendingPathComponent("test1.txt"), atomically: true, encoding: .utf8)
        try await serverRepository.add()
        let _ = try await serverRepository.commitCreate(
            message: "test1",
            signature: Signature(name: "bkd", email: "noone@foo.com", time: Date())
        )

        try "test2\n".write(to: serverURL.appendingPathComponent("test2.txt"), atomically: true, encoding: .utf8)
        try await serverRepository.add()
        let _ = try await serverRepository.commitCreate(
            message: "test2",
            signature: Signature(name: "bkd", email: "noone@foo.com", time: Date())
        )

        try await clientRepository.fetchProgress(remote: "origin").complete()
        let fetchedTuple = try await clientRepository.commitsAheadBehind("origin/main")
        #expect(fetchedTuple.ahead == 0)
        #expect(fetchedTuple.behind == 2)

        let mergeResult = try await clientRepository.merge("origin/main",
            signature: Signature(name: "bkd", email: "noone@foo.com", time: Date())
        )
        #expect(mergeResult.isFastForward)

        let nothingOnServer = try await clientRepository.commitsAheadBehind("fake")
        #expect(nothingOnServer.ahead == 2)
        #expect(nothingOnServer.behind == 0)
    }

    @Test("Private Clone")
    func testPrivateBasicClone() async throws {
        let location = FileManager.default.temporaryDirectory.appendingPathComponent("testPrivateBasicClone")
        defer { try? FileManager.default.removeItem(at: location) }

        // Github Personal Access Token (read-only access)
        let username = "nathanborror"
        let token = "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"

        let repository = try await Repository.clone(
            URL(string: "https://github.com/nathanborror/swift-git.git")!, into: location, credentials: .plaintext(username: username, password: token)
        )
        #expect(repository.workingDirectoryURL != nil)
    }

    // git clone ...
    // git fetch; git merge
    // git add .; git commit -m "..."
    // git push

    // git clone --depth=1 ...
    // git fetch; git merge
}
