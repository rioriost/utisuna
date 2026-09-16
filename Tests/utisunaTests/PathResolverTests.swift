import Darwin
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import utisuna

struct PathResolverTests {
    @Test func resolvesValidApplicationAndSpacedFilePaths() throws {
        let fixture = try TestFixture()
        defer { fixture.cleanUp() }

        let paths = try PathResolver.resolve(sampleFilePath: fixture.sample.path, applicationPath: fixture.app.path)
        #expect(paths.sampleFileURL == fixture.sample)
        #expect(paths.applicationURL == fixture.app)
        let type = try PathResolver.resolveType(for: paths.sampleFileURL)
        #expect(type.identifier == UTType.plainText.identifier)
        #expect(!type.description.isEmpty)
    }

    @Test func resolvesRelativePathsWithoutChangingWorkingDirectory() throws {
        let fixture = try TestFixture()
        defer { fixture.cleanUp() }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .standardizedFileURL.resolvingSymlinksInPath().path
        let samplePath = "./" + fixture.sample.path.dropFirst(cwd.count + 1)
        let appPath = "./" + fixture.app.path.dropFirst(cwd.count + 1)

        let paths = try PathResolver.resolve(sampleFilePath: samplePath, applicationPath: appPath)
        #expect(paths.sampleFileURL == fixture.sample)
        #expect(paths.applicationURL == fixture.app)
    }

    @Test func expandsTildePaths() throws {
        let fixture = try TestFixture()
        defer { fixture.cleanUp() }
        let home = FileManager.default.homeDirectoryForCurrentUser
        func tildePath(for url: URL) -> String {
            if url.path.hasPrefix(home.path + "/") {
                return "~" + url.path.dropFirst(home.path.count)
            }
            let parents = Array(repeating: "..", count: home.pathComponents.count - 1).joined(separator: "/")
            return "~/\(parents)\(url.path)"
        }

        let paths = try PathResolver.resolve(
            sampleFilePath: tildePath(for: fixture.sample), applicationPath: tildePath(for: fixture.app))
        #expect(paths.sampleFileURL == fixture.sample)
        #expect(paths.applicationURL == fixture.app)
    }

    @Test func followsSampleAndApplicationSymlinks() throws {
        let fixture = try TestFixture()
        defer { fixture.cleanUp() }
        let sampleLink = fixture.root.appendingPathComponent("sample link")
        let appLink = fixture.root.appendingPathComponent("app link")
        try FileManager.default.createSymbolicLink(at: sampleLink, withDestinationURL: fixture.sample)
        try FileManager.default.createSymbolicLink(at: appLink, withDestinationURL: fixture.app)

        let paths = try PathResolver.resolve(sampleFilePath: sampleLink.path, applicationPath: appLink.path)
        #expect(paths.sampleFileURL == fixture.sample)
        #expect(paths.applicationURL.path == fixture.app.path)
        #expect(try PathResolver.resolveType(for: sampleLink).identifier == UTType.plainText.identifier)
    }

    @Test func acceptsRecognizedPackageDocuments() throws {
        let fixture = try TestFixture()
        defer { fixture.cleanUp() }
        let package = try fixture.makePackageDocument()
        let paths = try PathResolver.resolve(sampleFilePath: package.path, applicationPath: fixture.app.path)
        #expect(paths.sampleFileURL == package)
        #expect(try PathResolver.resolveType(for: package).identifier == UTType.rtfd.identifier)
    }

    @Test func followsPackageDocumentSymlinks() throws {
        let fixture = try TestFixture()
        defer { fixture.cleanUp() }
        let package = try fixture.makePackageDocument()
        let link = fixture.root.appendingPathComponent("package link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: package)

        let paths = try PathResolver.resolve(sampleFilePath: link.path, applicationPath: fixture.app.path)
        #expect(paths.sampleFileURL.path == package.path)
        #expect(try PathResolver.resolveType(for: link).identifier == UTType.rtfd.identifier)
    }

    @Test func rejectsMissingSample() throws {
        let fixture = try TestFixture()
        defer { fixture.cleanUp() }
        let missing = fixture.root.appendingPathComponent("missing.txt")
        #expect(throws: PathResolutionError.sampleFileNotFound(missing.path)) {
            try PathResolver.resolve(sampleFilePath: missing.path, applicationPath: fixture.app.path)
        }
        #expect(throws: PathResolutionError.sampleFileNotFound(missing.path)) {
            try PathResolver.resolveType(for: missing)
        }
    }

    @Test func rejectsMissingApplication() throws {
        let fixture = try TestFixture()
        defer { fixture.cleanUp() }
        let missing = fixture.root.appendingPathComponent("Missing.app")
        #expect(throws: PathResolutionError.applicationNotFound(missing.path)) {
            try PathResolver.resolve(sampleFilePath: fixture.sample.path, applicationPath: missing.path)
        }
    }

    @Test(arguments: ["folder", "misleading.txt"])
    func rejectsOrdinaryDirectorySamples(name: String) throws {
        let fixture = try TestFixture()
        defer { fixture.cleanUp() }
        let directory = fixture.root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(throws: PathResolutionError.invalidSampleFile(directory.path)) {
            try PathResolver.resolve(sampleFilePath: directory.path, applicationPath: fixture.app.path)
        }
        #expect(throws: PathResolutionError.invalidSampleFile(directory.path)) {
            try PathResolver.resolveType(for: directory)
        }
    }

    @Test func rejectsApplicationAsSampleDocument() throws {
        let fixture = try TestFixture()
        defer { fixture.cleanUp() }
        #expect(throws: PathResolutionError.invalidSampleFile(fixture.app.path)) {
            try PathResolver.resolve(sampleFilePath: fixture.app.path, applicationPath: fixture.app.path)
        }
    }

    @Test func rejectsSpecialFileSamples() throws {
        let fixture = try TestFixture()
        defer { fixture.cleanUp() }
        let fifo = fixture.root.appendingPathComponent("pipe.txt")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: PathResolutionError.invalidSampleFile(fifo.path)) {
            try PathResolver.resolve(sampleFilePath: fifo.path, applicationPath: fixture.app.path)
        }
        #expect(throws: PathResolutionError.invalidSampleFile(fifo.path)) {
            try PathResolver.resolveType(for: fifo)
        }
    }

    @Test func rejectsSymlinkToOrdinaryDirectory() throws {
        let fixture = try TestFixture()
        defer { fixture.cleanUp() }
        let link = fixture.root.appendingPathComponent("folder-link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.root)
        #expect(throws: PathResolutionError.invalidSampleFile(link.path)) {
            try PathResolver.resolve(sampleFilePath: link.path, applicationPath: fixture.app.path)
        }
    }

    @Test func rejectsBrokenSymlinks() throws {
        let fixture = try TestFixture()
        defer { fixture.cleanUp() }
        let link = fixture.root.appendingPathComponent("broken.app")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: fixture.root.appendingPathComponent("missing"))
        #expect(throws: PathResolutionError.sampleFileNotFound(link.path)) {
            try PathResolver.resolve(sampleFilePath: link.path, applicationPath: fixture.app.path)
        }
        #expect(throws: PathResolutionError.applicationNotFound(link.path)) {
            try PathResolver.resolve(sampleFilePath: fixture.sample.path, applicationPath: link.path)
        }
    }

    @Test func rejectsFileNamedApp() throws {
        let fixture = try TestFixture()
        defer { fixture.cleanUp() }
        let file = fixture.root.appendingPathComponent("Not A Bundle.app")
        try "not an application".write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: PathResolutionError.notAnApplicationBundle(file.path)) {
            try PathResolver.resolve(sampleFilePath: fixture.sample.path, applicationPath: file.path)
        }
    }

    @Test(arguments: ["Empty.app", "NotApp"])
    func rejectsEmptyApplicationDirectories(name: String) throws {
        let fixture = try TestFixture()
        defer { fixture.cleanUp() }
        let directory = fixture.root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(throws: PathResolutionError.notAnApplicationBundle(directory.path)) {
            try PathResolver.resolve(sampleFilePath: fixture.sample.path, applicationPath: directory.path)
        }
    }

    @Test(arguments: ["missing-plist", "invalid-plist", "wrong-package-type", "missing-identifier",
                      "missing-executable", "nonexecutable-file", "executable-directory"])
    func rejectsMalformedApplicationBundles(defect: String) throws {
        let fixture = try TestFixture()
        defer { fixture.cleanUp() }
        let fm = FileManager.default
        switch defect {
        case "missing-plist":
            try fm.removeItem(at: fixture.infoPlist)
        case "invalid-plist":
            try "not a property list".write(to: fixture.infoPlist, atomically: true, encoding: .utf8)
        case "wrong-package-type", "missing-identifier":
            var info = try #require(
                PropertyListSerialization.propertyList(
                    from: Data(contentsOf: fixture.infoPlist), options: [], format: nil) as? [String: String])
            if defect == "wrong-package-type" {
                info["CFBundlePackageType"] = "BNDL"
            } else {
                info.removeValue(forKey: "CFBundleIdentifier")
            }
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: fixture.infoPlist)
        case "missing-executable":
            try fm.removeItem(at: fixture.executable)
        case "nonexecutable-file":
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.executable.path)
        case "executable-directory":
            try fm.removeItem(at: fixture.executable)
            try fm.createDirectory(at: fixture.executable, withIntermediateDirectories: false)
        default:
            Issue.record("Unknown application fixture defect: \(defect)")
        }

        #expect(throws: PathResolutionError.notAnApplicationBundle(fixture.app.path)) {
            try PathResolver.resolve(sampleFilePath: fixture.sample.path, applicationPath: fixture.app.path)
        }
    }
}
