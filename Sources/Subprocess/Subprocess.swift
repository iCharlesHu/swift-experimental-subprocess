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

// MARK: - Result
extension Subprocess {
    /// Conform to this protocol if you wish to have `Subprocess.run` return
    /// your custom type. For example:
    /// ```
    /// extension MyType : Subprocess.OutputConvertible { ... }
    ///
    /// let result = try await Subprocess.run(
    ///     .at(...),
    ///     output: .collect(as: MyType.self)
    /// )
    ///
    /// print(result.standardOutput) // MyType
    /// ```
    public protocol OutputConvertible {
        static func convert(from input: Data) -> Self
    }

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
            standardOutput: Data?,
            standardError: Data?,
            output: Output,
            error: Error
        ) {
            self.processIdentifier = processIdentifier
            self.terminationStatus = terminationStatus
            self._standardOutput = standardOutput
            self._standardError = standardError
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
    }
}

extension Data : Subprocess.OutputConvertible {
    public static func convert(from data: Data) -> Self {
        return data
    }
}

extension Subprocess.CollectedResult where Output.OutputType: Subprocess.OutputConvertible {
    /// The collected standard output value for the subprocess.
    /// Accessing this property will *fatalError* if the
    /// corresponding `CollectedOutputMethod` is not set to
    /// `.collect` or `.collect(upTo:)`
    public var standardOutput: Output.OutputType {
        guard let output = self._standardOutput else {
            fatalError("standardOutput is only available if the Subprocess was ran with .collect as output")
        }
        return Output.OutputType.convert(from: output)
    }
}

extension Subprocess.CollectedResult where Error.OutputType : Subprocess.OutputConvertible {
    /// The collected standard error value for the subprocess.
    /// Accessing this property will *fatalError* if the
    /// corresponding `CollectedOutputMethod` is not set to
    /// `.collect` or `.collect(upTo:)`
    public var standardError: Error.OutputType {
        guard let output = self._standardError else {
            fatalError("standardError is only available if the Subprocess was ran with .collect as error ")
        }
        return Error.OutputType.convert(from: output)
    }
}

extension Subprocess.CollectedResult where Output == Subprocess.StringOutput {
    /// The collected standard output value for the subprocess.
    /// Accessing this property will *fatalError* if the
    /// corresponding `CollectedOutputMethod` is not set to
    /// `.collect` or `.collect(upTo:)`
    public var standardOutput: String? {
        guard let output = self._standardOutput else {
            fatalError("standardOutput is only available if the Subprocess was ran with .collect as output")
        }
        return String(data: output, encoding: self.output.encoding)
    }
}

extension Subprocess.CollectedResult where Error == Subprocess.StringOutput {
    public var standardError: String? {
        guard let output = self._standardError else {
            fatalError("standardOutput is only available if the Subprocess was ran with .collect as output")
        }
        return String(data: output, encoding: self.error.encoding)
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

extension Subprocess.CollectedResult {
    /// A simple wrapper that offers a convinent way to access
    /// the Subprocess output as Data or String assuming UTF8
    /// encoding.
    public struct OutputWrapper: Sendable, Hashable, Codable {
        public let data: Data
        public var stringUsingUTF8: String? {
            return String(data: self.data, encoding: .utf8)
        }

        internal init(data: Data) {
            self.data = data
        }
    }
}

