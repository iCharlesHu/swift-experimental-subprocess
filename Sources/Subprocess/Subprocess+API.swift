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
    public static func run(
        _ executable: Executable,
        arguments: Arguments = [],
        environment: Environment = .inherit,
        workingDirectory: FilePath? = nil,
        platformOptions: PlatformOptions = .default,
        input: InputMethod = .noInput,
        output: CollectedOutputMethod = .collect,
        error: CollectedOutputMethod = .collect
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

    public static func run(
        _ executable: Executable,
        arguments: Arguments = [],
        environment: Environment = .inherit,
        workingDirectory: FilePath? = nil,
        platformOptions: PlatformOptions = .default,
        input: some Sequence<UInt8>,
        output: CollectedOutputMethod = .collect,
        error: CollectedOutputMethod = .collect
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

    public static func run<S: AsyncSequence>(
        _ executable: Executable,
        arguments: Arguments = [],
        environment: Environment = .inherit,
        workingDirectory: FilePath? = nil,
        platformOptions: PlatformOptions = .default,
        input: S,
        output: CollectedOutputMethod = .collect,
        error: CollectedOutputMethod = .collect
    ) async throws -> CollectedResult where S.Element == UInt8 {
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
    public static func run<R>(
        _ executable: Executable,
        arguments: Arguments = [],
        environment: Environment = .inherit,
        workingDirectory: FilePath? = nil,
        platformOptions: PlatformOptions = .default,
        input: InputMethod = .noInput,
        output: RedirectedOutputMethod = .redirectToSequence,
        error: RedirectedOutputMethod = .redirectToSequence,
        _ body: (sending @escaping (Subprocess) async throws -> R)
    ) async throws -> ExecutionResult<R> {
        return try await Configuration(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            platformOptions: platformOptions
        )
        .run(input: input, output: output, error: error, body)
    }

    public static func run<R>(
        _ executable: Executable,
        arguments: Arguments = [],
        environment: Environment = .inherit,
        workingDirectory: FilePath? = nil,
        platformOptions: PlatformOptions = .default,
        input: some Sequence<UInt8>,
        output: RedirectedOutputMethod = .redirectToSequence,
        error: RedirectedOutputMethod = .redirectToSequence,
        _ body: (sending @escaping (Subprocess) async throws -> R)
    ) async throws -> ExecutionResult<R> {
        return try await Configuration(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            platformOptions: platformOptions
        )
        .run(output: output, error: error) { execution, writer in
            return try await withThrowingTaskGroup(of: R?.self) { group in
                group.addTask {
                    try await writer.write(input)
                    try await writer.finish()
                    return nil
                }
                group.addTask {
                    return try await body(execution)
                }
                var result: R!
                while let next = try await group.next() {
                    result = next
                }
                return result
            }
        }
    }

    public static func run<R, S: AsyncSequence>(
        _ executable: Executable,
        arguments: Arguments = [],
        environment: Environment = .inherit,
        workingDirectory: FilePath? = nil,
        platformOptions: PlatformOptions = .default,
        input: S,
        output: RedirectedOutputMethod = .redirectToSequence,
        error: RedirectedOutputMethod = .redirectToSequence,
        _ body: (sending @escaping (Subprocess) async throws -> R)
    ) async throws -> ExecutionResult<R> where S.Element == UInt8 {
        return try await Configuration(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            platformOptions: platformOptions
        )
        .run(output: output, error: error) { execution, writer in
            return try await withThrowingTaskGroup(of: R?.self) { group in
                group.addTask {
                    try await writer.write(input)
                    try await writer.finish()
                    return nil
                }
                group.addTask {
                    return try await body(execution)
                }
                var result: R!
                while let next = try await group.next() {
                    result = next
                }
                return result
            }
        }
    }

    public static func run<R>(
        _ executable: Executable,
        arguments: Arguments = [],
        environment: Environment = .inherit,
        workingDirectory: FilePath? = nil,
        platformOptions: PlatformOptions = .default,
        output: RedirectedOutputMethod = .redirectToSequence,
        error: RedirectedOutputMethod = .redirectToSequence,
        _ body: (sending @escaping (Subprocess, StandardInputWriter) async throws -> R)
    ) async throws -> ExecutionResult<R> {
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
    public static func run<R>(
        using configuration: Configuration,
        output: RedirectedOutputMethod = .redirectToSequence,
        error: RedirectedOutputMethod = .redirectToSequence,
        _ body: (sending @escaping (Subprocess, StandardInputWriter) async throws -> R)
    ) async throws -> ExecutionResult<R> {
        return try await configuration.run(output: output, error: error, body)
    }
}

// MARK: - Detached
extension Subprocess {
    public static func runDetached(
        _ executable: Executable,
        arguments: Arguments = [],
        environment: Environment = .inherit,
        workingDirectory: FilePath? = nil,
        platformOptions: PlatformOptions = .default,
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
        // Spawn!
        let config: Configuration = Configuration(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            platformOptions: platformOptions
        )
        return try config.spawn(
            withInput: executionInput,
            output: executionOutput,
            error: executionError
        ).processIdentifier
    }
}

