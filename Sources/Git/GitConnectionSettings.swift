import Foundation

extension CodingUserInfoKey {
    /// Include this key in `JSONEncoder.userInfo` (and set it to any non-nil value) to include the password in the serialized settings.
    public static let includeConnectionPasswordKey = CodingUserInfoKey(
        rawValue: "com.git-scm.includeConnectionPassword"
    )!
}

/// Type for all of the settings required to connect to a remote ``Repository``.
///
/// This type is designed for use in UI components that let people fill out sync settings -- it is possible to have invalid settings (e.g., missing required values or invalid connection strings).
/// You can determine if the contents of this type are valid for synchronization by using ``isValid``.
///
/// If the type is valid, you can get ``Credentials`` for connection and a ``Signature`` for authoring commits.
public struct GitConnectionSettings: Codable, Equatable, Sendable {

    public enum AuthenticationType: String, Codable, Sendable {
        case usernamePassword = "https"  // There are serialized versions of settings that called this "https"
        case ssh
        case none
    }

    public struct SSHKeyPair: Codable, Equatable, Sendable {
        public var publicKey = ""
        public var privateKey = ""

        public init(publicKey: String = "", privateKey: String = "") {
            self.publicKey = publicKey
            self.privateKey = privateKey
        }

        public var isValid: Bool {
            !publicKey.isEmpty && !privateKey.isEmpty
        }
    }

    public init(remote: URL? = nil, username: String = "", email: String = "", password: String = "", isReadOnly: Bool = false) {
        self.remote = remote
        self.username = username
        self.email = email
        self.password = password
        self.isReadOnly = isReadOnly
    }

    /// How we are supposed to connect to the server
    public var connectionType = AuthenticationType.usernamePassword

    /// The `git` remote URL containing the master copy of the repository.
    public var remote: URL?

    /// The username to use for recording all transactions.
    public var username: String

    /// The email to use for recording all transactions. This will also be used in the "username" field when connecting to ``remoteURLString``.
    public var email: String

    /// If true, we expect to only have read-only credentials. Don't try to push changes and don't allow transaction edits.
    public var isReadOnly: Bool

    /// The password to use when connecting to the repository. (This is probably a Github Personal Access Token, not a real password.)
    /// Note we have a custom `Codable` conformance to make sure this value isn't persisted
    public var password: String

    /// If connectionType == .ssh, this will contain the SSH key pair
    public var sshKeyPair = SSHKeyPair()

    public var keychainIdentifier: String {
        [remote?.absoluteString ?? "", email].joined(separator: "__")
    }

    /// True if all required settings properties are filled in
    public var isValid: Bool {
        isConnectionInformationValid && isPersonalInformationValid
    }

    private var isPersonalInformationValid: Bool {
        // EITHER we are read-only (and don't need username / email) OR we need both username & email.
        isReadOnly || (!username.isEmpty && !email.isEmpty)
    }

    private var isConnectionInformationValid: Bool {
        switch connectionType {
        case .usernamePassword:
            isRemoteURLValid && !email.isEmpty && (isReadOnly || !password.isEmpty)
        case .ssh:
            sshKeyPair.isValid && !password.isEmpty
        case .none:
            true
        }
    }

    public var credentials: Credentials {
        switch connectionType {
        case .usernamePassword:
            .plaintext(username: username, password: password)
        case .ssh:
            .sshMemory(
                username: "git",
                publicKey: sshKeyPair.publicKey,
                privateKey: sshKeyPair.privateKey,
                passphrase: password
            )
        case .none:
            .default
        }
    }

    public func makeSignature(time: Date, timeZone: TimeZone = .current) throws -> Signature {
        try Signature(name: username, email: email, time: time, timeZone: timeZone)
    }

    public var isRemoteURLValid: Bool {
        if connectionType == .ssh {
            return true // I don't validate SSH connection strings right now
        }
        guard let remote else {
            return false
        }
        let validScheme = remote.scheme?.lowercased() == "http" || remote.scheme?.lowercased() == "https"
        let emptyHost = remote.host?.isEmpty ?? true
        return validScheme && !emptyHost
    }
}
