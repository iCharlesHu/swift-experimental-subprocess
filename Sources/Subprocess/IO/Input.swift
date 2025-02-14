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

#if canImport(System)
import System
#else
@preconcurrency import SystemPackage
#endif

#if canImport(Synchronization)
import Synchronization

private typealias Lock = Mutex
#else
private typealias Lock = LockedState
#endif

// MARK: - Input

/// `InputProtocol` specifies the set of methods that a type
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
    func write(into writeFileDescriptor: FileDescriptor) async throws
}

public protocol ManagedInputProtocol: InputProtocol {
    /// The underlying pipe used by this input in order to
    /// write input to child process
    var pipe: Pipe { get }
}

/// A concrete `Input` type for subprocesses that indicates
/// the absence of input to the subprocess. On Unix-like systems,
/// `NoInput` redirects the standard input of the subprocess
/// to `/dev/null`, while on Windows, it does not bind any
/// file handle to the subprocess standard input handle.
public final class NoInput: InputProtocol {
    private let devnull: Lock<FileDescriptor?>

    public func readFileDescriptor() throws -> FileDescriptor? {
#if !os(Windows)
        return try self.devnull.withLock { fd in
            if let devnull = fd {
                return devnull
            }
            let devnull: FileDescriptor = try .openDevNull(withAcessMode: .readOnly)
            fd = devnull
            return devnull
        }
#else
        // On Windows, instead of binding to dev null,
        // we don't set the input handle in the `STARTUPINFOW`
        // to signal no input
        return nil
#endif // !os(Windows)
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

    public func write(into writeFileDescriptor: FileDescriptor) async throws {
        // NOOP
    }

    internal init() {
        self.devnull = Lock(nil)
    }
}

/// A concrete `Input` type for subprocesses that
/// reads input from a specified `FileDescriptor`.
/// Developers have the option to instruct the `Subprocess` to
/// automatically close the provided `FileDescriptor`
/// after the subprocess is spawned.
public final class FileDescriptorInput: InputProtocol {
    private let closeAfterSpawningProcess: Bool
    private let fileDescriptor: Lock<FileDescriptor?>

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

    public func write(into writeFileDescriptor: FileDescriptor) async throws {
        // NOOP
    }

    internal init(
        fileDescriptor: FileDescriptor,
        closeAfterSpawningProcess: Bool
    ) {
        self.fileDescriptor = Lock(fileDescriptor)
        self.closeAfterSpawningProcess = closeAfterSpawningProcess
    }
}

/// A concrete `Input` type for subprocesses that reads input
/// from a given type conforming to `StringProtocol`.
/// Developers can specify the string encoding to use when
/// encoding the string to data, which defaults to UTF-8.
public final class StringInput<
    InputString: StringProtocol & Sendable
>: ManagedInputProtocol {
    private let string: InputString
    internal let encoding: String.Encoding
    public let pipe: Pipe

    public func write(into writeFileDescriptor: FileDescriptor) async throws {
        guard let data = self.string.data(using: self.encoding) else {
            return
        }
        _ = try await writeFileDescriptor.write(data)
    }

    internal init(string: InputString, encoding: String.Encoding) {
        self.string = string
        self.encoding = encoding
        self.pipe = Pipe()
    }
}

/// A concrete `Input` type for subprocesses that reads input
/// from a given `UInt8` Array.
public final class ArrayInput: ManagedInputProtocol {
    private let array: [UInt8]
    public let pipe: Pipe

    public func write(into writeFileDescriptor: FileDescriptor) async throws {
        _ = try await writeFileDescriptor.write(self.array)
    }

    internal init(array: [UInt8]) {
        self.array = array
        self.pipe = Pipe()
    }
}

/// A concrete `Input` type for subprocesses that reads input
/// from a given `Data`.
public final class DataInput: ManagedInputProtocol {
    private let data: Data
    public let pipe: Pipe

    public func write(into writeFileDescriptor: FileDescriptor) async throws {
        _ = try await writeFileDescriptor.write(self.data)
    }

    internal init(data: Data) {
        self.data = data
        self.pipe = Pipe()
    }
}

/// A concrete `Input` type for subprocesses that accepts input
/// from a specified sequence of `Data`. This type should be preferred
/// over `UInt8SequenceInput` when dealing with
/// large amount input data.
public final class DataSequenceInput<
    InputSequence: Sequence & Sendable
>: ManagedInputProtocol where InputSequence.Element == Data {
    private let sequence: InputSequence
    public let pipe: Pipe

    public func write(into writeFileDescriptor: FileDescriptor) async throws {
        var buffer = Data()
        for chunk in self.sequence {
            buffer.append(chunk)
        }
        _ = try await writeFileDescriptor.write(buffer)
    }

    internal init(underlying: InputSequence) {
        self.sequence = underlying
        self.pipe = Pipe()
    }
}

/// A concrete `Input` type for subprocesses that reads input
/// from a given async sequence of `Data`.
public final class DataAsyncSequenceInput<
    InputSequence: AsyncSequence & Sendable
>: ManagedInputProtocol where InputSequence.Element == Data {
    private let sequence: InputSequence
    public let pipe: Pipe

    private func writeChunk(_ chunk: Data, into writeFileDescriptor: FileDescriptor) async throws {
        _ = try await writeFileDescriptor.write(chunk)
    }

    public func write(into writeFileDescriptor: FileDescriptor) async throws {
        for try await chunk in self.sequence {
            try await self.writeChunk(chunk, into: writeFileDescriptor)
        }
    }

    internal init(underlying: InputSequence) {
        self.sequence = underlying
        self.pipe = Pipe()
    }
}

/// A concrete `Input` type for subprocess that indicates that
/// the Subprocess should read its input from `StandardInputWriter`.
public final class CustomWriteInput: ManagedInputProtocol {
    public let pipe: Pipe

    public func write(into writeFileDescriptor: FileDescriptor) async throws {
        // NOOP
    }

    internal init() {
        self.pipe = Pipe()
    }
}

extension InputProtocol where Self == NoInput {
    /// Create a Subprocess input that specfies there is no input
    public static var none: Self { .init() }
}

extension InputProtocol where Self == FileDescriptorInput {
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

extension InputProtocol {
    /// Create a Subprocess input from a `Array` of `UInt8`.
    public static func array(
        _ array: [UInt8]
    ) -> Self where Self == ArrayInput {
        return ArrayInput(array: array)
    }

    /// Create a Subprocess input from a `Data`
    public static func data(_ data: Data) -> Self where Self == DataInput {
        return DataInput(data: data)
    }

    /// Create a Subprocess input from a `Sequence` of `Data`.
    public static func sequence<InputSequence: Sequence & Sendable>(
        _ sequence: InputSequence
    ) -> Self where Self == DataSequenceInput<InputSequence> {
        return .init(underlying: sequence)
    }

    /// Create a Subprocess input from a `AsyncSequence` of `Data`.
    public static func sequence<InputSequence: AsyncSequence & Sendable>(
        _ asyncSequence: InputSequence
    ) -> Self where Self == DataAsyncSequenceInput<InputSequence> {
        return .init(underlying: asyncSequence)
    }

    /// Create a Subprocess input from a type that conforms to `StringProtocol`
    public static func string<InputString: StringProtocol & Sendable>(
        _ string: InputString,
        using encoding: String.Encoding = .utf8
    ) -> Self where Self == StringInput<InputString> {
        return .init(string: string, encoding: encoding)
    }
}

extension ManagedInputProtocol {
    public func readFileDescriptor() throws -> FileDescriptor? {
        return try self.pipe.readFileDescriptor(creatingIfNeeded: true)
    }

    public func writeFileDescriptor() throws -> FileDescriptor? {
        return try self.pipe.writeFileDescriptor(creatingIfNeeded: true)
    }

    public func closeReadFileDescriptor() throws {
        try self.pipe.closeReadFileDescriptor()
    }

    public func closeWriteFileDescriptor() throws {
        try self.pipe.closeWriteFileDescriptor()
    }
}

// MARK: - StandardInputWriter

/// A writer that writes to the standard input of the subprocess.
public final actor StandardInputWriter: Sendable {

    private let input: CustomWriteInput

    init(input: CustomWriteInput) {
        self.input = input
    }

    /// Write an array of UInt8 to the standard input of the subprocess.
    /// - Parameter array: The sequence of bytes to write.
    /// - Returns number of bytes written.
    public func write(
        _ array: [UInt8]
    ) async throws -> Int {
        guard let fd: FileDescriptor = try self.input.writeFileDescriptor() else {
            fatalError("Attempting to write to a file descriptor that's already closed")
        }
        return try await fd.write(array)
    }

    /// Write a `Data` to the standard input of the subprocess.
    /// - Parameter data: The sequence of bytes to write.
    /// - Returns number of bytes written.
    public func write(
        _ data: Data
    ) async throws -> Int {
        guard let fd: FileDescriptor = try self.input.writeFileDescriptor() else {
            fatalError("Attempting to write to a file descriptor that's already closed")
        }
        return try await fd.write(data)
    }

    /// Write a StringProtocol to the standard input of the subprocess.
    /// - Parameters:
    ///   - string: The string to write.
    ///   - encoding: The encoding to use when converting string to bytes
    /// - Returns number of bytes written.
    public func write(
        _ string: some StringProtocol,
        using encoding: String.Encoding = .utf8
    ) async throws -> Int {
        guard encoding != .utf8 else {
            return try await self.write(Data(string.utf8))
        }
        if let data = string.data(using: encoding) {
            return try await self.write(data)
        }
        return 0
    }

    /// Write a AsyncSequence of UInt8 to the standard input of the subprocess.
    /// - Parameter sequence: The sequence of bytes to write.
    /// - Returns number of bytes written.
    public func write<AsyncSendableSequence: AsyncSequence & Sendable>(
        _ asyncSequence: AsyncSendableSequence
    ) async throws -> Int where AsyncSendableSequence.Element == Data {
        var buffer = Data()
        for try await data in asyncSequence {
            buffer.append(data)
        }
        return try await self.write(buffer)
    }

    /// Signal all writes are finished
    public func finish() async throws {
        try self.input.closeWriteFileDescriptor()
    }
}

