import Foundation

let programName = URL(fileURLWithPath: CommandLine.arguments.first ?? "utisuna").lastPathComponent

do {
    let options = try CLI.parse(arguments: Array(CommandLine.arguments.dropFirst()))

    #if canImport(AppKit)
        if #available(macOS 12.0, *) {
            let output = try await Runner.execute(
                options: options,
                setter: WorkspaceDefaultApplicationSetter()
            )
            for line in output.lines {
                print(line)
            }
            Foundation.exit(EXIT_SUCCESS)
        } else {
            fputs("utisuna requires macOS 12 or later.\n", stderr)
            Foundation.exit(EXIT_FAILURE)
        }
    #else
        fputs("utisuna requires AppKit and must be built on macOS.\n", stderr)
        Foundation.exit(EXIT_FAILURE)
    #endif
} catch CLIError.helpRequested {
    print(CLI.helpText(programName: programName))
    Foundation.exit(EXIT_SUCCESS)
} catch CLIError.versionRequested {
    print(CLI.version)
    Foundation.exit(EXIT_SUCCESS)
} catch {
    fputs("Error: \(error.localizedDescription)\n\n", stderr)
    fputs(CLI.helpText(programName: programName) + "\n", stderr)
    Foundation.exit(EXIT_FAILURE)
}
