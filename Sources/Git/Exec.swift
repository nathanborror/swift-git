import Foundation
import CGit2

func Exec(_ name: String, closure: () -> Int32) throws {
    let result = closure()
    guard result == GIT_OK.rawValue else {
        throw GitError(code: result, apiName: name)
    }
}

func ExecReturn(_ name: String, closure: (inout OpaquePointer?) -> Int32) throws -> OpaquePointer {
    var pointer: OpaquePointer?
    let result = closure(&pointer)
    guard let returnedPointer = pointer, result == GIT_OK.rawValue else {
        throw GitError(code: result, apiName: name)
    }
    return returnedPointer
}

func ExecReturnID(_ name: String, closure: (inout git_oid) -> Int32) throws -> ObjectID {
    var id = git_oid()
    let result = closure(&id)
    guard result == GIT_OK.rawValue else {
        throw GitError(code: result, apiName: name)
    }
    return ObjectID(id)
}
