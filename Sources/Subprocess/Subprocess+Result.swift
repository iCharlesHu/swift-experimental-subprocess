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

import System
import Dispatch

#if canImport(FoundationEssentials)
import FoundationEssentials
#elseif canImport(Foundation)
import Foundation
#endif

// MARK: - Result
@available(macOS 9999, *)
extension Subprocess {
    /// A simple wrapper around the generic result returned by the
    /// `run` closures with the corresponding `TerminationStatus`
    /// of the child process.
    public struct ExecutionResult<Result> {
        /// The termination status of the child process
        public let terminationStatus: TerminationStatus
        /// The result returned by the closure passed to `.run` methods
        public let value: Result

        internal init(terminationStatus: TerminationStatus, value: Result) {
            self.terminationStatus = terminationStatus
            self.value = value
        }
    }

    /// The result of a subprocess execution with its collected
    /// standard output and standard error.
    public struct CollectedResult<
        Output: Subprocess.OutputProtocol,
        Error:Subprocess.OutputProtocol
    >: Sendable {
        /// The process identifier for the executed subprocess
        public let processIdentifier: ProcessIdentifier
        /// The termination status of the executed subprocess
        public let terminationStatus: TerminationStatus
        public let standardOutput: Output.OutputType
        public let standardError: Error.OutputType

        internal init(
            processIdentifier: ProcessIdentifier,
            terminationStatus: TerminationStatus,
            standardOutput: Output.OutputType,
            standardError: Error.OutputType
        ) {
            self.processIdentifier = processIdentifier
            self.terminationStatus = terminationStatus
            self.standardOutput = standardOutput
            self.standardError = standardError
        }
    }
}

// MARK: - CollectedResult Conformances
@available(macOS 9999, *)
extension Subprocess.CollectedResult: Equatable where Output.OutputType: Equatable, Error.OutputType: Equatable {}

@available(macOS 9999, *)
extension Subprocess.CollectedResult: Hashable where Output.OutputType: Hashable, Error.OutputType: Hashable {}

@available(macOS 9999, *)
extension Subprocess.CollectedResult: Codable where Output.OutputType: Codable, Error.OutputType: Codable {}

@available(macOS 9999, *)
extension Subprocess.CollectedResult: CustomStringConvertible where Output.OutputType: CustomStringConvertible, Error.OutputType: CustomStringConvertible {
    public var description: String {
        return """
Subprocess.CollectedResult(
    processIdentifier: \(self.processIdentifier),
    terminationStatus: \(self.terminationStatus.description),
    standardOutput: \(self.standardOutput.description)
    standardError: \(self.standardError.description)
)
"""
    }
}

@available(macOS 9999, *)
extension Subprocess.CollectedResult: CustomDebugStringConvertible where Output.OutputType: CustomDebugStringConvertible, Error.OutputType: CustomDebugStringConvertible {
    public var debugDescription: String {
        return """
Subprocess.CollectedResult(
    processIdentifier: \(self.processIdentifier),
    terminationStatus: \(self.terminationStatus.description),
    standardOutput: \(self.standardOutput.debugDescription)
    standardError: \(self.standardError.debugDescription)
)
"""
    }
}


// MARK: - ExecutionResult Conformances
@available(macOS 9999, *)
extension Subprocess.ExecutionResult: Equatable where Result : Equatable {}

@available(macOS 9999, *)
extension Subprocess.ExecutionResult: Hashable where Result : Hashable {}

@available(macOS 9999, *)
extension Subprocess.ExecutionResult: Codable where Result : Codable {}

@available(macOS 9999, *)
extension Subprocess.ExecutionResult: CustomStringConvertible where Result : CustomStringConvertible {
    public var description: String {
        return """
Subprocess.ExecutionResult(
    terminationStatus: \(self.terminationStatus.description),
    value: \(self.value.description)
)
"""
    }
}

@available(macOS 9999, *)
extension Subprocess.ExecutionResult: CustomDebugStringConvertible where Result : CustomDebugStringConvertible {
    public var debugDescription: String {
        return """
Subprocess.ExecutionResult(
    terminationStatus: \(self.terminationStatus.debugDescription),
    value: \(self.value.debugDescription)
)
"""
    }
}

// MARK: - StandardInputWriter
@available(macOS 9999, *)
extension Subprocess {
    /// A writer that writes to the standard input of the subprocess.
    public final actor StandardInputWriter: Sendable {

        private let input: CustomWriteInput

        init(input: CustomWriteInput) {
            self.input = input
        }

        /// Write a sequence of UInt8 to the standard input of the subprocess.
        /// - Parameter sequence: The sequence of bytes to write.
        public func write<SendableSequence: Sequence<UInt8> & Sendable>(
            _ sequence: SendableSequence
        ) async throws {
            guard let fd: FileDescriptor = try self.input.writeFileDescriptor() else {
                fatalError("Attempting to write to a file descriptor that's already closed")
            }
            if let array = sequence as? Array<UInt8> {
                try await fd.write(array)
            } else {
                try await fd.write(Array(sequence))
            }
        }

        /// Write a sequence of CChar to the standard input of the subprocess.
        /// - Parameter sequence: The sequence of bytes to write.
        public func write(
            _ string: some StringProtocol,
            using encoding: String.Encoding = .utf8
        ) async throws {
            guard encoding != .utf8 else {
                try await self.write(Data(string.utf8))
                return
            }
            if let data = string.data(using: encoding) {
                try await self.write(data)
            }
        }

        /// Write a AsyncSequence of UInt8 to the standard input of the subprocess.
        /// - Parameter sequence: The sequence of bytes to write.
        public func write<AsyncSendableSequence: AsyncSequence & Sendable>(
            _ asyncSequence: AsyncSendableSequence
        ) async throws where AsyncSendableSequence.Element == Data {
            var buffer = Data()
            for try await data in asyncSequence {
                buffer.append(data)
            }
            try await self.write(buffer)
        }

        /// Signal all writes are finished
        public func finish() async throws {
            try self.input.closeWriteFileDescriptor()
        }
    }
}

