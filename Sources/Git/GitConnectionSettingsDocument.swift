import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A `UTType` for a document containing a ``GitConnectionSettingsSerialized`` struct.
    public static let gitConnectionSettings = UTType(exportedAs: "com.git-scm.GitConnectionSettings")
}

/// A `FileDocument` for reading and writing ``GitConnectionSettingsSerialized`` structs.
public struct GitConnectionSettingsDocument: FileDocument {
    public init(settings: GitConnectionSettingsSerialized = .plaintext(settings: GitConnectionSettings())) {
        self.settings = settings
    }

    public var settings: GitConnectionSettingsSerialized

    public static var readableContentTypes: [UTType] = [.gitConnectionSettings]

    public init(configuration: ReadConfiguration) throws {
        guard
            configuration.file.isRegularFile,
            let data = configuration.file.regularFileContents
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.settings = try JSONDecoder().decode(GitConnectionSettingsSerialized.self, from: data)
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(settings)
        return FileWrapper(regularFileWithContents: data)
    }
}
