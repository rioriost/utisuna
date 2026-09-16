import Foundation
import Testing
@testable import utisuna

enum SetterFailure: Error, Equatable {
    case rejected
}

final class MockSetter: DefaultApplicationSetting {
    var invocationCount = 0
    var lastAppURL: URL?
    var lastSampleURL: URL?
    var failure: SetterFailure?

    func setDefaultApplication(appURL: URL, sampleFileURL: URL) async throws {
        invocationCount += 1
        lastAppURL = appURL
        lastSampleURL = sampleFileURL
        if let failure {
            throw failure
        }
    }
}

struct RunnerTests {
    @Test func dryRunDoesNotInvokeSetter() async throws {
        let fixture = try TestFixture()
        defer { fixture.cleanUp() }
        let setter = MockSetter()
        setter.failure = .rejected

        let output = try await Runner.execute(
            options: Options(sampleFilePath: fixture.sample.path, applicationPath: fixture.app.path, dryRun: true),
            setter: setter
        )
        let type = try PathResolver.resolveType(for: fixture.sample)

        #expect(setter.invocationCount == 0)
        #expect(output.lines == [
            "sample file : \(fixture.sample.path)",
            "application : \(fixture.app.path)",
            "content type: \(type.identifier) (\(type.description))",
            "role       : all",
            "status     : dry run, no changes made",
        ])
    }

    @Test func runnerInvokesSetter() async throws {
        let fixture = try TestFixture()
        defer { fixture.cleanUp() }
        let setter = MockSetter()

        let output = try await Runner.execute(
            options: Options(sampleFilePath: fixture.sample.path, applicationPath: fixture.app.path),
            setter: setter
        )
        let type = try PathResolver.resolveType(for: fixture.sample)

        #expect(setter.invocationCount == 1)
        #expect(setter.lastAppURL == fixture.app)
        #expect(setter.lastSampleURL == fixture.sample)
        #expect(output.lines == [
            "sample file : \(fixture.sample.path)",
            "application : \(fixture.app.path)",
            "content type: \(type.identifier) (\(type.description))",
            "role       : all",
            "status     : default application updated",
        ])
    }

    @Test func propagatesSetterFailure() async throws {
        let fixture = try TestFixture()
        defer { fixture.cleanUp() }
        let setter = MockSetter()
        setter.failure = .rejected

        await #expect(throws: SetterFailure.rejected) {
            _ = try await Runner.execute(
                options: Options(sampleFilePath: fixture.sample.path, applicationPath: fixture.app.path),
                setter: setter
            )
        }
        #expect(setter.invocationCount == 1)
    }

    @Test(arguments: [false, true])
    func verboseAddsOnlyDiagnostics(dryRun: Bool) async throws {
        let fixture = try TestFixture()
        defer { fixture.cleanUp() }
        let normalSetter = MockSetter()
        let verboseSetter = MockSetter()
        var options = Options(sampleFilePath: fixture.sample.path, applicationPath: fixture.app.path, dryRun: dryRun)
        let normal = try await Runner.execute(options: options, setter: normalSetter)
        options.verbose = true
        let verbose = try await Runner.execute(options: options, setter: verboseSetter)

        #expect(verbose.lines.count == normal.lines.count + 2)
        #expect(verbose.lines.contains("scope      : all files with this content type, not a per-file or role-specific change"))
        #expect(verbose.lines.contains(where: { $0.hasPrefix("confirmation:") && $0.contains("macOS") }))
        #expect(verbose.lines.filter { !$0.hasPrefix("scope ") && !$0.hasPrefix("confirmation:") } == normal.lines)
        #expect(normalSetter.invocationCount == (dryRun ? 0 : 1))
        #expect(verboseSetter.invocationCount == normalSetter.invocationCount)
        if dryRun {
            #expect(verbose.lines.contains(where: { $0.contains("no request sent to macOS in dry run") }))
        }
    }

    @Test(arguments: ["editor", "viewer", "shell", "none", "banana", "Editor", "", "all "], [false, true])
    func rejectsDirectUnsupportedRolesBeforePathsOrSetter(role: String, dryRun: Bool) async {
        let setter = MockSetter()
        await #expect(throws: PathResolutionError.unsupportedRole(role)) {
            _ = try await Runner.execute(
                options: Options(sampleFilePath: "./does-not-exist", applicationPath: "./missing.app", role: role, dryRun: dryRun),
                setter: setter
            )
        }
        #expect(setter.invocationCount == 0)
    }

    @Test func directOptionsNormalizeCompatibilityRole() async throws {
        let fixture = try TestFixture()
        defer { fixture.cleanUp() }
        let setter = MockSetter()
        let output = try await Runner.execute(
            options: Options(sampleFilePath: fixture.sample.path, applicationPath: fixture.app.path, role: "ALL"),
            setter: setter
        )
        #expect(output.lines.contains("role       : all"))
        #expect(setter.invocationCount == 1)
    }

    @Test(arguments: [false, true])
    func propagatesPathFailureWithoutInvokingSetter(dryRun: Bool) async throws {
        let fixture = try TestFixture()
        defer { fixture.cleanUp() }
        let setter = MockSetter()
        await #expect(throws: PathResolutionError.invalidSampleFile(fixture.root.path)) {
            _ = try await Runner.execute(
                options: Options(sampleFilePath: fixture.root.path, applicationPath: fixture.app.path, dryRun: dryRun),
                setter: setter
            )
        }
        #expect(setter.invocationCount == 0)
    }

    @Test func acceptsPackageDocumentWithMockSetter() async throws {
        let fixture = try TestFixture()
        defer { fixture.cleanUp() }
        let package = try fixture.makePackageDocument()
        let setter = MockSetter()
        _ = try await Runner.execute(
            options: Options(sampleFilePath: package.path, applicationPath: fixture.app.path),
            setter: setter
        )
        #expect(setter.invocationCount == 1)
        #expect(setter.lastSampleURL == package)
    }
}
