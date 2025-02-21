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

#if os(Windows)

import Testing
import Dispatch

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

import TestResources
@testable import Subprocess
@testable import SubprocessFoundation

@Suite(.serialized)
struct SubprocessFoundationWindowsTests {
    private let cmdExe: Subprocess.Executable = .path("C:\\Windows\\System32\\cmd.exe")

    @available(macOS 9999, *)
    @Test func testInputNoInput() async throws {
        let catResult = try await Subprocess.run(
            self.cmdExe,
            arguments: ["/c", "more"],
            input: .none,
            output: .data
        )
        #expect(catResult.terminationStatus.isSuccess)
        // We should have read exactly 0 bytes
        #expect(catResult.standardOutput.isEmpty)
    }

    @available(macOS 9999, *)
    @Test func testInputFileDescriptor() async throws {
        // Make sure we can read long text from standard input
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let text: FileDescriptor = try .open(
            theMysteriousIsland, .readOnly
        )

        let catResult = try await Subprocess.run(
            self.cmdExe,
            arguments: [
                "/c",
                "findstr x*"
            ],
            input: .fileDescriptor(text, closeAfterSpawningProcess: true),
            output: .data(limit: 2048 * 1024)
        )

        #expect(catResult.terminationStatus.isSuccess)
        // Make sure we read all bytes
        #expect(
            catResult.standardOutput ==
            expected
        )
    }

    @available(macOS 9999, *)
    @Test func testInputSequence() async throws {
        // Make sure we can read long text as Sequence
        let expected: Data = try Data(
            contentsOf: URL(filePath: getgroupsSwift.string)
        )
        let catResult = try await Subprocess.run(
            self.cmdExe,
            arguments: [
                "/c",
                "findstr x*"
            ],
            input: .data(expected),
            output: .data(limit: 2048 * 1024),
            error: .discarded
        )
        #expect(catResult.terminationStatus.isSuccess)
        // Make sure we read all bytes
        #expect(
            catResult.standardOutput ==
            expected
        )
    }

    @available(macOS 9999, *)
    @Test func testInputAsyncSequence() async throws {
        let chunkSize = 4096
        // Maeks ure we can read long text as AsyncSequence
        let fd: FileDescriptor = try .open(theMysteriousIsland, .readOnly)
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let stream: AsyncStream<Data> = AsyncStream { continuation in
            DispatchQueue.global().async {
                var currentStart = 0
                while currentStart + chunkSize < expected.count {
                    continuation.yield(expected[currentStart ..< currentStart + chunkSize])
                    currentStart += chunkSize
                }
                if expected.count - currentStart > 0 {
                    continuation.yield(expected[currentStart ..< expected.count])
                }
                continuation.finish()
            }
        }
        let catResult = try await Subprocess.run(
            self.cmdExe,
            arguments: ["/c", "findstr x*"],
            input: .sequence(stream),
            output: .data(limit: 2048 * 1024)
        )
        #expect(catResult.terminationStatus.isSuccess)
        #expect(
            catResult.standardOutput ==
            expected
        )
    }

    @available(macOS 9999, *)
    @Test func testInputSequenceCustomExecutionBody() async throws {
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let result = try await Subprocess.run(
            self.cmdExe,
            arguments: ["/c", "findstr x*"],
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

    @available(macOS 9999, *)
    @Test func testInputAsyncSequenceCustomExecutionBody() async throws {
        // Maeks ure we can read long text as AsyncSequence
        let chunkSize = 4096
        let fd: FileDescriptor = try .open(theMysteriousIsland, .readOnly)
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let stream: AsyncStream<Data> = AsyncStream { continuation in
            DispatchQueue.global().async {
                var currentStart = 0
                while currentStart + chunkSize < expected.count {
                    continuation.yield(expected[currentStart ..< currentStart + chunkSize])
                    currentStart += chunkSize
                }
                if expected.count - currentStart > 0 {
                    continuation.yield(expected[currentStart ..< expected.count])
                }
                continuation.finish()
            }
        }
        let result = try await Subprocess.run(
            self.cmdExe,
            arguments: ["/c", "findstr x*"],
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
}


#endif
