import CGit2
import Foundation

/// A snapshot of the contents of a single directory stored in a ``Repository``.
///
/// A `Tree` is a random-access collection of ``TreeEntry`` structs.
public final class Tree {
    init(_ treePointer: OpaquePointer) {
        self.treePointer = treePointer
        self.entryCount = git_tree_entrycount(treePointer)
    }

    deinit {
        git_object_free(treePointer)
    }

    let treePointer: OpaquePointer
    let entryCount: Int

    /// Retrieve a tree entry contained in a tree or in any of its subtrees, given its relative path.
    public subscript(path path: String) -> TreeEntry? {
        do {
            let entryPointer = try GitError.checkAndReturn(
                apiName: "git_tree_entry_bypath",
                closure: { pointer in
                    git_tree_entry_bypath(&pointer, treePointer, path)
                }
            )
            defer {
                git_tree_entry_free(entryPointer)
            }
            return TreeEntry(entryPointer)
        } catch {
            return nil
        }
    }
}

extension Tree: RandomAccessCollection {
    public var startIndex: Int { 0 }
    public var endIndex: Int { entryCount }
    public func index(after i: Int) -> Int { i + 1 }
    public func index(before i: Int) -> Int { i - 1 }
    public var count: Int { entryCount }

    public subscript(position: Int) -> TreeEntry {
        TreeEntry(git_tree_entry_byindex(treePointer, position))
    }
}
