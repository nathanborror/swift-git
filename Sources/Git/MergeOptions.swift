import Foundation
import CGit2

extension git_merge_flag_t: @retroactive OptionSet {}
extension git_merge_file_flag_t: @retroactive OptionSet {}

struct MergeOptions {
    var checkoutOptions: CheckoutOptions
    var mergeFlags: git_merge_flag_t
    var fileFlags: git_merge_file_flag_t

    func withOptions<T>(_ block: (inout git_merge_options, inout git_checkout_options) throws -> T) rethrows -> T {
        var options = git_merge_options()
        git_merge_options_init(&options, UInt32(GIT_MERGE_OPTIONS_VERSION))
        options.flags = mergeFlags.rawValue
        options.file_flags = fileFlags.rawValue
        return try checkoutOptions.withOptions { checkout_options in
            try block(&options, &checkout_options)
        }
    }
}
