import Foundation

public struct OutputLines: Equatable {
    public let lines: [String]

    public init(lines: [String]) {
        self.lines = lines
    }
}

public enum Runner {
    public static func execute(options: Options, setter: DefaultApplicationSetting) async throws -> OutputLines {
        _ = try RoleMapper.normalize(options.role)
        let resolved = try PathResolver.resolve(sampleFilePath: options.sampleFilePath, applicationPath: options.applicationPath)
        let type = try PathResolver.resolveType(for: resolved.sampleFileURL)

        var lines: [String] = []
        lines.append("sample file : \(resolved.sampleFileURL.path)")
        lines.append("application : \(resolved.applicationURL.path)")
        lines.append("content type: \(type.identifier) (\(type.description))")
        lines.append("role       : \(options.role)")

        if options.dryRun {
            lines.append("status     : dry run, no changes made")
            return OutputLines(lines: lines)
        }

        try await setter.setDefaultApplication(appURL: resolved.applicationURL, sampleFileURL: resolved.sampleFileURL)
        lines.append("status     : default application updated")
        return OutputLines(lines: lines)
    }
}
