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

import SystemPackage
#if canImport(FoundationEssentials)
import FoundationEssentials
#elseif canImport(Foundation)
import Foundation
#endif

extension Subprocess {
    /// Run a executable with given parameters and capture its
    /// standard output and standard error.
    /// - Parameters:
    ///   - executable: The executable to run.
    ///   - arguments: The arguments to pass to the executable.
    ///   - environment: The environment to use for the process.
    ///   - workingDirectory: The working directory to use for the subprocess.
    ///   - platformOptions: The platform specific options to use
    ///     when running the executable.
    ///   - input: The input to send to the executable.
    ///   - output: The method to use for collecting the standard output.
    ///   - error: The method to use for collecting the standard error.
    /// - Returns: `CollectedResult` which contains process identifier,
    ///     termination status, captured standard output and standard error.
    public static func run(
        _ executable: Executable,
        arguments: Arguments = [],
        environment: Environment = .inherit,
        workingDirectory: FilePath? = nil,
        platformOptions: PlatformOptions = PlatformOptions(),
        input: InputMethod = .noInput,
        output: CollectedOutputMethod = .collect(),
        error: CollectedOutputMethod = .collect()
    ) async throws -> CollectedResult {
        let result = try await self.run(
            executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            platformOptions: platformOptions,
            input: input,
            output: .init(method: output.method),
            error: .init(method: error.method)
        ) { subprocess in
            let (standardOutput, standardError) = try await subprocess.captureIOs()
            return (
                processIdentifier: subprocess.processIdentifier,
                standardOutput: standardOutput,
                standardError: standardError
            )
        }
        return CollectedResult(
            processIdentifier: result.value.processIdentifier,
            terminationStatus: result.terminationStatus,
            standardOutput: result.value.standardOutput,
            standardError: result.value.standardError
        )
    }

    /// Run a executable with given parameters and capture its
    /// standard output and standard error.
    /// - Parameters:
    ///   - executable: The executable to run.
    ///   - arguments: The arguments to pass to the executable.
    ///   - environment: The environment to use for the process.
    ///   - workingDirectory: The working directory to use for the subprocess.
    ///   - platformOptions: The platform specific options to use
    ///     when running the executable.
    ///   - input: The input to send to the executable.
    ///   - output: The method to use for collecting the standard output.
    ///   - error: The method to use for collecting the standard error.
    /// - Returns: `CollectedResult` which contains process identifier,
    ///     termination status, captured standard output and standard error.
    public static func run(
        _ executable: Executable,
        arguments: Arguments = [],
        environment: Environment = .inherit,
        workingDirectory: FilePath? = nil,
        platformOptions: PlatformOptions = PlatformOptions(),
        input: some Sequence<UInt8> & Sendable,
        output: CollectedOutputMethod = .collect(),
        error: CollectedOutputMethod = .collect()
    ) async throws -> CollectedResult {
        let result = try await self.run(
            executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            platformOptions: platformOptions,
            output: .init(method: output.method),
            error: .init(method: output.method)
        ) { subprocess, writer in
            return try await withThrowingTaskGroup(of: CapturedIOs?.self) { group in
                group.addTask {
                    try await writer.write(input)
                    try await writer.finish()
                    return nil
                }
                group.addTask {
                    return try await subprocess.captureIOs()
                }
                var capturedIOs: CapturedIOs!
                while let result = try await group.next() {
                    if result != nil {
                        capturedIOs = result
                    }
                }
                return (
                    processIdentifier: subprocess.processIdentifier,
                    standardOutput: capturedIOs.standardOutput,
                    standardError: capturedIOs.standardError
                )
            }
        }
        return CollectedResult(
            processIdentifier: result.value.processIdentifier,
            terminationStatus: result.terminationStatus,
            standardOutput: result.value.standardOutput,
            standardError: result.value.standardError
        )
    }

    /// Run a executable with given parameters and capture its
    /// standard output and standard error.
    /// - Parameters:
    ///   - executable: The executable to run.
    ///   - arguments: The arguments to pass to the executable.
    ///   - environment: The environment to use for the process.
    ///   - workingDirectory: The working directory to use for the subprocess.
    ///   - platformOptions: The platform specific options to use
    ///     when running the executable.
    ///   - input: The input to send to the executable.
    ///   - output: The method to use for collecting the standard output.
    ///   - error: The method to use for collecting the standard error.
    /// - Returns: `CollectedResult` which contains process identifier,
    ///     termination status, captured standard output and standard error.
    public static func run(
        _ executable: Executable,
        arguments: Arguments = [],
        environment: Environment = .inherit,
        workingDirectory: FilePath? = nil,
        platformOptions: PlatformOptions = PlatformOptions(),
        input: some StringProtocol,
        output: CollectedOutputMethod = .collect(),
        error: CollectedOutputMethod = .collect()
    ) async throws -> CollectedResult {
        return try await self.run(
            executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            platformOptions: platformOptions,
            input: Data(input.utf8),
            output: output,
            error: error
        )
    }

    /// Run a executable with given parameters and capture its
    /// standard output and standard error.
    /// - Parameters:
    ///   - executable: The executable to run.
    ///   - arguments: The arguments to pass to the executable.
    ///   - environment: The environment to use for the process.
    ///   - workingDirectory: The working directory to use for the subprocess.
    ///   - platformOptions: The platform specific options to use
    ///     when running the executable.
    ///   - input: The input to send to the executable.
    ///   - output: The method to use for collecting the standard output.
    ///   - error: The method to use for collecting the standard error.
    /// - Returns: `CollectedResult` which contains process identifier,
    ///     termination status, captured standard output and standard error.
    public static func run(
        _ executable: Executable,
        arguments: Arguments = [],
        environment: Environment = .inherit,
        workingDirectory: FilePath? = nil,
        platformOptions: PlatformOptions = PlatformOptions(),
        input: some Sequence<Data> & Sendable,
        output: CollectedOutputMethod = .collect(),
        error: CollectedOutputMethod = .collect()
    ) async throws -> CollectedResult {
        let result = try await self.run(
            executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            platformOptions: platformOptions,
            output: .init(method: output.method),
            error: .init(method: output.method)
        ) { subprocess, writer in
            return try await withThrowingTaskGroup(of: CapturedIOs?.self) { group in
                group.addTask {
                    var buffer = Data()
                    for chunk in input {
                        buffer.append(chunk)
                    }
                    try await writer.write(buffer)
                    try await writer.finish()
                    return nil
                }
                group.addTask {
                    return try await subprocess.captureIOs()
                }
                var capturedIOs: CapturedIOs!
                while let result = try await group.next() {
                    if result != nil {
                        capturedIOs = result
                    }
                }
                return (
                    processIdentifier: subprocess.processIdentifier,
                    standardOutput: capturedIOs.standardOutput,
                    standardError: capturedIOs.standardError
                )
            }
        }
        return CollectedResult(
            processIdentifier: result.value.processIdentifier,
            terminationStatus: result.terminationStatus,
            standardOutput: result.value.standardOutput,
            standardError: result.value.standardError
        )
    }

    /// Run a executable with given parameters and capture its
    /// standard output and standard error.
    /// - Parameters:
    ///   - executable: The executable to run.
    ///   - arguments: The arguments to pass to the executable.
    ///   - environment: The environment to use for the process.
    ///   - workingDirectory: The working directory to use for the subprocess.
    ///   - platformOptions: The platform specific options to use
    ///     when running the executable.
    ///   - input: The input to send to the executable.
    ///   - output: The method to use for collecting the standard output.
    ///   - error: The method to use for collecting the standard error.
    /// - Returns: `CollectedResult` which contains process identifier,
    ///     termination status, captured standard output and standard error.
    public static func run<AsyncSendableSequence: AsyncSequence & Sendable>(
        _ executable: Executable,
        arguments: Arguments = [],
        environment: Environment = .inherit,
        workingDirectory: FilePath? = nil,
        platformOptions: PlatformOptions = PlatformOptions(),
        input: AsyncSendableSequence,
        output: CollectedOutputMethod = .collect(),
        error: CollectedOutputMethod = .collect()
    ) async throws -> CollectedResult where AsyncSendableSequence.Element == Data {
        let result =  try await self.run(
            executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            platformOptions: platformOptions,
            output: .init(method: output.method),
            error: .init(method: output.method)
        ) { subprocess, writer in
            return try await withThrowingTaskGroup(of: CapturedIOs?.self) { group in
                group.addTask {
                    try await writer.write(input)
                    try await writer.finish()
                    return nil
                }
                group.addTask {
                    return try await subprocess.captureIOs()
                }
                var capturedIOs: CapturedIOs!
                while let result = try await group.next() {
                    capturedIOs = result
                }
                return (
                    processIdentifier: subprocess.processIdentifier,
                    standardOutput: capturedIOs.standardOutput,
                    standardError: capturedIOs.standardError
                )
            }
        }
        return CollectedResult(
            processIdentifier: result.value.processIdentifier,
            terminationStatus: result.terminationStatus,
            standardOutput: result.value.standardOutput,
            standardError: result.value.standardError
        )
    }
}

// MARK: Custom Execution Body
extension Subprocess {
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
    /// - Returns a ExecutableResult type containing the return value
    ///     of the closure.
    public static func run<Result>(
        _ executable: Executable,
        arguments: Arguments = [],
        environment: Environment = .inherit,
        workingDirectory: FilePath? = nil,
        platformOptions: PlatformOptions = PlatformOptions(),
        input: InputMethod = .noInput,
        output: RedirectedOutputMethod = .redirectToSequence,
        error: RedirectedOutputMethod = .redirectToSequence,
        isolation: isolated (any Actor)? = #isolation,
        _ body: (@escaping (Subprocess) async throws -> Result)
    ) async throws -> ExecutionResult<Result> {
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
    /// - Returns a ExecutableResult type containing the return value
    ///     of the closure.
    public static func run<Result>(
        _ executable: Executable,
        arguments: Arguments = [],
        environment: Environment = .inherit,
        workingDirectory: FilePath? = nil,
        platformOptions: PlatformOptions = PlatformOptions(),
        input: some StringProtocol,
        output: RedirectedOutputMethod = .redirectToSequence,
        error: RedirectedOutputMethod = .redirectToSequence,
        isolation: isolated (any Actor)? = #isolation,
        _ body: (@escaping (Subprocess) async throws -> Result)
    ) async throws -> ExecutionResult<Result> {
        return try await Self.run(
            executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            platformOptions: platformOptions,
            input: Data(input.utf8),
            body
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
    ///   - input: The input to send to the executable.
    ///   - output: The method to use for redirecting the standard output.
    ///   - error: The method to use for redirecting the standard error.
    ///   - body: The custom execution body to manually control the running process
    /// - Returns a `ExecutableResult` type containing the return value
    ///     of the closure.
    public static func run<Result>(
        _ executable: Executable,
        arguments: Arguments = [],
        environment: Environment = .inherit,
        workingDirectory: FilePath? = nil,
        platformOptions: PlatformOptions = PlatformOptions(),
        input: some Sequence<UInt8> & Sendable,
        output: RedirectedOutputMethod = .redirectToSequence,
        error: RedirectedOutputMethod = .redirectToSequence,
        isolation: isolated (any Actor)? = #isolation,
        _ body: (@escaping (Subprocess) async throws -> Result)
    ) async throws -> ExecutionResult<Result> {
        return try await Configuration(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            platformOptions: platformOptions
        )
        .run(output: output, error: error) { execution, writer in
            return try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await writer.write(input)
                    try await writer.finish()
                }
                let result = try await body(execution)
                try await group.waitForAll()
                return result
            }
        }
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
    ///   - input: The input to send to the executable.
    ///   - output: The method to use for redirecting the standard output.
    ///   - error: The method to use for redirecting the standard error.
    ///   - body: The custom execution body to manually control the running process
    /// - Returns a `ExecutableResult` type containing the return value
    ///     of the closure.
    public static func run<Result>(
        _ executable: Executable,
        arguments: Arguments = [],
        environment: Environment = .inherit,
        workingDirectory: FilePath? = nil,
        platformOptions: PlatformOptions = PlatformOptions(),
        input: some Sequence<Data> & Sendable,
        output: RedirectedOutputMethod = .redirectToSequence,
        error: RedirectedOutputMethod = .redirectToSequence,
        isolation: isolated (any Actor)? = #isolation,
        _ body: (@escaping (Subprocess) async throws -> Result)
    ) async throws -> ExecutionResult<Result> {
        return try await Configuration(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            platformOptions: platformOptions
        )
        .run(output: output, error: error) { execution, writer in
            return try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    var buffer = Data()
                    for chunk in input {
                        buffer.append(chunk)
                    }
                    try await writer.write(buffer)
                    try await writer.finish()
                }
                let result = try await body(execution)
                try await group.waitForAll()
                return result
            }
        }
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
    ///   - input: The input to send to the executable.
    ///   - output: The method to use for redirecting the standard output.
    ///   - error: The method to use for redirecting the standard error.
    ///   - body: The custom execution body to manually control the running process
    /// - Returns a `ExecutableResult` type containing the return value
    ///     of the closure.
    public static func run<Result, AsyncSendableSequence: AsyncSequence & Sendable>(
        _ executable: Executable,
        arguments: Arguments = [],
        environment: Environment = .inherit,
        workingDirectory: FilePath? = nil,
        platformOptions: PlatformOptions = PlatformOptions(),
        input: AsyncSendableSequence,
        output: RedirectedOutputMethod = .redirectToSequence,
        error: RedirectedOutputMethod = .redirectToSequence,
        isolation: isolated (any Actor)? = #isolation,
        _ body: (@escaping (Subprocess) async throws -> Result)
    ) async throws -> ExecutionResult<Result> where AsyncSendableSequence.Element == Data {
        return try await Configuration(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            platformOptions: platformOptions
        )
        .run(output: output, error: error) { execution, writer in
            return try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await writer.write(input)
                    try await writer.finish()
                }
                let result = try await body(execution)
                try await group.waitForAll()
                return result
            }
        }
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
    ///   - output: The method to use for redirecting the standard output.
    ///   - error: The method to use for redirecting the standard error.
    ///   - body: The custom execution body to manually control the running process
    /// - Returns a ExecutableResult type containing the return value
    ///     of the closure.
    public static func run<Result>(
        _ executable: Executable,
        arguments: Arguments = [],
        environment: Environment = .inherit,
        workingDirectory: FilePath? = nil,
        platformOptions: PlatformOptions = PlatformOptions(),
        output: RedirectedOutputMethod = .redirectToSequence,
        error: RedirectedOutputMethod = .redirectToSequence,
        isolation: isolated (any Actor)? = #isolation,
        _ body: (@escaping (Subprocess, StandardInputWriter) async throws -> Result)
    ) async throws -> ExecutionResult<Result> {
        return try await Configuration(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            platformOptions: platformOptions
        )
        .run(output: output, error: error, body)
    }
}

// MARK: - Configuration Based
extension Subprocess {
    /// Run a executable with given parameters specified by a
    /// `Subprocess.Configuration`
    /// - Parameters:
    ///   - configuration: The `Subprocess` configuration to run.
    ///   - output: The method to use for redirecting the standard output.
    ///   - error: The method to use for redirecting the standard error.
    ///   - body: The custom configuration body to manually control
    ///       the running process and write to its standard input.
    /// - Returns a ExecutableResult type containing the return value
    ///     of the closure.
    public static func run<Result>(
        _ configuration: Configuration,
        output: RedirectedOutputMethod = .redirectToSequence,
        error: RedirectedOutputMethod = .redirectToSequence,
        isolation: isolated (any Actor)? = #isolation,
        _ body: (@escaping (Subprocess, StandardInputWriter) async throws -> Result)
    ) async throws -> ExecutionResult<Result> {
        return try await configuration.run(output: output, error: error, body)
    }
}

// MARK: - Detached
extension Subprocess {
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
    public static func runDetached(
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
        return try Self.runDeatched(config, input: input, output: output, error: error)
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
    public static func runDeatched(
        _ configuration: Configuration,
        input: FileDescriptor? = nil,
        output: FileDescriptor? = nil,
        error: FileDescriptor? = nil
    ) throws -> ProcessIdentifier {
        // Create input
        let executionInput: ExecutionInput
        let executionOutput: ExecutionOutput
        let executionError: ExecutionOutput
        if let inputFd = input {
            executionInput = .init(storage: .fileDescriptor(inputFd, false))
        } else {
            let devnull: FileDescriptor = try .openDevNull(withAcessMode: .readOnly)
            executionInput = .init(storage: .noInput(devnull))
        }
        if let outputFd = output {
            executionOutput = .init(storage: .fileDescriptor(outputFd, false))
        } else {
            let devnull: FileDescriptor = try .openDevNull(withAcessMode: .writeOnly)
            executionOutput = .init(storage: .discarded(devnull))
        }
        if let errorFd = error {
            executionError = .init(
                storage: .fileDescriptor(errorFd, false)
            )
        } else {
            let devnull: FileDescriptor = try .openDevNull(withAcessMode: .writeOnly)
            executionError = .init(storage: .discarded(devnull))
        }

        return try configuration.spawn(
            withInput: executionInput,
            output: executionOutput,
            error: executionError
        ).processIdentifier
    }
}

