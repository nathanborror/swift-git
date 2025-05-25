import Foundation
import CGit2

/// Swift-y wrapper around `git_signature`
public final class Signature {

    public init(name: String, email: String, time: Date = Date(), timeZone: TimeZone = .current) throws {
        var signature: UnsafeMutablePointer<git_signature>?
        try GitError.check(apiName: "git_signature_new") {
            let gitTime = git_time_t(time.timeIntervalSince1970)
            let offset = Int32(timeZone.secondsFromGMT(for: time) / 60)
            return git_signature_new(&signature, name, email, gitTime, offset)
        }
        if let signature {
            self.signature = signature
        } else {
            throw GitError(code: GIT_ERROR.rawValue, apiName: "git_signature_new")
        }
    }

    deinit {
        git_signature_free(signature)
    }

    let signature: UnsafeMutablePointer<git_signature>
}
