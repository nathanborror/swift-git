import CGit2
import Foundation

/// Mirrors `git_object_t` to be a little more swift-y
public enum ObjectType: Int32, Sendable {
    /// Object can be any of the following
    case any = -2

    /// Object is invalid
    case invalid = -1

    /// A commit object
    case commit = 1

    /// A tree (directory listing) object
    case tree = 2

    /// A file revision object
    case blob = 3

    /// An annotated tag object
    case tag = 4

    /// A delta, base is given by its offset
    case ofsDelta = 6

    /// A delta, base is given by object id
    case refDelta = 7
}
