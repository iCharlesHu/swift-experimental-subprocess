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
import Dispatch

#if canImport(FoundationEssentials)
import FoundationEssentials
#elseif canImport(Foundation)
import Foundation
#endif

// MARK: - Result
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
    >: Sendable, Hashable {
        /// The process identifier for the executed subprocess
        public let processIdentifier: ProcessIdentifier
        /// The termination status of the executed subprocess
        public let terminationStatus: TerminationStatus
        private let _standardOutput: Data?
        private let _standardError: Data?
        private let output: Output
        private let error: Error

        internal init(
            processIdentifier: ProcessIdentifier,
            terminationStatus: TerminationStatus,
            output: Output,
            error: Error,
            standardOutputData: Data?,
            standardErrorData: Data?
        ) {
            self.processIdentifier = processIdentifier
            self.terminationStatus = terminationStatus
            self._standardOutput = standardOutputData
            self._standardError = standardErrorData
            self.output = output
            self.error = error
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(self.processIdentifier)
            hasher.combine(self.terminationStatus)
            hasher.combine(self._standardOutput)
            hasher.combine(self._standardError)
        }

        public static func ==(lhs: Self, rhs: Self) -> Bool {
            return lhs.processIdentifier == rhs.processIdentifier
            && lhs.terminationStatus == rhs.terminationStatus
            && lhs._standardOutput == rhs._standardOutput
            && lhs._standardError == rhs._standardError
        }

        /// The collected standard output value for the subprocess.
        public var standardOutput: Output.OutputType {
            guard let output = self._standardOutput else {
                fatalError("standardOutput is only available if the Subprocess was ran with .collect as output")
            }
            return self.output.convert(from: output)
        }

        /// The collected standard error value for the subprocess.
        public var standardError: Error.OutputType {
            guard let error = self._standardError else {
                fatalError("standardError is only available if the Subprocess was ran with .collect as error ")
            }
            return self.error.convert(from: error)
        }
    }
}
extension Subprocess.ExecutionResult: Equatable where Result : Equatable {}

extension Subprocess.ExecutionResult: Hashable where Result : Hashable {}

extension Subprocess.ExecutionResult: Codable where Result : Codable {}

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

extension Subprocess.CollectedResult : CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        return """
Subprocess.CollectedResult(
    processIdentifier: \(self.processIdentifier.description),
    terminationStatus: \(self.terminationStatus.description),
    standardOutput: \(self._standardOutput?.description ?? "not captured"),
    standardError: \(self._standardError?.description ?? "not captured")
)
"""
    }

    public var debugDescription: String {
        return """
Subprocess.CollectedResult(
    processIdentifier: \(self.processIdentifier.debugDescription),
    terminationStatus: \(self.terminationStatus.debugDescription),
    standardOutput: \(self._standardOutput?.debugDescription ?? "not captured"),
    standardError: \(self._standardError?.debugDescription ?? "not captured")
)
"""
    }
}

// MARK: - StandardInputWriter
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
            guard let fd: FileDescriptor = try self.input.getWriteFileDescriptor() else {
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

