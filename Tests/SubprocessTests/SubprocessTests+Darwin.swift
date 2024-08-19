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

#if canImport(Darwin)

import XCTest
import SystemPackage
@testable import SwiftExperimentalSubprocess

// MARK: PlatformOptions Tests
final class SubprocessDarwinTests : XCTestCase {
    // Run this test with sudo
    func testSubprocessPlatformOptionsUserID() async throws {
        guard getuid() == 0 else {
            throw XCTSkip("This test requires root privileges")
        }
        let expectedUserID = Int.random(in: 1000 ... 2000)
        var platformOptions: Subprocess.PlatformOptions = .default
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
        let expectedGroupID = Int.random(in: 1000 ... 2000)
        var platformOptions: Subprocess.PlatformOptions = .default
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
        var expectedGroups: Set<Int> = Set()
        for _ in 0 ..< Int.random(in: 5 ... 10) {
            expectedGroups.insert(Int.random(in: 1000 ... 2000))
        }
        var platformOptions: Subprocess.PlatformOptions = .default
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
        .map { Int($0.trimmingCharacters(in: .whitespacesAndNewlines))! }
        XCTAssertEqual(Set(ids), expectedGroups)
    }

    func testSubprocessPlatformOptionsProcessGroupID() async throws {
        guard getuid() == 0 else {
            throw XCTSkip("This test requires root privileges")
        }
        let expectedPGID = Int.random(in: 1000 ... Int(pid_t.max))
        var platformOptions: Subprocess.PlatformOptions = .default
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
        var platformOptions: Subprocess.PlatformOptions = .default
        platformOptions.createSession = true
        // Check the proces ID (pid), pross group ID (pgid), and
        // controling terminal's process group ID (tpgid)
        let psResult = try await Subprocess.run(
            .named("/bin/bash"),
            arguments: ["-c", "ps -o pid,pgid,tpgid -p $$"],
            platformOptions: platformOptions
        )
        try self.assertNewSessionCreated(with: psResult)
    }

    func testSubprocessPlatformOptionsAttributeConfigurator() async throws {
        var platformOptions: Subprocess.PlatformOptions = .default
        platformOptions.preSpawnAttributeConfigurator = {
            // Set POSIX_SPAWN_SETSID flag, which implies calls
            // to setsid
            var flags: Int16 = 0
            posix_spawnattr_getflags(&$0, &flags)
            posix_spawnattr_setflags(&$0, flags | Int16(POSIX_SPAWN_SETSID))
        }
        // Check the proces ID (pid), pross group ID (pgid), and
        // controling terminal's process group ID (tpgid)
        let psResult = try await Subprocess.run(
            .named("/bin/bash"),
            arguments: ["-c", "ps -o pid,pgid,tpgid -p $$"],
            platformOptions: platformOptions
        )
        try self.assertNewSessionCreated(with: psResult)
    }

    func testSubprocessPlatformOptionsFileAttributeConfigurator() async throws {
        let intendedWorkingDir = FileManager.default.temporaryDirectory.path()
        var platformOptions: Subprocess.PlatformOptions = .default
        platformOptions.preSpawnFileAttributeConfigurator = { fileAttr in
            // Change the working directory
            intendedWorkingDir.withCString { path in
                _ = posix_spawn_file_actions_addchdir_np(&fileAttr, path)
            }
        }
        let pwdResult = try await Subprocess.run(
            .at("/bin/pwd"),
            platformOptions: platformOptions
        )
        XCTAssertTrue(pwdResult.terminationStatus.isSuccess)
        let currentDir = try XCTUnwrap(
            String(data: pwdResult.standardOutput, encoding: .utf8)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
#if canImport(Darwin)
        // On Darwin, /var is linked to /private/var; /tmp is linked /private/tmp
        var expected = FilePath(intendedWorkingDir)
        if expected.starts(with: "/var") || expected.starts(with: "/tmp") {
            expected = FilePath("/private").appending(expected.components)
        }
        XCTAssertEqual(FilePath(currentDir), expected)
#else
        XCTAssertEqual(FilePath(currentDir), FilePath(intendedWorkingDir))
#endif
    }
}

// MARK: - Utils
extension SubprocessDarwinTests {
    private func assertID(
        withArgument argument: String,
        platformOptions: Subprocess.PlatformOptions,
        isEqualTo expected: Int
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

    private func assertNewSessionCreated(with result: Subprocess.CollectedResult) throws {
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
}

#endif // canImport(Darwin)
