import Foundation
import CGit2

/// In-memory representation of a reference.
public final class Reference {

    let referencePointer: OpaquePointer

    public var name: String? {
        if let charPointer = git_reference_name(referencePointer) {
            return String(cString: charPointer)
        } else {
            return nil
        }
    }

    public var commit: Commit {
        get throws {
            let commit = try ExecReturn("git_reference_peel") { pointer in
                git_reference_peel(&pointer, referencePointer, GIT_OBJECT_COMMIT)
            }
            return Commit(commit)
        }
    }

    public var tree: Tree {
        get throws {
            let tree = try ExecReturn("git_reference_peel") { pointer in
                git_reference_peel(&pointer, referencePointer, GIT_OBJECT_TREE)
            }
            return Tree(tree)
        }
    }

    public var upstream: Reference? {
        get throws {
            do {
                let upstream = try ExecReturn("git_branch_upstream") { pointer in
                    git_branch_upstream(&pointer, referencePointer)
                }
                return Reference(pointer: upstream)
            } catch let error as GitError {
                if error.code == GIT_ENOTFOUND.rawValue {
                    return nil
                } else {
                    throw error
                }
            }
        }
    }

    init(pointer: OpaquePointer) {
        self.referencePointer = pointer
    }

    deinit {
        git_reference_free(referencePointer)
    }
}
