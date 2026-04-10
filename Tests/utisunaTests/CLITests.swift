import Testing
@testable import utisuna

struct CLITests {
    @Test func parsesBasicArguments() throws {
        let options = try CLI.parse(arguments: ["/tmp/Makefile", "/Applications/Zed.app"])
        #expect(options == Options(sampleFilePath: "/tmp/Makefile", applicationPath: "/Applications/Zed.app", role: "all", dryRun: false, verbose: false))
    }

    @Test func parsesFlags() throws {
        let options = try CLI.parse(arguments: ["--dry-run", "--verbose", "--role", "editor", "/tmp/file", "/Applications/Zed.app"])
        #expect(options.dryRun)
        #expect(options.verbose)
        #expect(options.role == "editor")
    }

    @Test func rejectsInvalidRole() {
        #expect(throws: CLIError.invalidArguments("Unsupported role: banana. Use one of: all, editor, viewer, shell, none.")) {
            try CLI.parse(arguments: ["--role", "banana", "/tmp/file", "/Applications/Zed.app"])
        }
    }
}
