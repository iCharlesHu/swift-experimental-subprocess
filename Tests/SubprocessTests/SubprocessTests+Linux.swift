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
@testable import Subprocess

// MARK: PlatformOption Tests
final class SubprocessLinuxTests: XCTestCase {
    func testSubprocessPlatfomOptionsPreSpawnProcessConfigurator() async throws {
        guard getuid() == 0 else {
            throw XCTSkip("This test requires root privileges")
        }
        var platformOptions = PlatformOptions()
        platformOptions.preSpawnProcessConfigurator = {
            setgid(4321)
        }
        let idResult = try await Subprocess.run(
            .named("/usr/bin/id"),
            arguments: ["-g"],
            platformOptions: platformOptions,
            output: .string
        )
        XCTAssertTrue(idResult.terminationStatus.isSuccess)
        let id = try XCTUnwrap(idResult.standardOutput)
        XCTAssertEqual(
            id.trimmingCharacters(in: .whitespacesAndNewlines),
            "\(4321)"
        )
    }

    func testSuspendResumeProcess() async throws {
        func isProcessSuspended(_ pid: pid_t) throws -> Bool {
            let status = try Data(
                contentsOf: URL(filePath: "/proc/\(pid)/status")
            )
            let statusString = try XCTUnwrap(
                String(data: status, encoding: .utf8)
            )
            // Parse the status string
            let stats = statusString.split(separator: "\n")
            if let index = stats.firstIndex(
                where: { $0.hasPrefix("State:") }
            ) {
                let processState = stats[index].split(
                    separator: ":"
                ).map {
                    $0.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                }

                return processState[1].hasPrefix("T")
            }
            return false
        }

        _ = try await Subprocess.run(
            // This will intentionally hang
            .at("/usr/bin/sleep"),
            arguments: ["infinity"]
        ) { subprocess in
            // First suspend the procss
            try subprocess.send(signal: .suspend)
            XCTAssertTrue(
                try isProcessSuspended(subprocess.processIdentifier.value)
            )
            // Now resume the process
            try subprocess.send(signal: .resume)
            XCTAssertFalse(
                try isProcessSuspended(subprocess.processIdentifier.value)
            )
            // Now kill the process
            try subprocess.send(signal: .terminate)
        }
    }
}

#endif // canImport(Glibc)
