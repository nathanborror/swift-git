import Foundation
import CGit2

/// A snapshot of the contents of a single directory stored in a ``Repository``.
///
/// A `Tree` is a random-access collection of ``TreeEntry`` structs.
public final class Tree {
    init(_ tree: OpaquePointer) {
        self.tree = tree
        self.entryCount = git_tree_entrycount(tree)
    }

    deinit {
        git_object_free(tree)
    }

    let tree: OpaquePointer
    let entryCount: Int

    /// Retrieve a tree entry contained in a tree or in any of its subtrees, given its relative path.
    public subscript(path path: String) -> TreeEntry? {
        do {
            let entry = try ExecReturn("git_tree_entry_bypath") { pointer in
                git_tree_entry_bypath(&pointer, tree, path)
            }
            defer {
                git_tree_entry_free(entry)
            }
            return TreeEntry(entry)
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
        TreeEntry(git_tree_entry_byindex(tree, position))
    }
}
