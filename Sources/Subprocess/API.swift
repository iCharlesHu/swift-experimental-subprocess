//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

#if canImport(System)
import System
#else
@preconcurrency import SystemPackage
#endif


// MARK: - Collected Result

/// Run a executable with given parameters and a custom closure
/// to manage the running subprocess' lifetime and its IOs.
/// - Parameters:
///   - executable: The executable to run.
///   - arguments: The arguments to pass to the executable.
///   - environment: The environment in which to run the executable.
///   - workingDirectory: The working directory in which to run the executable.
///   - platformOptions: The platform specific options to use
///     when running the executable.
///   - input: The input to send to the executable.
///   - output: The method to use for redirecting the standard output.
///   - error: The method to use for redirecting the standard error.
/// - Returns a CollectedResult containing the result of the run.
@available(macOS 9999, *)
public func run<
    Input: InputProtocol,
    Output: OutputProtocol,
    Error: OutputProtocol
>(
    _ executable: Executable,
    arguments: Arguments = [],
    environment: Environment = .inherit,
    workingDirectory: FilePath? = nil,
    platformOptions: PlatformOptions = PlatformOptions(),
    input: Input = .none,
    output: Output = .string,
    error: Error = .discarded
) async throws -> CollectedResult<Output, Error> {
    let result = try await Configuration(
        executable: executable,
        arguments: arguments,
        environment: environment,
        workingDirectory: workingDirectory,
        platformOptions: platformOptions
    )
    .run(input: input, output: output, error: error) { execution in
        let (
            standardOutput,
            standardError,
        ) = try await execution.captureIOs()
        return (
            processIdentifier: execution.processIdentifier,
            standardOutput: standardOutput,
            standardError: standardError,
        )
    }
    return CollectedResult(
        processIdentifier: result.value.processIdentifier,
        terminationStatus: result.terminationStatus,
        standardOutput: result.value.standardOutput,
        standardError: result.value.standardError,
    )
}

/// Run a executable with given parameters and a custom closure
/// to manage the running subprocess' lifetime and its IOs.
/// - Parameters:
///   - executable: The executable to run.
///   - arguments: The arguments to pass to the executable.
///   - environment: The environment in which to run the executable.
///   - workingDirectory: The working directory in which to run the executable.
///   - platformOptions: The platform specific options to use
///     when running the executable.
///   - input: span to write to subprocess' standard input.
///   - output: The method to use for redirecting the standard output.
///   - error: The method to use for redirecting the standard error.
/// - Returns a CollectedResult containing the result of the run.
@available(macOS 9999, *)
public func run<
    InputElement: BitwiseCopyable,
    Output: OutputProtocol,
    Error: OutputProtocol
>(
    _ executable: Executable,
    arguments: Arguments = [],
    environment: Environment = .inherit,
    workingDirectory: FilePath? = nil,
    platformOptions: PlatformOptions = PlatformOptions(),
    input: borrowing Span<InputElement>,
    output: Output = .string,
    error: Error = .discarded
) async throws -> CollectedResult<Output, Error> {
    return try await Configuration(
        executable: executable,
        arguments: arguments,
        environment: environment,
        workingDirectory: workingDirectory,
        platformOptions: platformOptions
    ).run(input: input, output: output, error: error)
}


// MARK: - Custom Execution Body

/// Run a executable with given parameters and a custom closure
/// to manage the running subprocess' lifetime and its IOs.
/// - Parameters:
///   - executable: The executable to run.
///   - arguments: The arguments to pass to the executable.
///   - environment: The environment in which to run the executable.
///   - workingDirectory: The working directory in which to run the executable.
///   - platformOptions: The platform specific options to use
///     when running the executable.
///   - input: The input to send to the executable.
///   - output: How to manage the executable standard ouput.
///   - error: How to manager executable standard error.
///   - isolation: the isolation context to run the body closure.
///   - body: The custom execution body to manually control the running process
/// - Returns a ExecutableResult type containing the return value
///     of the closure.
public func run<Result, Input: InputProtocol, Output: OutputProtocol, Error: OutputProtocol>(
    _ executable: Executable,
    arguments: Arguments = [],
    environment: Environment = .inherit,
    workingDirectory: FilePath? = nil,
    platformOptions: PlatformOptions = PlatformOptions(),
    input: Input = .none,
    output: Output,
    error: Error,
    isolation: isolated (any Actor)? = #isolation,
    body: (@escaping (Execution<Output, Error>) async throws -> Result)
) async throws -> ExecutionResult<Result> where Output.OutputType == Void, Error.OutputType == Void {
    return try await Configuration(
        executable: executable,
        arguments: arguments,
        environment: environment,
        workingDirectory: workingDirectory,
        platformOptions: platformOptions
    )
    .run(input: input, output: output, error: error, body)
}

/// Run a executable with given parameters and a custom closure
/// to manage the running subprocess' lifetime and write to its
/// standard input via `StandardInputWriter`
/// - Parameters:
///   - executable: The executable to run.
///   - arguments: The arguments to pass to the executable.
///   - environment: The environment in which to run the executable.
///   - workingDirectory: The working directory in which to run the executable.
///   - platformOptions: The platform specific options to use
///     when running the executable.
///   - output:How to handle executable's standard output
///   - error: How to handle executable's standard error
///   - isolation: the isolation context to run the body closure.
///   - body: The custom execution body to manually control the running process
/// - Returns a ExecutableResult type containing the return value
///     of the closure.
public func run<Result, Output: OutputProtocol, Error: OutputProtocol>(
    _ executable: Executable,
    arguments: Arguments = [],
    environment: Environment = .inherit,
    workingDirectory: FilePath? = nil,
    platformOptions: PlatformOptions = PlatformOptions(),
    output: Output,
    error: Error,
    isolation: isolated (any Actor)? = #isolation,
    body: (@escaping (Execution<Output, Error>, StandardInputWriter) async throws -> Result)
) async throws -> ExecutionResult<Result> where Output.OutputType == Void, Error.OutputType == Void {
    return try await Configuration(
        executable: executable,
        arguments: arguments,
        environment: environment,
        workingDirectory: workingDirectory,
        platformOptions: platformOptions
    )
    .run(output: output, error: error, body)
}


// MARK: - Configuration Based

/// Run a executable with given parameters and a custom closure
/// to manage the running subprocess' lifetime and its IOs.
/// - Parameters:
///   - executable: The executable to run.
///   - arguments: The arguments to pass to the executable.
///   - environment: The environment in which to run the executable.
///   - workingDirectory: The working directory in which to run the executable.
///   - platformOptions: The platform specific options to use
///     when running the executable.
///   - input: The input to send to the executable.
///   - output: The method to use for redirecting the standard output.
///   - error: The method to use for redirecting the standard error.
///   - body: The custom execution body to manually control the running process
/// - Returns a CollectedResult containing the result of the run.
@available(macOS 9999, *)
public func run<
    Input: InputProtocol,
    Output: OutputProtocol,
    Error: OutputProtocol
>(
    _ configuration: ConfigurationBuilder,
    input: Input = .none,
    output: Output = .string,
    error: Error = .discarded
) async throws -> CollectedResult<Output, Error> {
    let result = try await configuration.config().run(input: input, output: output, error: error){ execution in
        let (
            standardOutput,
            standardError,
        ) = try await execution.captureIOs()
        return (
            processIdentifier: execution.processIdentifier,
            standardOutput: standardOutput,
            standardError: standardError,
        )
    }
    return CollectedResult(
        processIdentifier: result.value.processIdentifier,
        terminationStatus: result.terminationStatus,
        standardOutput: result.value.standardOutput,
        standardError: result.value.standardError,
    )
}

/// Run a executable with given parameters specified by a `Configuration`
/// - Parameters:
///   - configuration: The `Subprocess` configuration to run.
///   - output: The method to use for redirecting the standard output.
///   - error: The method to use for redirecting the standard error.
///   - isolation: the isolation context to run the body closure.
///   - body: The custom configuration body to manually control
///       the running process and write to its standard input.
/// - Returns a ExecutableResult type containing the return value
///     of the closure.
public func run<Result, Output: OutputProtocol, Error: OutputProtocol>(
    _ configuration: ConfigurationBuilder,
    output: Output,
    error: Error,
    isolation: isolated (any Actor)? = #isolation,
    body: (@escaping (Execution<Output, Error>, StandardInputWriter) async throws -> Result)
) async throws -> ExecutionResult<Result> where Output.OutputType == Void, Error.OutputType == Void {
    return try await configuration.config().run(output: output, error: error, body)
}


// MARK: - Detached

/// Run a executable with given parameters and return its process
/// identifier immediately without monitoring the state of the
/// subprocess nor waiting until it exits.
///
/// This method is useful for launching subprocesses that outlive their
/// parents (for example, daemons and trampolines).
///
/// - Parameters:
///   - executable: The executable to run.
///   - arguments: The arguments to pass to the executable.
///   - environment: The environment to use for the process.
///   - workingDirectory: The working directory for the process.
///   - platformOptions: The platform specific options to use for the process.
///   - input: A file descriptor to bind to the subprocess' standard input.
///   - output: A file descriptor to bind to the subprocess' standard output.
///   - error: A file descriptor to bind to the subprocess' standard error.
/// - Returns: the process identifier for the subprocess.
public func runDetached(
    _ executable: Executable,
    arguments: Arguments = [],
    environment: Environment = .inherit,
    workingDirectory: FilePath? = nil,
    platformOptions: PlatformOptions = PlatformOptions(),
    input: FileDescriptor? = nil,
    output: FileDescriptor? = nil,
    error: FileDescriptor? = nil
) throws -> ProcessIdentifier {
    let config: Configuration = Configuration(
        executable: executable,
        arguments: arguments,
        environment: environment,
        workingDirectory: workingDirectory,
        platformOptions: platformOptions
    )
    return try runDetached(config, input: input, output: output, error: error)
}

/// Run a executable with given configuration and return its process
/// identifier immediately without monitoring the state of the
/// subprocess nor waiting until it exits.
///
/// This method is useful for launching subprocesses that outlive their
/// parents (for example, daemons and trampolines).
///
/// - Parameters:
///   - configuration: The `Subprocess` configuration to run.
///   - input: A file descriptor to bind to the subprocess' standard input.
///   - output: A file descriptor to bind to the subprocess' standard output.
///   - error: A file descriptor to bind to the subprocess' standard error.
/// - Returns: the process identifier for the subprocess.
public func runDetached(
    _ configuration: Configuration,
    input: FileDescriptor? = nil,
    output: FileDescriptor? = nil,
    error: FileDescriptor? = nil
) throws -> ProcessIdentifier {
    // Create input
    switch (input, output, error) {
    case (.none, .none, .none):
        return try configuration.config().spawn(
            withInput: .none,
            output: .discarded,
            error: .discarded
        ).processIdentifier
    case (.none, .none, .some(let errorFd)):
        return try configuration.config().spawn(
            withInput: .none,
            output: .discarded,
            error: .fileDescriptor(errorFd, closeAfterSpawningProcess: false)
        ).processIdentifier
    case (.none, .some(let outputFd), .none):
        return try configuration.config().spawn(
            withInput: .none,
            output: .fileDescriptor(outputFd, closeAfterSpawningProcess: false),
            error: .discarded
        ).processIdentifier
    case (.none, .some(let outputFd), .some(let errorFd)):
        return try configuration.config().spawn(
            withInput: .none,
            output: .fileDescriptor(outputFd, closeAfterSpawningProcess: false),
            error: .fileDescriptor(errorFd, closeAfterSpawningProcess: false)
        ).processIdentifier
    case (.some(let inputFd), .none, .none):
        return try configuration.config().spawn(
            withInput: .fileDescriptor(inputFd, closeAfterSpawningProcess: false),
            output: .discarded,
            error: .discarded
        ).processIdentifier
    case (.some(let inputFd), .none, .some(let errorFd)):
        return try configuration.config().spawn(
            withInput: .fileDescriptor(inputFd, closeAfterSpawningProcess: false),
            output: .discarded,
            error: .fileDescriptor(errorFd, closeAfterSpawningProcess: false)
        ).processIdentifier
    case (.some(let inputFd), .some(let outputFd), .none):
        return try configuration.config().spawn(
            withInput: .fileDescriptor(inputFd, closeAfterSpawningProcess: false),
            output: .fileDescriptor(outputFd, closeAfterSpawningProcess: false),
            error: .discarded
        ).processIdentifier
    case (.some(let inputFd), .some(let outputFd), .some(let errorFd)):
        return try configuration.config().spawn(
            withInput: .fileDescriptor(inputFd, closeAfterSpawningProcess: false),
            output: .fileDescriptor(outputFd, closeAfterSpawningProcess: false),
            error: .fileDescriptor(errorFd, closeAfterSpawningProcess: false)
        ).processIdentifier
    }
}

