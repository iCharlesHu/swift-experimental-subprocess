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
        try assertNewSessionCreated(with: psResult)
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
        // On Darwin, /var is linked to /private/var; /tmp is linked /private/tmp
        var expected = FilePath(intendedWorkingDir)
        if expected.starts(with: "/var") || expected.starts(with: "/tmp") {
            expected = FilePath("/private").appending(expected.components)
        }
        XCTAssertEqual(FilePath(currentDir), expected)
    }
}

#endif // canImport(Darwin)
