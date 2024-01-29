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
import FoundationEssentials

public struct Subprocess {
    public static func run(
        executing executable: ExecutableConfiguration,
        arguments: Arguments = [],
        environment: Environment = .inheritFromLaunchingProcess,
        workingDirectory: FilePath? = nil,
        qualityOfService: QualityOfService = .default,
        input: InputMethod = .noInput,
        output: CollectedOutputMethod = .collected,
        error: CollectedOutputMethod = .discarded
    ) async throws -> ExecutionResult {
        return try await self.run(
            executing: executable,
            input: input,
            output: .init(method: output.method),
            error: .init(method: error.method)
        ) { execution in
            return try await execution.createExecutionResult()
        }
    }

    public static func run(
        executing executable: ExecutableConfiguration,
        arguments: Arguments = [],
        environment: Environment = .inheritFromLaunchingProcess,
        workingDirectory: FilePath? = nil,
        qualityOfService: QualityOfService = .default,
        input: some Sequence<UInt8>,
        output: CollectedOutputMethod = .collected,
        error: CollectedOutputMethod = .discarded
    ) async throws -> ExecutionResult {
        return try await self.run(
            executing: executable,
            output: .init(method: output.method),
            error: .init(method: output.method)
        ) { execution, writer in
            try await writer.write(input)
            try await writer.finishWriting()
            return try await execution.createExecutionResult()
        }
    }

    public static func run<S: AsyncSequence>(
        executing executable: ExecutableConfiguration,
        arguments: Arguments = [],
        environment: Environment = .inheritFromLaunchingProcess,
        workingDirectory: FilePath? = nil,
        qualityOfService: QualityOfService = .default,
        input: S,
        output: CollectedOutputMethod = .collected,
        error: CollectedOutputMethod = .discarded
    ) async throws -> ExecutionResult where S.Element == UInt8 {
        return try await self.run(
            executing: executable,
            output: .init(method: output.method),
            error: .init(method: output.method)
        ) { execution, writer in
            try await writer.write(input)
            try await writer.finishWriting()
            return try await execution.createExecutionResult()
        }
    }
}

// MARK: Custom Execution Body
extension Subprocess {
    public static func run<R>(
        executing executable: ExecutableConfiguration,
        arguments: Arguments = [],
        environment: Environment = .inheritFromLaunchingProcess,
        workingDirectory: FilePath? = nil,
        qualityOfService: QualityOfService = .default,
        input: InputMethod = .noInput,
        output: RedirectedOutputMethod = .redirected,
        error: RedirectedOutputMethod = .discarded,
        _ body: (@Sendable @escaping (borrowing Execution) async throws -> R)
    ) async throws -> R {
        return try await Configuration(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            qualityOfService: qualityOfService
        )
        .run(input: input, output: output, error: error, body)
    }

    public static func run<R>(
        executing executable: ExecutableConfiguration,
        arguments: Arguments = [],
        environment: Environment = .inheritFromLaunchingProcess,
        workingDirectory: FilePath? = nil,
        qualityOfService: QualityOfService = .default,
        input: some Sequence<UInt8>,
        output: RedirectedOutputMethod = .redirected,
        error: RedirectedOutputMethod = .discarded,
        _ body: (@Sendable @escaping (borrowing Execution) async throws -> R)
    ) async throws -> R {
        return try await Configuration(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            qualityOfService: qualityOfService
        )
        .run(output: output, error: error) { execution, writer in
            try await writer.write(input)
            try await writer.finishWriting()
            return try await body(execution)
        }
    }

    public static func run<R, S: AsyncSequence>(
        executing executable: ExecutableConfiguration,
        arguments: Arguments = [],
        environment: Environment = .inheritFromLaunchingProcess,
        workingDirectory: FilePath? = nil,
        qualityOfService: QualityOfService = .default,
        input: S,
        output: RedirectedOutputMethod = .redirected,
        error: RedirectedOutputMethod = .discarded,
        _ body: (@Sendable @escaping (borrowing Execution) async throws -> R)
    ) async throws -> R where S.Element == UInt8 {
        return try await Configuration(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            qualityOfService: qualityOfService
        )
        .run(output: output, error: error) { execution, writer in
            try await writer.write(input)
            try await writer.finishWriting()
            return try await body(execution)
        }
    }

    public static func run<R>(
        executing executable: ExecutableConfiguration,
        arguments: Arguments = [],
        environment: Environment = .inheritFromLaunchingProcess,
        workingDirectory: FilePath? = nil,
        qualityOfService: QualityOfService = .default,
        output: RedirectedOutputMethod = .redirected,
        error: RedirectedOutputMethod = .discarded,
        _ body: (@Sendable @escaping (borrowing Execution, StandardInputWriter) async throws -> R)
    ) async throws -> R {
        return try await Configuration(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            qualityOfService: qualityOfService
        )
        .run(output: output, error: error, body)
    }
}

