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
    public struct InputMethod: Sendable, Hashable {
        internal enum Storage: Sendable, Hashable {
            case noInput
            case fileDescriptor(FileDescriptor, Bool)
        }

        internal let method: Storage

        internal init(method: Storage) {
            self.method = method
        }

        internal func createExecutionInput() throws -> ExecutionInput {
            switch self.method {
            case .noInput:
                let devnull: FileDescriptor = try .openDevNull(withAcessMode: .readOnly)
                return .init(storage: .noInput(devnull))
            case .fileDescriptor(let fileDescriptor, let closeWhenDone):
                return .init(storage: .fileDescriptor(fileDescriptor, closeWhenDone))
            }
        }

        public static var noInput: Self {
            return .init(method: .noInput)
        }

        public static func readFrom(_ fd: FileDescriptor, closeAfterProcessSpawned: Bool) -> Self {
            return .init(method: .fileDescriptor(fd, closeAfterProcessSpawned))
        }
    }
}

extension Subprocess {
    public struct CollectedOutputMethod: Sendable, Hashable {
        internal enum Storage: Sendable, Hashable {
            case discarded
            case fileDescriptor(FileDescriptor, Bool)
            case collected(Int)
        }

        internal let method: Storage

        internal init(method: Storage) {
            self.method = method
        }

        public static var discard: Self {
            return .init(method: .discarded)
        }

        public static var collect: Self {
            return .init(method: .collected(128 * 1024))
        }

        public static func writeTo(_ fd: FileDescriptor, closeAfterProcessSpawned: Bool) -> Self {
            return .init(method: .fileDescriptor(fd, closeAfterProcessSpawned))
        }

        public static func collect(upTo limit: Int) -> Self {
            return .init(method: .collected(limit))
        }

        internal func createExecutionOutput() throws -> ExecutionOutput {
            switch self.method {
            case .discarded:
                // Bind to /dev/null
                let devnull: FileDescriptor = try .openDevNull(withAcessMode: .writeOnly)
                return .init(storage: .discarded(devnull))
            case .fileDescriptor(let fileDescriptor, let closeWhenDone):
                return .init(storage: .fileDescriptor(fileDescriptor, closeWhenDone))
            case .collected(let limit):
                let (readFd, writeFd) = try FileDescriptor.pipe()
                return .init(storage: .collected(limit, readFd, writeFd))
            }
        }
    }

    public struct RedirectedOutputMethod: Sendable, Hashable {
        typealias Storage = CollectedOutputMethod.Storage

        internal let method: Storage

        internal init(method: Storage) {
            self.method = method
        }

        public static var discard: Self {
            return .init(method: .discarded)
        }

        public static var redirectToSequence: Self {
            return .init(method: .collected(128 * 1024))
        }

        public static func writeTo(_ fd: FileDescriptor, closeAfterProcessSpawned: Bool) -> Self {
            return .init(method: .fileDescriptor(fd, closeAfterProcessSpawned))
        }

        internal func createExecutionOutput() throws -> ExecutionOutput {
            switch self.method {
            case .discarded:
                // Bind to /dev/null
                let devnull: FileDescriptor = try .openDevNull(withAcessMode: .writeOnly)
                return .init(storage: .discarded(devnull))
            case .fileDescriptor(let fileDescriptor, let closeWhenDone):
                return .init(storage: .fileDescriptor(fileDescriptor, closeWhenDone))
            case .collected(let limit):
                let (readFd, writeFd) = try FileDescriptor.pipe()
                return .init(storage: .collected(limit, readFd, writeFd))
            }
        }
    }
}

// MARK: - Execution IO
extension Subprocess {
    internal final class ExecutionInput: Sendable {

        internal enum Storage: Sendable {
            case noInput(FileDescriptor?)
            case customWrite(FileDescriptor?, FileDescriptor?)
            case fileDescriptor(FileDescriptor?, Bool)
        }
        
        let storage: Mutex<Storage>

        internal init(storage: Storage) {
            self.storage = .init(storage)
        }

        internal func getReadFileDescriptor() -> FileDescriptor? {
            return self.storage.withLock {
                switch $0 {
                case .noInput(let readFd):
                    return readFd
                case .customWrite(let readFd, _):
                    return readFd
                case .fileDescriptor(let readFd, _):
                    return readFd
                }
            }
        }

        internal func getWriteFileDescriptor() -> FileDescriptor? {
            return self.storage.withLock {
                switch $0 {
                case .noInput(_), .fileDescriptor(_, _):
                    return nil
                case .customWrite(_, let writeFd):
                    return writeFd
                }
            }
        }

        internal func closeChildSide() throws {
            try self.storage.withLock {
                switch $0 {
                case .noInput(let devnull):
                    try devnull?.close()
                    $0 = .noInput(nil)
                case .customWrite(let readFd, let writeFd):
                    try readFd?.close()
                    $0 = .customWrite(nil, writeFd)
                case .fileDescriptor(let fd, let closeWhenDone):
                    // User passed in fd
                    if closeWhenDone {
                        try fd?.close()
                        $0 = .fileDescriptor(nil, closeWhenDone)
                    }
                }
            }
        }

        internal func closeParentSide() throws {
            try self.storage.withLock {
                switch $0 {
                case .noInput(_), .fileDescriptor(_, _):
                    break
                case .customWrite(let readFd, let writeFd):
                    // The parent fd should have been closed
                    // in the `body` when writer.finish() is called
                    // But in case it isn't call it agian
                    try writeFd?.close()
                    $0 = .customWrite(readFd, nil)
                }
            }
        }

        internal func closeAll() throws {
            try self.storage.withLock {
                switch $0 {
                case .noInput(let readFd):
                    try readFd?.close()
                    $0 = .noInput(nil)
                case .customWrite(let readFd, let writeFd):
                    var readFdCloseError: Error?
                    var writeFdCloseError: Error?
                    do {
                        try readFd?.close()
                    } catch {
                        readFdCloseError = error
                    }
                    do {
                        try writeFd?.close()
                    } catch {
                        writeFdCloseError = error
                    }
                    $0 = .customWrite(nil, nil)
                    if let readFdCloseError {
                        throw readFdCloseError
                    }
                    if let writeFdCloseError {
                        throw writeFdCloseError
                    }
                case .fileDescriptor(let fd, let closeWhenDone):
                    try fd?.close()
                    $0 = .fileDescriptor(nil, closeWhenDone)
                }
            }
        }
    }

    internal final class ExecutionOutput: Sendable {
        internal enum Storage: Sendable {
            case discarded(FileDescriptor?)
            case fileDescriptor(FileDescriptor?, Bool)
            case collected(Int, FileDescriptor?, FileDescriptor?)
        }
        
        private let storage: Mutex<Storage>

        internal init(storage: Storage) {
            self.storage = .init(storage)
        }

        internal func getWriteFileDescriptor() -> FileDescriptor? {
            return self.storage.withLock {
                switch $0 {
                case .discarded(let writeFd):
                    return writeFd
                case .fileDescriptor(let writeFd, _):
                    return writeFd
                case .collected(_, _, let writeFd):
                    return writeFd
                }
            }
        }

        internal func getReadFileDescriptor() -> FileDescriptor? {
            return self.storage.withLock {
                switch $0 {
                case .discarded(_), .fileDescriptor(_, _):
                    return nil
                case .collected(_, let readFd, _):
                    return readFd
                }
            }
        }
        
        internal func consumeCollectedFileDescriptor() -> (limit: Int, fd: FileDescriptor?)? {
            return self.storage.withLock {
                switch $0 {
                case .discarded(_), .fileDescriptor(_, _):
                    // The output has been written somewhere else
                    return nil
                case .collected(let limit, let readFd, let writeFd):
                    $0 = .collected(limit, nil, writeFd)
                    return (limit, readFd)
                }
            }
        }

        internal func closeChildSide() throws {
            try self.storage.withLock {
                switch $0 {
                case .discarded(let writeFd):
                    try writeFd?.close()
                    $0 = .discarded(nil)
                case .fileDescriptor(let fd, let closeWhenDone):
                    // User passed fd
                    if closeWhenDone {
                        try fd?.close()
                        $0 = .fileDescriptor(nil, closeWhenDone)
                    }
                case .collected(let limit, let readFd, let writeFd):
                    try writeFd?.close()
                    $0 = .collected(limit, readFd, nil)
                }
            }
        }

        internal func closeParentSide() throws {
            try self.storage.withLock {
                switch $0 {
                case .discarded(_), .fileDescriptor(_, _):
                    break
                case .collected(let limit, let readFd, let writeFd):
                    try readFd?.close()
                    $0 = .collected(limit, nil, writeFd)
                }
            }
        }

        internal func closeAll() throws {
            try self.storage.withLock {
                switch $0 {
                case .discarded(let writeFd):
                    try writeFd?.close()
                    $0 = .discarded(nil)
                case .fileDescriptor(let fd, let closeWhenDone):
                    try fd?.close()
                    $0 = .fileDescriptor(nil, closeWhenDone)
                case .collected(let limit, let readFd, let writeFd):
                    var readFdCloseError: Error?
                    var writeFdCloseError: Error?
                    do {
                        try readFd?.close()
                    } catch {
                        readFdCloseError = error
                    }
                    do {
                        try writeFd?.close()
                    } catch {
                        writeFdCloseError = error
                    }
                    $0 = .collected(limit, nil, nil)
                    if let readFdCloseError {
                        throw readFdCloseError
                    }
                    if let writeFdCloseError {
                        throw writeFdCloseError
                    }
                }
            }
        }
    }
}
