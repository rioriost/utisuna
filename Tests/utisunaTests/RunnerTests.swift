import Foundation
import Testing
@testable import utisuna

final class MockSetter: DefaultApplicationSetting {
    var invocationCount = 0
    var lastAppURL: URL?
    var lastSampleURL: URL?

    func setDefaultApplication(appURL: URL, sampleFileURL: URL) async throws {
        invocationCount += 1
        lastAppURL = appURL
        lastSampleURL = sampleFileURL
    }
}

struct RunnerTests {
    @Test func dryRunDoesNotInvokeSetter() async throws {
        let tempDir = try makeTempFixture()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sample = tempDir.appendingPathComponent("Makefile")
        try "all:\n\techo hi\n".write(to: sample, atomically: true, encoding: .utf8)

        let app = tempDir.appendingPathComponent("Fake.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)

        let setter = MockSetter()
        let output = try await Runner.execute(
            options: Options(sampleFilePath: sample.path, applicationPath: app.path, dryRun: true),
            setter: setter
        )

        #expect(setter.invocationCount == 0)
        #expect(output.lines.contains(where: { $0.contains("dry run") }))
    }

    @Test func runnerInvokesSetter() async throws {
        let tempDir = try makeTempFixture()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sample = tempDir.appendingPathComponent("readme.txt")
        try "hello\n".write(to: sample, atomically: true, encoding: .utf8)

        let app = tempDir.appendingPathComponent("Fake.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)

        let setter = MockSetter()
        _ = try await Runner.execute(
            options: Options(sampleFilePath: sample.path, applicationPath: app.path),
            setter: setter
        )

        #expect(setter.invocationCount == 1)
        #expect(setter.lastAppURL?.path == app.path)
        #expect(setter.lastSampleURL?.path == sample.path)
    }

    @Test func pathResolverRejectsNonAppBundle() throws {
        let tempDir = try makeTempFixture()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sample = tempDir.appendingPathComponent("readme.txt")
        try "hello\n".write(to: sample, atomically: true, encoding: .utf8)

        let app = tempDir.appendingPathComponent("NotApp")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)

        #expect(throws: PathResolutionError.notAnApplicationBundle(app.path)) {
            try PathResolver.resolve(sampleFilePath: sample.path, applicationPath: app.path)
        }
    }

    private func makeTempFixture() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}
