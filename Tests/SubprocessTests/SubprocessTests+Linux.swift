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

#if canImport(Glibc)

import XCTest
@testable import SwiftExperimentalSubprocess

// MARK: PlatformOption Tests
final class SubprocessLinuxTests: XCTestCase {
    func testSubprocessPlatfomOptionsPreSpawnProcessConfigurator() async throws {
        guard getuid() == 0 else {
            throw XCTSkip("This test requires root privileges")
        }
        var platformOptions: Subprocess.PlatformOptions = .default
        platformOptions.preSpawnProcessConfigurator = {
            setgid(4321)
        }
        let idResult = try await Subprocess.run(
            .named("/usr/bin/id"),
            arguments: ["-g"],
            platformOptions: platformOptions
        )
        XCTAssertTrue(idResult.terminationStatus.isSuccess)
        let id = try XCTUnwrap(String(data: idResult.standardOutput, encoding: .utf8))
        XCTAssertEqual(
            id.trimmingCharacters(in: .whitespacesAndNewlines),
            "\(4321)"
        )
    }
}

#endif // canImport(Glibc)
