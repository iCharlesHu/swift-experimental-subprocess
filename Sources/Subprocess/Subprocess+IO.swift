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

// MARK: - Input
extension Subprocess {
    public struct InputMethod {
        internal enum Storage {
            case noInput
            case fileDescriptor(FileDescriptor)
        }

        internal let method: Storage

        internal init(method: Storage) {
            self.method = method
        }

        internal func createExecutionInput() throws -> ExecutionInput {
            switch self.method {
            case .noInput:
                let devnull: FileDescriptor = try .open("/dev/null", .readOnly)
                return .noInput(devnull)
            case .fileDescriptor(let fileDescriptor):
                return .fileDescriptor(fileDescriptor)
            }
        }

        public static var noInput: Self {
            return .init(method: .noInput)
        }

        public static func readingFrom(_ fd: FileDescriptor) -> Self {
            return .init(method: .fileDescriptor(fd))
        }
    }
}

extension Subprocess {
    public struct CollectedOutputMethod {
        internal enum Storage {
            case discarded
            case fileDescriptor(FileDescriptor)
            case collected(Int)
        }

        internal let method: Storage

        internal init(method: Storage) {
            self.method = method
        }

        public static var discarded: Self {
            return .init(method: .discarded)
        }

        public static var collected: Self {
            return .init(method: .collected(128 * 1024))
        }

        public static func writingTo(_ fd: FileDescriptor) -> Self {
            return .init(method: .fileDescriptor(fd))
        }

        public static func collected(withCollectionByteLimit limit: Int) -> Self {
            return .init(method: .collected(limit))
        }

        internal func createExecutionOutput() throws -> ExecutionOutput {
            switch self.method {
            case .discarded:
                // Bind to /dev/null
                let devnull: FileDescriptor = try .open("/dev/null", .writeOnly)
                return .discarded(devnull)
            case .fileDescriptor(let fileDescriptor):
                return .fileDescriptor(fileDescriptor)
            case .collected(let limit):
                let (readFd, writeFd) = try FileDescriptor.pipe()
                return .collected(limit, readFd, writeFd)
            }
        }
    }

    public struct RedirectedOutputMethod {
        typealias Storage = CollectedOutputMethod.Storage

        internal let method: Storage

        internal init(method: Storage) {
            self.method = method
        }

        public static var discarded: Self {
            return .init(method: .discarded)
        }

        public static var redirected: Self {
            return .init(method: .collected(128 * 1024))
        }

        public static func writingTo(_ fd: FileDescriptor) -> Self {
            return .init(method: .fileDescriptor(fd))
        }

        internal func createExecutionOutput() throws -> ExecutionOutput {
            switch self.method {
            case .discarded:
                // Bind to /dev/null
                let devnull: FileDescriptor = try .open("/dev/null", .writeOnly)
                return .discarded(devnull)
            case .fileDescriptor(let fileDescriptor):
                return .fileDescriptor(fileDescriptor)
            case .collected(let limit):
                let (readFd, writeFd) = try FileDescriptor.pipe()
                return .collected(limit, readFd, writeFd)
            }
        }
    }
}

// MARK: - Execution IO
extension Subprocess {
    internal enum ExecutionInput {
        case noInput(FileDescriptor)
        case customWrite(FileDescriptor, FileDescriptor)
        case fileDescriptor(FileDescriptor)

        internal func getReadFileDescriptor() -> FileDescriptor {
            switch self {
            case .noInput(let readFd):
                return readFd
            case .customWrite(let readFd, _):
                return readFd
            case .fileDescriptor(let readFd):
                return readFd
            }
        }

        internal func getWriteFileDescriptor() -> FileDescriptor? {
            switch self {
            case .noInput(_), .fileDescriptor(_):
                return nil
            case .customWrite(_, let writeFd):
                return writeFd
            }
        }

        internal func closeAll() throws {
            switch self {
            case .noInput(let readFd):
                try readFd.close()
            case .customWrite(let readFd, let writeFd):
                try readFd.close()
                try writeFd.close()
            case .fileDescriptor(let fd):
                try fd.close()
            }
        }
    }

    internal enum ExecutionOutput {
        case discarded(FileDescriptor)
        case fileDescriptor(FileDescriptor)
        case collected(Int, FileDescriptor, FileDescriptor)

        internal func getWriteFileDescriptor() -> FileDescriptor {
            switch self {
            case .discarded(let writeFd):
                return writeFd
            case .fileDescriptor(let writeFd):
                return writeFd
            case .collected(_, _, let writeFd):
                return writeFd
            }
        }

        internal func getReadFileDescriptor() -> FileDescriptor? {
            switch self {
            case .discarded(_), .fileDescriptor(_):
                return nil
            case .collected(_, let readFd, _):
                return readFd
            }
        }

        internal func closeAll() throws {
            switch self {
            case .discarded(let writeFd):
                try writeFd.close()
            case .fileDescriptor(let fd):
                try fd.close()
            case .collected(_, let readFd, let writeFd):
                try readFd.close()
                try writeFd.close()
            }
        }
    }
}

// MARK: - Private Helpers
extension FileDescriptor {
    internal func read(upToLength maxLength: Int) throws -> [UInt8] {
        let buffer: UnsafeMutableBufferPointer<UInt8> = .allocate(capacity: maxLength)
        let readCount = try self.read(into: .init(buffer))
        let resizedBuffer: UnsafeBufferPointer<UInt8> = .init(start: buffer.baseAddress, count: readCount)
        return Array(resizedBuffer)
    }
}
