//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
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
internal import Dispatch
#if canImport(Synchronization)
import Synchronization

private typealias Lock = Mutex
#else
private typealias Lock = LockedState
#endif

// MARK: - Output

/// `OutputProtocol` specifies the set of methods that a type
/// must implement to serve as the output target for a subprocess.
/// Instead of developing custom implementations of `OutputProtocol`,
/// it is recommended to utilize the default implementations provided
/// by the `Subprocess` library to specify the output handling requirements.
public protocol OutputProtocol: Sendable {
    associatedtype OutputType: Sendable
    /// Lazily create and return the FileDescriptor for reading
    func readFileDescriptor() throws -> FileDescriptor?
    /// Lazily create the FileDescriptor for writing
    func writeFileDescriptor() throws -> FileDescriptor?
    /// Return the read `FileDescriptor` and remove it from the output
    /// such that the next call to `consumeReadFileDescriptor` will
    /// return `nil`.
    func consumeReadFileDescriptor() -> FileDescriptor?

    /// Close the FileDescriptor for reading
    func closeReadFileDescriptor() throws
    /// Close the FileDescriptor for writing
    func closeWriteFileDescriptor() throws

    /// Capture the output from the subprocess up to maxSize
    func captureOutput() async throws -> OutputType
}

/// `ManagedOutputProtocol` is managed by `Subprocess` and
/// utilizes its `Pipe` type to facilitate output reading.
/// Developers have the option to implement custom input types
/// by conforming to `ManagedOutputProtocol`
/// and implementing the `output(from:)` method.
@available(macOS 9999, *)
public protocol ManagedOutputProtocol: OutputProtocol {
    /// The underlying pipe used by this output in order to
    /// read from the child process
    var pipe: Pipe { get }

    /// Convert the output from Data to expected output type
    func output(from span: RawSpan) throws -> OutputType
    /// The max amount of data to collect for this output.
    var maxSize: Int { get }
}

/// A concrete `Output` type for subprocesses that indicates that
/// the `Subprocess` should not collect or redirect output
/// from the child process. On Unix-like systems, `DiscardedOutput`
/// redirects the standard output of the subprocess to `/dev/null`,
/// while on Windows, it does not bind any file handle to the
/// subprocess standard output handle.
public final class DiscardedOutput: OutputProtocol {
    public typealias OutputType = Void

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
        // to signal no output
        return nil
#endif
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
        self.devnull = Lock(nil)
    }
}

/// A concrete `Output` type for subprocesses that
/// writes output to a specified `FileDescriptor`.
/// Developers have the option to instruct the `Subprocess` to
/// automatically close the provided `FileDescriptor`
/// after the subprocess is spawned.
public final class FileDescriptorOutput: OutputProtocol {
    public typealias OutputType = Void

    private let closeAfterSpawningProcess: Bool
    private let fileDescriptor: Lock<FileDescriptor?>

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
        self.fileDescriptor = Lock(fileDescriptor)
        self.closeAfterSpawningProcess = closeAfterSpawningProcess
    }
}

/// A concrete `Output` type for subprocesses that collects output
/// from the subprocess as `String` with the given encoding.
/// This option must be used with he `run()` method that
/// returns a `CollectedResult`.
@available(macOS 9999, *)
public final class StringOutput<Encoding: Unicode.Encoding>: ManagedOutputProtocol {
    public typealias OutputType = String?
    public let maxSize: Int
    public let pipe: Pipe
    private let encoding: Encoding.Type

    public func output(from span: RawSpan) throws -> String? {
        // FIXME: Span to String
        var array: [UInt8] = []
        for index in 0 ..< span.byteCount {
            array.append(span.unsafeLoad(fromByteOffset: index, as: UInt8.self))
        }
        return String(decodingBytes: array, as: self.encoding)
    }

    internal init(limit: Int, encoding: Encoding.Type) {
        self.maxSize = limit
        self.pipe = Pipe()
        self.encoding = encoding
    }
}

/// A concrete `Output` type for subprocesses that collects output
/// from the subprocess as `Buffer`. This option must be used with
/// the `run()` method that returns a `CollectedResult`
@available(macOS 9999, *)
public final class BufferOutput: ManagedOutputProtocol {
    public typealias OutputType = Buffer
    public let maxSize: Int
    public let pipe: Pipe

    public func captureOutput() async throws -> Buffer {
        return try await withCheckedThrowingContinuation { continuation in
            guard let readFd = self.consumeReadFileDescriptor() else {
                fatalError("Trying to capture Subprocess output that has already been closed.")
            }
            readFd.readUntilEOF(upToLength: self.maxSize) { result in
                do {
                    switch result {
                    case .success(let data):
                        //FIXME: remove workaround for rdar://143992296
                        let output = Buffer(data: data)
                        try readFd.close()
                        continuation.resume(returning: output)
                    case .failure(let error):
                        try readFd.close()
                        continuation.resume(throwing: error)
                    }
                } catch {
                    try? readFd.close()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func output(from span: RawSpan) throws -> Buffer {
        fatalError("Not implemented")
    }

    internal init(limit: Int) {
        self.maxSize = limit
        self.pipe = Pipe()
    }
}

/// A concrete `Output` type for subprocesses that redirects
/// the child output to the `.standardOutput` (a sequence) or `.standardError`
/// property of `Execution`. This output type is
/// only applicable to the `run()` family that takes a custom closure.
public final class SequenceOutput: OutputProtocol {
    public typealias OutputType = Void

    private let pipe: Pipe

    public func readFileDescriptor() throws -> FileDescriptor? {
        return try self.pipe.readFileDescriptor(creatingIfNeeded: true)
    }

    public func writeFileDescriptor() throws -> FileDescriptor? {
        return try self.pipe.writeFileDescriptor(creatingIfNeeded: true)
    }

    public func consumeReadFileDescriptor() -> FileDescriptor? {
        return self.pipe.consumeReadFileDescriptor()
    }

    public func closeReadFileDescriptor() throws {
        return try self.pipe.closeReadFileDescriptor()
    }

    public func closeWriteFileDescriptor() throws {
        return try self.pipe.closeWriteFileDescriptor()
    }

    internal init() {
        self.pipe = Pipe()
    }
}

extension OutputProtocol where Self == DiscardedOutput {
    /// Create a Subprocess output that discards the output
    public static var discarded: Self { .init() }
}

extension OutputProtocol where Self == FileDescriptorOutput {
    /// Create a Subprocess output that writes output to a `FileDescriptor`
    /// and optionally close the `FileDescriptor` once process spawned.
    public static func fileDescriptor(
        _ fd: FileDescriptor,
        closeAfterSpawningProcess: Bool
    ) -> Self {
        return .init(fileDescriptor: fd, closeAfterSpawningProcess: closeAfterSpawningProcess)
    }
}

@available(macOS 9999, *)
extension OutputProtocol where Self == StringOutput<UTF8> {
    /// Create a `Subprocess` output that collects output as
    /// UTF8 String with 128kb limit.
    public static var string: Self {
        .init(limit: 128 * 1024, encoding: UTF8.self)
    }
}

@available(macOS 9999, *)
extension OutputProtocol {
    /// Create a `Subprocess` output that collects output as
    /// `String` using the given encoding up to limit it bytes.
    public static func string<Encoding: Unicode.Encoding>(
        limit: Int,
        encoding: Encoding.Type
    ) -> Self where Self == StringOutput<Encoding> {
        return .init(limit: limit, encoding: encoding)
    }
}

@available(macOS 9999, *)
extension OutputProtocol where Self == BufferOutput {
    /// Create a `Subprocess` output that collects output as
    /// `Buffer` with 128kb limit.
    public static var buffer: Self { .init(limit: 128 * 1024) }

    /// Create a `Subprocess` output that collects output as
    /// `Buffer` up to limit it bytes.
    public static func buffer(limit: Int) -> Self {
        return .init(limit: limit)
    }
}

extension OutputProtocol where Self == SequenceOutput {
    /// Create a `Subprocess` output that redirects the output
    /// to the `.standardOutput` (or `.standardError`) property
    /// of `Execution` as `AsyncSequence<Data>`.
    public static var sequence: Self { .init() }
}

// MARK: Default Implementations
@available(macOS 9999, *)
extension ManagedOutputProtocol {
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

    public func consumeReadFileDescriptor() -> FileDescriptor? {
        return self.pipe.consumeReadFileDescriptor()
    }

    public func captureOutput() async throws -> OutputType {
        return try await withCheckedThrowingContinuation { continuation in
            guard let readFd = self.consumeReadFileDescriptor() else {
                fatalError("Trying to capture Subprocess output that has already been closed.")
            }
            readFd.readUntilEOF(upToLength: self.maxSize) { result in
                do {
                    switch result {
                    case .success(let data):
                        //FIXME: remove workaround for rdar://143992296
                        let output = try self.output(from: data)
                        try readFd.close()
                        continuation.resume(returning: output)
                    case .failure(let error):
                        try readFd.close()
                        continuation.resume(throwing: error)
                    }
                } catch {
                    try? readFd.close()
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

extension OutputProtocol where OutputType == Void {
    public func captureOutput() async throws -> Void { /* noop */ }
}

@available(macOS 9999, *)
extension ManagedOutputProtocol {
    internal func output(from data: DispatchData) throws -> OutputType {
        guard !data.isEmpty else {
            let empty = UnsafeRawBufferPointer(start: nil, count: 0)
            let span = RawSpan(_unsafeBytes: empty)
            return try self.output(from: span)
        }

        return try data.withUnsafeBytes { ptr in
            let bufferPtr = UnsafeRawBufferPointer(start: ptr, count: data.count)
            let span = RawSpan(_unsafeBytes: bufferPtr)
            return try self.output(from: span)
        }
    }
}

