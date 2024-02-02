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
        public var executable: Executable
        public var arguments: Arguments
        public var environment: Environment
        public var workingDirectory: FilePath
        public var platformOptions: PlatformOptions

        public init(
            executable: Executable,
            arguments: Arguments = [],
            environment: Environment = .inherit,
            workingDirectory: FilePath? = nil,
            platformOptions: PlatformOptions = .default
        ) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
            self.workingDirectory = workingDirectory ?? .currentWorkingDirectory
            self.platformOptions = platformOptions
        }

        public func run<R>(
            output: RedirectedOutputMethod,
            error: RedirectedOutputMethod,
            _ body: @Sendable @escaping (Subprocess, StandardInputWriter) async throws -> R
        ) async throws -> Result<R> {
            let (readFd, writeFd) = try FileDescriptor.pipe()
            let executionInput: ExecutionInput = .customWrite(readFd, writeFd)
            let executionOutput: ExecutionOutput = try output.createExecutionOutput()
            let executionError: ExecutionOutput = try error.createExecutionOutput()
            let process: Subprocess = try self.spawn(
                withInput: executionInput,
                output: executionOutput,
                error: executionError)
            return try await withThrowingTaskGroup(of: RunState<R>.self) { group in
                @Sendable func cleanup() throws {
                    // Clean up
                    try process.executionInput.closeAll()
                    try process.executionOutput.closeAll()
                    try process.executionError.closeAll()
                }

                group.addTask {
                    let status = monitorProcessTermination(
                        forProcessWithIdentifier: process.processIdentifier)
                    return .monitorChildProcess(status)
                }
                group.addTask {
                    do {
                        let result = try await body(process, .init(fileDescriptor: writeFd))
                        try cleanup()
                        return .workBody(result)
                    } catch {
                        try cleanup()
                        throw error
                    }
                }

                var result: R!
                var terminationStatus: TerminationStatus!
                while let state = try await group.next() {
                    switch state {
                    case .monitorChildProcess(let status):
                        // We don't really care about termination status here
                        terminationStatus = status
                    case .workBody(let workResult):
                        result = workResult
                    }
                }
                return Result(terminationStatus: terminationStatus, value: result)
            }
        }

        public func run<R>(
            input: InputMethod,
            output: RedirectedOutputMethod,
            error: RedirectedOutputMethod,
            _ body: (@Sendable @escaping (Subprocess) async throws -> R)
        ) async throws -> Result<R> {
            let executionInput = try input.createExecutionInput()
            let executionOutput = try output.createExecutionOutput()
            let executionError = try error.createExecutionOutput()
            let process = try self.spawn(
                withInput: executionInput,
                output: executionOutput,
                error: executionError)
            return try await withThrowingTaskGroup(of: RunState<R>.self) { group in
                @Sendable func cleanup() throws {
                    try process.executionInput.closeAll()
                    try process.executionOutput.closeAll()
                    try process.executionError.closeAll()
                }
                group.addTask {
                    let status = monitorProcessTermination(
                        forProcessWithIdentifier: process.processIdentifier)
                    return .monitorChildProcess(status)
                }
                group.addTask {
                    do {
                        let result = try await body(process)
                        try cleanup()
                        return .workBody(result)
                    } catch {
                        try cleanup()
                        throw error
                    }
                }

                var result: R!
                var terminationStatus: TerminationStatus!
                while let state = try await group.next() {
                    switch state {
                    case .monitorChildProcess(let status):
                        terminationStatus = status
                    case .workBody(let workResult):
                        result = workResult
                    }
                }
                return Result(terminationStatus: terminationStatus, value: result)
            }
        }
    }
}

// MARK: - Executable
extension Subprocess {
    public struct Executable: Sendable, CustomStringConvertible, Hashable {
        internal enum Configuration: Sendable, Hashable {
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

        public init(_ array: [Data], executablePathOverride: Data? = nil) {
            self.storage = array.map { .rawBytes($0.toArray()) }
            if let override = executablePathOverride {
                self.executablePathOverride = .rawBytes(override.toArray())
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
            case inherit([StringOrRawBytes : StringOrRawBytes])
            case custom([StringOrRawBytes : StringOrRawBytes])
        }

        internal let config: Configuration

        init(config: Configuration) {
            self.config = config
        }

        public static var inherit: Self {
            return .init(config: .inherit([:]))
        }

        public func updating(_ newValue: [String : String]) -> Self {
            return .init(config: .inherit(newValue.wrapToStringOrRawBytes()))
        }

        public func updating(_ newValue: [Data : Data]) -> Self {
            return .init(config: .inherit(newValue.wrapToStringOrRawBytes()))
        }

        public static func custom(_ newValue: [String : String]) -> Self {
            return .init(config: .custom(newValue.wrapToStringOrRawBytes()))
        }

        public static func custom(_ newValue: [Data : Data]) -> Self {
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

fileprivate extension Dictionary where Key == Data, Value == Data {
    func wrapToStringOrRawBytes() -> [Subprocess.StringOrRawBytes : Subprocess.StringOrRawBytes] {
        var result = Dictionary<
            Subprocess.StringOrRawBytes,
            Subprocess.StringOrRawBytes
        >(minimumCapacity: self.count)
        for (key, value) in self {
            result[.rawBytes(key.toArray())] = .rawBytes(value.toArray())
        }
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

// MARK: - ProcessIdentifier
extension Subprocess {
    public struct ProcessIdentifier: Sendable, Hashable {
        let value: pid_t

        public init(value: pid_t) {
            self.value = value
        }
    }
}

// MARK: - TerminationStatus
extension Subprocess {
    public enum TerminationStatus: Sendable, Hashable {
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

        public var isUnhandledException: Bool {
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

// MARK: - Stubs for the one from Foundation
public enum QualityOfService: Int, Sendable {
    case userInteractive    = 0x21
    case userInitiated      = 0x19
    case utility            = 0x11
    case background         = 0x09
    case `default`          = -1
}
