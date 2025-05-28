import Foundation
import CGit2

public struct BranchType: OptionSet, Sendable {
    public var rawValue: UInt32

    var gitType: git_branch_t {
        git_branch_t(rawValue: rawValue)
    }

    public static let local = BranchType(rawValue: GIT_BRANCH_LOCAL.rawValue)
    public static let remote = BranchType(rawValue: GIT_BRANCH_REMOTE.rawValue)
    public static let all: BranchType = [.local, .remote]

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}
