//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
//
//===---------------------------------------------------------------------s-===//

#if canImport(WinSDK)

import WinSDK
import XCTest
import SystemPackage
@testable import SwiftExperimentalSubprocess

final class SubprocessWindowsTests: XCTestCase {
    private let cmdExe: Subprocess.Executable = .at("C:\\Windows\\System32\\cmd.exe")
}

// MARK: - Executable Tests
extension SubprocessWindowsTests {
    func testExecutableNamed() async throws {
        // Simple test to make sure we can run a common utility
        let message = "Hello, world from Swift!"

        let result = try await Subprocess.run(
            .named("cmd.exe"),
            arguments: ["/c", "echo", message],
            output: .collectString(),
            error: .discard
        )

        XCTAssertTrue(result.terminationStatus.isSuccess)
        XCTAssertEqual(
            result.standardOutput?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "\"\(message)\""
        )
    }

    func testExecutableNamedCannotResolve() async throws {
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
        let result = try await Subprocess.run(
            self.cmdExe,
            arguments: ["/c", "cd"],
            output: .collectString()
        )
        XCTAssertTrue(result.terminationStatus.isSuccess)
        XCTAssertEqual(
            result.standardOutput?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            expected
        )
    }

    func testExecutableAtPathCannotResolve() async {
        do {
            // Since we are using the path directly,
            // we expect the error to be thrown by the underlying
            // CreateProcssW
            _ = try await Subprocess.run(.at("X:\\do-not-exist"))
            XCTFail("Expected to throw POSIXError")
        } catch {
            guard let cocoaError: CocoaError = error as? CocoaError,
                  let underlying: Win32Error = cocoaError.underlying as? Win32Error else {
                XCTFail("Expected CocoaError, got \(error)")
                return
            }
            XCTAssertEqual(underlying.code, DWORD(ERROR_FILE_NOT_FOUND))
        }
    }
}

// MARK: - Argument Tests
extension SubprocessWindowsTests {
    func testArgumentsFromArray() async throws {
        let message = "Hello, World!"
        let args: [String] = [
            "/c",
            "echo",
            message
        ]
        let result = try await Subprocess.run(
            self.cmdExe,
            arguments: .init(args),
            output: .collectString()
        )
        XCTAssertTrue(result.terminationStatus.isSuccess)
        XCTAssertEqual(
            result.standardOutput?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "\"\(message)\""
        )
    }
}

// MARK: - Environment Tests
extension SubprocessWindowsTests {
    func testEnvironmentInherit() async throws {
        let result = try await Subprocess.run(
            self.cmdExe,
            arguments: ["/c", "echo %Path%"],
            environment: .inherit,
            output: .collectString()
        )
        XCTAssertTrue(result.terminationStatus.isSuccess)
        // As a sanity check, make sure there's
        // `C:\Windows\system32` in PATH
        // since we inherited the environment variables
        let pathValue = try XCTUnwrap(result.standardOutput)
        XCTAssertTrue(pathValue.contains("C:\\Windows\\system32"))
    }

    func testEnvironmentInheritOverride() async throws {
        let result = try await Subprocess.run(
            self.cmdExe,
            arguments: ["/c", "echo %HOMEPATH%"],
            environment: .inherit.updating([
                "HOMEPATH": "/my/new/home",
            ]),
            output: .collectString()
        )
        XCTAssertTrue(result.terminationStatus.isSuccess)
        XCTAssertEqual(
            result.standardOutput?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "/my/new/home"
        )
    }

    func testEnvironmentCustom() async throws {
        // By default Windows environment shold have `SystemRoot`
        guard ProcessInfo.processInfo.environment["SystemRoot"] != nil else {
            throw XCTSkip("SystemRoot environment variable not set")
        }
        let result = try await Subprocess.run(
            self.cmdExe,
            arguments: [
                "/c", "set"
            ],
            environment: .custom([
                "Path": "C:\\Windows\\system32;C:\\Windows",
                "ComSpec": "C:\\Windows\\System32\\cmd.exe"
            ]),
            output: .collectString()
        )
        XCTAssertTrue(result.terminationStatus.isSuccess)
        // Make sure the newly launched process does
        // NOT have `SystemRoot` in environment
        let output = result.standardOutput!
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(!output.contains("SystemRoot"))
    }
}

// MARK: - Working Directory Tests
extension SubprocessWindowsTests {
    func testWorkingDirectoryDefaultValue() async throws {
        // By default we should use the working directory of the parent process
        let workingDirectory = FileManager.default.currentDirectoryPath
        let result = try await Subprocess.run(
            self.cmdExe,
            arguments: ["/c", "cd"],
            workingDirectory: nil,
            output: .collectString()
        )
        XCTAssertTrue(result.terminationStatus.isSuccess)
        // There shouldn't be any other environment variables besides
        // `PATH` that we set
        XCTAssertEqual(
            result.standardOutput?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            workingDirectory
        )
    }

    func testWorkingDirectoryCustomValue() async throws {
        let workingDirectory = FilePath(
            FileManager.default.temporaryDirectory._fileSystemPath
        )
        let result = try await Subprocess.run(
            self.cmdExe,
            arguments: ["/c", "cd"],
            workingDirectory: workingDirectory,
            output: .collectString()
        )
        XCTAssertTrue(result.terminationStatus.isSuccess)
        // There shouldn't be any other environment variables besides
        // `PATH` that we set
        let resultPath = result.standardOutput!
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            FilePath(resultPath),
            workingDirectory
        )
    }
}

// MARK: - Input Tests
extension SubprocessWindowsTests {
    func testInputNoInput() async throws {
        let catResult = try await Subprocess.run(
            self.cmdExe,
            arguments: ["/c", "more"],
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
            theMysteriousIsland, .readOnly
        )

        let catResult = try await Subprocess.run(
            self.cmdExe,
            arguments: [
                "/c",
                "findstr x*"
            ],
            input: .readFrom(text, closeAfterSpawningProcess: true),
            output: .collect(upTo: 2048 * 1024)
        )

        XCTAssertTrue(catResult.terminationStatus.isSuccess)
        // Make sure we read all bytes
        XCTAssertEqual(
            catResult.standardOutput,
            expected
        )
    }

    func testInputSequence() async throws {
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
            input: expected,
            output: .collect(upTo: 2048 * 1024),
            error: .discard
        )
        XCTAssertTrue(catResult.terminationStatus.isSuccess)
        // Make sure we read all bytes
        XCTAssertEqual(
            catResult.standardOutput,
            expected
        )
    }

    func testInputAsyncSequence() async throws {
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
            input: stream,
            output: .collect(upTo: 2048 * 1024)
        )
        XCTAssertTrue(catResult.terminationStatus.isSuccess)
        XCTAssertEqual(
            catResult.standardOutput,
            expected
        )
    }

    func testInputSequenceCustomExecutionBody() async throws {
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let result = try await Subprocess.run(
            self.cmdExe,
            arguments: ["/c", "findstr x*"],
            input: expected,
            output: .redirectToSequence
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
            input: stream
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
extension SubprocessWindowsTests {
    func testCollectedOutput() async throws {
        let expected = randomString(length: 32)
        let echoResult = try await Subprocess.run(
            self.cmdExe,
            arguments: ["/c", "echo \(expected)"],
            output: .collectString()
        )
        XCTAssertTrue(echoResult.terminationStatus.isSuccess)
        let output = try XCTUnwrap(
            echoResult.standardOutput
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(output, expected)
    }

    func testCollectedOutputWithLimit() async throws {
        let limit = 2
        let expected = randomString(length: 32)
        let echoResult = try await Subprocess.run(
            self.cmdExe,
            arguments: ["/c", "echo \(expected)"],
            output: .collectString(upTo: limit)
        )
        XCTAssertTrue(echoResult.terminationStatus.isSuccess)
        let output = try XCTUnwrap(
            echoResult.standardOutput
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let targetRange = expected.startIndex ..< expected.index(expected.startIndex, offsetBy: limit)
        XCTAssertEqual(String(expected[targetRange]), output)
    }

    func testCollectedOutputFileDesriptor() async throws {
        let outputFilePath = FilePath(
            FileManager.default.temporaryDirectory._fileSystemPath
        ).appending("Test.out")
        let outputFile: FileDescriptor = try .open(
            outputFilePath,
            .readWrite,
            options: .create,
            permissions: [.ownerReadWrite, .groupReadWrite]
        )
        let expected = randomString(length: 32)
        let echoResult = try await Subprocess.run(
            self.cmdExe,
            arguments: ["/c", "echo \(expected)"],
            output: .writeTo(
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
        throw XCTSkip("This test doues not support windows -- Double closing file descriptors on Windows causes system error")

        let outputFilePath = FilePath(
            FileManager.default.temporaryDirectory._fileSystemPath
        ).appending("Test.out")
        let outputFile: FileDescriptor = try .open(
            outputFilePath,
            .readWrite,
            options: .create,
            permissions: [.ownerReadWrite, .groupReadWrite]
        )
        let echoResult = try await Subprocess.run(
            self.cmdExe,
            arguments: ["/c", "echo Hello World"],
            output: .writeTo(
                outputFile,
                closeAfterSpawningProcess: true
            )
        )
        XCTAssertTrue(echoResult.terminationStatus.isSuccess)
        // Make sure the file descriptor is already closed
        do {
            // On windows instead of throwing the execuatble will get killed
            try outputFile.close()
            XCTFail("Output file descriptor should be closed automatically")
        } catch {
            guard let typedError = error as? CocoaError,
                  let windowsError: Win32Error = typedError.underlying as? Win32Error else {
                XCTFail("Wrong type of error thrown")
                return
            }
            XCTAssertEqual(windowsError.code, Win32Error.Code(ERROR_FILE_NOT_FOUND))
        }
    }

    func testRedirectedOutputFileDescriptor() async throws {
        let outputFilePath = FilePath(
            FileManager.default.temporaryDirectory._fileSystemPath
        ).appending("Test.out")
        let outputFile: FileDescriptor = try .open(
            outputFilePath,
            .readWrite,
            options: .create,
            permissions: [.ownerReadWrite, .groupReadWrite]
        )
        let expected = randomString(length: 32)
        let echoResult = try await Subprocess.run(
            self.cmdExe,
            arguments: ["/c", "echo \(expected)"],
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
        throw XCTSkip("This test doues not support windows -- Double closing file descriptors on Windows causes system error")

        let outputFilePath = FilePath(
            FileManager.default.temporaryDirectory._fileSystemPath
        ).appending("Test.out")
        let outputFile: FileDescriptor = try .open(
            outputFilePath,
            .readWrite,
            options: .create,
            permissions: [.ownerReadWrite, .groupReadWrite]
        )
        let echoResult = try await Subprocess.run(
            self.cmdExe,
            arguments: ["/c", "echo Hello world"],
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

    func testRedirectedOutputRedirectToSequence() async throws {
        // Maeks ure we can read long text redirected to AsyncSequence
        let expected: Data = try Data(
            contentsOf: URL(filePath: theMysteriousIsland.string)
        )
        let catResult = try await Subprocess.run(
            self.cmdExe,
            arguments: ["/c", "type \(theMysteriousIsland.string)"],
            output: .redirectToSequence
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
}

// MARK: - PlatformOption Tests
extension SubprocessWindowsTests {
    func testPlatformOptionsRunAsUser() async throws {
        guard self.hasAdminPrivileges() else {
            throw XCTSkip("This test requires admin privileges to create and delete temporary users.")
        }

        try await self.withTemporaryUser { username, password in
            // Use public directory as working directory so the newly created user
            // has access to it
            let workingDirectory = FilePath("C:\\Users\\Public")

            var platformOptions: Subprocess.PlatformOptions = .init()
            platformOptions.userCredentials = .init(
                username: username,
                password: password,
                domain: nil
            )

            let whoamiResult = try await Subprocess.run(
                .at("C:\\Windows\\System32\\whoami.exe"),
                workingDirectory: workingDirectory,
                platformOptions: platformOptions,
                output: .collectString()
            )
            XCTAssertTrue(whoamiResult.terminationStatus.isSuccess)
            let result = try XCTUnwrap(
                whoamiResult.standardOutput
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            // whoami returns `computerName\userName`.
            let userInfo = result.split(separator: "\\")
            guard userInfo.count == 2 else {
                XCTFail("Fail to parse the restult for whoami: \(result)")
                return
            }
            XCTAssertEqual(
                userInfo[1].lowercased(),
                username.lowercased()
            )
        }
    }

    func testPlatformOptionsCreateNewConsole() async throws {
        let parentConsole = GetConsoleWindow()
        let sameConsoleResult = try await Subprocess.run(
            .at("C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"),
            arguments: [
                "-File", windowsTester.string,
                "-mode", "get-console-window"
            ],
            output: .collectString()
        )
        XCTAssertTrue(sameConsoleResult.terminationStatus.isSuccess)
        let sameConsoleValue = try XCTUnwrap(
            sameConsoleResult.standardOutput
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        // Make sure the child console is same as parent
        XCTAssertEqual(
            "\(intptr_t(bitPattern: parentConsole))",
            sameConsoleValue
        )
        // Now launch a procss with new console
        var platformOptions: Subprocess.PlatformOptions = .init()
        platformOptions.consoleBehavior = .createNew
        let differentConsoleResult = try await Subprocess.run(
            .at("C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"),
            arguments: [
                "-File", windowsTester.string,
                "-mode", "get-console-window"
            ],
            platformOptions: platformOptions,
            output: .collectString()
        )
        XCTAssertTrue(differentConsoleResult.terminationStatus.isSuccess)
        let differentConsoleValue = try XCTUnwrap(
            differentConsoleResult.standardOutput
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        // Make sure the child console is different from parent
        XCTAssertNotEqual(
            "\(intptr_t(bitPattern: parentConsole))",
            differentConsoleValue
        )
    }

    func testPlatformOptionsDetachedProcess() async throws {
        var platformOptions: Subprocess.PlatformOptions = .init()
        platformOptions.consoleBehavior = .detatch
        let detachConsoleResult = try await Subprocess.run(
            .at("C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"),
            arguments: [
                "-File", windowsTester.string,
                "-mode", "get-console-window"
            ],
            platformOptions: platformOptions,
            output: .collectString()
        )
        XCTAssertTrue(detachConsoleResult.terminationStatus.isSuccess)
        let detachConsoleValue = try XCTUnwrap(
            detachConsoleResult.standardOutput
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        // Detached process shoud NOT have a console
        XCTAssertTrue(detachConsoleValue.isEmpty)
    }

    func testPlatformOptionsPreSpawnConfigurator() async throws {
        // Manually set the create new console flag
        var platformOptions: Subprocess.PlatformOptions = .init()
        platformOptions.preSpawnProcessConfigurator = { creationFlags, _ in
            creationFlags |= DWORD(CREATE_NEW_CONSOLE)
        }
        let parentConsole = GetConsoleWindow()
        let newConsoleResult = try await Subprocess.run(
            .at("C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"),
            arguments: [
                "-File", windowsTester.string,
                "-mode", "get-console-window"
            ],
            platformOptions: platformOptions,
            output: .collectString()
        )
        XCTAssertTrue(newConsoleResult.terminationStatus.isSuccess)
        let newConsoleValue = try XCTUnwrap(
            newConsoleResult.standardOutput
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        // Make sure the child console is different from parent
        XCTAssertNotEqual(
            "\(intptr_t(bitPattern: parentConsole))",
            newConsoleValue
        )

        guard !self.hasAdminPrivileges() else {
            try XCTSkip("Admin process cannot change title")
            return
        }
        // Change the console title
        let title = "My Awesome Process"
        platformOptions.preSpawnProcessConfigurator = { creationFlags, startupInfo in
            creationFlags |= DWORD(CREATE_NEW_CONSOLE)
            title.withCString(
                encodedAs: UTF16.self
            ) { titleW in
                startupInfo.lpTitle = UnsafeMutablePointer(mutating: titleW)
            }
        }
        let changeTitleResult = try await Subprocess.run(
            .at("C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"),
            arguments: [
                "-Command", "$consoleTitle = [console]::Title; Write-Host $consoleTitle",
            ],
            platformOptions: platformOptions,
            output: .collectString()
        )
        XCTAssertTrue(changeTitleResult.terminationStatus.isSuccess)
        let newTitle = try XCTUnwrap(
            changeTitleResult.standardOutput
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        // Make sure the child console is different from parent\
        XCTAssertEqual(newTitle, title)
    }
}

// MARK: - Subprocess Controlling Tests
extension SubprocessWindowsTests {
    func testTerminateProcess() async throws {
        let stuckProcess = try await Subprocess.run(
            self.cmdExe,
            // This command will intentionally hang
            arguments: ["/c", "type con"]
        ) { subprocess in
            // Make sure we can kill the hung process
            try subprocess.terminate(withExitCode: 42)
        }
        // If we got here, the process was terminated
        guard case .exited(let exitCode) = stuckProcess.terminationStatus else {
            XCTFail("Process should have exited")
            return
        }
        XCTAssertEqual(exitCode, 42)
    }

    func testSuspendResumeProcess() async throws {
        let stuckProcess = try await Subprocess.run(
            self.cmdExe,
            // This command will intentionally hang
            arguments: ["/c", "type con"]
        ) { subprocess in
            try subprocess.suspend()
            // Now check the to make sure the procss is actually suspended
            // Why not spawn a nother process to do that?
            var checkResult = try await Subprocess.run(
                .at("C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"),
                arguments: [
                    "-File", windowsTester.string,
                    "-mode", "is-process-suspended",
                    "-processID", "\(subprocess.processIdentifier.value)"
                ],
                output: .collectString()
            )
            XCTAssertTrue(checkResult.terminationStatus.isSuccess)
            var isSuspended = try XCTUnwrap(
                checkResult.standardOutput
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(isSuspended, "true")

            // Now resume the process
            try subprocess.resume()
            checkResult = try await Subprocess.run(
                .at("C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"),
                arguments: [
                    "-File", windowsTester.string,
                    "-mode", "is-process-suspended",
                    "-processID", "\(subprocess.processIdentifier.value)"
                ],
                output: .collectString()
            )
            XCTAssertTrue(checkResult.terminationStatus.isSuccess)
            isSuspended = try XCTUnwrap(
                checkResult.standardOutput
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(isSuspended, "false")

            // Now finally kill the process since it's intentionally hung
            try subprocess.terminate(withExitCode: 0)
        }
        XCTAssertTrue(stuckProcess.terminationStatus.isSuccess)
    }

    func testRunDetached() async throws {
        let (readFd, writeFd) = try FileDescriptor.pipe()
        SetHandleInformation(
            readFd.platformDescriptor,
            DWORD(HANDLE_FLAG_INHERIT),
            0
        )
        let pid = try Subprocess.runDetached(
            .at("C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"),
            arguments: [
                "-Command", "Write-Host $PID"
            ],
            output: writeFd
        )
        // Wait for procss to finish
        guard let processHandle = OpenProcess(
            DWORD(PROCESS_QUERY_INFORMATION | SYNCHRONIZE),
            false,
            pid.value
        ) else {
            XCTFail("Failed to get process handle")
            return
        }

        // Wait for the process to finish
        WaitForSingleObject(processHandle, INFINITE);

        let data = try await readFd.readUntilEOF(upToLength: 5)
        let resultPID = try XCTUnwrap(
            String(data: data, encoding: .utf8)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual("\(pid.value)", resultPID)
        try readFd.close()
        try writeFd.close()
    }
}

// MARK: - User Utils
extension SubprocessWindowsTests {
    private func withTemporaryUser(
        _ work: (String, String) async throws -> Void
    ) async throws {
        let username: String = "TestUser\(randomString(length: 5, lettersOnly: true))"
        let password: String = "Password\(randomString(length: 10))"

        func createUser(withUsername username: String, password: String) {
            username.withCString(
                encodedAs: UTF16.self
            ) { usernameW in
                password.withCString(
                    encodedAs: UTF16.self
                ) { passwordW in
                    var userInfo: USER_INFO_1 = USER_INFO_1()
                    userInfo.usri1_name = UnsafeMutablePointer<WCHAR>(mutating: usernameW)
                    userInfo.usri1_password = UnsafeMutablePointer<WCHAR>(mutating: passwordW)
                    userInfo.usri1_priv = DWORD(USER_PRIV_USER)
                    userInfo.usri1_home_dir = nil
                    userInfo.usri1_comment = nil
                    userInfo.usri1_flags = DWORD(UF_SCRIPT | UF_DONT_EXPIRE_PASSWD)
                    userInfo.usri1_script_path = nil

                    var error: DWORD = 0

                    var status = NetUserAdd(
                        nil,
                        1,
                        &userInfo,
                        &error
                    )
                    guard status == NERR_Success else {
                        XCTFail("Failed to create user with error: \(error)")
                        return
                    }
                }
            }
        }

        createUser(withUsername: username, password: password)
        defer {
            // Now delete the user
            let status = username.withCString(
                encodedAs: UTF16.self
            ) { usernameW in
                return NetUserDel(nil, usernameW)
            }
            if status != NERR_Success {
                XCTFail("Failed to delete user with error: \(status)")
            }
        }
        // Run work
        try await work(username, password)
    }

    private func hasAdminPrivileges() -> Bool {
        var isAdmin: WindowsBool = false
        var adminGroup: PSID? = nil
        // SECURITY_NT_AUTHORITY
        var netAuthority = SID_IDENTIFIER_AUTHORITY(Value: (0, 0, 0, 0, 0, 5))
        guard AllocateAndInitializeSid(
            &netAuthority,
            2,  // nSubAuthorityCount
            DWORD(SECURITY_BUILTIN_DOMAIN_RID),
            DWORD(DOMAIN_ALIAS_RID_ADMINS),
            0, 0, 0, 0, 0, 0,
            &adminGroup
        ) else {
            return false
        }
        defer {
            FreeSid(adminGroup)
        }
        // Check if the current process's token is part of
        // the Administrators group
        guard CheckTokenMembership(
            nil,
            adminGroup,
            &isAdmin
        ) else {
            return false
        }
        // Okay the below is intentional because
        // `isAdmin` is a `WindowsBool` and we need `Bool`
        return isAdmin.boolValue
    }
}

#endif // canImport(WinSDK)
