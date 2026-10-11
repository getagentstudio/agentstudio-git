import AgentStudioGit
import Foundation
import Testing

@Suite("Git status options contracts")
struct GitStatusOptionsContractTests {
    @Test("submodule exclusion round-trips with scoped options", arguments: [false, true])
    func submoduleExclusionRoundTrips(excludeSubmodules: Bool) throws {
        // Arrange
        let options = GitStatusOptions(
            includeIgnored: true,
            includeUntracked: false,
            pathspecs: ["src", "Vendor/Child"],
            excludeSubmodules: excludeSubmodules
        )

        // Act
        let encoded = try JSONEncoder().encode(options)
        let decoded = try JSONDecoder().decode(GitStatusOptions.self, from: encoded)
        let encodedText = try #require(String(data: encoded, encoding: .utf8))

        // Assert
        #expect(decoded == options)
        #expect(encodedText.contains("\"excludeSubmodules\":true") == excludeSubmodules)
        #expect(!GitStatusOptions().excludeSubmodules)
    }

    @Test(
        "payloads without submodule exclusion preserve existing options",
        arguments: [
            #"{"includeIgnored":false,"includeUntracked":true}"#,
            #"{"includeIgnored":true,"includeUntracked":false,"pathspecs":["src"]}"#,
        ]
    )
    func missingSubmoduleExclusionDecodesAsFalse(payload: String) throws {
        // Arrange
        let encoded = Data(payload.utf8)

        // Act
        let options = try JSONDecoder().decode(GitStatusOptions.self, from: encoded)

        // Assert
        #expect(!options.excludeSubmodules)
        if payload.contains("pathspecs") {
            #expect(options.includeIgnored)
            #expect(!options.includeUntracked)
            #expect(options.pathspecs == ["src"])
        } else {
            #expect(options == GitStatusOptions())
        }
    }
}
