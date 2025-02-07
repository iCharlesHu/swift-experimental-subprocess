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

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(WinSDK)
import WinSDK
#endif

#if canImport(FoundationEssentials)
import FoundationEssentials
#elseif canImport(Foundation)
import Foundation
#endif

import Dispatch

/// A collection of configurations parameters to use when
/// spawning a subprocess.
@available(macOS 9999, *)
public struct Configuration: Sendable, Hashable {

    internal enum RunState<Result: Sendable>: Sendable {
        case workBody(Result)
        case monitorChildProcess(TerminationStatus)
    }

    /// The executable to run.
    public var executable: Executable
    /// The arguments to pass to the executable.
    public var arguments: Arguments
    /// The environment to use when running the executable.
    public var environment: Environment
    /// The working directory to use when running the executable.
    public var workingDirectory: FilePath
    /// The platform specifc options to use when
    /// running the subprocess.
    public var platformOptions: PlatformOptions

    public init(
        executable: Executable,
        arguments: Arguments = [],
        environment: Environment = .inherit,
        workingDirectory: FilePath? = nil,
        platformOptions: PlatformOptions = PlatformOptions()
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory ?? .currentWorkingDirectory
        self.platformOptions = platformOptions
    }

    /// Close each input individually, and throw the first error if there's multiple errors thrown
    @Sendable
    private func cleanup<
        Input: InputProtocol,
        Output: OutputProtocol,
        Error: OutputProtocol
    >(
        execution: Execution<Output, Error>,
        input: Input,
        childSide: Bool, parentSide: Bool,
        attemptToTerminateSubProcess: Bool
    ) async throws {
        func safeClose(_ work: () throws -> Void) -> Swift.Error? {
            do {
                try work()
                return nil
            } catch {
                return error
            }
        }

        guard childSide || parentSide || attemptToTerminateSubProcess else {
            return
        }

        var exitError: Swift.Error? = nil
        // Attempt to teardown the subprocess
        if attemptToTerminateSubProcess {
#if os(Windows)
            exitError = execution.tryTerminate()
#else
            await execution.teardown(
                using: self.platformOptions.teardownSequence
            )
#endif
        }

        var inputError: Swift.Error?
        var outputError: Swift.Error?
        var errorError: Swift.Error? // lol

        if childSide {
            inputError = safeClose(input.closeReadFileDescriptor)
            outputError = safeClose(execution.output.closeWriteFileDescriptor)
            errorError = safeClose(execution.error.closeWriteFileDescriptor)
        }

        if parentSide {
            inputError = safeClose(input.closeWriteFileDescriptor)
            outputError = safeClose(execution.output.closeReadFileDescriptor)
            errorError = safeClose(execution.error.closeReadFileDescriptor)
        }

        if let inputError = inputError {
            throw inputError
        }

        if let outputError = outputError {
            throw outputError
        }

        if let errorError = errorError {
            throw errorError
        }

        if let exitError = exitError {
            throw exitError
        }
    }

    /// Close each input individually, and throw the first error if there's multiple errors thrown
    @Sendable
    internal func cleanupAll<
        Input: InputProtocol,
        Output: OutputProtocol,
        Error: OutputProtocol
    >(
        input: Input,
        output: Output,
        error: Error
    ) throws {
        var inputError: Swift.Error?
        var outputError: Swift.Error?
        var errorError: Swift.Error?

        do {
            try input.closeReadFileDescriptor()
            try input.closeWriteFileDescriptor()
        } catch {
            inputError = error
        }

        do {
            try output.closeReadFileDescriptor()
            try output.closeWriteFileDescriptor()
        } catch {
            outputError = error
        }

        do {
            try error.closeReadFileDescriptor()
            try error.closeWriteFileDescriptor()
        } catch {
            errorError = error
        }

        if let inputError = inputError {
            throw inputError
        }
        if let outputError = outputError {
            throw outputError
        }
        if let errorError = errorError {
            throw errorError
        }
    }

    internal func run<
        Result,
        Output: OutputProtocol,
        Error: OutputProtocol
    >(
        output: Output,
        error: Error,
        isolation: isolated (any Actor)? = #isolation,
        _ body: @escaping (
            Execution<Output, Error>,
            StandardInputWriter
        ) async throws -> Result
    ) async throws -> ExecutionResult<Result> {
        let input = CustomWriteInput()
        let execution = try self.spawn(
            withInput: input,
            output: output,
            error: error
        )
        // After spawn, cleanup child side fds
        try await self.cleanup(
            execution: execution,
            input: input,
            childSide: true,
            parentSide: false,
            attemptToTerminateSubProcess: false
        )
        return try await withAsyncTaskCancellationHandler {
            async let waitingStatus = try await monitorProcessTermination(forProcessWithIdentifier: execution.processIdentifier)
            // Body runs in the same isolation
            do {
                let result = try await body(execution, .init(input: input))
                // Clean up parent side when body finishes
                try await self.cleanup(
                    execution: execution,
                    input: input,
                    childSide: false,
                    parentSide: true,
                    attemptToTerminateSubProcess: false
                )
                let status: TerminationStatus = try await waitingStatus
                return ExecutionResult(terminationStatus: status, value: result)
            } catch {
                // Cleanup everything
                try await self.cleanup(
                    execution: execution,
                    input: input,
                    childSide: false,
                    parentSide: true,
                    attemptToTerminateSubProcess: false
                )
                throw error
            }
        } onCancel: {
            // Attempt to terminate the child process
            // Since the task has already been cancelled,
            // this is the best we can do
            try? await self.cleanup(
                execution: execution,
                input: input,
                childSide: true,
                parentSide: true,
                attemptToTerminateSubProcess: true
            )
        }
    }

    @available(macOS 9999, *)
    internal func run<
        InputElement: BitwiseCopyable,
        Output: OutputProtocol,
        Error: OutputProtocol
    >(
        input: borrowing Span<InputElement>,
        output: Output,
        error: Error,
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> CollectedResult<Output, Error> {
        let writerInput = CustomWriteInput()
        let execution = try self.spawn(
            withInput: writerInput,
            output: output,
            error: error
        )
        // After spawn, clean up child side
        try await self.cleanup(
            execution: execution,
            input: writerInput,
            childSide: true,
            parentSide: false,
            attemptToTerminateSubProcess: false
        )
        return try await withAsyncTaskCancellationHandler {
            // Spawn parallel tasks to monitor exit status
            // and capture outputs. Input writing must happen
            // in this scope for Span
            async let terminationStatus = try monitorProcessTermination(
                forProcessWithIdentifier: execution.processIdentifier
            )
            async let (
                standardOutput,
                standardError,
            ) = try await execution.captureIOs()
            // Write input in the same scope
            guard let writeFd = try writerInput.writeFileDescriptor() else {
                fatalError("Trying to write to an input that has been closed")
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Swift.Error>) in
                input.withUnsafeBytes { ptr in
                    let dispatchData = DispatchData(bytesNoCopy: ptr, deallocator: .custom(nil, { /* noop */ }))

                    writeFd.write(dispatchData) { error in
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }

            }
            try writerInput.closeWriteFileDescriptor()

            return CollectedResult(
                processIdentifier: execution.processIdentifier,
                terminationStatus: try await terminationStatus,
                standardOutput: try await standardOutput,
                standardError: try await standardError
            )
        } onCancel: {
            // Attempt to terminate the child process
            // Since the task has already been cancelled,
            // this is the best we can do
            try? await self.cleanup(
                execution: execution,
                input: writerInput,
                childSide: true,
                parentSide: true,
                attemptToTerminateSubProcess: true
            )
        }
    }

    internal func run<
        Result,
        Input: InputProtocol,
        Output: OutputProtocol,
        Error: OutputProtocol
    >(
        input: Input,
        output: Output,
        error: Error,
        isolation: isolated (any Actor)? = #isolation,
        _ body: (@escaping (Execution<Output, Error>) async throws -> Result)
    ) async throws -> ExecutionResult<Result> {
        let execution = try self.spawn(
            withInput: input,
            output: output,
            error: error
        )
        // After spawn, clean up child side
        try await self.cleanup(
            execution: execution,
            input: input,
            childSide: true,
            parentSide: false,
            attemptToTerminateSubProcess: false
        )

        return try await withAsyncTaskCancellationHandler {
            do {
                return try await withThrowingTaskGroup(
                    of: TerminationStatus?.self,
                    returning: ExecutionResult.self
                ) { group in
                    group.addTask {
                        try await input.write()
                        try input.closeWriteFileDescriptor()
                        return nil
                    }
                    group.addTask {
                        return try await monitorProcessTermination(
                            forProcessWithIdentifier: execution.processIdentifier
                        )
                    }

                    // Body runs in the same isolation
                    let result = try await body(execution)
                    // After body finishes, cleanup parent side
                    try await self.cleanup(
                        execution: execution,
                        input: input,
                        childSide: false,
                        parentSide: true,
                        attemptToTerminateSubProcess: false
                    )
                    var status: TerminationStatus? = nil
                    while let monitorResult = try await group.next() {
                        if let monitorResult = monitorResult {
                            status = monitorResult
                        }
                    }
                    return ExecutionResult(terminationStatus: status!, value: result)
                }
            } catch {
                try await self.cleanup(
                    execution: execution,
                    input: input,
                    childSide: false,
                    parentSide: true,
                    attemptToTerminateSubProcess: false
                )
                throw error
            }
        } onCancel: {
            // Attempt to terminate the child process
            // Since the task has already been cancelled,
            // this is the best we can do
            try? await self.cleanup(
                execution: execution,
                input: input,
                childSide: true,
                parentSide: true,
                attemptToTerminateSubProcess: true
            )
        }
    }
}

@available(macOS 9999, *)
extension Configuration : CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        return """
Configuration(
    executable: \(self.executable.description),
    arguments: \(self.arguments.description),
    environment: \(self.environment.description),
    workingDirectory: \(self.workingDirectory),
    platformOptions: \(self.platformOptions.description(withIndent: 1))
)
"""
    }

    public var debugDescription: String {
        return """
Configuration(
    executable: \(self.executable.debugDescription),
    arguments: \(self.arguments.debugDescription),
    environment: \(self.environment.debugDescription),
    workingDirectory: \(self.workingDirectory),
    platformOptions: \(self.platformOptions.description(withIndent: 1))
)
"""
    }
}

// MARK: - Executable

/// `Executable` defines how should the executable
/// be looked up for execution.
@available(macOS 9999, *)
public struct Executable: Sendable, Hashable {
    internal enum Storage: Sendable, Hashable {
        case executable(String)
        case path(FilePath)
    }

    internal let storage: Storage

    private init(_config: Storage) {
        self.storage = _config
    }

    /// Locate the executable by its name.
    /// `Subprocess` will use `PATH` value to
    /// determine the full path to the executable.
    public static func named(_ executableName: String) -> Self {
        return .init(_config: .executable(executableName))
    }
    /// Locate the executable by its full path.
    /// `Subprocess` will use this  path directly.
    public static func at(_ filePath: FilePath) -> Self {
        return .init(_config: .path(filePath))
    }
    /// Returns the full executable path given the environment value.
    public func resolveExecutablePath(in environment: Environment) throws -> FilePath {
        let path = try self.resolveExecutablePath(withPathValue: environment.pathValue())
        return FilePath(path)
    }
}

@available(macOS 9999, *)
extension Executable : CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        switch storage {
        case .executable(let executableName):
            return executableName
        case .path(let filePath):
            return filePath.string
        }
    }

    public var debugDescription: String {
        switch storage {
        case .executable(let string):
            return "executable(\(string))"
        case .path(let filePath):
            return "path(\(filePath.string))"
        }
    }
}

// MARK: - Arguments

/// A collection of arguments to pass to the subprocess.
@available(macOS 9999, *)
public struct Arguments: Sendable, ExpressibleByArrayLiteral, Hashable {
    public typealias ArrayLiteralElement = String

    internal let storage: [StringOrRawBytes]
    internal let executablePathOverride: StringOrRawBytes?

    /// Create an Arguments object using the given literal values
    public init(arrayLiteral elements: String...) {
        self.storage = elements.map { .string($0) }
        self.executablePathOverride = nil
    }
    /// Create an Arguments object using the given array
    public init(_ array: [String]) {
        self.storage = array.map { .string($0) }
        self.executablePathOverride = nil
    }

#if !os(Windows) // Windows does NOT support arg0 override
    /// Create an `Argument` object using the given values, but
    /// override the first Argument value to `executablePathOverride`.
    /// If `executablePathOverride` is nil,
    /// `Arguments` will automatically use the executable path
    /// as the first argument.
    /// - Parameters:
    ///   - executablePathOverride: the value to override the first argument.
    ///   - remainingValues: the rest of the argument value
    public init(executablePathOverride: String?, remainingValues: [String]) {
        self.storage = remainingValues.map { .string($0) }
        if let executablePathOverride = executablePathOverride {
            self.executablePathOverride = .string(executablePathOverride)
        } else {
            self.executablePathOverride = nil
        }
    }

    /// Create an `Argument` object using the given values, but
    /// override the first Argument value to `executablePathOverride`.
    /// If `executablePathOverride` is nil,
    /// `Arguments` will automatically use the executable path
    /// as the first argument.
    /// - Parameters:
    ///   - executablePathOverride: the value to override the first argument.
    ///   - remainingValues: the rest of the argument value
    public init(executablePathOverride: Data?, remainingValues: [Data]) {
        self.storage = remainingValues.map { .rawBytes($0.toArray()) }
        if let override = executablePathOverride {
            self.executablePathOverride = .rawBytes(override.toArray())
        } else {
            self.executablePathOverride = nil
        }
    }

    public init(_ array: [Data]) {
        self.storage = array.map { .rawBytes($0.toArray()) }
        self.executablePathOverride = nil
    }
#endif
}

@available(macOS 9999, *)
extension Arguments : CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        var result: [String] = self.storage.map(\.description)

        if let override = self.executablePathOverride {
            result.insert("override\(override.description)", at: 0)
        }
        return result.description
    }

    public var debugDescription: String { return self.description }
}

// MARK: - Environment

/// A set of environment variables to use when executing the subprocess.
@available(macOS 9999, *)
public struct Environment: Sendable, Hashable {
    internal enum Configuration: Sendable, Hashable {
        case inherit([StringOrRawBytes : StringOrRawBytes])
        case custom([StringOrRawBytes : StringOrRawBytes])
    }

    internal let config: Configuration

    init(config: Configuration) {
        self.config = config
    }
    /// Child process should inherit the same environment
    /// values from its parent process.
    public static var inherit: Self {
        return .init(config: .inherit([:]))
    }
    /// Override the provided `newValue` in the existing `Environment`
    public func updating(_ newValue: [String : String]) -> Self {
        return .init(config: .inherit(newValue.wrapToStringOrRawBytes()))
    }
    /// Use custom environment variables
    public static func custom(_ newValue: [String : String]) -> Self {
        return .init(config: .custom(newValue.wrapToStringOrRawBytes()))
    }

#if !os(Windows)
    /// Override the provided `newValue` in the existing `Environment`
    public func updating(_ newValue: [Data : Data]) -> Self {
        return .init(config: .inherit(newValue.wrapToStringOrRawBytes()))
    }
    /// Use custom environment variables
    public static func custom(_ newValue: [Data : Data]) -> Self {
        return .init(config: .custom(newValue.wrapToStringOrRawBytes()))
    }
#endif
}

@available(macOS 9999, *)
extension Environment : CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        switch self.config {
        case .custom(let customDictionary):
            return customDictionary.dictionaryDescription
        case .inherit(let updateValue):
            return "Inherting current environment with updates: \(updateValue.dictionaryDescription)"
        }
    }

    public var debugDescription: String {
        return self.description
    }
}

// MARK: - TerminationStatus

/// An exit status of a subprocess.
@frozen
@available(macOS 9999, *)
public enum TerminationStatus: Sendable, Hashable, Codable {
#if canImport(WinSDK)
    public typealias Code = DWORD
#else
    public typealias Code = CInt
#endif

    /// The subprocess was existed with the given code
    case exited(Code)
    /// The subprocess was signalled with given exception value
    case unhandledException(Code)
    /// Whether the current TerminationStatus is successful.
    public var isSuccess: Bool {
        switch self {
        case .exited(let exitCode):
            return exitCode == 0
        case .unhandledException(_):
            return false
        }
    }
}

@available(macOS 9999, *)
extension TerminationStatus : CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        switch self {
        case .exited(let code):
            return "exited(\(code))"
        case .unhandledException(let code):
            return "unhandledException(\(code))"
        }
    }

    public var debugDescription: String {
        return self.description
    }
}

// MARK: - Internal

@available(macOS 9999, *)
internal enum StringOrRawBytes: Sendable, Hashable {
    case string(String)
    case rawBytes([CChar])

    // Return value needs to be deallocated manually by callee
    func createRawBytes() -> UnsafeMutablePointer<CChar> {
        switch self {
        case .string(let string):
            return strdup(string)
        case .rawBytes(let rawBytes):
            return strdup(rawBytes)
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let string):
            return string
        case .rawBytes(let rawBytes):
            return String(validatingUTF8: rawBytes)
        }
    }

    var description: String {
        switch self {
        case .string(let string):
            return string
        case .rawBytes(let bytes):
            return bytes.description
        }
    }

    var count: Int {
        switch self {
        case .string(let string):
            return string.count
        case .rawBytes(let rawBytes):
            return strnlen(rawBytes, Int.max)
        }
    }

    func hash(into hasher: inout Hasher) {
        // If Raw bytes is valid UTF8, hash it as so
        switch self {
        case .string(let string):
            hasher.combine(string)
        case .rawBytes(let bytes):
            if let stringValue = self.stringValue {
                hasher.combine(stringValue)
            } else {
                hasher.combine(bytes)
            }
        }
    }
}

extension FilePath {
    static var currentWorkingDirectory: Self {
        let path = getcwd(nil, 0)!
        defer { free(path) }
        return .init(String(cString: path))
    }
}

extension Optional where Wrapped : Collection {
    func withOptionalUnsafeBufferPointer<Result>(
        _ body: ((UnsafeBufferPointer<Wrapped.Element>)?) throws -> Result
    ) rethrows -> Result {
        switch self {
        case .some(let wrapped):
            guard let array: Array<Wrapped.Element> = wrapped as? Array else {
                return try body(nil)
            }
            return try array.withUnsafeBufferPointer { ptr in
                return try body(ptr)
            }
        case .none:
            return try body(nil)
        }
    }
}

extension Optional where Wrapped == String {
    func withOptionalCString<Result>(
        _ body: ((UnsafePointer<Int8>)?) throws -> Result
    ) rethrows -> Result {
        switch self {
        case .none:
            return try body(nil)
        case .some(let wrapped):
            return try wrapped.withCString {
                return try body($0)
            }
        }
    }

    var stringValue: String {
        return self ?? "nil"
    }
}

@available(macOS 9999, *)
fileprivate extension Dictionary where Key == String, Value == String {
    func wrapToStringOrRawBytes() -> [StringOrRawBytes : StringOrRawBytes] {
        var result = Dictionary<
            StringOrRawBytes,
            StringOrRawBytes
        >(minimumCapacity: self.count)
        for (key, value) in self {
            result[.string(key)] = .string(value)
        }
        return result
    }
}

@available(macOS 9999, *)
fileprivate extension Dictionary where Key == Data, Value == Data {
    func wrapToStringOrRawBytes() -> [StringOrRawBytes : StringOrRawBytes] {
        var result = Dictionary<
            StringOrRawBytes,
            StringOrRawBytes
        >(minimumCapacity: self.count)
        for (key, value) in self {
            result[.rawBytes(key.toArray())] = .rawBytes(value.toArray())
        }
        return result
    }
}

@available(macOS 9999, *)
fileprivate extension Dictionary where Key == StringOrRawBytes, Value == StringOrRawBytes {
    var dictionaryDescription: String {
        var result = "[\n"
        for (key, value) in self {
            result += "\t\(key.description) : \(value.description),\n"
        }
        result += "]"
        return result
    }
}

fileprivate extension Data {
    func toArray<T>() -> [T] {
        return self.withUnsafeBytes { ptr in
            return Array(ptr.bindMemory(to: T.self))
        }
    }
}

// MARK: - Stubs for the one from Foundation
public enum QualityOfService: Int, Sendable {
    case userInteractive    = 0x21
    case userInitiated      = 0x19
    case utility            = 0x11
    case background         = 0x09
    case `default`          = -1
}

internal func withAsyncTaskCancellationHandler<Result>(
    _ body: () async throws -> Result,
    onCancel handler: @Sendable @escaping () async -> Void,
    isolation: isolated (any Actor)? = #isolation
) async rethrows -> Result {
    return try await withThrowingTaskGroup(
        of: Void.self,
        returning: Result.self
    ) { group in
        group.addTask {
            // wait until cancelled
            do { while true { try await Task.sleep(nanoseconds: 1_000_000_000) } } catch {}
            // Run task cancel handler
            await handler()
        }

        let result = try await body()
        group.cancelAll()
        return result
    }
}

