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

import _CShims
import XCTest
import System
@testable import SwiftExperimentalSubprocess

// MARK: PlatformOptions Tests
@available(macOS 9999, *)
final class SubprocessDarwinTests : XCTestCase {
    func testSubprocessPlatformOptionsProcessConfiguratorUpdateSpawnAttr() async throws {
        var platformOptions = Subprocess.PlatformOptions()
        platformOptions.preSpawnProcessConfigurator = { spawnAttr, _ in
            // Set POSIX_SPAWN_SETSID flag, which implies calls
            // to setsid
            var flags: Int16 = 0
            posix_spawnattr_getflags(&spawnAttr, &flags)
            posix_spawnattr_setflags(&spawnAttr, flags | Int16(POSIX_SPAWN_SETSID))
        }
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

    func testSubprocessPlatformOptionsProcessConfiguratorUpdateFileAction() async throws {
        let intendedWorkingDir = FileManager.default.temporaryDirectory.path()
        var platformOptions = Subprocess.PlatformOptions()
        platformOptions.preSpawnProcessConfigurator = { _, fileAttr in
            // Change the working directory
            intendedWorkingDir.withCString { path in
                _ = posix_spawn_file_actions_addchdir_np(&fileAttr, path)
            }
        }
        let pwdResult = try await Subprocess.run(
            .at("/bin/pwd"),
            platformOptions: platformOptions,
            output: .string
        )
        XCTAssertTrue(pwdResult.terminationStatus.isSuccess)
        let currentDir = try XCTUnwrap(
            pwdResult.standardOutput
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        // On Darwin, /var is linked to /private/var; /tmp is linked /private/tmp
        var expected = FilePath(intendedWorkingDir)
        if expected.starts(with: "/var") || expected.starts(with: "/tmp") {
            expected = FilePath("/private").appending(expected.components)
        }
        XCTAssertEqual(FilePath(currentDir), expected)
    }

    func testSuspendResumeProcess() async throws {
        _ = try await Subprocess.run(
            // This will intentionally hang
            .at("/bin/cat")
        ) { subprocess in
            // First suspend the procss
            try subprocess.send(signal: .suspend)
            var suspendedStatus: Int32 = 0
            waitpid(subprocess.processIdentifier.value, &suspendedStatus, WNOHANG | WUNTRACED)
            XCTAssertTrue(_was_process_suspended(suspendedStatus) > 0)
            // Now resume the process
            try subprocess.send(signal: .resume)
            var resumedStatus: Int32 = 0
            waitpid(subprocess.processIdentifier.value, &resumedStatus, WNOHANG | WUNTRACED)
            XCTAssertTrue(_was_process_suspended(resumedStatus) == 0)

            // Now kill the process
            try subprocess.send(signal: .terminate)
        }
    }
}

#endif // canImport(Darwin)
