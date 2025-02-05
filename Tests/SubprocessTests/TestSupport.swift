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

#if canImport(WinSDK)
import WinSDK
#endif

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

#if canImport(System)
import System
#else
@preconcurrency import SystemPackage
#endif
import class Foundation.Bundle
import struct Foundation.URL

internal var prideAndPrejudice: FilePath {
    let path = Bundle.module.url(
        forResource: "PrideAndPrejudice",
        withExtension: "txt",
        subdirectory: "Resources"
    )!._fileSystemPath
    return FilePath(path)
}

internal var theMysteriousIsland: FilePath {
    let path = Bundle.module.url(
        forResource: "TheMysteriousIsland",
        withExtension: "txt",
        subdirectory: "Resources"
    )!._fileSystemPath
    return FilePath(path)
}

internal var getgroupsSwift: FilePath {
    let path = Bundle.module.url(
        forResource: "getgroups",
        withExtension: "swift",
        subdirectory: "Resources"
    )!._fileSystemPath
    return FilePath(path)
}

internal var windowsTester: FilePath {
    let path = Bundle.module.url(
        forResource: "windows-tester",
        withExtension: "ps1",
        subdirectory: "Resources"
    )!._fileSystemPath
    return FilePath(path)
}

extension Foundation.URL {
    var _fileSystemPath: String {
#if canImport(WinSDK)
        var path = self.path(percentEncoded: false)
        if path.starts(with: "/") {
            path.removeFirst()
            return path
        }
        return path
#else
        return self.path(percentEncoded: false)
#endif
    }
}

internal func randomString(length: Int, lettersOnly: Bool = false) -> String {
    let letters: String
    if lettersOnly {
        letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    } else {
        letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    }
    return String((0..<length).map{ _ in letters.randomElement()! })
}

internal func directory(_ lhs: String, isSameAs rhs: String) -> Bool {
    guard lhs != rhs else {
        return true
    }
    var canonicalLhs: String = (try? FileManager.default.destinationOfSymbolicLink(atPath: lhs)) ?? lhs
    var canonicalRhs: String = (try? FileManager.default.destinationOfSymbolicLink(atPath: rhs)) ?? rhs
    if !canonicalLhs.starts(with: "/") {
        canonicalLhs = "/\(canonicalLhs)"
    }
    if !canonicalRhs.starts(with: "/") {
        canonicalRhs = "/\(canonicalRhs)"
    }

    return canonicalLhs == canonicalRhs
}

