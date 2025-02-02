import SystemPackage
import XCTest
@testable import SwiftExperimentalSubprocess

// An API that uses a Subprocessable to run "ls" processes, overridable for testing purposes.
func listFiles<SP: Subprocessable>(_ subprocessable: SP.Type = Subprocess.self, dir: String) async throws -> [String] {
    let result = try await SP.run(
        .named("ls"),
        arguments: [dir],
        environment: .inherit,
        workingDirectory: nil,
        platformOptions: Subprocess.PlatformOptions(),
        input: .none,
        output: .string,
        error: .discarded
    )

    let output = result.standardOutput
    guard let output else { return [] }
    return output.split(separator: "\n").map({ $0.split(separator: "/").last ?? "" }).map(String.init)
}

// Override of Subprocess that provides alternative and mocked outputs for ls.
struct InProcessSubprocess: Subprocessable {
    static func ls(path: String) throws -> String {
        return try FileManager.default.contentsOfDirectory(atPath: path).joined(separator: "\n") + "\n"
    }

    static func run<
        Input: Subprocess.InputProtocol,
        Output: Subprocess.OutputProtocol,
        Error: Subprocess.OutputProtocol
    >(
        _ executable: Subprocess.Executable,
        arguments: Subprocess.Arguments,
        environment: Subprocess.Environment,
        workingDirectory: FilePath?,
        platformOptions: Subprocess.PlatformOptions,
        input: Input,
        output: Output,
        error: Error
    ) async throws -> Subprocess.CollectedResult<Output, Error> {
        switch(executable.configuration()) {
        case let .executable(program):
           switch(program) {
               case "ls":
                   return Subprocess.CollectedResult(
                       processIdentifier: .init(value: 1),
                       terminationStatus: .exited(0),
                       output: output,
                       error: error,
                       standardOutputData: Data(try Self.ls(path: arguments.args()[0]).utf8),
                       standardErrorData: Data()
                   )
               default:
                   fatalError("Not Implemented")
           }
        default:
            fatalError("Not Implemented")
        }
    }

    static func run<Result, Input: Subprocess.InputProtocol, Output: Subprocess.OutputProtocol, Error: Subprocess.OutputProtocol>(
        _ executable: Subprocess.Executable,
        arguments: Subprocess.Arguments,
        environment: Subprocess.Environment,
        workingDirectory: FilePath?,
        platformOptions: Subprocess.PlatformOptions,
        input: Input,
        output: Output,
        error: Error,
        isolation: isolated (any Actor)?,
        body: (@escaping (Subprocess.Execution<Input, Output, Error>) async throws -> Result)
    ) async throws -> Subprocess.ExecutionResult<Result> where Output.OutputType == Void, Error.OutputType == Void {
        fatalError("Not Implemented")
    }

    static func run<Result, Output: Subprocess.OutputProtocol, Error: Subprocess.OutputProtocol>(
        _ executable: Subprocess.Executable,
        arguments: Subprocess.Arguments,
        environment: Subprocess.Environment,
        workingDirectory: FilePath?,
        platformOptions: Subprocess.PlatformOptions,
        isolation: isolated (any Actor)?,
        output: Output,
        error: Error,
        body: (@escaping (Subprocess.Execution<Subprocess.CustomWriteInput, Output, Error>, Subprocess.StandardInputWriter) async throws -> Result)
    ) async throws -> Subprocess.ExecutionResult<Result> where Output.OutputType == Void, Error.OutputType == Void {
        fatalError("Not Implemented")
    }

    static func run<Result, Output: Subprocess.OutputProtocol, Error: Subprocess.OutputProtocol>(
        _ configuration: Subprocess.Configuration,
        isolation: isolated (any Actor)?,
        output: Output,
        error: Error,
        body: (@escaping (Subprocess.Execution<Subprocess.CustomWriteInput, Output, Error>, Subprocess.StandardInputWriter) async throws -> Result)
    ) async throws -> Subprocess.ExecutionResult<Result> where Output.OutputType == Void, Error.OutputType == Void {
        fatalError("Not Implemented")
    }

    static func runDetached(
        _ executable: Subprocess.Executable,
        arguments: Subprocess.Arguments,
        environment: Subprocess.Environment,
        workingDirectory: FilePath?,
        platformOptions: Subprocess.PlatformOptions,
        input: FileDescriptor?,
        output: FileDescriptor?,
        error: FileDescriptor?
    ) throws -> Subprocess.ProcessIdentifier {
        fatalError("Not Implemented")
    }

    static func runDetached(
        _ configuration: Subprocess.Configuration,
        input: FileDescriptor?,
        output: FileDescriptor?,
        error: FileDescriptor?
    ) throws -> Subprocess.ProcessIdentifier {
        fatalError("Not Implemented")
    }
}

// Comparative test suite
final class SubprocessableTests: XCTestCase {
    func testSubprocessPlatfomOptionsPreSpawnProcessConfigurator() async throws {
        // Create a sample directory with files in it
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("test-experimental-subprocess-\(randomString(length: 16))")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tmpDir.appendingPathComponent("bar.txt").path, contents: Data("".utf8))

        let filesOutProcess = try await listFiles(dir: tmpDir.path)
        XCTAssertEqual(filesOutProcess, ["bar.txt"])
        let filesInProcess = try await listFiles(InProcessSubprocess.self, dir: tmpDir.path)
        XCTAssertEqual(filesInProcess, ["bar.txt"])
    }
}
