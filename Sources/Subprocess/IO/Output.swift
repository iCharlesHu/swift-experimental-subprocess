//
//  File.swift
//  Subprocess
//
//  Created by Charles Hu on 2/7/25.
//

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
/// from the subprocess as `Data`. This option must be used with
/// the `run()` method that returns a `CollectedResult`
@available(macOS 9999, *)
public final class DataOutput: ManagedOutputProtocol {
    public typealias OutputType = Data
    public let maxSize: Int
    public let pipe: Pipe

    public func output(from span: RawSpan) throws -> Data {
        return Data(span)
    }

    internal init(limit: Int) {
        self.maxSize = limit
        self.pipe = Pipe()
    }
}


/// A concrete `Output` type for subprocesses that collects output
/// from the subprocess as `String` with the given encoding.
/// This option must be used with he `run()` method that
/// returns a `CollectedResult`.
@available(macOS 9999, *)
public final class StringOutput: ManagedOutputProtocol {
    public typealias OutputType = String?
    public let maxSize: Int
    internal let encoding: String.Encoding
    public let pipe: Pipe

    public func output(from span: RawSpan) throws -> String? {
        // FIXME: Span to String
        var array: [UInt8] = []
        for index in 0 ..< span.byteCount {
            array.append(span.unsafeLoad(fromByteOffset: index, as: UInt8.self))
        }
        return String(bytes: array, encoding: self.encoding)
    }

    internal init(limit: Int, encoding: String.Encoding) {
        self.maxSize = limit
        self.encoding = encoding
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

@available(macOS 9999, *)
extension ManagedOutputProtocol {
    public func output(from data: some DataProtocol) throws -> OutputType {
        //FIXME: remove workaround for rdar://143992296
        return try self.output(from: data.bytes)
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
extension OutputProtocol where Self == StringOutput {
    /// Create a `Subprocess` output that collects output as
    /// UTF8 String with 128kb limit.
    public static var string: Self {
        return .string(limit: 128 * 1024)
    }

    /// Create a `Subprocess` output that collects output as
    /// `String` using the given encoding up to limit it bytes.
    public static func string(
        limit: Int,
        encoding: String.Encoding = .utf8
    ) -> Self {
        return .init(limit: limit, encoding: encoding)
    }
}

@available(macOS 9999, *)
extension OutputProtocol where Self == DataOutput {
    /// Create a `Subprocess` output that collects output as `Data`
    /// up to 128kb.
    public static var data: Self {
        return .data(limit: 128 * 1024)
    }

    /// Create a `Subprocess` output that collects output as `Data`
    /// with given max number of bytes to collect.
    public static func data(limit: Int) -> Self  {
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

