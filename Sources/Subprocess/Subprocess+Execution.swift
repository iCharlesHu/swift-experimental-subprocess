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

        internal func captureStandardOutput() throws -> [UInt8]? {
            guard case .collected(let limit, let readFd, _) = self.executionOutput else {
                return nil
            }
            return try readFd.read(upToLength: limit)
        }

        internal func captureStandardError() throws -> [UInt8]? {
            guard case .collected(let limit, let readFd, _) = self.executionError else {
                return nil
            }
            return try readFd.read(upToLength: limit)
        }
    }
}

// MARK: - StandardInputWriter
extension Subprocess {
    internal actor StandardInputWriterActor {
        private let fileDescriptor: FileDescriptor

        internal init(fileDescriptor: FileDescriptor) {
            self.fileDescriptor = fileDescriptor
        }

        @discardableResult
        public func write<S>(_ sequence: S) async throws -> Int where S : Sequence, S.Element == UInt8 {
            return try self.fileDescriptor.writeAll(sequence)
        }

        @discardableResult
        public func write<S: AsyncSequence>(_ asyncSequence: S) async throws -> Int where S.Element == UInt8 {
            let sequence = try await Array(asyncSequence)
            return try self.fileDescriptor.writeAll(sequence)
        }

        public func finish() async throws {
            try self.fileDescriptor.close()
        }
    }

    public struct StandardInputWriter {

        private let actor: StandardInputWriterActor

        init(fileDescriptor: FileDescriptor) {
            self.actor = StandardInputWriterActor(fileDescriptor: fileDescriptor)
        }

        @discardableResult
        public func write<S>(_ sequence: S) async throws -> Int where S : Sequence, S.Element == UInt8 {
            return try await self.actor.write(sequence)
        }

        @discardableResult
        public func write<S>(_ sequence: S) async throws -> Int where S : Sequence, S.Element == CChar {
            return try await self.actor.write(sequence.map { UInt8($0) })
        }

        @discardableResult
        public func write<S: AsyncSequence>(_ asyncSequence: S) async throws -> Int where S.Element == CChar {
            let sequence = try await Array(asyncSequence).map { UInt8($0) }
            return try await self.actor.write(sequence)
        }

        @discardableResult
        public func write<S: AsyncSequence>(_ asyncSequence: S) async throws -> Int where S.Element == UInt8 {
            let sequence = try await Array(asyncSequence)
            return try await self.actor.write(sequence)
        }

        public func finish() async throws {
            try await self.actor.finish()
        }
    }
}

// MARK: - Result
extension Subprocess {
    public struct Result<T> {
        public let terminationStatus: TerminationStatus
        public let value: T

        internal init(terminationStatus: TerminationStatus, value: T) {
            self.terminationStatus = terminationStatus
            self.value = value
        }
    }

    public struct CapturedResult {
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
