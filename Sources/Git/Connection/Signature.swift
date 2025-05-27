import Foundation
import CGit2

public final class Signature {

    let signature: UnsafeMutablePointer<git_signature>

    public init(name: String, email: String, time: Date = Date(), timeZone: TimeZone = .current) throws {
        var signature: UnsafeMutablePointer<git_signature>?
        try Exec("git_signature_new") {
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
}
