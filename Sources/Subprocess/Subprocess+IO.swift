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
    public protocol InputProtocol: Sendable {
        func getReadFileDescriptor() throws -> FileDescriptor?
        func getWriteFileDescriptor() throws -> FileDescriptor?

        func closeReadFileDescriptor() throws
        func closeWriteFileDescriptor() throws

        func writeInput() async throws
    }

    internal protocol PipeInputProtocol: InputProtocol, AnyObject {
        // Use DispatchQueue instead of LockedState as synchornization
        // since wirteInput uses DispatchIO
        var pipe: LockedState<(readEnd: FileDescriptor?, writeEnd: FileDescriptor?)?> { get }
    }

    public final class NoInput: InputProtocol {
        private let devnull: LockedState<FileDescriptor?>

        public func getReadFileDescriptor() throws -> FileDescriptor? {
            return try self.devnull.withLock { fd in
                if let devnull = fd {
                    return devnull
                }
                let devnull: FileDescriptor = try .openDevNull(withAcessMode: .readOnly)
                fd = devnull
                return devnull
            }
        }

        public func getWriteFileDescriptor() throws -> FileDescriptor? {
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

        public func writeInput() async throws {
            // NOOP
        }

        internal init() {
            self.devnull = LockedState(initialState: nil)
        }
    }

    public final class FileDescriptorInput: InputProtocol {
        private let closeAfterSpawningProcess: Bool
        private let fileDescriptor: LockedState<FileDescriptor?>

        public func getReadFileDescriptor() throws -> FileDescriptor? {
            return self.fileDescriptor.withLock { $0 }
        }

        public func getWriteFileDescriptor() throws -> FileDescriptor? {
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

        public func writeInput() async throws {
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

    public final class StringInput<
        InputString: StringProtocol & Sendable
    >: PipeInputProtocol, @unchecked Sendable {
        private let string: InputString
        internal let encoding: String.Encoding
        internal let queue: DispatchQueue
        internal let pipe: LockedState<(readEnd: FileDescriptor?, writeEnd: FileDescriptor?)?>

        public func writeInput() async throws {
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
                    guard error == 0 else {
                        continuation.resume(throwing: POSIXError(.init(rawValue: error) ?? .ENODEV))
                        return
                    }
                    continuation.resume()
                }
            }
        }

        internal init(string: InputString, encoding: String.Encoding) {
            self.string = string
            self.encoding = encoding
            self.pipe = LockedState(initialState: nil)
            self.queue = DispatchQueue(label: "Subprocess.\(Self.self)Queue")
        }
    }

    public final class UInt8SequenceInput<
        InputSequence: Sequence & Sendable
    >: PipeInputProtocol, @unchecked Sendable where InputSequence.Element == UInt8 {
        private let sequence: InputSequence
        internal let queue: DispatchQueue
        internal let pipe: LockedState<(readEnd: FileDescriptor?, writeEnd: FileDescriptor?)?>

        public func writeInput() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let writeEnd = self.pipe.withLock { pipeStore in
                    return pipeStore?.writeEnd
                }
                guard let writeEnd = writeEnd else {
                    fatalError("Attempting to write before process is launched")
                }
                let array: [UInt8] = self.sequence as? [UInt8] ?? Array(self.sequence)
                writeEnd.write(array) { error in
                    guard error == 0 else {
                        continuation.resume(throwing: POSIXError(.init(rawValue: error) ?? .ENODEV))
                        return
                    }
                    continuation.resume()
                }
            }
        }

        internal init(underlying: InputSequence) {
            self.sequence = underlying
            self.pipe = LockedState(initialState: nil)
            self.queue = DispatchQueue(label: "Subprocess.\(Self.self)Queue")
        }
    }

    public final class DataSequenceInput<
        InputSequence: Sequence & Sendable
    >: PipeInputProtocol, @unchecked Sendable where InputSequence.Element == Data {
        private let sequence: InputSequence
        internal let queue: DispatchQueue
        internal let pipe: LockedState<(readEnd: FileDescriptor?, writeEnd: FileDescriptor?)?>

        public func writeInput() async throws {
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
                    guard error == 0 else {
                        continuation.resume(throwing: POSIXError(.init(rawValue: error) ?? .ENODEV))
                        return
                    }
                    continuation.resume()
                }
            }
        }

        internal init(underlying: InputSequence) {
            self.sequence = underlying
            self.pipe = LockedState(initialState: nil)
            self.queue = DispatchQueue(label: "Subprocess.\(Self.self)Queue")
        }
    }

    public final class DataAsyncSequenceInput<
        InputSequence: AsyncSequence & Sendable
    >: PipeInputProtocol, @unchecked Sendable where InputSequence.Element == Data {
        private let sequence: InputSequence
        internal let queue: DispatchQueue
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
                    guard error == 0 else {
                        continuation.resume(throwing: POSIXError(.init(rawValue: error) ?? .ENODEV))
                        return
                    }
                    continuation.resume()
                }
            }
        }

        public func writeInput() async throws {
            for try await chunk in self.sequence {
                try await self.writeChunk(chunk)
            }
        }

        internal init(underlying: InputSequence) {
            self.sequence = underlying
            self.pipe = LockedState(initialState: nil)
            self.queue = DispatchQueue(label: "Subprocess.\(Self.self)Queue")
        }
    }

    public final class CustomWriteInput: PipeInputProtocol, @unchecked Sendable {
        internal let queue: DispatchQueue
        internal let pipe: LockedState<(readEnd: FileDescriptor?, writeEnd: FileDescriptor?)?>

        public func writeInput() async throws {
            // NOOP
        }

        internal init() {
            self.pipe = LockedState(initialState: nil)
            self.queue = DispatchQueue(label: "Subprocess.\(Self.self)Queue")
        }
    }
}

extension Subprocess.PipeInputProtocol {
    public func getReadFileDescriptor() throws -> FileDescriptor? {
        return try self.pipe.withLock { pipeStore in
            if let pipe = pipeStore {
                return pipe.readEnd
            }
            let pipe = try FileDescriptor.pipe()
            pipeStore = pipe
            return pipe.readEnd
        }
    }

    public func getWriteFileDescriptor() throws -> FileDescriptor? {
        return try self.pipe.withLock { pipeStore in
            if let pipe = pipeStore {
                return pipe.writeEnd
            }
            let pipe = try FileDescriptor.pipe()
            pipeStore = pipe
            return pipe.writeEnd
        }
    }

    public func closeReadFileDescriptor() throws {
        try self.pipe.withLock { pipeStore in
            guard let pipe = pipeStore else {
                return
            }
            try pipe.readEnd?.close()
            pipeStore = (readEnd: nil, writeEnd: pipe.writeEnd)
        }
    }

    public func closeWriteFileDescriptor() throws {
        try self.pipe.withLock { pipeStore in
            guard let pipe = pipeStore else {
                return
            }
            try pipe.writeEnd?.close()
            pipeStore = (readEnd: pipe.readEnd, writeEnd: nil)
        }
    }
}

extension Subprocess.InputProtocol where Self == Subprocess.NoInput {
    public static var noInput: Self { .init() }
}

extension Subprocess.InputProtocol where Self == Subprocess.FileDescriptorInput {
    public static func readFrom(
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
    public static func sequence<InputSequence: Sequence & Sendable>(
        _ sequence: InputSequence
    ) -> Self where Self == Subprocess.UInt8SequenceInput<InputSequence> {
        return Subprocess.UInt8SequenceInput(underlying: sequence)
    }

    public static func sequence<InputSequence: Sequence & Sendable>(
        _ sequence: InputSequence
    ) -> Self where Self == Subprocess.DataSequenceInput<InputSequence> {
        return .init(underlying: sequence)
    }

    public static func asyncSequence<InputSequence: AsyncSequence & Sendable>(
        _ asyncSequence: InputSequence
    ) -> Self where Self == Subprocess.DataAsyncSequenceInput<InputSequence> {
        return .init(underlying: asyncSequence)
    }

    public static func string<InputString: StringProtocol & Sendable>(
        _ string: InputString,
        using encoding: String.Encoding = .utf8
    ) -> Self where Self == Subprocess.StringInput<InputString> {
        return .init(string: string, encoding: encoding)
    }
}

// MARK: - Output
extension Subprocess {
    public protocol OutputProtocol: Sendable {
        associatedtype OutputType

        func getReadFileDescriptor() throws -> FileDescriptor?
        func getWriteFileDescriptor() throws -> FileDescriptor?

        func closeReadFileDescriptor() throws
        func closeWriteFileDescriptor() throws
    }

    public protocol CollectedOutputProtocol: OutputProtocol {
        var maxCollectionLength: Int { get }
        func consumeReadFileDescriptor() -> FileDescriptor?
    }

    internal protocol PipeOutput: CollectedOutputProtocol {
        var pipe: LockedState<(readEnd: FileDescriptor?, writeEnd: FileDescriptor?)?> { get }
    }

    public final class DiscardedOutput: OutputProtocol {
        public typealias OutputType = Void

        private let devnull: LockedState<FileDescriptor?>

         public func getReadFileDescriptor() throws -> FileDescriptor? {
             return try self.devnull.withLock { fd in
                 if let devnull = fd {
                     return devnull
                 }
                 let devnull: FileDescriptor = try .openDevNull(withAcessMode: .readOnly)
                 fd = devnull
                 return devnull
             }
        }

        public func getWriteFileDescriptor() throws -> FileDescriptor? {
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

    public final class FileDescriptorOutput: OutputProtocol {
        public typealias OutputType = Void
        private let closeAfterSpawningProcess: Bool
        private let fileDescriptor: LockedState<FileDescriptor?>

        public func getReadFileDescriptor() throws -> FileDescriptor? {
            return nil
        }

        public func getWriteFileDescriptor() throws -> FileDescriptor? {
            return self.fileDescriptor.withLock { $0 }
        }

        public func closeReadFileDescriptor() throws {
            // NOOP
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

    public final class CollectedOutput<Output: Subprocess.OutputConvertible>: PipeOutput {
        public typealias OutputType = Output
        public let maxCollectionLength: Int
        internal let pipe: LockedState<(readEnd: FileDescriptor?, writeEnd: FileDescriptor?)?>

        internal init(limit: Int) {
            self.maxCollectionLength = limit
            self.pipe = LockedState(initialState: nil)
        }
    }

    public struct RedirectedOutput: PipeOutput {
        public typealias OutputType = _AsyncSequence<Data, any Error>
        public let maxCollectionLength: Int = .max // not used
        internal let pipe: LockedState<(readEnd: FileDescriptor?, writeEnd: FileDescriptor?)?>

        internal init() {
            self.pipe = LockedState(initialState: nil)
        }
    }

    public struct StringOutput: PipeOutput {
        public typealias OutputType = String?
        public let maxCollectionLength: Int
        internal let encoding: String.Encoding
        internal let pipe: LockedState<(readEnd: FileDescriptor?, writeEnd: FileDescriptor?)?>

        internal init(limit: Int, encoding: String.Encoding) {
            self.maxCollectionLength = limit
            self.encoding = encoding
            self.pipe = LockedState(initialState: nil)
        }
    }
}

extension Subprocess.PipeOutput {
    public func getReadFileDescriptor() throws -> FileDescriptor? {
        return try self.pipe.withLock { pipeStore in
            if let pipe = pipeStore {
                return pipe.readEnd
            }
            // Create pipe now
            let pipe = try FileDescriptor.pipe()
            pipeStore = pipe
            return pipe.readEnd
        }
    }

    public func getWriteFileDescriptor() throws -> FileDescriptor? {
        return try self.pipe.withLock { pipeStore in
            if let pipe = pipeStore {
                return pipe.writeEnd
            }
            // Create pipe now
            let pipe = try FileDescriptor.pipe()
            pipeStore = pipe
            return pipe.writeEnd
        }
    }

    public func closeReadFileDescriptor() throws {
        try self.pipe.withLock { pipeStore in
            guard let pipe = pipeStore else {
                return
            }
            try pipe.readEnd?.close()
            pipeStore = (readEnd: nil, writeEnd: pipe.writeEnd)
        }
    }

    public func closeWriteFileDescriptor() throws {
        try self.pipe.withLock { pipeStore in
            guard let pipe = pipeStore else {
                return
            }
            try pipe.writeEnd?.close()
            pipeStore = (readEnd: pipe.readEnd, writeEnd: nil)
        }
    }

    public func consumeReadFileDescriptor() -> FileDescriptor? {
        return self.pipe.withLock { pipeStore in
            guard let pipe = pipeStore else {
                return nil
            }
            pipeStore = (readEnd: nil, writeEnd: pipe.writeEnd)
            return pipe.readEnd
        }
    }
}

extension Subprocess.OutputProtocol where Self == Subprocess.DiscardedOutput {
    public static var discarded: Self { .init() }
}

extension Subprocess.OutputProtocol where Self == Subprocess.FileDescriptorOutput {
    public static func writeTo(
        _ fd: FileDescriptor,
        closeAfterSpawningProcess: Bool
    ) -> Self {
        return .init(fileDescriptor: fd, closeAfterSpawningProcess: closeAfterSpawningProcess)
    }
}

extension Subprocess.OutputProtocol where Self == Subprocess.StringOutput {
    public static func collectString(
        upTo limit: Int = 128 * 1024,
        encoding: String.Encoding = .utf8
    ) -> Self {
        return .init(limit: limit, encoding: encoding)
    }
}

extension Subprocess.OutputProtocol where Self == Subprocess.RedirectedOutput {
    public static var redirectToSequence: Self { .init() }
}

extension Subprocess.OutputProtocol {
    public static func collect<Output>(upTo limit: Int = 128 * 1024, as: Output.Type) -> Self where Self == Subprocess.CollectedOutput<Output> {
        return .init(limit: limit)
    }

    public static func collect(upTo limit: Int = 128 * 1024) -> Self where Self == Subprocess.CollectedOutput<Data> {
        return .init(limit: limit)
    }
}

