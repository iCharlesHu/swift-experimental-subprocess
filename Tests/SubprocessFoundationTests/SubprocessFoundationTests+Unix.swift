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

#if canImport(Darwin) || canImport(Glibc)

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

#if canImport(System)
import System
#else
@preconcurrency import SystemPackage
#endif

import Testing
import TestResources

import Dispatch

@testable import Subprocess
@testable import SubprocessFoundation

@Suite(.serialized)
struct SubprocessFoundationTests {
    @available(macOS 9999, *)
    @Test func testInputFileDescriptor() async throws {
        // Make sure we can read long text from standard input
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let text: FileDescriptor = try .open(
            theMysteriousIsland, .readOnly)
        let cat = try await Subprocess.run(
            .name("cat"),
            input: .fileDescriptor(text, closeAfterSpawningProcess: true),
            output: .data(limit: 2048 * 1024)
        )
        #expect(cat.terminationStatus.isSuccess)
        // Make sure we read all bytes
        #expect(cat.standardOutput == expected)
    }

    @available(macOS 9999, *)
    @Test func testInputSequence() async throws {
        // Make sure we can read long text as Sequence
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let catResult = try await Subprocess.run(
            .path("/bin/cat"),
            input: .data(expected),
            output: .data(limit: 2048 * 1024)
        )
        #expect(catResult.terminationStatus.isSuccess)
        #expect(catResult.standardOutput.count == expected.count)
        #expect(Array(catResult.standardOutput) == Array(expected))
    }

    @available(macOS 9999, *)
    @Test func testInputSpan() async throws {
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let ptr = expected.withUnsafeBytes { return $0 }
        let span: Span<UInt8> = Span(_unsafeBytes: ptr)
        let catResult = try await Subprocess.run(
            .path("/bin/cat"),
            input: span,
            output: .data(limit: 2048 * 1024)
        )
        #expect(catResult.terminationStatus.isSuccess)
        #expect(catResult.standardOutput.count == expected.count)
        #expect(Array(catResult.standardOutput) == Array(expected))
    }

    @available(macOS 9999, *)
    @Test func testInputAsyncSequence() async throws {
        // Maeks ure we can read long text as AsyncSequence
        let fd: FileDescriptor = try .open(theMysteriousIsland, .readOnly)
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let channel = DispatchIO(type: .stream, fileDescriptor: fd.rawValue, queue: .main) { error in
            try? fd.close()
        }
        let stream: AsyncStream<Data> = AsyncStream { continuation in
            channel.read(offset: 0, length: .max, queue: .main) { done, data, error in
                if done {
                    continuation.finish()
                }
                guard let data = data else {
                    return
                }
                continuation.yield(Data(data))
            }
        }
        let catResult = try await Subprocess.run(
            .path("/bin/cat"),
            input: .sequence(stream),
            output: .data(limit: 2048 * 1024)
        )
        #expect(catResult.terminationStatus.isSuccess)
        #expect(catResult.standardOutput == expected)
    }

    @Test func testInputSequenceCustomExecutionBody() async throws {
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let result = try await Subprocess.run(
            .path("/bin/cat"),
            input: .data(expected),
            output: .sequence,
            error: .discarded
        ) { execution in
            var buffer = Data()
            for try await chunk in execution.standardOutput {
                buffer += chunk
            }
            return buffer
        }
        #expect(result.terminationStatus.isSuccess)
        #expect(result.value == expected)
    }

    @Test func testInputAsyncSequenceCustomExecutionBody() async throws {
        // Maeks ure we can read long text as AsyncSequence
        let fd: FileDescriptor = try .open(theMysteriousIsland, .readOnly)
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let channel = DispatchIO(type: .stream, fileDescriptor: fd.rawValue, queue: .main) { error in
            try? fd.close()
        }
        let stream: AsyncStream<Data> = AsyncStream { continuation in
            channel.read(offset: 0, length: .max, queue: .main) { done, data, error in
                if done {
                    continuation.finish()
                }
                guard let data = data else {
                    return
                }
                continuation.yield(Data(data))
            }
        }
        let result = try await Subprocess.run(
            .path("/bin/cat"),
            input: .sequence(stream),
            output: .sequence,
            error: .discarded
        ) { execution in
            var buffer = Data()
            for try await chunk in execution.standardOutput {
                buffer += chunk
            }
            return buffer
        }
        #expect(result.terminationStatus.isSuccess)
        #expect(result.value == expected)
    }

    @available(macOS 9999, *)
    @Test func testCollectedError() async throws {
        // Make ure we can capture long text on standard error
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let catResult = try await Subprocess.run(
            .name("/bin/bash"),
            arguments: ["-c", "cat \(theMysteriousIsland.string) 1>&2"],
            error: .data(limit: 2048 * 1024)
        )
        #expect(catResult.terminationStatus.isSuccess)
        #expect(catResult.standardError == expected)
    }
}

// MARK: - Performance Tests
extension SubprocessFoundationTests {
    @available(macOS 9999, *)
    @Test func testConcurrentRun() async throws {
        // Launch as many processes as we can
        // Figure out the max open file limit
        let limitResult = try await Subprocess.run(
            .path("/bin/bash"),
            arguments: ["-c", "ulimit -n"],
            output: .string
        )
        guard let limitString = limitResult
            .standardOutput?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let limit = Int(limitString) else {
            Issue.record("Failed to run  ulimit -n")
            return
        }
        // Since we open two pipes per `run`, launch
        // limit / 4 subprocesses should reveal any
        // file descriptor leaks
        let maxConcurrent = limit / 4
        try await withThrowingTaskGroup(of: Void.self) { group in
            var running = 0
            let byteCount = 1000
            for _ in 0 ..< maxConcurrent {
                group.addTask {
                    let r = try await Subprocess.run(
                        .path("/bin/bash"),
                        arguments: ["-sc", #"echo "$1" && echo "$1" >&2"#, "--", String(repeating: "X", count: byteCount)],
                        output: .data,
                        error: .data
                    )
                    guard r.terminationStatus.isSuccess else {
                        Issue.record("Unexpected exit \(r.terminationStatus) from \(r.processIdentifier)")
                        return
                    }
                    #expect(r.standardOutput.count == byteCount + 1, "\(r.standardOutput)")
                    #expect(r.standardError.count == byteCount + 1, "\(r.standardError)")
                }
                running += 1
                if running >= maxConcurrent / 4 {
                    try await group.next()
                }
            }
            try await group.waitForAll()
        }
    }

    @available(macOS 9999, *)
    @Test func testCaptureLongStandardOutputAndError() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var running = 0
            for _ in 0 ..< 10 {
                group.addTask {
                    let r = try await Subprocess.run(
                        .path("/bin/bash"),
                        arguments: ["-sc", #"echo "$1" && echo "$1" >&2"#, "--", String(repeating: "X", count: 100_000)],
                        output: .data,
                        error: .data
                    )
                    #expect(r.terminationStatus == .exited(0))
                    #expect(r.standardOutput.count == 100_001, "Standard output actual \(r.standardOutput)")
                    #expect(r.standardError.count == 100_001, "Standard error actual \(r.standardError)")
                }
                running += 1
                if running >= 1000 {
                    try await group.next()
                }
            }
            try await group.waitForAll()
        }
    }
}

#endif
