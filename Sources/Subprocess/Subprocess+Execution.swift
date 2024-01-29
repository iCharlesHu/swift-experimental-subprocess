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
import Darwin
import FoundationEssentials

extension Subprocess {
    public struct Execution: ~Copyable, Sendable {
        public let processIdentifier: ProcessIdentifier

        internal let monitorTask: Task<TerminationStatus, Never>
        internal let executionInput: ExecutionInput
        internal let executionOutput: ExecutionOutput
        internal let executionError: ExecutionOutput

        internal init(processIdentifier: ProcessIdentifier, executionInput: ExecutionInput, executionOutput: ExecutionOutput, executionError: ExecutionOutput) {
            self.processIdentifier = processIdentifier
            self.executionInput = executionInput
            self.executionOutput = executionOutput
            self.executionError = executionError
            self.monitorTask = Task {
                return monitorProcessTermination(
                    forProcessWithIdentifier: processIdentifier)
            }
        }

        public var terminationStatus: TerminationStatus {
            get async {
                return await self.monitorTask.value
            }
        }

        public var standardOutput: AsyncBytes? {
            switch self.executionOutput {
            case .discarded(_), .fileDescriptor(_):
                // The output has been written somewhere else
                return nil
            case .collected(_, let readFd, _):
                return AsyncBytes(file: readFd)
            }
        }

        public var standardError: AsyncBytes? {
            switch self.executionError {
            case .discarded(_), .fileDescriptor(_):
                // The output has been written somewhere else
                return nil
            case .collected(_, let readFd, _):
                return AsyncBytes(file: readFd)
            }
        }

        internal func createExecutionResult() async throws -> ExecutionResult {
            let terminationStatus = await self.terminationStatus
            var standardOutput: [UInt8]? = nil
            var standardError: [UInt8]? = nil

            if case .collected(let limit, let readFd, _) = self.executionOutput {
                standardOutput = try readFd.read(upToLength: limit)
            }

            if case .collected(let limit, let readFd, _) = self.executionError {
                standardError = try readFd.read(upToLength: limit)
            }

            return ExecutionResult(
                processIdentifier: self.processIdentifier,
                terminationStatus: terminationStatus,
                standardOutput: standardOutput,
                standardError: standardError
            )
        }
    }
}

// MARK: - StandardInputWriter
extension Subprocess {
    public actor StandardInputWriter {

        private let fileDescriptor: FileDescriptor

        init(fileDescriptor: FileDescriptor) {
            self.fileDescriptor = fileDescriptor
        }

        @discardableResult
        public func write<S>(_ sequence: S) async throws -> Int where S : Sequence, S.Element == UInt8 {
            return try self.fileDescriptor.writeAll(sequence)
        }

        @discardableResult
        public func write<S>(_ sequence: S) async throws -> Int where S : Sequence, S.Element == CChar {
            return try self.fileDescriptor.writeAll(sequence.map { UInt8($0) })
        }

        @discardableResult
        public func write<S: AsyncSequence>(_ asyncSequence: S) async throws -> Int where S.Element == CChar {
            let sequence = try await Array(asyncSequence).map { UInt8($0) }
            return try self.fileDescriptor.writeAll(sequence)
        }

        @discardableResult
        public func write<S: AsyncSequence>(_ asyncSequence: S) async throws -> Int where S.Element == UInt8 {
            let sequence = try await Array(asyncSequence)
            return try self.fileDescriptor.writeAll(sequence)
        }

        public func finishWriting() async throws {
            try self.fileDescriptor.close()
        }
    }
}

// MARK: - ExecutionResult
extension Subprocess {
    public struct ExecutionResult {
        public let processIdentifier: ProcessIdentifier
        public let terminationStatus: TerminationStatus
        public let standardOutput: [UInt8]?
        public let standardError: [UInt8]?

        internal init(
            processIdentifier: ProcessIdentifier,
            terminationStatus: TerminationStatus,
            standardOutput: [UInt8]?,
            standardError: [UInt8]?) {
            self.processIdentifier = processIdentifier
            self.terminationStatus = terminationStatus
            self.standardOutput = standardOutput
            self.standardError = standardError
        }
    }
}

// MARK: - Signals
extension Subprocess.Execution {
    public struct Signal : Hashable, Sendable {
        public let rawValue: Int32

        private init(rawValue: Int32) {
            self.rawValue = rawValue
        }

        public static var interrupt: Self { .init(rawValue: SIGINT) }
        public static var terminate: Self { .init(rawValue: SIGTERM) }
        public static var suspend: Self { .init(rawValue: SIGSTOP) }
        public static var resume: Self { .init(rawValue: SIGCONT) }
        public static var kill: Self { .init(rawValue: SIGKILL) }
    }

    public func sendSignal(_ signal: Signal) throws {
        guard kill(-(self.processIdentifier.value), signal.rawValue) == 0 else {
            throw POSIXError(.init(rawValue: errno)!)
        }
    }
}

extension POSIXError : Swift.Error {}
