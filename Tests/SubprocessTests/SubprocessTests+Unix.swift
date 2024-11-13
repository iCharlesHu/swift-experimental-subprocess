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

import _CShims
import XCTest
import FoundationEssentials
@testable import SwiftExperimentalSubprocess

import Dispatch
import SystemPackage

final class SubprocessUnixTests: XCTestCase { }

// MARK: - Executable test
extension SubprocessUnixTests {
    func testExecutableNamed() async throws {
        // Simple test to make sure we can find a common utility
        let message = "Hello, world!"
        let result = try await Subprocess.run(
            .named("echo"),
            arguments: [message],
            output: .collect
        )
        XCTAssertTrue(result.terminationStatus.isSuccess)
        XCTAssertEqual(
            String(data: result.standardOutput, encoding: .utf8)!
                .trimmingCharacters(in: .whitespacesAndNewlines),
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
        let result = try await Subprocess.run(.at("/bin/pwd"))
        XCTAssertTrue(result.terminationStatus.isSuccess)
        XCTAssertEqual(
            String(data: result.standardOutput, encoding: .utf8)!
                .trimmingCharacters(in: .whitespacesAndNewlines),
            expected
        )
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
extension SubprocessUnixTests {
    func testArgunementsArrayLitereal() async throws {
        let result = try await Subprocess.run(
            .at("/bin/bash"),
            arguments: ["-c", "echo Hello World!"]
        )
        XCTAssertTrue(result.terminationStatus.isSuccess)
        XCTAssertEqual(
            String(data: result.standardOutput, encoding: .utf8)!
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "Hello World!"
        )
    }

    func testArgumentsOverride() async throws {
        let result = try await Subprocess.run(
            .at("/bin/bash"),
            arguments: .init(
                executablePathOverride: "apple",
                remainingValues: ["-c", "echo $0"]
            )
        )
        XCTAssertTrue(result.terminationStatus.isSuccess)
        XCTAssertEqual(
            String(data: result.standardOutput, encoding: .utf8)!
                .trimmingCharacters(in: .whitespacesAndNewlines),
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
            )
        )
        XCTAssertTrue(result.terminationStatus.isSuccess)
        XCTAssertEqual(
            String(data: result.standardOutput, encoding: .utf8)!
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "Data Content"
        )
    }
}

// MARK: - Environment Tests
extension SubprocessUnixTests {
    func testEnvironmentInherit() async throws {
        let result = try await Subprocess.run(
            .at("/bin/bash"),
            arguments: ["-c", "printenv PATH"],
            environment: .inherit
        )
        XCTAssertTrue(result.terminationStatus.isSuccess)
        // As a sanity check, make sure there's `/bin` in PATH
        // since we inherited the environment variables
        let pathValue = try XCTUnwrap(String(data: result.standardOutput, encoding: .utf8))
        XCTAssertTrue(pathValue.contains("/bin"))
    }

    func testEnvironmentInheritOverride() async throws {
        let result = try await Subprocess.run(
            .at("/bin/bash"),
            arguments: ["-c", "printenv HOME"],
            environment: .inherit.updating([
                "HOME": "/my/new/home"
            ])
        )
        XCTAssertTrue(result.terminationStatus.isSuccess)
        XCTAssertEqual(
            String(data: result.standardOutput, encoding: .utf8)!
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "/my/new/home"
        )
    }

    func testEnvironmentCustom() async throws {
        let currentDir = FileManager.default.currentDirectoryPath
        let result = try await Subprocess.run(
            .at("/usr/bin/printenv"),
            environment: .custom([
                "PATH": "/bin:/usr/bin",
            ])
        )
        XCTAssertTrue(result.terminationStatus.isSuccess)
        // There shouldn't be any other environment variables besides
        // `PATH` that we set
        XCTAssertEqual(
            String(data: result.standardOutput, encoding: .utf8)!
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "PATH=/bin:/usr/bin"
        )
    }
}

// MARK: - Working Directory Tests
extension SubprocessUnixTests {
    func testWorkingDirectoryDefaultValue() async throws {
        // By default we should use the working directory of the parent process
        let workingDirectory = FileManager.default.currentDirectoryPath
        let result = try await Subprocess.run(
            .at("/bin/pwd"),
            workingDirectory: nil
        )
        XCTAssertTrue(result.terminationStatus.isSuccess)
        // There shouldn't be any other environment variables besides
        // `PATH` that we set
        XCTAssertEqual(
            String(data: result.standardOutput, encoding: .utf8)!
                .trimmingCharacters(in: .whitespacesAndNewlines),
            workingDirectory
        )
    }

    func testWorkingDirectoryCustomValue() async throws {
        let workingDirectory = FilePath(
            FileManager.default.temporaryDirectory.path()
        )
        let result = try await Subprocess.run(
            .at("/bin/pwd"),
            workingDirectory: workingDirectory
        )
        XCTAssertTrue(result.terminationStatus.isSuccess)
        // There shouldn't be any other environment variables besides
        // `PATH` that we set
        let resultPath = String(data: result.standardOutput, encoding: .utf8)!
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
extension SubprocessUnixTests {
    func testInputNoInput() async throws {
        let catResult = try await Subprocess.run(
            .at("/bin/cat"),
            input: .noInput
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
            input: .readFrom(text, closeAfterProcessSpawned: true),
            output: .collect(upTo: 2048 * 1024)
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
            input: expected,
            output: .collect(upTo: 2048 * 1024)
        )
        XCTAssertTrue(catResult.terminationStatus.isSuccess)
        XCTAssertEqual(catResult.standardOutput, expected)
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
        let stream: AsyncStream<UInt8> = AsyncStream { continuation in
            channel.read(offset: 0, length: .max, queue: .main) { done, data, error in
                if done {
                    continuation.finish()
                }
                guard let data = data else {
                    return
                }
                for byte in Array(data) {
                    continuation.yield(byte)
                }
            }
        }
        let catResult = try await Subprocess.run(
            .at("/bin/cat"),
            input: stream,
            output: .collect(upTo: 2048 * 1024)
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
            input: expected,
            output: .redirectToSequence
        ) { execution in
            return try await Array(execution.standardOutput)
        }
        XCTAssertTrue(result.terminationStatus.isSuccess)
        XCTAssertEqual(result.value, [UInt8](expected))
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
        let stream: AsyncStream<UInt8> = AsyncStream { continuation in
            channel.read(offset: 0, length: .max, queue: .main) { done, data, error in
                if done {
                    continuation.finish()
                }
                guard let data = data else {
                    return
                }
                for byte in Array(data) {
                    continuation.yield(byte)
                }
            }
        }
        let result = try await Subprocess.run(
            .at("/bin/cat"),
            input: stream
        ) { execution in
            return try await Array(execution.standardOutput)
        }
        XCTAssertTrue(result.terminationStatus.isSuccess)
        XCTAssertEqual(result.value, [UInt8](expected))
    }
}

// MARK: - Output Tests
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
            output: .collect
        )
        XCTAssertTrue(echoResult.terminationStatus.isSuccess)
        let output = try XCTUnwrap(
            String(data: echoResult.standardOutput, encoding: .utf8)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(output, expected)
    }

    func testCollectedOutputWithLimit() async throws {
        let expected = randomString(length: 32)
        let echoResult = try await Subprocess.run(
            .at("/bin/echo"),
            arguments: [expected],
            output: .collect(upTo: 2)
        )
        XCTAssertTrue(echoResult.terminationStatus.isSuccess)
        let output = try XCTUnwrap(
            String(data: echoResult.standardOutput, encoding: .utf8)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let targetRange = expected.startIndex ..< expected.index(expected.startIndex, offsetBy: 4)
        XCTAssertEqual(String(expected[targetRange]), output)
    }

    func testCollectedOutputFileDesriptor() async throws {
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
                closeAfterProcessSpawned: false
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
                closeAfterProcessSpawned: true
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
                closeAfterProcessSpawned: false
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
                closeAfterProcessSpawned: true
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

    func testRedirectedOutputRedirectToSequence() async throws {
        // Make ure we can read long text redirected to AsyncSequence
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let catResult = try await Subprocess.run(
            .at("/bin/cat"),
            arguments: [theMysteriousIsland.string],
            output: .redirectToSequence
        ) { subprocess in
            let collected = try await Array(subprocess.standardOutput)
            return Data(collected)
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
            error: .collect(upTo: 2048 * 1024)
        )
        XCTAssertTrue(catResult.terminationStatus.isSuccess)
        XCTAssertEqual(catResult.standardError, expected)
    }
}

// MARK: - PlatformOption Tests
extension SubprocessUnixTests {
    // Run this test with sudo
    func testSubprocessPlatformOptionsUserID() async throws {
        guard getuid() == 0 else {
            throw XCTSkip("This test requires root privileges")
        }
        let expectedUserID = uid_t(Int.random(in: 1000 ... 2000))
        var platformOptions = Subprocess.PlatformOptions()
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
        var platformOptions = Subprocess.PlatformOptions()
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
        var platformOptions = Subprocess.PlatformOptions()
        platformOptions.supplementaryGroups = Array(expectedGroups)
        let idResult = try await Subprocess.run(
            .named("/usr/bin/swift"),
            arguments: [getgroupsSwift.string],
            platformOptions: platformOptions
        )
        XCTAssertTrue(idResult.terminationStatus.isSuccess)
        let ids = try XCTUnwrap(
            String(data: idResult.standardOutput, encoding: .utf8)
        ).split(separator: ",")
            .map { gid_t($0.trimmingCharacters(in: .whitespacesAndNewlines))! }
        XCTAssertEqual(Set(ids), expectedGroups)
    }

    func testSubprocessPlatformOptionsProcessGroupID() async throws {
        guard getuid() == 0 else {
            throw XCTSkip("This test requires root privileges")
        }
        let expectedPGID = Int.random(in: 1000 ... Int(pid_t.max))
        var platformOptions = Subprocess.PlatformOptions()
        // Sets the process group ID to 0, which creates a new session
        platformOptions.processGroupID = 0
        let psResult = try await Subprocess.run(
            .named("/bin/bash"),
            arguments: ["-c", "ps -o pid,pgid -p $$"],
            platformOptions: platformOptions
        )
        XCTAssertTrue(psResult.terminationStatus.isSuccess)
        let resultValue = try XCTUnwrap(
            String(data: psResult.standardOutput, encoding: .utf8)
        ).split { $0.isWhitespace || $0.isNewline }
        XCTAssertEqual(resultValue.count, 4)
        XCTAssertEqual(resultValue[0], "PID")
        XCTAssertEqual(resultValue[1], "PGID")
        // PGID should == PID
        XCTAssertEqual(resultValue[2], resultValue[3])
    }

    func testSubprocessPlatformOptionsCreateSession() async throws {
        // platformOptions.createSession implies calls to setsid
        var platformOptions = Subprocess.PlatformOptions()
        platformOptions.createSession = true
        // Check the proces ID (pid), pross group ID (pgid), and
        // controling terminal's process group ID (tpgid)
        let psResult = try await Subprocess.run(
            .named("/bin/bash"),
            arguments: ["-c", "ps -o pid,pgid,tpgid -p $$"],
            platformOptions: platformOptions
        )
        try assertNewSessionCreated(with: psResult)
    }
}

// MARK: - Misc
extension SubprocessUnixTests {
    func testRunDetached() async throws {
        let (readFd, writeFd) = try FileDescriptor.pipe()
        let pid = try Subprocess.runDetached(
            .at("/bin/bash"),
            arguments: ["-c", "echo $$"],
            output: writeFd
        )
        var status: Int32 = 0
        waitpid(pid.value, &status, 0)
        XCTAssertTrue(_was_process_exited(status) > 0)
        let data = try await readFd.read(upToLength: 1024)
        let resultPID = try XCTUnwrap(
            String(data: Data(data), encoding: .utf8)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual("\(pid.value)", resultPID)
        try readFd.close()
        try writeFd.close()
    }

    func testTerminateProcess() async throws {
        let stuckResult = try await Subprocess.run(
            // This will intentionally hang
            .at("/bin/cat")
        ) { subprocess in
            // Make sure we can send signals to terminate the process
            try subprocess.send(.terminate, toProcessGroup: false)
        }
        guard case .unhandledException(let exception) = stuckResult.terminationStatus else {
            XCTFail("Wrong termination status repored")
            return
        }
        XCTAssertEqual(exception, Subprocess.Signal.terminate.rawValue)
    }
}

// MARK: - Utils
extension SubprocessUnixTests {
    private func assertID(
        withArgument argument: String,
        platformOptions: Subprocess.PlatformOptions,
        isEqualTo expected: gid_t
    ) async throws {
        let idResult = try await Subprocess.run(
            .named("/usr/bin/id"),
            arguments: [argument],
            platformOptions: platformOptions
        )
        XCTAssertTrue(idResult.terminationStatus.isSuccess)
        let id = try XCTUnwrap(String(data: idResult.standardOutput, encoding: .utf8))
        XCTAssertEqual(
            id.trimmingCharacters(in: .whitespacesAndNewlines),
            "\(expected)"
        )
    }
}

internal func assertNewSessionCreated(with result: Subprocess.CollectedResult) throws {
    XCTAssertTrue(result.terminationStatus.isSuccess)
    let psValue = try XCTUnwrap(
        String(data: result.standardOutput, encoding: .utf8)
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

#endif // canImport(Darwin) || canImport(Glibc)

