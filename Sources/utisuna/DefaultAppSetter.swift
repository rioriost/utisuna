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
    case notAnApplicationBundle(String)
    case unsupportedRole(String)
    case contentTypeNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .sampleFileNotFound(let path):
            return "Sample file not found: \(path)"
        case .applicationNotFound(let path):
            return "Application not found: \(path)"
        case .notAnApplicationBundle(let path):
            return "Not an application bundle (.app): \(path)"
        case .unsupportedRole(let role):
            return "Unsupported role: \(role)"
        case .contentTypeNotFound(let path):
            return "Could not resolve content type for: \(path)"
        }
    }
}

public enum RoleMapper {
    public static func normalize(_ role: String) throws -> String {
        let normalized = role.lowercased()
        guard ["all", "editor", "viewer", "shell", "none"].contains(normalized) else {
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
            .standardizedFileURL
        let appURL = URL(fileURLWithPath: (applicationPath as NSString).expandingTildeInPath)
            .standardizedFileURL
        let fm = FileManager.default

        guard fm.fileExists(atPath: sampleURL.path) else {
            throw PathResolutionError.sampleFileNotFound(sampleFilePath)
        }
        guard fm.fileExists(atPath: appURL.path) else {
            throw PathResolutionError.applicationNotFound(applicationPath)
        }
        guard appURL.pathExtension.lowercased() == "app" else {
            throw PathResolutionError.notAnApplicationBundle(applicationPath)
        }

        return ResolvedPaths(sampleFileURL: sampleURL, applicationURL: appURL)
    }

    public static func resolveType(for sampleFileURL: URL) throws -> ResolvedType {
        let values = try sampleFileURL.resourceValues(forKeys: [.contentTypeKey])
        guard let contentType = values.contentType else {
            throw PathResolutionError.contentTypeNotFound(sampleFileURL.path)
        }
        return ResolvedType(
            identifier: contentType.identifier,
            description: contentType.localizedDescription ?? contentType.identifier
        )
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
