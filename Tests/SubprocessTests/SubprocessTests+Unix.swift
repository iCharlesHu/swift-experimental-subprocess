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

#if canImport(Glibc)
import Glibc
#elseif canImport(Bionic)
import Bionic
#elseif canImport(Musl)
import Musl
#endif


import _CShims
import Testing
@testable import Subprocess

import TestResources

import Dispatch
#if canImport(System)
import System
#else
@preconcurrency import SystemPackage
#endif

@Suite(.serialized)
struct SubprocessUnixTests { }

// MARK: - Executable test
extension SubprocessUnixTests {
    @available(macOS 9999, *)
    @Test func testExecutableNamed() async throws {
        // Simple test to make sure we can find a common utility
        let message = "Hello, world!"
        let result = try await Subprocess.run(
            .name("echo"),
            arguments: [message]
        )
        #expect(result.terminationStatus.isSuccess)
        // rdar://138670128
        let output = result.standardOutput?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(output == message)
    }

    @available(macOS 9999, *)
    @Test func testExecutableNamedCannotResolve() async {
        do {
            _ = try await Subprocess.run(.name("do-not-exist"))
            Issue.record("Expected to throw")
        } catch {
            guard let subprocessError: SubprocessError = error as? SubprocessError else {
                Issue.record("Expected SubprocessError, got \(error)")
                return
            }
            #expect(subprocessError.code == .init(.executableNotFound("do-not-exist")))
        }
    }

    @available(macOS 9999, *)
    @Test func testExecutableAtPath() async throws {
        let expected = FileManager.default.currentDirectoryPath
        let result = try await Subprocess.run(.path("/bin/pwd"), output: .string())
        #expect(result.terminationStatus.isSuccess)
        // rdar://138670128
        let maybePath = result.standardOutput?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let path = try #require(maybePath)
        #expect(directory(path, isSameAs: expected))
    }

    @available(macOS 9999, *)
    @Test func testExecutableAtPathCannotResolve() async {
        do {
            // Since we are using the path directly,
            // we expect the error to be thrown by the underlying
            // posix_spawn
            _ = try await Subprocess.run(.path("/usr/bin/do-not-exist"))
            Issue.record("Expected to throw POSIXError")
        } catch {
            guard let subprocessError: SubprocessError = error as? SubprocessError else {
                Issue.record("Expected POSIXError, got \(error)")
                return
            }
            #expect(subprocessError.code == .init(.spawnFailed))
        }
    }
}

// MARK: - Arguments Tests
extension SubprocessUnixTests {
    @available(macOS 9999, *)
    @Test func testArgunementsArrayLitereal() async throws {
        let result = try await Subprocess.run(
            .path("/bin/bash"),
            arguments: ["-c", "echo Hello World!"],
            output: .string()
        )
        #expect(result.terminationStatus.isSuccess)
        // rdar://138670128
        let output = result.standardOutput?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(
            output ==
            "Hello World!"
        )
    }

    @available(macOS 9999, *)
    @Test func testArgumentsOverride() async throws {
        let result = try await Subprocess.run(
            .path("/bin/bash"),
            arguments: .init(
                executablePathOverride: "apple",
                remainingValues: ["-c", "echo $0"]
            ),
            output: .string()
        )
        #expect(result.terminationStatus.isSuccess)
        // rdar://138670128
        let output = result.standardOutput?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(
            output ==
            "apple"
        )
    }

    @available(macOS 9999, *)
    @Test func testArgumemtsFromArray() async throws {
        let arguments: [UInt8] = Array("Data Content\0".utf8)
        let result = try await Subprocess.run(
            .path("/bin/echo"),
            arguments: .init(
                executablePathOverride: nil,
                remainingValues: [arguments]
            ),
            output: .string()
        )
        #expect(result.terminationStatus.isSuccess)
        // rdar://138670128
        let output = result.standardOutput?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(
            output ==
            "Data Content"
        )
    }
}

// MARK: - Environment Tests
extension SubprocessUnixTests {
    @available(macOS 9999, *)
    @Test func testEnvironmentInherit() async throws {
        let result = try await Subprocess.run(
            .path("/bin/bash"),
            arguments: ["-c", "printenv PATH"],
            environment: .inherit,
            output: .string()
        )
        #expect(result.terminationStatus.isSuccess)
        // As a sanity check, make sure there's `/bin` in PATH
        // since we inherited the environment variables
        // rdar://138670128
        let maybeOutput = result.standardOutput
        let pathValue = try #require(maybeOutput)
        #expect(pathValue.contains("/bin"))
    }

    @available(macOS 9999, *)
    @Test func testEnvironmentInheritOverride() async throws {
        let result = try await Subprocess.run(
            .path("/bin/bash"),
            arguments: ["-c", "printenv HOME"],
            environment: .inherit.updating([
                "HOME": "/my/new/home"
            ]),
            output: .string()
        )
        #expect(result.terminationStatus.isSuccess)
        // rdar://138670128
        let output = result.standardOutput?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(
            output ==
            "/my/new/home"
        )
    }

    @available(macOS 9999, *)
    @Test func testEnvironmentCustom() async throws {
        let result = try await Subprocess.run(
            .path("/usr/bin/printenv"),
            environment: .custom([
                "PATH": "/bin:/usr/bin",
            ]),
            output: .string()
        )
        #expect(result.terminationStatus.isSuccess)
        // There shouldn't be any other environment variables besides
        // `PATH` that we set
        // rdar://138670128
        let output = result.standardOutput?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(
            output ==
            "PATH=/bin:/usr/bin"
        )
    }
}

// MARK: - Working Directory Tests
extension SubprocessUnixTests {
    @available(macOS 9999, *)
    @Test func testWorkingDirectoryDefaultValue() async throws {
        // By default we should use the working directory of the parent process
        let workingDirectory = FileManager.default.currentDirectoryPath
        let result = try await Subprocess.run(
            .path("/bin/pwd"),
            workingDirectory: nil,
            output: .string()
        )
        #expect(result.terminationStatus.isSuccess)
        // There shouldn't be any other environment variables besides
        // `PATH` that we set
        // rdar://138670128
        let output = result.standardOutput?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let path = try #require(output)
        #expect(directory(path, isSameAs: workingDirectory))
    }

    @available(macOS 9999, *)
    @Test func testWorkingDirectoryCustomValue() async throws {
        let workingDirectory = FilePath(
            FileManager.default.temporaryDirectory.path()
        )
        let result = try await Subprocess.run(
            .path("/bin/pwd"),
            workingDirectory: workingDirectory,
            output: .string()
        )
        #expect(result.terminationStatus.isSuccess)
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
        #expect(
            FilePath(resultPath) ==
            expected
        )
#else
        #expect(
            FilePath(resultPath) ==
            workingDirectory
        )
#endif
    }
}

// MARK: - Input Tests
extension SubprocessUnixTests {
    @available(macOS 9999, *)
    @Test func testInputNoInput() async throws {
        let catResult = try await Subprocess.run(
            .path("/bin/cat"),
            input: .none,
            output: .string()
        )
        #expect(catResult.terminationStatus.isSuccess)
        // We should have read exactly 0 bytes
        #expect(catResult.standardOutput == "")
    }
}

// MARK: - Output Tests
extension SubprocessUnixTests {
#if false // This test needs "death test" support
    @Test func testOutputDiscarded() async throws {
        let echoResult = try await Subprocess.run(
            .path("/bin/echo"),
            arguments: ["Some garbage text"],
            output: .discard
        )
        #expect(echoResult.terminationStatus.isSuccess)
        _ = echoResult.standardOutput // this line shold fatalError
    }
#endif

    @available(macOS 9999, *)
    @Test func testCollectedOutput() async throws {
        let expected = randomString(length: 32)
        let echoResult = try await Subprocess.run(
            .path("/bin/echo"),
            arguments: [expected],
            output: .string()
        )
        #expect(echoResult.terminationStatus.isSuccess)
        let output = try #require(
            echoResult.standardOutput
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(output == expected)
    }

    @available(macOS 9999, *)
    @Test func testCollectedOutputWithLimit() async throws {
        let limit = 4
        let expected = randomString(length: 32)
        let echoResult = try await Subprocess.run(
            .path("/bin/echo"),
            arguments: [expected],
            output: .string(limit: limit, encoding: UTF8.self)
        )
        #expect(echoResult.terminationStatus.isSuccess)
        let output = try #require(
            echoResult.standardOutput
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let targetRange = expected.startIndex ..< expected.index(expected.startIndex, offsetBy: limit)
        #expect(String(expected[targetRange]) == output)
    }

    @available(macOS 9999, *)
    @Test func testCollectedOutputFileDesriptor() async throws {
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
            .path("/bin/echo"),
            arguments: [expected],
            output: .fileDescriptor(
                outputFile,
                closeAfterSpawningProcess: false
            )
        )
        #expect(echoResult.terminationStatus.isSuccess)
        try outputFile.close()
        let outputData: Data = try Data(
            contentsOf: URL(filePath: outputFilePath.string)
        )
        let output = try #require(
            String(data: outputData, encoding: .utf8)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(echoResult.terminationStatus.isSuccess)
        #expect(output == expected)
    }

    @available(macOS 9999, *)
    @Test func testCollectedOutputFileDescriptorAutoClose() async throws {
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
            .path("/bin/echo"),
            arguments: ["Hello world"],
            output: .fileDescriptor(
                outputFile,
                closeAfterSpawningProcess: true
            )
        )
        #expect(echoResult.terminationStatus.isSuccess)
        // Make sure the file descriptor is already closed
        do {
            try outputFile.close()
            Issue.record("Output file descriptor should be closed automatically")
        } catch {
            guard let typedError = error as? Errno else {
                Issue.record("Wrong type of error thrown")
                return
            }
            #expect(typedError == .badFileDescriptor)
        }
    }

    @available(macOS 9999, *)
    @Test func testRedirectedOutputRedirectToSequence() async throws {
        // Make ure we can read long text redirected to AsyncSequence
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let catResult = try await Subprocess.run(
            .path("/bin/cat"),
            arguments: [theMysteriousIsland.string],
            output: .sequence,
            error: .discarded
        ) { subprocess in
            var buffer = Data()
            for try await chunk in subprocess.standardOutput {
                buffer += chunk
            }
            return buffer
        }
        #expect(catResult.terminationStatus.isSuccess)
        #expect(catResult.value == expected)
    }
}

// MARK: - PlatformOption Tests
extension SubprocessUnixTests {
    // Run this test with sudo
    @available(macOS 9999, *)

    @Test(
        .enabled(
            if: getgid() == 0,
            "This test requires root privileges"
        )
    )
    func testSubprocessPlatformOptionsUserID() async throws {
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
    @available(macOS 9999, *)
    @Test(
        .enabled(
            if: getgid() == 0,
            "This test requires root privileges"
        )
    )
    func testSubprocessPlatformOptionsGroupID() async throws {
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
    @available(macOS 9999, *)
    @Test(
        .enabled(
            if: getgid() == 0,
            "This test requires root privileges"
        )
    )
    func testSubprocssPlatformOptionsSuplimentaryGroups() async throws {
        var expectedGroups: Set<gid_t> = Set()
        for _ in 0 ..< Int.random(in: 5 ... 10) {
            expectedGroups.insert(gid_t(Int.random(in: 1000 ... 2000)))
        }
        var platformOptions = PlatformOptions()
        platformOptions.supplementaryGroups = Array(expectedGroups)
        let idResult = try await Subprocess.run(
            .name("/usr/bin/swift"),
            arguments: [getgroupsSwift.string],
            platformOptions: platformOptions,
            output: .string()
        )
        #expect(idResult.terminationStatus.isSuccess)
        let ids = try #require(
            idResult.standardOutput
        ).split(separator: ",")
            .map { gid_t($0.trimmingCharacters(in: .whitespacesAndNewlines))! }
        #expect(Set(ids) == expectedGroups)
    }

    @available(macOS 9999, *)
    @Test(
        .enabled(
            if: getgid() == 0,
            "This test requires root privileges"
        )
    )
    func testSubprocessPlatformOptionsProcessGroupID() async throws {
        var platformOptions = PlatformOptions()
        // Sets the process group ID to 0, which creates a new session
        platformOptions.processGroupID = 0
        let psResult = try await Subprocess.run(
            .name("/bin/bash"),
            arguments: ["-c", "ps -o pid,pgid -p $$"],
            platformOptions: platformOptions,
            output: .string()
        )
        #expect(psResult.terminationStatus.isSuccess)
        let resultValue = try #require(
            psResult.standardOutput
        ).split { $0.isWhitespace || $0.isNewline }
        #expect(resultValue.count == 4)
        #expect(resultValue[0] == "PID")
        #expect(resultValue[1] == "PGID")
        // PGID should == PID
        #expect(resultValue[2] == resultValue[3])
    }

    @available(macOS 9999, *)
    @Test func testSubprocessPlatformOptionsCreateSession() async throws {
        // platformOptions.createSession implies calls to setsid
        var platformOptions = PlatformOptions()
        platformOptions.createSession = true
        // Check the proces ID (pid), pross group ID (pgid), and
        // controling terminal's process group ID (tpgid)
        let psResult = try await Subprocess.run(
            .name("/bin/bash"),
            arguments: ["-c", "ps -o pid,pgid,tpgid -p $$"],
            platformOptions: platformOptions,
            output: .string()
        )
        try assertNewSessionCreated(with: psResult)
    }

    @Test func testTeardownSequence() async throws {
        let result = try await Subprocess.run(
            .name("/bin/bash"),
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
            ],
            output: .sequence,
            error: .discarded
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
                        let bitString = String(decoding: bit, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if bitString.contains("\n") {
                            outputs.append(contentsOf: bitString.split(separator: "\n").map{ String($0) })
                        } else {
                            outputs.append(bitString)
                        }
                    }
                    #expect(outputs == ["saw SIGQUIT", "saw SIGTERM", "saw SIGINT"])
                }
                try await group.waitForAll()
            }
        }
        #expect(result.terminationStatus == .exited(42))
    }
}

// MARK: - Misc
extension SubprocessUnixTests {
    @available(macOS 9999, *)
    @Test func testRunDetached() async throws {
        let (readFd, writeFd) = try FileDescriptor.pipe()
        let pid = try runDetached(
            .path("/bin/bash"),
            arguments: ["-c", "echo $$"],
            output: writeFd
        )
        var status: Int32 = 0
        waitpid(pid.value, &status, 0)
        #expect(_was_process_exited(status) > 0)
        try writeFd.close()
        let data = try await readFd.readUntilEOF(upToLength: 10)
        let resultPID = try #require(
            String(data: Data(data), encoding: .utf8)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect("\(pid.value)" == resultPID)
        try readFd.close()
    }

    @Test func testTerminateProcess() async throws {
        let stuckResult = try await Subprocess.run(
            // This will intentionally hang
            .path("/bin/cat"),
            output: .discarded,
            error: .discarded
        ) { subprocess in
            // Make sure we can send signals to terminate the process
            try subprocess.send(signal: .terminate)
        }
        guard case .unhandledException(let exception) = stuckResult.terminationStatus else {
            Issue.record("Wrong termination status repored: \(stuckResult.terminationStatus)")
            return
        }
        #expect(exception == Signal.terminate.rawValue)
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
            .name("/usr/bin/id"),
            arguments: [argument],
            platformOptions: platformOptions,
            output: .string()
        )
        #expect(idResult.terminationStatus.isSuccess)
        let id = try #require(idResult.standardOutput)
        #expect(
            id.trimmingCharacters(in: .whitespacesAndNewlines) ==
            "\(expected)"
        )
    }
}

@available(macOS 9999, *)
internal func assertNewSessionCreated<Output: OutputProtocol>(
    with result: CollectedResult<
        StringOutput<UTF8>,
        Output
    >
) throws {
    #expect(result.terminationStatus.isSuccess)
    let psValue = try #require(
        result.standardOutput
    ).split {
        return $0.isNewline || $0.isWhitespace
    }
    #expect(psValue.count == 6)
    // If setsid() has been called successfully, we shold observe:
    // - pid == pgid
    // - tpgid <= 0
    #expect(psValue[0] == "PID")
    #expect(psValue[1] == "PGID")
    #expect(psValue[2] == "TPGID")
    let pid = try #require(Int(psValue[3]))
    let pgid = try #require(Int(psValue[4]))
    let tpgid = try #require(Int(psValue[5]))
    #expect(pid == pgid)
    #expect(tpgid <= 0)
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

