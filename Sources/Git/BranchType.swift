import CGit2
import Foundation

/// A type of branch.
public struct BranchType: OptionSet, Sendable {
    public var rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// The `CGit2` `git_branch_t` value corresponding to this branch type.
    var gitType: git_branch_t {
        git_branch_t(rawValue: rawValue)
    }

    /// A local branch.
    public static let local = BranchType(rawValue: GIT_BRANCH_LOCAL.rawValue)

    /// A remote branch.
    public static let remote = BranchType(rawValue: GIT_BRANCH_REMOTE.rawValue)

    /// All branch types.
    public static let all: BranchType = [.local, .remote]
}
