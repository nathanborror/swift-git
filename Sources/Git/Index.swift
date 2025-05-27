import Foundation
import CGit2

/// The git `Index` for a repository.
public final class Index {
    public init(_ indexPointer: OpaquePointer) {
        self.indexPointer = indexPointer
    }

    deinit {
        git_index_free(indexPointer)
    }

    let indexPointer: OpaquePointer

    /// True if the index has conflict entries.
    public var hasConflicts: Bool {
        git_index_has_conflicts(indexPointer) != 0
    }

    /// The conflicting entries in the index.
    public var conflicts: ConflictSequence {
        ConflictSequence(self)
    }

    /// Adds an entry to the index.
    public func addEntry(_ entry: Entry) throws {
        var entry = entry.gitEntry
        try Exec("git_index_add") {
            git_index_add(indexPointer, &entry)
        }
    }

    /// Removes any conflict entries for `path`.
    public func removeConflictEntries(for path: String) throws {
        try Exec("git_index_conflict_remove") {
            git_index_conflict_remove(indexPointer, path)
        }
    }
}

extension Index {
    /// The sequence of conflicting entries in this index.
    public struct ConflictSequence: Sequence {
        private let index: Index

        init(_ index: Index) {
            self.index = index
        }

        /// Iterates through the conflicting entries in an index.
        public final class Iterator: IteratorProtocol {
            let iterator: OpaquePointer?

            init(index: Index) {
                self.iterator = try? ExecReturn("git_index_conflict_iterator_new") { pointer in
                    git_index_conflict_iterator_new(&pointer, index.indexPointer)
                }
            }

            deinit {
                if let iterator {
                    git_index_conflict_iterator_free(iterator)
                }
            }

            public func next() -> ConflictEntry? {
                guard let iterator else {
                    return nil
                }
                var ancestor: UnsafePointer<git_index_entry>?
                var ours: UnsafePointer<git_index_entry>?
                var theirs: UnsafePointer<git_index_entry>?

                if git_index_conflict_next(&ancestor, &ours, &theirs, iterator) == 0 {
                    let conflictEntry = ConflictEntry(
                        ancestor: Entry(ancestor),
                        ours: Entry(ours),
                        theirs: Entry(theirs)
                    )
                    assert(conflictEntry != nil)
                    return conflictEntry
                } else {
                    return nil
                }
            }
        }

        public func makeIterator() -> Iterator {
            Iterator(index: index)
        }
    }
}

extension Index: BidirectionalCollection {
    public var startIndex: Int { 0 }
    public var endIndex: Int { git_index_entrycount(indexPointer) }

    public func index(after i: Int) -> Int {
        i + 1
    }

    public func index(before i: Int) -> Int {
        i - 1
    }

    public subscript(position: Int) -> Entry {
        Entry(git_index_get_byindex(indexPointer, position))!
    }
}
