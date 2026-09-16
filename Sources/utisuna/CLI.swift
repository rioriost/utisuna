import Foundation

public struct Options: Equatable {
    public var sampleFilePath: String
    public var applicationPath: String
    public var role: String
    public var dryRun: Bool
    public var verbose: Bool

    public init(sampleFilePath: String, applicationPath: String, role: String = "all", dryRun: Bool = false, verbose: Bool = false) {
        self.sampleFilePath = sampleFilePath
        self.applicationPath = applicationPath
        self.role = role
        self.dryRun = dryRun
        self.verbose = verbose
    }
}

public enum CLIError: LocalizedError, Equatable {
    case helpRequested
    case versionRequested
    case invalidArguments(String)

    public var errorDescription: String? {
        switch self {
        case .helpRequested:
            return nil
        case .versionRequested:
            return nil
        case .invalidArguments(let message):
            return message
        }
    }
}

public enum CLI {
    public static let version = "0.1.2"

    public static func parse(arguments: [String]) throws -> Options {
        var positional: [String] = []
        var dryRun = false
        var verbose = false
        var role = "all"
        var endOfOptions = false

        var iterator = arguments.makeIterator()
        while let arg = iterator.next() {
            if endOfOptions {
                positional.append(arg)
                continue
            }

            switch arg {
            case "--":
                endOfOptions = true
            case "-h", "--help":
                throw CLIError.helpRequested
            case "-V", "--version":
                throw CLIError.versionRequested
            case "-n", "--dry-run":
                dryRun = true
            case "-v", "--verbose":
                verbose = true
            case "--role":
                guard let value = iterator.next(), !value.hasPrefix("-") else {
                    throw CLIError.invalidArguments("Missing value for --role.")
                }
                do {
                    role = try RoleMapper.normalize(value)
                } catch {
                    throw CLIError.invalidArguments(error.localizedDescription)
                }
            default:
                guard !arg.hasPrefix("-") || arg == "-" else {
                    throw CLIError.invalidArguments("Unknown option: \(arg). Use -- before paths that begin with '-'.")
                }
                positional.append(arg)
            }
        }

        guard positional.count == 2 else {
            throw CLIError.invalidArguments("Expected 2 positional arguments: <sample-file> <application.app>")
        }

        return Options(
            sampleFilePath: positional[0],
            applicationPath: positional[1],
            role: role,
            dryRun: dryRun,
            verbose: verbose
        )
    }

    public static func helpText(programName: String = "utisuna") -> String {
        """
        utisuna [うちすな]
        Set the default app for the content type of a sample file.

        USAGE:
          \(programName) [--dry-run] [--verbose] [--role all] [--] <sample-file> <application.app>
          \(programName) --help
          \(programName) --version

        EXAMPLES:
          \(programName) /path/to/Makefile /Applications/Zed.app
          \(programName) --dry-run ~/work/Makefile /Applications/Zed.app
          \(programName) --verbose ./README.md /Applications/BBEdit.app
          \(programName) -- -sample.txt /Applications/BBEdit.app

        NOTES:
          - The sample must be a regular file or a recognized package document (such as .rtfd).
          - The sample is used only to resolve its content type; the app must be a valid application bundle.
          - The change applies to that content type, not only to one file path.
          - --role all is a compatibility option; role-specific changes are unsupported.
          - --dry-run validates paths and resolves the type without changing defaults.
          - --verbose adds scope and macOS confirmation diagnostics.
          - Use -- to end options before paths that begin with '-'.
          - On recent macOS versions, the system may show a confirmation prompt.
        """
    }
}
