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

#if canImport(Synchronization)
import Synchronization

private typealias Lock = Mutex
#else
private typealias Lock = LockedState
#endif


/// A managed, opaque UNIX pipe used by `PipeOutputProtocol` and `PipeInputProtocol`
public final class Pipe: Sendable {
    private let pipe: Lock<(readEnd: FileDescriptor?, writeEnd: FileDescriptor?)?>

    public func readFileDescriptor(creatingIfNeeded: Bool) throws -> FileDescriptor? {
        return try self.pipe.withLock { pipeStore in
            if let pipe = pipeStore {
                return pipe.readEnd
            }
            // Create pipe now
            guard creatingIfNeeded else {
                return nil
            }
            let pipe = try FileDescriptor.pipe()
            pipeStore = pipe
            return pipe.readEnd
        }
    }

    public func writeFileDescriptor(creatingIfNeeded: Bool) throws -> FileDescriptor? {
        return try self.pipe.withLock { pipeStore in
            if let pipe = pipeStore {
                return pipe.writeEnd
            }
            guard creatingIfNeeded else {
                return nil
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

    /// Return the read `FileDescriptor` and remove it from the output
    /// such that the next call to `consumeReadFileDescriptor` will
    /// return `nil`.
    public func consumeReadFileDescriptor() -> FileDescriptor? {
        return self.pipe.withLock { pipeStore in
            guard let pipe = pipeStore else {
                return nil
            }
            pipeStore = (readEnd: nil, writeEnd: pipe.writeEnd)
            return pipe.readEnd
        }
    }

    public init() {
        self.pipe = Lock(nil)
    }
}

