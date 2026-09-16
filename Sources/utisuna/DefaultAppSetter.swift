import Foundation
import UniformTypeIdentifiers

#if canImport(AppKit)
    import AppKit
#endif

public struct ResolvedPaths: Equatable {
    public let sampleFileURL: URL
    public let applicationURL: URL

    public init(sampleFileURL: URL, applicationURL: URL) {
        self.sampleFileURL = sampleFileURL
        self.applicationURL = applicationURL
    }
}

public struct ResolvedType: Equatable {
    public let identifier: String
    public let description: String

    public init(identifier: String, description: String) {
        self.identifier = identifier
        self.description = description
    }
}

public enum PathResolutionError: LocalizedError, Equatable {
    case sampleFileNotFound(String)
    case applicationNotFound(String)
    case invalidSampleFile(String)
    case notAnApplicationBundle(String)
    case pathInspectionFailed(String, String)
    case unsupportedRole(String)
    case contentTypeNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .sampleFileNotFound(let path):
            return "Sample file not found: \(path)"
        case .applicationNotFound(let path):
            return "Application not found: \(path)"
        case .invalidSampleFile(let path):
            return "Sample must be a regular file or a recognized package document (such as .rtfd): \(path)"
        case .notAnApplicationBundle(let path):
            return "Not a valid application bundle (.app) with application metadata and an executable: \(path)"
        case .pathInspectionFailed(let path, let reason):
            return "Could not inspect path \(path): \(reason)"
        case .unsupportedRole(let role):
            return "Unsupported role: \(role). Role-specific changes are unsupported; use --role all or omit --role."
        case .contentTypeNotFound(let path):
            return "Could not resolve content type for: \(path)"
        }
    }
}

public enum RoleMapper {
    public static func normalize(_ role: String) throws -> String {
        let normalized = role.lowercased()
        guard normalized == "all" else {
            throw PathResolutionError.unsupportedRole(role)
        }
        return normalized
    }
}

public enum PathResolver {
    public static func resolve(sampleFilePath: String, applicationPath: String) throws
        -> ResolvedPaths
    {
        let sampleURL = URL(fileURLWithPath: (sampleFilePath as NSString).expandingTildeInPath)
            .standardizedFileURL.resolvingSymlinksInPath()
        let appURL = URL(fileURLWithPath: (applicationPath as NSString).expandingTildeInPath)
            .standardizedFileURL.resolvingSymlinksInPath()
        let fm = FileManager.default

        try validateSample(at: sampleURL, displayPath: sampleFilePath)
        guard fm.fileExists(atPath: appURL.path) else {
            throw PathResolutionError.applicationNotFound(applicationPath)
        }
        let appValues = try resourceValues(for: appURL, keys: [.isDirectoryKey])
        guard appValues.isDirectory == true,
            appURL.pathExtension.lowercased() == "app",
            let bundle = Bundle(url: appURL),
            bundle.infoDictionary?["CFBundlePackageType"] as? String == "APPL",
            let identifier = bundle.bundleIdentifier, !identifier.isEmpty,
            let executableURL = bundle.executableURL,
            fm.fileExists(atPath: executableURL.path)
        else {
            throw PathResolutionError.notAnApplicationBundle(applicationPath)
        }
        let executableValues = try resourceValues(
            for: executableURL.resolvingSymlinksInPath(), keys: [.isRegularFileKey])
        guard executableValues.isRegularFile == true,
            fm.isExecutableFile(atPath: executableURL.path)
        else {
            throw PathResolutionError.notAnApplicationBundle(applicationPath)
        }

        return ResolvedPaths(sampleFileURL: sampleURL, applicationURL: appURL)
    }

    public static func resolveType(for sampleFileURL: URL) throws -> ResolvedType {
        let sampleURL = sampleFileURL.standardizedFileURL.resolvingSymlinksInPath()
        try validateSample(at: sampleURL, displayPath: sampleFileURL.path)
        let values = try resourceValues(for: sampleURL, keys: [.contentTypeKey])
        guard let contentType = values.contentType else {
            throw PathResolutionError.contentTypeNotFound(sampleFileURL.path)
        }
        return ResolvedType(
            identifier: contentType.identifier,
            description: contentType.localizedDescription ?? contentType.identifier
        )
    }

    private static func validateSample(at url: URL, displayPath: String) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PathResolutionError.sampleFileNotFound(displayPath)
        }
        let values = try resourceValues(
            for: url, keys: [.isRegularFileKey, .isDirectoryKey, .isPackageKey])
        if values.isRegularFile == true {
            return
        }
        if values.isDirectory == true, values.isPackage == true {
            let typeValues = try resourceValues(for: url, keys: [.contentTypeKey])
            if let type = typeValues.contentType,
                type.conforms(to: .package), type.conforms(to: .content)
            {
                return
            }
        }
        throw PathResolutionError.invalidSampleFile(displayPath)
    }

    private static func resourceValues(for url: URL, keys: Set<URLResourceKey>) throws
        -> URLResourceValues
    {
        do {
            return try url.resourceValues(forKeys: keys)
        } catch {
            throw PathResolutionError.pathInspectionFailed(url.path, error.localizedDescription)
        }
    }
}

public protocol DefaultApplicationSetting {
    func setDefaultApplication(appURL: URL, sampleFileURL: URL) async throws
}

#if canImport(AppKit)
    @available(macOS 12.0, *)
    public final class WorkspaceDefaultApplicationSetter: DefaultApplicationSetting {
        public init() {}

        public func setDefaultApplication(appURL: URL, sampleFileURL: URL) async throws {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.setDefaultApplication(
                    at: appURL, toOpenContentTypeOfFileAt: sampleFileURL
                ) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }
#endif
