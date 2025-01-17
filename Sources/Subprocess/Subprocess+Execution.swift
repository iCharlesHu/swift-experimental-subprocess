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

import SystemPackage

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(WinSDK)
import WinSDK
#endif

#if canImport(FoundationEssentials)
import FoundationEssentials
#elseif canImport(Foundation)
import Foundation
#endif

extension Subprocess {
    /// An object that repersents a subprocess that has been
    /// executed. You can use this object to send signals to the
    /// child process as well as stream its output and error.
    public struct Execution<
        Input: Subprocess.InputProtocol,
        Output: Subprocess.OutputProtocol,
        Error: Subprocess.OutputProtocol
    >: Sendable {
        public let processIdentifier: ProcessIdentifier

        internal let input: Input
        internal let output: Output
        internal let error: Error
#if os(Windows)
        internal let consoleBehavior: PlatformOptions.ConsoleBehavior
#endif

        private func capture(fileDescriptor: FileDescriptor, maxLength: Int) async throws -> Data {
            return try await fileDescriptor.readUntilEOF(upToLength: maxLength)
        }
    }
}

extension Subprocess.Execution where Output == Subprocess.RedirectedOutput {
    /// The standard output of the subprocess.
    /// Accessing this property will **fatalError** if
    /// - `.output` wasn't set to `.redirectToSequence` when the subprocess was spawned;
    /// - This property was accessed multiple times. Subprocess communicates with
    ///   parent process via pipe under the hood and each pipe can only be consumed ones.
    public var standardOutput: some _AsyncSequence<Data, any Swift.Error> {
        guard let fd = self.output
            .consumeReadFileDescriptor() else {
            fatalError("The standard output has already been consumed")
        }
        return Subprocess.AsyncDataSequence(fileDescriptor: fd)
    }
}

extension Subprocess.Execution where Error == Subprocess.RedirectedOutput {
    /// The standard error of the subprocess.
    /// Accessing this property will **fatalError** if
    /// - `.error` wasn't set to `.redirectToSequence` when the subprocess was spawned;
    /// - This property was accessed multiple times. Subprocess communicates with
    ///   parent process via pipe under the hood and each pipe can only be consumed ones.
    public var standardError: some _AsyncSequence<Data, any Swift.Error> {
        guard let fd = self.error
            .consumeReadFileDescriptor() else {
            fatalError("The standard error has already been consumed")
        }
        return Subprocess.AsyncDataSequence(fileDescriptor: fd)
    }
}

// MARK: - Teardown
#if canImport(Darwin) || canImport(Glibc)
extension Subprocess.Execution {
    /// Performs a sequence of teardown steps on the Subprocess.
    /// Teardown sequence always ends with a `.kill` signal
    /// - Parameter sequence: The  steps to perform.
    public func teardown(using sequence: [Subprocess.TeardownStep]) async {
        await withUncancelledTask {
            await self.runTeardownSequence(sequence)
        }
    }
}
#endif

// MARK: - Output Capture
extension Subprocess {
    internal enum OutputCapturingState {
        case standardOutputCaptured(Data?)
        case standardErrorCaptured(Data?)
    }

    internal typealias CapturedIOs = (standardOutput: Data?, standardError: Data?)
}

extension Subprocess.Execution {
    internal func captureStandardOutput() async throws -> Data? {
        guard Output.OutputType.self != Void.self else {
            return nil
        }

        guard let readFd = self.output
            .consumeReadFileDescriptor() else {
            return nil
        }
        defer {
            try? readFd.close()
        }
        return try await self.capture(
            fileDescriptor: readFd,
            maxLength: self.output.maxCollectionLength
        )
    }

    internal func captureStandardError() async throws -> Data? {
        guard Error.OutputType.self != Void.self else {
            return nil
        }
        guard let readFd = self.error
            .consumeReadFileDescriptor() else {
            return nil
        }
        defer {
            try? readFd.close()
        }
        return try await self.capture(
            fileDescriptor: readFd,
            maxLength: self.error.maxCollectionLength
        )
    }

    internal func captureIOs() async throws -> Subprocess.CapturedIOs {
        return try await withThrowingTaskGroup(of: Subprocess.OutputCapturingState.self) { group in
            group.addTask {
                let stdout = try await self.captureStandardOutput()
                return .standardOutputCaptured(stdout)
            }
            group.addTask {
                let stderr = try await self.captureStandardError()
                return .standardErrorCaptured(stderr)
            }

            var stdout: Data?
            var stderror: Data?
            while let state = try await group.next() {
                switch state {
                case .standardOutputCaptured(let output):
                    stdout = output
                case .standardErrorCaptured(let error):
                    stderror = error
                }
            }
            return (standardOutput: stdout, standardError: stderror)
        }
    }
}

