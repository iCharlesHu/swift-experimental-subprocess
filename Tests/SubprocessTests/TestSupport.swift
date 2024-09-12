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


import SystemPackage
import FoundationEssentials
import class Foundation.Bundle

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
    )!.path()
    return FilePath(path)
}

internal var getgroupsSwift: FilePath {
    let path = Bundle.module.url(
        forResource: "getgroups",
        withExtension: "swift",
        subdirectory: "Resources"
    )!.path()
    return FilePath(path)
}

internal func randomString(length: Int) -> String {
    let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    return String((0..<length).map{ _ in letters.randomElement()! })
}

