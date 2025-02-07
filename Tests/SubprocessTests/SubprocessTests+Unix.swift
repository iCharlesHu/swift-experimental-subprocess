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

import _CShims
import XCTest
@testable import Subprocess

import Dispatch
#if canImport(System)
import System
#else
@preconcurrency import SystemPackage
#endif

final class SubprocessUnixTests: XCTestCase { }

// MARK: - Executable test
@available(macOS 9999, *)
extension SubprocessUnixTests {
    func testExecutableNamed() async throws {
        // Simple test to make sure we can find a common utility
        let message = "Hello, world!"
        let result = try await Subprocess.run(
            .named("echo"),
            arguments: .init([message])
        )
        XCTAssertTrue(result.terminationStatus.isSuccess)
        // rdar://138670128
        let output = result.standardOutput?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            output,
            message
        )
    }

    func testExecutableNamedCannotResolve() async {
        do {
            _ = try await Subprocess.run(.named("do-not-exist"))
            XCTFail("Expected to throw")
        } catch {
            guard let cocoaError: CocoaError = error as? CocoaError else {
                XCTFail("Expected CocoaError, got \(error)")
                return
            }
            XCTAssertEqual(cocoaError.code, .executableNotLoadable)
        }
    }

    func testExecutableAtPath() async throws {
        let expected = FileManager.default.currentDirectoryPath
        let result = try await Subprocess.run(.at("/bin/pwd"), output: .string)
        XCTAssertTrue(result.terminationStatus.isSuccess)
        // rdar://138670128
        let maybePath = result.standardOutput?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let path = try XCTUnwrap(maybePath)
        XCTAssertTrue(directory(path, isSameAs: expected))
    }

    func testExecutableAtPathCannotResolve() async {
        do {
            // Since we are using the path directly,
            // we expect the error to be thrown by the underlying
            // posix_spawn
            _ = try await Subprocess.run(.at("/usr/bin/do-not-exist"))
            XCTFail("Expected to throw POSIXError")
        } catch {
            guard let posixError: POSIXError = error as? POSIXError else {
                XCTFail("Expected POSIXError, got \(error)")
                return
            }
            XCTAssertEqual(posixError.code, .ENOENT)
        }
    }
}

// MARK: - Arguments Tests
@available(macOS 9999, *)
extension SubprocessUnixTests {
    func testArgunementsArrayLitereal() async throws {
        let result = try await Subprocess.run(
            .at("/bin/bash"),
            arguments: ["-c", "echo Hello World!"],
            output: .string
        )
        XCTAssertTrue(result.terminationStatus.isSuccess)
        // rdar://138670128
        let output = result.standardOutput?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            output,
            "Hello World!"
        )
    }

    func testArgumentsOverride() async throws {
        let result = try await Subprocess.run(
            .at("/bin/bash"),
            arguments: .init(
                executablePathOverride: "apple",
                remainingValues: ["-c", "echo $0"]
            ),
            output: .string
        )
        XCTAssertTrue(result.terminationStatus.isSuccess)
        // rdar://138670128
        let output = result.standardOutput?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            output,
            "apple"
        )
    }

    func testArgumemtsFromData() async throws {
        let arguments = Data("Data Content".utf8)
        let result = try await Subprocess.run(
            .at("/bin/echo"),
            arguments: .init(
                executablePathOverride: nil,
                remainingValues: [arguments]
            ),
            output: .string
        )
        XCTAssertTrue(result.terminationStatus.isSuccess)
        // rdar://138670128
        let output = result.standardOutput?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            output,
            "Data Content"
        )
    }
}

// MARK: - Environment Tests
@available(macOS 9999, *)
extension SubprocessUnixTests {
    func testEnvironmentInherit() async throws {
        let result = try await Subprocess.run(
            .at("/bin/bash"),
            arguments: ["-c", "printenv PATH"],
            environment: .inherit,
            output: .string
        )
        XCTAssertTrue(result.terminationStatus.isSuccess)
        // As a sanity check, make sure there's `/bin` in PATH
        // since we inherited the environment variables
        // rdar://138670128
        let maybeOutput = result.standardOutput
        let pathValue = try XCTUnwrap(maybeOutput)
        XCTAssertTrue(pathValue.contains("/bin"))
    }

    func testEnvironmentInheritOverride() async throws {
        let result = try await Subprocess.run(
            .at("/bin/bash"),
            arguments: ["-c", "printenv HOME"],
            environment: .inherit.updating([
                "HOME": "/my/new/home"
            ]),
            output: .string
        )
        XCTAssertTrue(result.terminationStatus.isSuccess)
        // rdar://138670128
        let output = result.standardOutput?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            output,
            "/my/new/home"
        )
    }

    func testEnvironmentCustom() async throws {
        let result = try await Subprocess.run(
            .at("/usr/bin/printenv"),
            environment: .custom([
                "PATH": "/bin:/usr/bin",
            ]),
            output: .string
        )
        XCTAssertTrue(result.terminationStatus.isSuccess)
        // There shouldn't be any other environment variables besides
        // `PATH` that we set
        // rdar://138670128
        let output = result.standardOutput?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            output,
            "PATH=/bin:/usr/bin"
        )
    }
}

// MARK: - Working Directory Tests
@available(macOS 9999, *)
extension SubprocessUnixTests {
    func testWorkingDirectoryDefaultValue() async throws {
        // By default we should use the working directory of the parent process
        let workingDirectory = FileManager.default.currentDirectoryPath
        let result = try await Subprocess.run(
            .at("/bin/pwd"),
            workingDirectory: nil,
            output: .string
        )
        XCTAssertTrue(result.terminationStatus.isSuccess)
        // There shouldn't be any other environment variables besides
        // `PATH` that we set
        // rdar://138670128
        let output = result.standardOutput?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let path = try XCTUnwrap(output)
        XCTAssertTrue(directory(path, isSameAs: workingDirectory))
    }

    func testWorkingDirectoryCustomValue() async throws {
        let workingDirectory = FilePath(
            FileManager.default.temporaryDirectory.path()
        )
        let result = try await Subprocess.run(
            .at("/bin/pwd"),
            workingDirectory: workingDirectory,
            output: .string
        )
        XCTAssertTrue(result.terminationStatus.isSuccess)
        // There shouldn't be any other environment variables besides
        // `PATH` that we set
        let resultPath = result.standardOutput!
            .trimmingCharacters(in: .whitespacesAndNewlines)
#if canImport(Darwin)
        // On Darwin, /var is linked to /private/var; /tmp is linked to /private/tmp
        var expected = workingDirectory
        if expected.starts(with: "/var") || expected.starts(with: "/tmp") {
            expected = FilePath("/private").appending(expected.components)
        }
        XCTAssertEqual(
            FilePath(resultPath),
            expected
        )
#else
        XCTAssertEqual(
            FilePath(resultPath),
            workingDirectory
        )
#endif
    }
}

// MARK: - Input Tests
@available(macOS 9999, *)
extension SubprocessUnixTests {
    func testInputNoInput() async throws {
        let catResult = try await Subprocess.run(
            .at("/bin/cat"),
            input: .none,
            output: .data
        )
        XCTAssertTrue(catResult.terminationStatus.isSuccess)
        // We should have read exactly 0 bytes
        XCTAssertTrue(catResult.standardOutput.isEmpty)
    }

    func testInputFileDescriptor() async throws {
        // Make sure we can read long text from standard input
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let text: FileDescriptor = try .open(
            theMysteriousIsland, .readOnly)
        let cat = try await Subprocess.run(
            .named("cat"),
            input: .fileDescriptor(text, closeAfterSpawningProcess: true),
            output: .data(limit: 2048 * 1024)
        )
        XCTAssertTrue(cat.terminationStatus.isSuccess)
        // Make sure we read all bytes
        XCTAssertEqual(cat.standardOutput, expected)
    }

    func testInputSequence() async throws {
        // Make sure we can read long text as Sequence
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let catResult = try await Subprocess.run(
            .at("/bin/cat"),
            input: .data(expected),
            output: .data(limit: 2048 * 1024)
        )
        XCTAssertTrue(catResult.terminationStatus.isSuccess)
        XCTAssertEqual(catResult.standardOutput.count, expected.count)
        XCTAssertEqual(Array(catResult.standardOutput), Array(expected))
    }

    @available(macOS 9999, *)
    func testInputSpan() async throws {
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let ptr = expected.withUnsafeBytes { return $0 }
        let span: Span<UInt8> = Span(_unsafeBytes: ptr)
        let catResult = try await Subprocess.run(
            .at("/bin/cat"),
            input: span,
            output: .data(limit: 2048 * 1024)
        )
        XCTAssertTrue(catResult.terminationStatus.isSuccess)
        XCTAssertEqual(catResult.standardOutput.count, expected.count)
        XCTAssertEqual(Array(catResult.standardOutput), Array(expected))
    }

    func testInputAsyncSequence() async throws {
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
            .at("/bin/cat"),
            input: .sequence(stream),
            output: .data(limit: 2048 * 1024)
        )
        XCTAssertTrue(catResult.terminationStatus.isSuccess)
        XCTAssertEqual(catResult.standardOutput, expected)
    }

    func testInputSequenceCustomExecutionBody() async throws {
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let result = try await Subprocess.run(
            .at("/bin/cat"),
            input: .data(expected)
        ) { execution in
            var buffer = Data()
            for try await chunk in execution.standardOutput {
                buffer += chunk
            }
            return buffer
        }
        XCTAssertTrue(result.terminationStatus.isSuccess)
        XCTAssertEqual(result.value, expected)
    }

    func testInputAsyncSequenceCustomExecutionBody() async throws {
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
            .at("/bin/cat"),
            input: .sequence(stream)
        ) { execution in
            var buffer = Data()
            for try await chunk in execution.standardOutput {
                buffer += chunk
            }
            return buffer
        }
        XCTAssertTrue(result.terminationStatus.isSuccess)
        XCTAssertEqual(result.value, expected)
    }
}

// MARK: - Output Tests
@available(macOS 9999, *)
extension SubprocessUnixTests {
#if false // This test needs "death test" support
    func testOutputDiscarded() async throws {
        let echoResult = try await Subprocess.run(
            .at("/bin/echo"),
            arguments: ["Some garbage text"],
            output: .discard
        )
        XCTAssertTrue(echoResult.terminationStatus.isSuccess)
        _ = echoResult.standardOutput // this line shold fatalError
    }
#endif

    func testCollectedOutput() async throws {
        let expected = randomString(length: 32)
        let echoResult = try await Subprocess.run(
            .at("/bin/echo"),
            arguments: [expected],
            output: .string
        )
        XCTAssertTrue(echoResult.terminationStatus.isSuccess)
        let output = try XCTUnwrap(
            echoResult.standardOutput
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(output, expected)
    }

    func testCollectedOutputWithLimit() async throws {
        let limit = 4
        let expected = randomString(length: 32)
        let echoResult = try await Subprocess.run(
            .at("/bin/echo"),
            arguments: [expected],
            output: .string(limit: limit)
        )
        XCTAssertTrue(echoResult.terminationStatus.isSuccess)
        let output = try XCTUnwrap(
            echoResult.standardOutput
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let targetRange = expected.startIndex ..< expected.index(expected.startIndex, offsetBy: limit)
        XCTAssertEqual(String(expected[targetRange]), output)
    }

    func testCollectedOutputFileDesriptor() async throws {
        let outputFilePath = FilePath(FileManager.default.temporaryDirectory.path())
            .appending("Test.out")
        if FileManager.default.fileExists(atPath: outputFilePath.string) {
            try FileManager.default.removeItem(atPath: outputFilePath.string)
        }
        let outputFile: FileDescriptor = try .open(
            outputFilePath,
            .readWrite,
            options: .create,
            permissions: [.ownerReadWrite, .groupReadWrite]
        )
        let expected = randomString(length: 32)
        let echoResult = try await Subprocess.run(
            .at("/bin/echo"),
            arguments: [expected],
            output: .fileDescriptor(
                outputFile,
                closeAfterSpawningProcess: false
            )
        )
        XCTAssertTrue(echoResult.terminationStatus.isSuccess)
        try outputFile.close()
        let outputData: Data = try Data(
            contentsOf: URL(filePath: outputFilePath.string)
        )
        let output = try XCTUnwrap(
            String(data: outputData, encoding: .utf8)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(echoResult.terminationStatus.isSuccess)
        XCTAssertEqual(output, expected)
    }

    func testCollectedOutputFileDescriptorAutoClose() async throws {
        let outputFilePath = FilePath(FileManager.default.temporaryDirectory.path())
            .appending("Test.out")
        if FileManager.default.fileExists(atPath: outputFilePath.string) {
            try FileManager.default.removeItem(atPath: outputFilePath.string)
        }
        let outputFile: FileDescriptor = try .open(
            outputFilePath,
            .readWrite,
            options: .create,
            permissions: [.ownerReadWrite, .groupReadWrite]
        )
        let echoResult = try await Subprocess.run(
            .at("/bin/echo"),
            arguments: ["Hello world"],
            output: .fileDescriptor(
                outputFile,
                closeAfterSpawningProcess: true
            )
        )
        XCTAssertTrue(echoResult.terminationStatus.isSuccess)
        // Make sure the file descriptor is already closed
        do {
            try outputFile.close()
            XCTFail("Output file descriptor should be closed automatically")
        } catch {
            guard let typedError = error as? Errno else {
                XCTFail("Wrong type of error thrown")
                return
            }
            XCTAssertEqual(typedError, .badFileDescriptor)
        }
    }

/*
    func testRedirectedOutputFileDescriptor() async throws {
        let outputFilePath = FilePath(FileManager.default.temporaryDirectory.path())
            .appending("Test.out")
        let outputFile: FileDescriptor = try .open(
            outputFilePath,
            .readWrite,
            options: .create,
            permissions: [.ownerReadWrite, .groupReadWrite]
        )
        let expected = randomString(length: 32)
        let echoResult = try await Subprocess.run(
            .at("/bin/echo"),
            arguments: [expected],
            output: .writeTo(
                outputFile,
                closeAfterSpawningProcess: false
            )
        ) { subproces, writer in
            return 0
        }
        XCTAssertTrue(echoResult.terminationStatus.isSuccess)
        try outputFile.close()
        let outputData: Data = try Data(
            contentsOf: URL(filePath: outputFilePath.string)
        )
        let output = try XCTUnwrap(
            String(data: outputData, encoding: .utf8)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(echoResult.terminationStatus.isSuccess)
        XCTAssertEqual(output, expected)
    }

    func testRedriectedOutputFileDescriptorAutoClose() async throws {
        let outputFilePath = FilePath(FileManager.default.temporaryDirectory.path())
            .appending("Test.out")
        let outputFile: FileDescriptor = try .open(
            outputFilePath,
            .readWrite,
            options: .create,
            permissions: [.ownerReadWrite, .groupReadWrite]
        )
        let echoResult = try await Subprocess.run(
            .at("/bin/echo"),
            arguments: ["Hello world"],
            output: .writeTo(
                outputFile,
                closeAfterSpawningProcess: true
            )
        ) { subproces, writer in
            return 0
        }
        XCTAssertTrue(echoResult.terminationStatus.isSuccess)
        // Make sure the file descriptor is already closed
        do {
            try outputFile.close()
            XCTFail("Output file descriptor should be closed automatically")
        } catch {
            guard let typedError = error as? Errno else {
                XCTFail("Wrong type of error thrown")
                return
            }
            XCTAssertEqual(typedError, .badFileDescriptor)
        }
    }
*/

    func testRedirectedOutputRedirectToSequence() async throws {
        // Make ure we can read long text redirected to AsyncSequence
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let catResult = try await Subprocess.run(
            .at("/bin/cat"),
            arguments: [theMysteriousIsland.string],
            output: .sequence
        ) { subprocess in
            var buffer = Data()
            for try await chunk in subprocess.standardOutput {
                buffer += chunk
            }
            return buffer
        }
        XCTAssertTrue(catResult.terminationStatus.isSuccess)
        XCTAssertEqual(catResult.value, expected)
    }

    func testCollectedError() async throws {
        // Make ure we can capture long text on standard error
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let catResult = try await Subprocess.run(
            .named("/bin/bash"),
            arguments: ["-c", "cat \(theMysteriousIsland.string) 1>&2"],
            error: .data(limit: 2048 * 1024)
        )
        XCTAssertTrue(catResult.terminationStatus.isSuccess)
        XCTAssertEqual(catResult.standardError, expected)
    }
}

// MARK: - PlatformOption Tests
@available(macOS 9999, *)
extension SubprocessUnixTests {
    // Run this test with sudo
    func testSubprocessPlatformOptionsUserID() async throws {
        guard getuid() == 0 else {
            throw XCTSkip("This test requires root privileges")
        }
        let expectedUserID = uid_t(Int.random(in: 1000 ... 2000))
        var platformOptions = PlatformOptions()
        platformOptions.userID = expectedUserID
        try await self.assertID(
            withArgument: "-u",
            platformOptions: platformOptions,
            isEqualTo: expectedUserID
        )
    }

    // Run this test with sudo
    func testSubprocessPlatformOptionsGroupID() async throws {
        guard getuid() == 0 else {
            throw XCTSkip("This test requires root privileges")
        }
        let expectedGroupID = gid_t(Int.random(in: 1000 ... 2000))
        var platformOptions = PlatformOptions()
        platformOptions.groupID = expectedGroupID
        try await self.assertID(
            withArgument: "-g",
            platformOptions: platformOptions,
            isEqualTo: expectedGroupID
        )
    }

    // Run this test with sudo
    func testSubprocssPlatformOptionsSuplimentaryGroups() async throws {
        guard getuid() == 0 else {
            throw XCTSkip("This test requires root privileges")
        }
        var expectedGroups: Set<gid_t> = Set()
        for _ in 0 ..< Int.random(in: 5 ... 10) {
            expectedGroups.insert(gid_t(Int.random(in: 1000 ... 2000)))
        }
        var platformOptions = PlatformOptions()
        platformOptions.supplementaryGroups = Array(expectedGroups)
        let idResult = try await Subprocess.run(
            .named("/usr/bin/swift"),
            arguments: [getgroupsSwift.string],
            platformOptions: platformOptions,
            output: .string
        )
        XCTAssertTrue(idResult.terminationStatus.isSuccess)
        let ids = try XCTUnwrap(
            idResult.standardOutput
        ).split(separator: ",")
            .map { gid_t($0.trimmingCharacters(in: .whitespacesAndNewlines))! }
        XCTAssertEqual(Set(ids), expectedGroups)
    }

    func testSubprocessPlatformOptionsProcessGroupID() async throws {
        guard getuid() == 0 else {
            throw XCTSkip("This test requires root privileges")
        }
        var platformOptions = PlatformOptions()
        // Sets the process group ID to 0, which creates a new session
        platformOptions.processGroupID = 0
        let psResult = try await Subprocess.run(
            .named("/bin/bash"),
            arguments: ["-c", "ps -o pid,pgid -p $$"],
            platformOptions: platformOptions,
            output: .string
        )
        XCTAssertTrue(psResult.terminationStatus.isSuccess)
        let resultValue = try XCTUnwrap(
            psResult.standardOutput
        ).split { $0.isWhitespace || $0.isNewline }
        XCTAssertEqual(resultValue.count, 4)
        XCTAssertEqual(resultValue[0], "PID")
        XCTAssertEqual(resultValue[1], "PGID")
        // PGID should == PID
        XCTAssertEqual(resultValue[2], resultValue[3])
    }

    func testSubprocessPlatformOptionsCreateSession() async throws {
        // platformOptions.createSession implies calls to setsid
        var platformOptions = PlatformOptions()
        platformOptions.createSession = true
        // Check the proces ID (pid), pross group ID (pgid), and
        // controling terminal's process group ID (tpgid)
        let psResult = try await Subprocess.run(
            .named("/bin/bash"),
            arguments: ["-c", "ps -o pid,pgid,tpgid -p $$"],
            platformOptions: platformOptions,
            output: .string
        )
        try assertNewSessionCreated(with: psResult)
    }

    func testTeardownSequence() async throws {
        let result = try await Subprocess.run(
            .named("/bin/bash"),
            arguments: [
                "-c",
                """
                set -e
                trap 'echo saw SIGQUIT;' SIGQUIT
                trap 'echo saw SIGTERM;' TERM
                trap 'echo saw SIGINT; exit 42;' INT
                while true; do sleep 1; done
                exit 2
                """,
            ]
        ) { subprocess in
            return try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await Task.sleep(for: .milliseconds(200))
                    // Send shut down signal
                    await subprocess.teardown(using: [
                        .sendSignal(.quit, allowedDurationToExit: .milliseconds(500)),
                        .sendSignal(.terminate, allowedDurationToExit: .milliseconds(500)),
                        .sendSignal(.interrupt, allowedDurationToExit: .milliseconds(1000))
                    ])
                }
                group.addTask {
                    var outputs: [String] = []
                    for try await bit in subprocess.standardOutput {
                        let bitString = String(data: bit, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if let bit = bitString {
                            if bit.contains("\n") {
                                outputs.append(contentsOf: bit.split(separator: "\n").map{ String($0) })
                            } else {
                                outputs.append(bit)
                            }
                        }
                    }
                    XCTAssert(outputs == ["saw SIGQUIT", "saw SIGTERM", "saw SIGINT"])
                }
                try await group.waitForAll()
            }
        }
        XCTAssertEqual(result.terminationStatus, .exited(42))
    }
}

// MARK: - Misc
@available(macOS 9999, *)
extension SubprocessUnixTests {
    func testRunDetached() async throws {
        let (readFd, writeFd) = try FileDescriptor.pipe()
        let pid = try runDetached(
            .at("/bin/bash"),
            arguments: ["-c", "echo $$"],
            output: writeFd
        )
        var status: Int32 = 0
        waitpid(pid.value, &status, 0)
        XCTAssertTrue(_was_process_exited(status) > 0)
        try writeFd.close()
        let data = try await readFd.readUntilEOF(upToLength: 10)
        let resultPID = try XCTUnwrap(
            String(data: Data(data), encoding: .utf8)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual("\(pid.value)", resultPID)
        try readFd.close()
    }

    func testTerminateProcess() async throws {
        let stuckResult = try await Subprocess.run(
            // This will intentionally hang
            .at("/bin/cat")
        ) { subprocess in
            // Make sure we can send signals to terminate the process
            try subprocess.send(signal: .terminate)
        }
        guard case .unhandledException(let exception) = stuckResult.terminationStatus else {
            XCTFail("Wrong termination status repored")
            return
        }
        XCTAssertEqual(exception, Signal.terminate.rawValue)
    }
}

// MARK: - Performance Tests
@available(macOS 9999, *)
extension SubprocessUnixTests {
    func testConcurrentRun() async throws {
        // Launch as many processes as we can
        // Figure out the max open file limit
        let limitResult = try await Subprocess.run(
            .at("/bin/bash"),
            arguments: ["-c", "ulimit -n"],
            output: .string
        )
        guard let limitString = limitResult
            .standardOutput?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let limit = Int(limitString) else {
            XCTFail("Failed to run  ulimit -n")
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
                        .at("/bin/bash"),
                        arguments: ["-sc", #"echo "$1" && echo "$1" >&2"#, "--", String(repeating: "X", count: byteCount)],
                        output: .data,
                        error: .data
                    )
                    guard r.terminationStatus.isSuccess else {
                        XCTFail("Unexpected exit \(r.terminationStatus) from \(r.processIdentifier)")
                        return
                    }
                    XCTAssert(r.standardOutput.count == byteCount + 1, "\(r.standardOutput)")
                    XCTAssert(r.standardError.count == byteCount + 1, "\(r.standardError)")
                }
                running += 1
                if running >= maxConcurrent / 4 {
                    try await group.next()
                }
            }
            try await group.waitForAll()
        }
    }

    func testCaptureLongStandardOutputAndError() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var running = 0
            for _ in 0 ..< 10 {
                group.addTask {
                    let r = try await Subprocess.run(
                        .at("/bin/bash"),
                        arguments: ["-sc", #"echo "$1" && echo "$1" >&2"#, "--", String(repeating: "X", count: 100_000)],
                        output: .data,
                        error: .data
                    )
                    XCTAssert(r.terminationStatus == .exited(0))
                    XCTAssert(r.standardOutput.count == 100_001, "Standard output actual \(r.standardOutput)")
                    XCTAssert(r.standardError.count == 100_001, "Standard error actual \(r.standardError)")
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

// MARK: - Utils
@available(macOS 9999, *)
extension SubprocessUnixTests {
    private func assertID(
        withArgument argument: String,
        platformOptions: PlatformOptions,
        isEqualTo expected: gid_t
    ) async throws {
        let idResult = try await Subprocess.run(
            .named("/usr/bin/id"),
            arguments: [argument],
            platformOptions: platformOptions,
            output: .string
        )
        XCTAssertTrue(idResult.terminationStatus.isSuccess)
        let id = try XCTUnwrap(idResult.standardOutput)
        XCTAssertEqual(
            id.trimmingCharacters(in: .whitespacesAndNewlines),
            "\(expected)"
        )
    }
}

@available(macOS 9999, *)
internal func assertNewSessionCreated<Output: OutputProtocol>(
    with result: CollectedResult<
        StringOutput,
        Output
    >
) throws {
    XCTAssertTrue(result.terminationStatus.isSuccess)
    let psValue = try XCTUnwrap(
        result.standardOutput
    ).split {
        return $0.isNewline || $0.isWhitespace
    }
    XCTAssertEqual(psValue.count, 6)
    // If setsid() has been called successfully, we shold observe:
    // - pid == pgid
    // - tpgid <= 0
    XCTAssertEqual(psValue[0], "PID")
    XCTAssertEqual(psValue[1], "PGID")
    XCTAssertEqual(psValue[2], "TPGID")
    let pid = try XCTUnwrap(Int(psValue[3]))
    let pgid = try XCTUnwrap(Int(psValue[4]))
    let tpgid = try XCTUnwrap(Int(psValue[5]))
    XCTAssertEqual(pid, pgid)
    XCTAssertTrue(tpgid <= 0)
}

extension FileDescriptor {
    internal func readUntilEOF(upToLength maxLength: Int) async throws -> Data {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            let dispatchIO = DispatchIO(
                type: .stream,
                fileDescriptor: self.rawValue,
                queue: .global()
            ) { error in
                if error != 0 {
                    continuation.resume(throwing: POSIXError(.init(rawValue: error) ?? .ENODEV))
                }
            }
            var buffer: Data = Data()
            dispatchIO.read(
                offset: 0,
                length: maxLength,
                queue: .global()
            ) { done, data, error in
                guard error == 0 else {
                    continuation.resume(throwing: POSIXError(.init(rawValue: error) ?? .ENODEV))
                    return
                }
                if let data = data {
                    buffer += Data(data)
                }
                if done {
                    dispatchIO.close()
                    continuation.resume(returning: buffer)
                }
            }
        }
    }
}

#endif // canImport(Darwin) || canImport(Glibc)

