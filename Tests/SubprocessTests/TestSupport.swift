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

import SystemPackage
@testable import FoundationEssentials
import class Foundation.Bundle
import struct Foundation.URL

typealias Data = FoundationEssentials.Data
typealias URL = FoundationEssentials.URL
typealias CocoaError = FoundationEssentials.CocoaError
typealias FileManager = FoundationEssentials.FileManager
typealias POSIXError = FoundationEssentials.POSIXError

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
        // Hack to remove leading slash
        var path = FoundationEssentials.URL(
            string: self.absoluteString
        )!.fileSystemPath
        if path.hasPrefix("/") {
            path.removeFirst()
        }
        return path
#else
        return FoundationEssentials.URL(
            string: self.absoluteString
        )!.fileSystemPath
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

