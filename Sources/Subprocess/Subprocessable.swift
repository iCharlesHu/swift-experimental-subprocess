import SystemPackage
#if canImport(FoundationEssentials)
import FoundationEssentials
#elseif canImport(Foundation)
import Foundation
#endif

public protocol Subprocessable {
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
    ) async throws -> Subprocess.CollectedResult<Output, Error>

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
    ) async throws -> Subprocess.ExecutionResult<Result> where Output.OutputType == Void, Error.OutputType == Void

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
    ) async throws -> Subprocess.ExecutionResult<Result> where Output.OutputType == Void, Error.OutputType == Void

    static func run<Result, Output: Subprocess.OutputProtocol, Error: Subprocess.OutputProtocol>(
        _ configuration: Subprocess.Configuration,
        isolation: isolated (any Actor)?,
        output: Output,
        error: Error,
        body: (@escaping (Subprocess.Execution<Subprocess.CustomWriteInput, Output, Error>, Subprocess.StandardInputWriter) async throws -> Result)
    ) async throws -> Subprocess.ExecutionResult<Result> where Output.OutputType == Void, Error.OutputType == Void

    static func runDetached(
        _ executable: Subprocess.Executable,
        arguments: Subprocess.Arguments,
        environment: Subprocess.Environment,
        workingDirectory: FilePath?,
        platformOptions: Subprocess.PlatformOptions,
        input: FileDescriptor?,
        output: FileDescriptor?,
        error: FileDescriptor?
    ) throws -> Subprocess.ProcessIdentifier

    static func runDetached(
        _ configuration: Subprocess.Configuration,
        input: FileDescriptor?,
        output: FileDescriptor?,
        error: FileDescriptor?
    ) throws -> Subprocess.ProcessIdentifier
}
