import Foundation
import CGit2

public struct ObjectID: CustomStringConvertible, Hashable, Sendable {
    var id: git_oid

    init(_ id: git_oid) {
        self.id = id
    }

    init?(_ idPointer: UnsafePointer<git_oid>?) {
        guard let id = idPointer?.pointee else {
            return nil
        }
        self.init(id)
    }

    public var description: String {
        let length = Int(GIT_OID_RAWSZ) * 2
        let string = UnsafeMutablePointer<Int8>.allocate(capacity: length)
        var id = id
        git_oid_fmt(string, &id)

        let data = Data(bytes: string, count: length)
        return String(data: data, encoding: .ascii) ?? "<error>"
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id.id.0)
        hasher.combine(id.id.1)
        hasher.combine(id.id.2)
        hasher.combine(id.id.3)
        hasher.combine(id.id.4)
        hasher.combine(id.id.5)
        hasher.combine(id.id.6)
        hasher.combine(id.id.7)
        hasher.combine(id.id.8)
        hasher.combine(id.id.9)
        hasher.combine(id.id.10)
        hasher.combine(id.id.11)
        hasher.combine(id.id.12)
        hasher.combine(id.id.13)
        hasher.combine(id.id.14)
        hasher.combine(id.id.15)
        hasher.combine(id.id.16)
        hasher.combine(id.id.17)
        hasher.combine(id.id.18)
        hasher.combine(id.id.19)
    }
}

extension ObjectID: Equatable {
    public static func == (lhs: ObjectID, rhs: ObjectID) -> Bool {
        lhs.description == rhs.description
    }
}
