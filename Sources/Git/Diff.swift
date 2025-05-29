import Foundation
import CGit2

/// The cumulative list of differences between two snapshots of a repository (possibly filtered by a set of file name patterns).
public final class Diff {
    private let diff: OpaquePointer
    private let deltaCount: Int // The number of ``Delta`` structs contained in this diff

    init(_ diff: OpaquePointer) {
        self.diff = diff
        self.deltaCount = git_diff_num_deltas(diff)
    }

    deinit {
        git_diff_free(diff)
    }

    /// A description of changes to a single entry between two snapshots of a repository.
    ///
    /// A `Delta` is a file pair with an old and new revision. The old version may be absent if the file was just created and the new version may be absent if the file was deleted.
    /// A ``Diff`` is mostly just a list of deltas.
    public struct Delta {
        public let status: Status
        public let flags: Flags
        public let oldFile: File
        public let newFile: File

        init(_ delta: git_diff_delta) {
            self.status = Status(rawValue: delta.status.rawValue) ?? .unreadable
            self.flags = Flags(rawValue: delta.flags)
            self.oldFile = File(delta.old_file)
            self.newFile = File(delta.new_file)
        }
    }

    public enum Status: UInt32, CustomStringConvertible {
        case unmodified = 0
        case added = 1
        case deleted = 2
        case modified = 3
        case renamed = 4
        case copied = 5
        case ignored = 6
        case untracked = 7
        case typechange = 8
        case unreadable = 9
        case conflicted = 10

        public var description: String {
            switch self {
            case .unmodified:
                "no changes"
            case .added:
                "entry does not exist in old version"
            case .deleted:
                "entry does not exist in new version"
            case .modified:
                "entry content changed between old and new"
            case .renamed:
                "entry was renamed between old and new"
            case .copied:
                "entry was copied from another old entry"
            case .ignored:
                "entry is ignored item in workdir"
            case .untracked:
                "entry is untracked item in workdir"
            case .typechange:
                "type of entry changed between old and new"
            case .unreadable:
                "entry is unreadable"
            case .conflicted:
                "entry in the index is conflicted"
            }
        }
    }

    /// Flag values for a ``Delta`` and a ``File``.
    ///
    /// Values outside of this public range should be considered reserved for internal or future use.
    public struct Flags: RawRepresentable, OptionSet {
        public let rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        /// file(s) treated as binary data
        public static let binary = Flags(rawValue: 1 << 0)

        /// file(s) treated as text data
        public static let notBinary = Flags(rawValue: 1 << 1)

        /// `id` value is known correct
        public static let validId = Flags(rawValue: 1 << 2)

        /// file exists at this side of the delta
        public static let exists = Flags(rawValue: 1 << 3)
    }

    /// Description of one side of a ``Delta``.
    public struct File {
        /// The `git_oid` of the item. If the entry represents an absent side of a diff (e.g. the `old_file` of a `GIT_DELTA_ADDED` delta), then the id will be zeroes.
        public let id: ObjectID

        /// The path to the entry, relative to the working directory of the repository.
        public let path: String

        /// The size of the entry, in bytes.
        public let size: Int

        public let flags: Flags

        public init(_ gitFile: git_diff_file) {
            self.id = ObjectID(gitFile.id)
            self.path = String(cString: gitFile.path)
            self.size = Int(gitFile.size)
            self.flags = Flags(rawValue: UInt32(gitFile.flags))
        }
    }
}

extension Diff: RandomAccessCollection {
    public var startIndex: Int { 0 }
    public var endIndex: Int { deltaCount }

    public func index(after i: Int) -> Int {
        i + 1
    }

    public func index(before i: Int) -> Int {
        i - 1
    }

    public subscript(position: Int) -> Delta {
        Delta(git_diff_get_delta(diff, position)!.pointee)
    }
}
