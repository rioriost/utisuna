import Foundation
import Testing

struct TestFixture {
    let root: URL
    let sample: URL
    let app: URL

    var infoPlist: URL { app.appendingPathComponent("Contents/Info.plist") }
    var executable: URL { app.appendingPathComponent("Contents/MacOS/TestViewer") }

    init() throws {
        let fm = FileManager.default
        root = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build/utisuna-test-fixtures/\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        sample = root.appendingPathComponent("read me.txt")
        app = root.appendingPathComponent("Test Viewer.app", isDirectory: true)

        do {
            try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "hello\n".write(to: sample, atomically: true, encoding: .utf8)
            let info: [String: String] = [
                "CFBundleIdentifier": "org.example.utisuna.fixture.\(UUID().uuidString)",
                "CFBundleName": "Test Viewer",
                "CFBundlePackageType": "APPL",
                "CFBundleExecutable": "TestViewer",
                "CFBundleVersion": "1",
                "CFBundleInfoDictionaryVersion": "6.0",
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: infoPlist)
            try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        } catch {
            cleanUp()
            throw error
        }
    }

    func cleanUp() {
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            Issue.record(error, "Could not remove fixture at \(root.path)")
        }
    }

    func makePackageDocument() throws -> URL {
        let package = root.appendingPathComponent("Sample Document.rtfd", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try "{\\rtf1\\ansi Hello}\n".write(
            to: package.appendingPathComponent("TXT.rtf"), atomically: true, encoding: .utf8)
        return package
    }
}
