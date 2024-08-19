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
            contentsOf: URL(filePath: prideAndPrejudice.string)
        )
        let text: FileDescriptor = try .open(
            prideAndPrejudice, .readOnly)
        let cat = try await Subprocess.run(
            .named("cat"),
            input: .readFrom(text, closeAfterProcessSpawned: true),
            output: .collect(limit: 1024 * 1024)
        )
        XCTAssertTrue(cat.terminationStatus.isSuccess)
        // Make sure we read all bytes
        XCTAssertEqual(cat.standardOutput, expected)
    }

    func testInputSequence() async throws {
        // Make sure we can read long text as Sequence
        let expected: Data = try Data(
            contentsOf: URL(filePath: prideAndPrejudice.string)
        )
        let catResult = try await Subprocess.run(
            .at("/bin/cat"),
            input: expected,
            output: .collect(limit: 1024 * 1024)
        )
        XCTAssertTrue(catResult.terminationStatus.isSuccess)
        XCTAssertEqual(catResult.standardOutput, expected)
    }

    func testInputAsyncSequence() async throws {
        // Maeks ure we can read long text as AsyncSequence
        let fd: FileDescriptor = try .open(prideAndPrejudice, .readOnly)
        let expected: Data = try Data(
            contentsOf: URL(filePath: prideAndPrejudice.string)
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
            output: .collect(limit: 1024 * 1024)
        )
        XCTAssertTrue(catResult.terminationStatus.isSuccess)
        XCTAssertEqual(catResult.standardOutput, expected)
    }

    func testInputSequenceCustomExecutionBody() async throws {
        let expected: Data = try Data(
            contentsOf: URL(filePath: prideAndPrejudice.string)
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
        let fd: FileDescriptor = try .open(prideAndPrejudice, .readOnly)
        let expected: Data = try Data(
            contentsOf: URL(filePath: prideAndPrejudice.string)
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
        let expected = self.randomString(length: 32)
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
        let expected = self.randomString(length: 32)
        let echoResult = try await Subprocess.run(
            .at("/bin/echo"),
            arguments: [expected],
            output: .collect(limit: 2)
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
        let expected = self.randomString(length: 32)
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
        let expected = self.randomString(length: 32)
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
        // Maeks ure we can read long text redirected to AsyncSequence
        let expected: Data = try Data(
            contentsOf: URL(filePath: prideAndPrejudice.string)
        )
        let catResult = try await Subprocess.run(
            .at("/bin/cat"),
            arguments: [prideAndPrejudice.string],
            output: .redirectToSequence
        ) { subprocess in
            let collected = try await Array(subprocess.standardOutput)
            return Data(collected)
        }
        XCTAssertTrue(catResult.terminationStatus.isSuccess)
        XCTAssertEqual(catResult.value, expected)
    }
}

// MARK: - Utils
extension SubprocessUnixTests {
    private func randomString(length: Int) -> String {
        let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<length).map{ _ in letters.randomElement()! })
    }
}

#endif // canImport(Darwin) || canImport(Glibc)
