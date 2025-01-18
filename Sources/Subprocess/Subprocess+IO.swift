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

#if canImport(FoundationEssentials)
import FoundationEssentials
#elseif canImport(Foundation)
import Foundation
#endif

import Dispatch
import SystemPackage
import Synchronization

// MARK: - Input
extension Subprocess {
    /// The `InputProtocol` protocol specifies the set of methods that a type
    /// must implement to serve as the input source for a subprocess.
    /// Instead of developing custom implementations of `InputProtocol`,
    /// it is recommended to utilize the default implementations provided
    /// by the `Subprocess` library to specify the input handling requirements.
    public protocol InputProtocol: Sendable {
        /// Lazily create and return the FileDescriptor for reading
        func readFileDescriptor() throws -> FileDescriptor?
        /// Lazily create and return the FileDescriptor for writing
        func writeFileDescriptor() throws -> FileDescriptor?

        /// Close the FileDescriptor for reading
        func closeReadFileDescriptor() throws
        /// Close the FileDescriptor for writing
        func closeWriteFileDescriptor() throws

        /// Asynchronously write the input to the subprocess using the
        /// write file descriptor
        func write() async throws
    }

    /// A concrete `Input` type for subprocesses that indicates
    /// the absence of input to the subprocess. On Unix-like systems,
    /// `NoInput` redirects the standard input of the subprocess
    /// to `/dev/null`, while on Windows, it does not bind any
    /// file handle to the subprocess standard input handle.
    public struct NoInput: InputProtocol {
        private let devnull: LockedState<FileDescriptor?>

        public func readFileDescriptor() throws -> FileDescriptor? {
            return try self.devnull.withLock { fd in
                if let devnull = fd {
                    return devnull
                }
                let devnull: FileDescriptor = try .openDevNull(withAcessMode: .readOnly)
                fd = devnull
                return devnull
            }
        }

        public func writeFileDescriptor() throws -> FileDescriptor? {
            return nil
        }

        public func closeReadFileDescriptor() throws {
            try self.devnull.withLock { fd in
                try fd?.close()
                fd = nil
            }
        }

        public func closeWriteFileDescriptor() throws {
            // NOOP
        }

        public func write() async throws {
            // NOOP
        }

        internal init() {
            self.devnull = LockedState(initialState: nil)
        }
    }

    /// A concrete `Input` type for subprocesses that
    /// reads input from a specified `FileDescriptor`.
    /// Developers have the option to instruct the `Subprocess` to
    /// automatically close the provided `FileDescriptor`
    /// after the subprocess is spawned.
    public struct FileDescriptorInput: InputProtocol {
        private let closeAfterSpawningProcess: Bool
        private let fileDescriptor: LockedState<FileDescriptor?>

        public func readFileDescriptor() throws -> FileDescriptor? {
            return self.fileDescriptor.withLock { $0 }
        }

        public func writeFileDescriptor() throws -> FileDescriptor? {
            return nil
        }

        public func closeReadFileDescriptor() throws {
            if self.closeAfterSpawningProcess {
                try self.fileDescriptor.withLock { fd in
                    try fd?.close()
                    fd = nil
                }
            }
        }

        public func closeWriteFileDescriptor() throws {
            // NOOP
        }

        public func write() async throws {
            // NOOP
        }

        internal init(
            fileDescriptor: FileDescriptor,
            closeAfterSpawningProcess: Bool
        ) {
            self.fileDescriptor = LockedState(initialState: fileDescriptor)
            self.closeAfterSpawningProcess = closeAfterSpawningProcess
        }
    }

    /// A concrete `Input` type for subprocesses that reads input
    /// from a given type conforming to `StringProtocol`.
    /// Developers can specify the string encoding to use when
    /// encoding the string to data, which defaults to UTF-8.
    public final class StringInput<
        InputString: StringProtocol & Sendable
    >: InputProtocol {
        private let string: InputString
        internal let encoding: String.Encoding
        internal let queue: DispatchQueue
        internal let pipe: LockedState<(readEnd: FileDescriptor?, writeEnd: FileDescriptor?)?>

        public func write() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let writeEnd = self.pipe.withLock { pipeStore in
                    return pipeStore?.writeEnd
                }
                guard let writeEnd = writeEnd else {
                    fatalError("Attempting to write before process is launched")
                }
                guard let data = self.string.data(using: self.encoding) else {
                    continuation.resume()
                    return
                }
                writeEnd.write(data) { error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }

        public func readFileDescriptor() throws -> FileDescriptor? {
            return try self.pipe.getReadFileDescriptor()
        }

        public func writeFileDescriptor() throws -> FileDescriptor? {
            return try self.pipe.getWriteFileDescriptor()
        }

        public func closeReadFileDescriptor() throws {
            try self.pipe.closeReadFileDescriptor()
        }

        public func closeWriteFileDescriptor() throws {
            try self.pipe.closeWriteFileDescriptor()
        }

        internal init(string: InputString, encoding: String.Encoding) {
            self.string = string
            self.encoding = encoding
            self.pipe = LockedState(initialState: nil)
            self.queue = DispatchQueue(label: "Subprocess.\(Self.self)Queue")
        }
    }
    
    /// A concrete `Input` type for subprocesses that reads input
    /// from a given sequence of `UInt8` (such as `Data` or `[UInt8]`).
    public struct UInt8SequenceInput<
        InputSequence: Sequence & Sendable
    >: InputProtocol, Sendable where InputSequence.Element == UInt8 {
        private let sequence: InputSequence
        internal let pipe: LockedState<(readEnd: FileDescriptor?, writeEnd: FileDescriptor?)?>

        public func readFileDescriptor() throws -> FileDescriptor? {
            return try self.pipe.getReadFileDescriptor()
        }

        public func writeFileDescriptor() throws -> FileDescriptor? {
            return try self.pipe.getWriteFileDescriptor()
        }

        public func closeReadFileDescriptor() throws {
            try self.pipe.closeReadFileDescriptor()
        }

        public func closeWriteFileDescriptor() throws {
            try self.pipe.closeWriteFileDescriptor()
        }

        public func write() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let writeEnd = self.pipe.withLock { pipeStore in
                    return pipeStore?.writeEnd
                }
                guard let writeEnd = writeEnd else {
                    fatalError("Attempting to write before process is launched")
                }
                writeEnd.write(self.sequence) { error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }

        internal init(underlying: InputSequence) {
            self.sequence = underlying
            self.pipe = LockedState(initialState: nil)
        }
    }

    /// A concrete `Input` type for subprocesses that accepts input
    /// from a specified sequence of `Data`. This type should be preferred
    /// over `Subprocess.UInt8SequenceInput` when dealing with
    /// large amount input data.
    public struct DataSequenceInput<
        InputSequence: Sequence & Sendable
    >: InputProtocol where InputSequence.Element == Data {
        private let sequence: InputSequence
        internal let queue: DispatchQueue
        internal let pipe: LockedState<(readEnd: FileDescriptor?, writeEnd: FileDescriptor?)?>

        public func readFileDescriptor() throws -> FileDescriptor? {
            return try self.pipe.getReadFileDescriptor()
        }

        public func writeFileDescriptor() throws -> FileDescriptor? {
            return try self.pipe.getWriteFileDescriptor()
        }

        public func closeReadFileDescriptor() throws {
            try self.pipe.closeReadFileDescriptor()
        }

        public func closeWriteFileDescriptor() throws {
            try self.pipe.closeWriteFileDescriptor()
        }

        public func write() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                var buffer = Data()
                for chunk in self.sequence {
                    buffer.append(chunk)
                }
                let writeEnd = self.pipe.withLock { pipeStore in
                    return pipeStore?.writeEnd
                }
                guard let writeEnd = writeEnd else {
                    fatalError("Attempting to write before process is launched")
                }

                writeEnd.write(buffer) { error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }

        internal init(underlying: InputSequence) {
            self.sequence = underlying
            self.pipe = LockedState(initialState: nil)
            self.queue = DispatchQueue(label: "Subprocess.\(Self.self)Queue")
        }
    }

    /// A concrete `Input` type for subprocesses that reads input
    /// from a given async sequence of `Data`.
    public struct DataAsyncSequenceInput<
        InputSequence: AsyncSequence & Sendable
    >: InputProtocol where InputSequence.Element == Data {
        private let sequence: InputSequence
        internal let pipe: LockedState<(readEnd: FileDescriptor?, writeEnd: FileDescriptor?)?>

        private func writeChunk(_ chunk: Data) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let writeEnd = self.pipe.withLock { pipeStore in
                    return pipeStore?.writeEnd
                }
                guard let writeEnd = writeEnd else {
                    fatalError("Attempting to write before process is launched")
                }
                writeEnd.write(chunk) { error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }

        public func write() async throws {
            for try await chunk in self.sequence {
                try await self.writeChunk(chunk)
            }
        }

        public func readFileDescriptor() throws -> FileDescriptor? {
            return try self.pipe.getReadFileDescriptor()
        }

        public func writeFileDescriptor() throws -> FileDescriptor? {
            return try self.pipe.getWriteFileDescriptor()
        }

        public func closeReadFileDescriptor() throws {
            try self.pipe.closeReadFileDescriptor()
        }

        public func closeWriteFileDescriptor() throws {
            try self.pipe.closeWriteFileDescriptor()
        }

        internal init(underlying: InputSequence) {
            self.sequence = underlying
            self.pipe = LockedState(initialState: nil)
        }
    }

    /// A concrete `Input` type for subprocess that indicates that
    /// the Subprocess should read its input from `StandardInputWriter`.
    public struct CustomWriteInput: InputProtocol {
        internal let pipe: LockedState<(readEnd: FileDescriptor?, writeEnd: FileDescriptor?)?>

        public func write() async throws {
            // NOOP
        }

        public func readFileDescriptor() throws -> FileDescriptor? {
            return try self.pipe.getReadFileDescriptor()
        }

        public func writeFileDescriptor() throws -> FileDescriptor? {
            return try self.pipe.getWriteFileDescriptor()
        }

        public func closeReadFileDescriptor() throws {
            try self.pipe.closeReadFileDescriptor()
        }

        public func closeWriteFileDescriptor() throws {
            try self.pipe.closeWriteFileDescriptor()
        }

        internal init() {
            self.pipe = LockedState(initialState: nil)
        }
    }
}

extension Subprocess.InputProtocol where Self == Subprocess.NoInput {
    /// Create a Subprocess input that specfies there is no input
    public static var none: Self { .init() }
}

extension Subprocess.InputProtocol where Self == Subprocess.FileDescriptorInput {
    /// Create a Subprocess input from a `FileDescriptor` and
    /// specify whether the `FileDescriptor` should be closed
    /// after the process is spawned.
    public static func fileDescriptor(
        _ fd: FileDescriptor,
        closeAfterSpawningProcess: Bool
    ) -> Self {
        return .init(
            fileDescriptor: fd,
            closeAfterSpawningProcess: closeAfterSpawningProcess
        )
    }
}

extension Subprocess.InputProtocol {
    /// Create a Subprocess input from a `Sequence` of `UInt8` such as
    /// `Data` or `Array<UInt8>`.
    public static func sequence<InputSequence: Sequence & Sendable>(
        _ sequence: InputSequence
    ) -> Self where Self == Subprocess.UInt8SequenceInput<InputSequence> {
        return Subprocess.UInt8SequenceInput(underlying: sequence)
    }

    /// Create a Subprocess input from a `Sequence` of `Data`.
    public static func sequence<InputSequence: Sequence & Sendable>(
        _ sequence: InputSequence
    ) -> Self where Self == Subprocess.DataSequenceInput<InputSequence> {
        return .init(underlying: sequence)
    }

    /// Create a Subprocess input from a `AsyncSequence` of `Data`.
    public static func sequence<InputSequence: AsyncSequence & Sendable>(
        _ asyncSequence: InputSequence
    ) -> Self where Self == Subprocess.DataAsyncSequenceInput<InputSequence> {
        return .init(underlying: asyncSequence)
    }

    /// Create a Subprocess input from a type that conforms to `StringProtocol`
    public static func string<InputString: StringProtocol & Sendable>(
        _ string: InputString,
        using encoding: String.Encoding = .utf8
    ) -> Self where Self == Subprocess.StringInput<InputString> {
        return .init(string: string, encoding: encoding)
    }
}

// MARK: - Output
extension Subprocess {
    /// The `OutputProtocol` protocol specifies the set of methods that a type
    /// must implement to serve as the output target for a subprocess.
    /// Instead of developing custom implementations of `OutputProtocol`,
    /// it is recommended to utilize the default implementations provided
    /// by the `Subprocess` library to specify the output handling requirements.
    public protocol OutputProtocol: Sendable {
        associatedtype OutputType
        /// Lazily create and return the FileDescriptor for reading
        func readFileDescriptor() throws -> FileDescriptor?
        /// Lazily create and return the FileDescriptor for writing
        func writeFileDescriptor() throws -> FileDescriptor?
        /// Return the read `FileDescriptor` and remove it from the output
        /// such that the next call to `consumeReadFileDescriptor` will
        /// return `nil`.
        func consumeReadFileDescriptor() -> FileDescriptor?

        /// Close the FileDescriptor for reading
        func closeReadFileDescriptor() throws
        /// Close the FileDescriptor for writing
        func closeWriteFileDescriptor() throws

        /// Convert the output from Data to expected output type
        func output(from data: Data) -> OutputType
        /// The max amount of data to collect for this output.
        var maxSize: Int { get }
    }

    /// A concrete `Output` type for subprocesses that indicates that
    /// the `Subprocess` should not collect or redirect output
    /// from the child process. On Unix-like systems, `DiscardedOutput`
    /// redirects the standard output of the subprocess to `/dev/null`,
    /// while on Windows, it does not bind any file handle to the
    /// subprocess standard output handle.
    public struct DiscardedOutput: OutputProtocol {
        public typealias OutputType = Void

        private let devnull: LockedState<FileDescriptor?>

         public func readFileDescriptor() throws -> FileDescriptor? {
             return try self.devnull.withLock { fd in
                 if let devnull = fd {
                     return devnull
                 }
                 let devnull: FileDescriptor = try .openDevNull(withAcessMode: .readOnly)
                 fd = devnull
                 return devnull
             }
        }

        public func consumeReadFileDescriptor() -> FileDescriptor? {
            return self.devnull.withLock { fd in
                if let devnull = fd {
                    fd = nil
                    return devnull
                }
                return nil
            }
        }

        public func writeFileDescriptor() throws -> FileDescriptor? {
            return nil
        }

        public func closeReadFileDescriptor() throws {
            try self.devnull.withLock { fd in
                try fd?.close()
                fd = nil
            }
        }

        public func closeWriteFileDescriptor() throws {
            // NOOP
        }

        internal init() {
            self.devnull = LockedState(initialState: nil)
        }
    }

    /// A concrete `Output` type for subprocesses that
    /// writes output to a specified `FileDescriptor`.
    /// Developers have the option to instruct the `Subprocess` to
    /// automatically close the provided `FileDescriptor`
    /// after the subprocess is spawned.
    public struct FileDescriptorOutput: OutputProtocol {
        public typealias OutputType = Void

        private let closeAfterSpawningProcess: Bool
        private let fileDescriptor: LockedState<FileDescriptor?>

        public func readFileDescriptor() throws -> FileDescriptor? {
            return nil
        }

        public func writeFileDescriptor() throws -> FileDescriptor? {
            return self.fileDescriptor.withLock { $0 }
        }

        public func closeReadFileDescriptor() throws {
            // NOOP
        }

        public func consumeReadFileDescriptor() -> FileDescriptor? {
            return nil
        }

        public func closeWriteFileDescriptor() throws {
            if self.closeAfterSpawningProcess {
                try self.fileDescriptor.withLock { fd in
                    try fd?.close()
                    fd = nil
                }
            }
        }

        internal init(
            fileDescriptor: FileDescriptor,
            closeAfterSpawningProcess: Bool
        ) {
            self.fileDescriptor = LockedState(initialState: fileDescriptor)
            self.closeAfterSpawningProcess = closeAfterSpawningProcess
        }
    }

    /// A concrete `Output` type for subprocesses that redirects
    /// the child output to the `.standardOutput` (a sequence) or `.standardError`
    /// property of `Subprocess.Execution`. This output type is
    /// only applicable to the `run()` family that takes a custom closure.
    public struct SequenceOutput: OutputProtocol {
        public typealias OutputType = Void
        internal let pipe: LockedState<(readEnd: FileDescriptor?, writeEnd: FileDescriptor?)?>

        public func readFileDescriptor() throws -> FileDescriptor? {
            return try self.pipe.getReadFileDescriptor()
        }

        public func writeFileDescriptor() throws -> FileDescriptor? {
            return try self.pipe.getWriteFileDescriptor()
        }

        public func closeReadFileDescriptor() throws {
            try self.pipe.closeReadFileDescriptor()
        }

        public func closeWriteFileDescriptor() throws {
            try self.pipe.closeWriteFileDescriptor()
        }

        public func consumeReadFileDescriptor() -> FileDescriptor? {
            return self.pipe.consumeReadFileDescriptor()
        }

        internal init() {
            self.pipe = LockedState(initialState: nil)
        }
    }

    /// A concrete `Output` type for subprocesses that collects output
    /// from the subprocess as `Data`. This option must be used with
    /// the `run()` method that returns a `CollectedResult`
    public struct DataOutput: OutputProtocol {
        public typealias OutputType = Data
        public let maxSize: Int
        internal let pipe: LockedState<(readEnd: FileDescriptor?, writeEnd: FileDescriptor?)?>

        public func output(from data: Data) -> Data {
            return data
        }

        public func readFileDescriptor() throws -> FileDescriptor? {
            return try self.pipe.getReadFileDescriptor()
        }

        public func writeFileDescriptor() throws -> FileDescriptor? {
            return try self.pipe.getWriteFileDescriptor()
        }

        public func closeReadFileDescriptor() throws {
            try self.pipe.closeReadFileDescriptor()
        }

        public func closeWriteFileDescriptor() throws {
            try self.pipe.closeWriteFileDescriptor()
        }

        public func consumeReadFileDescriptor() -> FileDescriptor? {
            return self.pipe.consumeReadFileDescriptor()
        }

        internal init(limit: Int) {
            self.maxSize = limit
            self.pipe = LockedState(initialState: nil)
        }
    }

    /// A concrete `Output` type for subprocesses that collects output
    /// from the subprocess as `String` with the given encoding.
    /// This option must be used with he `run()` method that
    /// returns a `CollectedResult`.
    public struct StringOutput: OutputProtocol {
        public typealias OutputType = String?
        public let maxSize: Int
        internal let encoding: String.Encoding
        internal let pipe: LockedState<(readEnd: FileDescriptor?, writeEnd: FileDescriptor?)?>

        public func output(from data: Data) -> String? {
            return String(data: data, encoding: self.encoding)
        }

        public func readFileDescriptor() throws -> FileDescriptor? {
            return try self.pipe.getReadFileDescriptor()
        }

        public func writeFileDescriptor() throws -> FileDescriptor? {
            return try self.pipe.getWriteFileDescriptor()
        }

        public func closeReadFileDescriptor() throws {
            try self.pipe.closeReadFileDescriptor()
        }

        public func closeWriteFileDescriptor() throws {
            try self.pipe.closeWriteFileDescriptor()
        }

        public func consumeReadFileDescriptor() -> FileDescriptor? {
            return self.pipe.consumeReadFileDescriptor()
        }

        internal init(limit: Int, encoding: String.Encoding) {
            self.maxSize = limit
            self.encoding = encoding
            self.pipe = LockedState(initialState: nil)
        }
    }
}

extension Subprocess.OutputProtocol where OutputType == Void {
    public func output(from data: Data) -> Void { /* noop */ }
    public var maxSize: Int { 0 }
}

extension Subprocess.OutputProtocol where Self == Subprocess.DiscardedOutput {
    /// Create a Subprocess output that discards the output
    public static var discarded: Self { .init() }
}

extension Subprocess.OutputProtocol where Self == Subprocess.FileDescriptorOutput {
    /// Create a Subprocess output that writes output to a `FileDescriptor`
    /// and optionally close the `FileDescriptor` once process spawned.
    public static func fileDescriptor(
        _ fd: FileDescriptor,
        closeAfterSpawningProcess: Bool
    ) -> Self {
        return .init(fileDescriptor: fd, closeAfterSpawningProcess: closeAfterSpawningProcess)
    }
}

extension Subprocess.OutputProtocol where Self == Subprocess.StringOutput {
    public static var string: Self {
        return .string(limit: 128 * 1024)
    }

    /// Create a `Subprocess` output that collects output as
    /// `String` using the given encoding.
    public static func string(
        limit: Int,
        encoding: String.Encoding = .utf8
    ) -> Self {
        return .init(limit: limit, encoding: encoding)
    }
}

extension Subprocess.OutputProtocol where Self == Subprocess.DataOutput {
    public static var data: Self {
        return .data(limit: 128 * 1024)
    }

    /// Create a `Subprocess` output that collects output as `Data`
    public static func data(limit: Int) -> Self  {
        return .init(limit: limit)
    }
}

extension Subprocess.OutputProtocol where Self == Subprocess.SequenceOutput {
    /// Create a `Subprocess` output that redirects the output
    /// to the `.standardOutput` (or `.standardError`) property
    /// of `Subprocess.Execution` as `AsyncSequence<Data>`.
    public static var sequence: Self { .init() }
}

// MARK: Internal
private extension LockedState where State == Optional<Subprocess.Pipe> {
    func getReadFileDescriptor() throws -> FileDescriptor? {
        return try self.withLock { pipeStore in
            if let pipe = pipeStore {
                return pipe.readEnd
            }
            // Create pipe now
            let pipe = try FileDescriptor.pipe()
            pipeStore = pipe
            return pipe.readEnd
        }
    }

    func getWriteFileDescriptor() throws -> FileDescriptor? {
        return try self.withLock { pipeStore in
            if let pipe = pipeStore {
                return pipe.writeEnd
            }
            // Create pipe now
            let pipe = try FileDescriptor.pipe()
            pipeStore = pipe
            return pipe.writeEnd
        }
    }

    func closeReadFileDescriptor() throws {
        try self.withLock { pipeStore in
            guard let pipe = pipeStore else {
                return
            }
            try pipe.readEnd?.close()
            pipeStore = (readEnd: nil, writeEnd: pipe.writeEnd)
        }
    }

    func closeWriteFileDescriptor() throws {
        try self.withLock { pipeStore in
            guard let pipe = pipeStore else {
                return
            }
            try pipe.writeEnd?.close()
            pipeStore = (readEnd: pipe.readEnd, writeEnd: nil)
        }
    }

    func consumeReadFileDescriptor() -> FileDescriptor? {
        return self.withLock { pipeStore in
            guard let pipe = pipeStore else {
                return nil
            }
            pipeStore = (readEnd: nil, writeEnd: pipe.writeEnd)
            return pipe.readEnd
        }
    }
}

extension Subprocess {
    internal typealias Pipe = (readEnd: FileDescriptor?, writeEnd: FileDescriptor?)
}
