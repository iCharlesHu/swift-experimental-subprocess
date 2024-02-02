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

import XCTest
import FoundationEssentials
@testable import SwiftExperimentalSubprocess

final class SubprocessTests: XCTestCase {
    func testSimple() async throws {
        let ls = try await Subprocess.run(executing: .named("ls"), output: .collect, error: .discard)
        let result = String(data: ls.standardOutput!, encoding: .utf8)!
        print("Result: \(result)")
    }

    func testComplex() async throws {
        struct Address: Codable {
            let ip: String
        }

        let result = try await Subprocess.run(
            executing: .named("curl"),
            arguments: ["http://ip.jsontest.com/"]
        ) { execution in
            let output = try await Array(execution.standardOutput!)
            let decoder = FoundationEssentials.JSONDecoder()
            return try decoder.decode(Address.self, from: Data(output))
        }
        print("Result: \(result.value)")
    }
}
