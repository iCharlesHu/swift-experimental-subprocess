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

@preconcurrency import SystemPackage

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

import _Shims
import FoundationEssentials

extension Subprocess {
    public struct Configuration: Sendable {

        internal enum RunState<Result: Sendable>: Sendable {
            case workBody(Result)
            case monitorChildProcess(TerminationStatus)
        }

        // Configurable properties
        public var executable: ExecutableConfiguration
        public var arguments: Arguments
        public var environment: Environment
        public var workingDirectory: FilePath
        public var qualityOfService: QualityOfService
#if canImport(Darwin)
        public var additionalSpawnAttributeConfiguration: (@Sendable (inout posix_spawnattr_t?) throws -> Void)?
        public var additionalFileAttributeConfiguration: (@Sendable (inout posix_spawn_file_actions_t?) throws -> Void)?
#endif

        public init(
            executable: ExecutableConfiguration,
            arguments: Arguments = [],
            environment: Environment = .inheritFromLaunchingProcess,
            workingDirectory: FilePath? = nil,
            qualityOfService: QualityOfService = .default
        ) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
            self.workingDirectory = workingDirectory ?? .currentWorkingDirectory
            self.qualityOfService = qualityOfService
        }

        public func run<R: Sendable>(
            output: RedirectedOutputMethod,
            error: RedirectedOutputMethod,
            _ body: @Sendable @escaping (borrowing Execution, StandardInputWriter) async throws -> R
        ) async throws -> R {
            let (readFd, writeFd) = try FileDescriptor.pipe()
            let executionInput: ExecutionInput = .customWrite(readFd, writeFd)
            let executionOutput: ExecutionOutput = try output.createExecutionOutput()
            let executionError: ExecutionOutput = try error.createExecutionOutput()
            let execution: Execution = try self.spawn(
                withInput: executionInput,
                output: executionOutput,
                error: executionError)
            return try await withThrowingTaskGroup(of: RunState<R>.self) { group in
                group.addTask {
                    let status = await execution.monitorTask.value
                    return .monitorChildProcess(status)
                }
                group.addTask {
                    let result = try await body(execution, .init(fileDescriptor: writeFd))
                    // Clean up
                    try execution.executionInput.closeAll()
                    try execution.executionOutput.closeAll()
                    try execution.executionError.closeAll()
                    return .workBody(result)
                }

                var result: R!
                while let state = try await group.next() {
                    switch state {
                    case .monitorChildProcess(_):
                        // We don't really care about termination status here
                        break
                    case .workBody(let workResult):
                        result = workResult
                    }
                }
                return result
            }
        }

        public func run<R>(
            input: InputMethod,
            output: RedirectedOutputMethod,
            error: RedirectedOutputMethod,
            _ body: (@Sendable @escaping (borrowing Execution) async throws -> R)
        ) async throws -> R {
            let executionInput = try input.createExecutionInput()
            let executionOutput = try output.createExecutionOutput()
            let executionError = try error.createExecutionOutput()
            let execution = try self.spawn(
                withInput: executionInput,
                output: executionOutput,
                error: executionError)
            return try await withThrowingTaskGroup(of: RunState<R>.self) { group in
                group.addTask {
                    let status = await execution.monitorTask.value
                    return .monitorChildProcess(status)
                }
                group.addTask {
                    let result = try await body(execution)
                    // Clean up
                    try execution.executionInput.closeAll()
                    try execution.executionOutput.closeAll()
                    try execution.executionError.closeAll()
                    return .workBody(result)
                }

                var result: R!
                while let state = try await group.next() {
                    switch state {
                    case .monitorChildProcess(_):
                        // Here we don't care about termination status
                        break
                    case .workBody(let workResult):
                        result = workResult
                    }
                }
                return result
            }
        }
    }
}

// MARK: - ExecutableConfiguration
extension Subprocess {
    public struct ExecutableConfiguration: Sendable, CustomStringConvertible {
        internal enum Configuration {
            case executable(String)
            case path(FilePath)
        }

        internal let storage: Configuration

        public var description: String {
            switch storage {
            case .executable(let executableName):
                return executableName
            case .path(let filePath):
                return filePath.string
            }
        }

        private init(_config: Configuration) {
            self.storage = _config
        }

        public static func named(_ executableName: String) -> Self {
            return .init(_config: .executable(executableName))
        }

        public static func at(_ filePath: FilePath) -> Self {
            return .init(_config: .path(filePath))
        }
    }
}

// MARK: - Arguments
extension Subprocess {
    public struct Arguments: Sendable, ExpressibleByArrayLiteral {
        public typealias ArrayLiteralElement = String

        internal let storage: [StringOrRawBytes]
        internal let executablePathOverride: StringOrRawBytes?

        public init(arrayLiteral elements: String...) {
            self.storage = elements.map { .string($0) }
            self.executablePathOverride = nil
        }

        public init(_ array: [String], executablePathOverride: String) {
            self.storage = array.map { .string($0) }
            self.executablePathOverride = .string(executablePathOverride)
        }

        public init<S: Sequence>(_ array: [S], executablePathOverride: S? = nil) where S.Element == CChar {
            self.storage = array.map { .rawBytes(Array($0)) }
            if let override = executablePathOverride {
                self.executablePathOverride = .rawBytes(Array(override))
            } else {
                self.executablePathOverride = nil
            }
        }
    }
}

// MARK: - Environment
extension Subprocess {
    public struct Environment: Sendable {
        internal enum Configuration {
            case inheritFromLaunchingProcess([StringOrRawBytes : StringOrRawBytes])
            case custom([StringOrRawBytes : StringOrRawBytes])
        }

        internal let config: Configuration

        init(config: Configuration) {
            self.config = config
        }

        public static var inheritFromLaunchingProcess: Self {
            return .init(config: .inheritFromLaunchingProcess([:]))
        }

        public func updating(_ newValue: [String : String]) -> Self {
            return .init(config: .inheritFromLaunchingProcess(newValue.wrapToStringOrRawBytes()))
        }

        public func updating<S: Sequence>(_ newValue: [S : S]) -> Self where S.Element == CChar {
            return .init(config: .inheritFromLaunchingProcess(newValue.wrapToStringOrRawBytes()))
        }

        public static func custom(_ newValue: [String : String]) -> Self {
            return .init(config: .custom(newValue.wrapToStringOrRawBytes()))
        }

        public static func custom<S: Sequence>(_ newValue: [S : S]) -> Self where S.Element == CChar {
            return .init(config: .custom(newValue.wrapToStringOrRawBytes()))
        }
    }
}

fileprivate extension Dictionary where Key == String, Value == String {
    func wrapToStringOrRawBytes() -> [Subprocess.StringOrRawBytes : Subprocess.StringOrRawBytes] {
        var result = Dictionary<
            Subprocess.StringOrRawBytes,
            Subprocess.StringOrRawBytes
        >(minimumCapacity: self.count)
        for (key, value) in self {
            result[.string(key)] = .string(value)
        }
        return result
    }
}

fileprivate extension Dictionary where Key : Sequence<CChar>, Value : Sequence<CChar> {
    func wrapToStringOrRawBytes() -> [Subprocess.StringOrRawBytes : Subprocess.StringOrRawBytes] {
        var result = Dictionary<
            Subprocess.StringOrRawBytes,
            Subprocess.StringOrRawBytes
        >(minimumCapacity: self.count)
        for (key, value) in self {
            result[.rawBytes(Array(key))] = .rawBytes(Array(value))
        }
        return result
    }
}

// MARK: - ProcessIdentifier
extension Subprocess {
    public struct ProcessIdentifier: Sendable {
        let value: pid_t

        public init(value: pid_t) {
            self.value = value
        }
    }
}

// MARK: - TerminationStatus
extension Subprocess {
    public enum TerminationStatus: Sendable {
        #if canImport(WinSDK)
        public typealias Code = DWORD
        #else
        public typealias Code = CInt
        #endif

        #if canImport(WinSDK)
        case stillActive
        #endif

        case exit(Code)
        case unhandledException(Code)

        public var isSuccess: Bool {
            switch self {
            case .exit(let exitCode):
                return exitCode == 0
            case .unhandledException(_):
                return false
            }
        }

        public var wasUnhandledException: Bool {
            switch self {
            case .exit(_):
                return false
            case .unhandledException(_):
                return true
            }
        }
    }
}

// MARK: - Internal
extension Subprocess {
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

        var count: Int {
            switch self {
            case .string(let string):
                return string.count
            case .rawBytes(let rawBytes):
                return strnlen(rawBytes, Int.max)
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

// MARK: - Stubs
public enum QualityOfService: Int, Sendable {
    case userInteractive    = 0x21
    case userInitiated      = 0x19
    case utility            = 0x11
    case background         = 0x09
    case `default`          = -1
}
