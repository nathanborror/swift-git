import Foundation
import CGit2

/// A snapshot of the contents of a single directory stored in a ``Repository``.
public final class Tree {

    let tree: OpaquePointer
    let entryCount: Int

    public struct Entry: Hashable, CustomStringConvertible {
        public let objectID: ObjectID
        public let name: String
        public let type: ObjectType

        public var description: String {
            "\(objectID) \(type) \(name)"
        }

        init(_ entry: OpaquePointer, root: String? = nil) {
            self.objectID = ObjectID(git_tree_entry_id(entry)!.pointee)
            let entryName = String(validatingUTF8: git_tree_entry_name(entry))
            if let root = root {
                assert(root.isEmpty || root.last == "/")
                self.name = root + (entryName ?? "")
            } else {
                self.name = entryName ?? ""
            }
            self.type = ObjectType(rawValue: git_tree_entry_type(entry).rawValue) ?? .invalid
        }
    }

    init(_ tree: OpaquePointer) {
        self.tree = tree
        self.entryCount = git_tree_entrycount(tree)
    }

    deinit {
        git_object_free(tree)
    }

    /// Retrieve a tree entry contained in a tree or in any of its subtrees, given its relative path.
    public subscript(path path: String) -> Entry? {
        do {
            let entry = try ExecReturn("git_tree_entry_bypath") { pointer in
                git_tree_entry_bypath(&pointer, tree, path)
            }
            defer { git_tree_entry_free(entry) }
            return Entry(entry)
        } catch {
            return nil
        }
    }
}

extension Tree: RandomAccessCollection {
    public var startIndex: Int { 0 }
    public var endIndex: Int { entryCount }
    public var count: Int { entryCount }

    public func index(after i: Int) -> Int { i + 1 }
    public func index(before i: Int) -> Int { i - 1 }

    public subscript(position: Int) -> Entry {
        .init(git_tree_entry_byindex(tree, position))
    }
}
