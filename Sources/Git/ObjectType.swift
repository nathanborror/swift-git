import Foundation
import CGit2

/// Mirrors `git_object_t` to be a little more swift-y
public enum ObjectType: Int32, Sendable, CustomStringConvertible {
    case any = -2
    case invalid = -1
    case commit = 1
    case tree = 2
    case blob = 3
    case tag = 4
    case deltaOffset = 6
    case deltaRef = 7

    public var description: String {
        switch self {
        case .any:
            "Object can be any of the types"
        case .invalid:
            "Object is invalid"
        case .commit:
            "Commit object"
        case .tree:
            "Tree (directory listing) object"
        case .blob:
            "File revision object"
        case .tag:
            "Annotated tag object"
        case .deltaOffset:
            "Delta, base is given by its offset"
        case .deltaRef:
            "Delta, base is given by object id"
        }
    }
}
