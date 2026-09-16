import Testing
@testable import utisuna

struct CLITests {
    @Test func parsesBasicArguments() throws {
        let options = try CLI.parse(arguments: ["./Makefile", "/Applications/Zed.app"])
        #expect(options == Options(sampleFilePath: "./Makefile", applicationPath: "/Applications/Zed.app"))
    }

    @Test(arguments: [["--dry-run", "--verbose"], ["-n", "-v"]])
    func parsesFlags(flags: [String]) throws {
        let options = try CLI.parse(arguments: flags + ["--role", "all", "./file", "/Applications/Zed.app"])
        #expect(options.dryRun)
        #expect(options.verbose)
        #expect(options.role == "all")
    }

    @Test(arguments: ["all", "ALL", "All"])
    func normalizesCompatibilityRole(role: String) throws {
        let options = try CLI.parse(arguments: ["--role", role, "./file", "./Viewer.app"])
        #expect(options.role == "all")
        #expect(try RoleMapper.normalize(role) == options.role)
    }

    @Test(arguments: ["editor", "viewer", "shell", "none", "banana", "Editor", "", "all "])
    func rejectsUnsupportedRoles(role: String) {
        let message = PathResolutionError.unsupportedRole(role).localizedDescription
        #expect(message.contains("Role-specific changes are unsupported"))
        #expect(throws: CLIError.invalidArguments(message)) {
            try CLI.parse(arguments: ["--role", role, "./file", "./Viewer.app"])
        }
    }

    @Test func rejectsUnsupportedRoleEvenWhenFollowedByAll() {
        #expect(throws: CLIError.self) {
            try CLI.parse(arguments: ["--role", "editor", "--role", "all", "./file", "./Viewer.app"])
        }
    }

    @Test(arguments: ["-h", "--help"])
    func requestsHelp(flag: String) {
        #expect(throws: CLIError.helpRequested) {
            try CLI.parse(arguments: [flag])
        }
    }

    @Test(arguments: ["-V", "--version"])
    func requestsVersion(flag: String) {
        #expect(throws: CLIError.versionRequested) {
            try CLI.parse(arguments: [flag])
        }
        #expect(CLI.version == "0.1.3")
    }

    @Test func helpDescribesImplementedBehavior() {
        let help = CLI.helpText(programName: "custom-utisuna")
        #expect(help.contains("custom-utisuna [--dry-run] [--verbose] [--role all] [--]"))
        #expect(help.contains("custom-utisuna --help"))
        #expect(help.contains("custom-utisuna --version"))
        #expect(help.contains("role-specific changes are unsupported"))
        #expect(help.contains("--verbose adds scope and macOS confirmation diagnostics"))
        #expect(help.contains("recognized package document"))
        #expect(!help.contains("--role editor"))
        #expect(!help.contains("all|editor"))
    }

    @Test(arguments: [[], ["file"], ["file", "Viewer.app", "extra"]])
    func rejectsBadArgumentCounts(arguments: [String]) {
        #expect(throws: CLIError.invalidArguments("Expected 2 positional arguments: <sample-file> <application.app>")) {
            try CLI.parse(arguments: arguments)
        }
    }

    @Test(arguments: [["--role"], ["--role", "--dry-run"], ["--role", "--"]])
    func rejectsMissingRoleValue(arguments: [String]) {
        #expect(throws: CLIError.invalidArguments("Missing value for --role.")) {
            try CLI.parse(arguments: arguments)
        }
    }

    @Test(arguments: ["--unknown", "-x", "--dry-rnu", "-sample.txt"])
    func rejectsUnknownOptions(option: String) {
        #expect(throws: CLIError.invalidArguments("Unknown option: \(option). Use -- before paths that begin with '-'.")) {
            try CLI.parse(arguments: [option, "./file", "./Viewer.app"])
        }
    }

    @Test func endOfOptionsPreservesLiteralDashPaths() throws {
        let options = try CLI.parse(arguments: ["-n", "--", "-sample.txt", "--help"])
        #expect(options.sampleFilePath == "-sample.txt")
        #expect(options.applicationPath == "--help")
        #expect(options.dryRun)
        #expect(!options.verbose)
    }

    @Test func flagsCanFollowPositionalArguments() throws {
        let options = try CLI.parse(arguments: ["./file", "./Viewer.app", "-v", "-n"])
        #expect(options.verbose)
        #expect(options.dryRun)
    }

    @Test func bareDashIsAPositionalPath() throws {
        let options = try CLI.parse(arguments: ["-", "./Viewer.app"])
        #expect(options.sampleFilePath == "-")
    }
}
