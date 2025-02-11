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

#if canImport(Darwin)
import Darwin
#elseif canImport(Bionic)
import Bionic
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
import WinSDK
#endif

#if canImport(FoundationEssentials)
import FoundationEssentials
#elseif canImport(Foundation)
import Foundation
#endif

/// An object that repersents a subprocess that has been
/// executed. You can use this object to send signals to the
/// child process as well as stream its output and error.
public struct Execution<
    Output: OutputProtocol,
    Error: OutputProtocol
>: Sendable {
    /// The process identifier of the current execution
    public let processIdentifier: ProcessIdentifier

    internal let output: Output
    internal let error: Error
#if os(Windows)
    internal let consoleBehavior: PlatformOptions.ConsoleBehavior

    init(
        processIdentifier: ProcessIdentifier,
        output: Output,
        error: Error,
        consoleBehavior: PlatformOptions.ConsoleBehavior
    ) {
        self.processIdentifier = processIdentifier
        self.output = output
        self.error = error
        self.consoleBehavior = consoleBehavior
    }
#else
    init(processIdentifier: ProcessIdentifier, output: Output, error: Error) {
        self.processIdentifier = processIdentifier
        self.output = output
        self.error = error
    }
#endif // os(Windows)
}

extension Execution where Output == SequenceOutput {
    /// The standard output of the subprocess.
    /// Accessing this property will **fatalError** if
    /// - `.output` wasn't set to `.redirectToSequence` when the subprocess was spawned;
    /// - This property was accessed multiple times. Subprocess communicates with
    ///   parent process via pipe under the hood and each pipe can only be consumed ones.
    public var standardOutput: some AsyncSequence<Data, any Swift.Error> {
        guard let fd = self.output
            .consumeReadFileDescriptor() else {
            fatalError("The standard output has already been consumed")
        }
        return AsyncDataSequence(fileDescriptor: fd)
    }
}

extension Execution where Error == SequenceOutput {
    /// The standard error of the subprocess.
    /// Accessing this property will **fatalError** if
    /// - `.error` wasn't set to `.redirectToSequence` when the subprocess was spawned;
    /// - This property was accessed multiple times. Subprocess communicates with
    ///   parent process via pipe under the hood and each pipe can only be consumed ones.
    public var standardError: some AsyncSequence<Data, any Swift.Error> {
        guard let fd = self.error
            .consumeReadFileDescriptor() else {
            fatalError("The standard error has already been consumed")
        }
        return AsyncDataSequence(fileDescriptor: fd)
    }
}

// MARK: - Teardown
#if canImport(Darwin) || canImport(Glibc) || canImport(Bionic) || canImport(Musl)
extension Execution {
    /// Performs a sequence of teardown steps on the Subprocess.
    /// Teardown sequence always ends with a `.kill` signal
    /// - Parameter sequence: The  steps to perform.
    public func teardown(using sequence: [TeardownStep]) async {
        await withUncancelledTask {
            await self.runTeardownSequence(sequence)
        }
    }
}
#endif // canImport(Glibc) || canImport(Bionic) || canImport(Musl)

// MARK: - Output Capture
internal enum OutputCapturingState<Output: Sendable, Error: Sendable>: Sendable {
    case standardOutputCaptured(Output)
    case standardErrorCaptured(Error)
}

internal typealias CapturedIOs<
    Output: Sendable, Error: Sendable
> = (standardOutput: Output, standardError: Error)

extension Execution {
    internal func captureIOs() async throws -> CapturedIOs<
        Output.OutputType, Error.OutputType
    > {
        return try await withThrowingTaskGroup(
            of: OutputCapturingState<Output.OutputType, Error.OutputType>.self
        ) { group in
            group.addTask {
                let stdout = try await self.output.captureOutput()
                return .standardOutputCaptured(stdout)
            }
            group.addTask {
                let stderr = try await self.error.captureOutput()
                return .standardErrorCaptured(stderr)
            }

            var stdout: Output.OutputType!
            var stderror: Error.OutputType!
            while let state = try await group.next() {
                switch state {
                case .standardOutputCaptured(let output):
                    stdout = output
                case .standardErrorCaptured(let error):
                    stderror = error
                }
            }
            return (
                standardOutput: stdout,
                standardError: stderror,
            )
        }
    }
}

