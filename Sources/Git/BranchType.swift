import Foundation
import CGit2

public struct BranchType: OptionSet, Sendable {
    public var rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// The `CGit2` `git_branch_t` value corresponding to this branch type.
    var gitType: git_branch_t {
        git_branch_t(rawValue: rawValue)
    }

    public static let local = BranchType(rawValue: GIT_BRANCH_LOCAL.rawValue)
    public static let remote = BranchType(rawValue: GIT_BRANCH_REMOTE.rawValue)
    public static let all: BranchType = [.local, .remote]
}
