import Foundation
import Testing

@testable import Git
@testable import GitInit

@Suite("Repository Tests")
struct ConectionTests {

    let settings = GitConnectionSettings(
        remote: .init(string:"https://github.com/bdewey/AsyncSwiftGit"),
        username: "bdewey@gmail.com",
        email: "",
        password: "p@ssw0rd",
        isReadOnly: true
    )

    @Test("Password Protected Serialization Includes Password")
    func testPasswordProtectedSerializationIncludesPassword() throws {
        let deserializedSettings = try settings.roundtrip(password: "xyzzy")
        #expect(deserializedSettings == settings)
    }

    @Test("Normal Serialization Does Not Include Password")
    func testNormalSerializationDoesNotIncludePassword() throws {
        var expectedDeserializedSettings = settings
        expectedDeserializedSettings.password = ""

        let deserializedSettings = try settings.roundtrip(password: nil)
        #expect(deserializedSettings == expectedDeserializedSettings)
    }
}

extension GitConnectionSettings {
    
    func roundtrip(password: String?) throws -> GitConnectionSettings {
        let serializedSettings = try serialize(password: password)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let serialiedData = try encoder.encode(serializedSettings)
        print(String(data: serialiedData, encoding: .utf8)!)

        return try serializedSettings.deserialize(password: password)
    }
}
