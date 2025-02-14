//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

#if canImport(Darwin)
import Darwin
#elseif canImport(Bionic)
import Bionic
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
import WinSDK
#endif

public struct SubprocessError: Swift.Error, Hashable, Sendable {
    public let code: SubprocessError.Code
    public let underlyingError: UnderlyingError?
}

// MARK: - Error Codes

extension SubprocessError {
    public struct Code: Hashable, Sendable {
        internal enum Storage: Hashable, Sendable {
            case spawnFailed
            case executableNotFound(String)
            case failedToChangeWorkingDirectory(String)
            case failedToReadFromSubprocess
            case failedToWriteToSubprocess
            case failedToMonitorProcess
            // Signal
            case failedToSendSignal(Int32)
            // Windows Only
            case failedToTerminate
            case failedToSuspend
            case failedToResume
            case failedToCreatePipe
            case invalidWindowsPath(String)
        }

        public var value: Int {
            switch self.storage {
            case .spawnFailed:
                return 0
            case .executableNotFound(_):
                return 1
            case .failedToChangeWorkingDirectory(_):
                return 2
            case .failedToReadFromSubprocess:
                return 3
            case .failedToWriteToSubprocess:
                return 4
            case .failedToMonitorProcess:
                return 5
            case .failedToSendSignal(_):
                return 6
            case .failedToTerminate:
                return 7
            case .failedToSuspend:
                return 8
            case .failedToResume:
                return 9
            case .failedToCreatePipe:
                return 10
            case .invalidWindowsPath(_):
                return 11
            }
        }

        internal let storage: Storage

        internal init(_ storage: Storage) {
            self.storage = storage
        }
    }
}

#if canImport(WinSDK)
extension SubprocessError {
    public typealias UnderlyingError = WindowsError

    public struct WindowsError: Swift.Error, RawRepresentable, Hashable, Sendable {
        public typealias RawValue = DWORD

        public let rawValue: DWORD

        public init(rawValue: DWORD) {
            self.rawValue = rawValue
        }
    }
}
#else
extension SubprocessError {
    public typealias UnderlyingError = POSIXError

    public struct POSIXError: Swift.Error, RawRepresentable, Hashable, Sendable {
        public typealias RawValue = Int32

        public let rawValue: Int32

        public init(rawValue: Int32) {
            self.rawValue = rawValue
        }
    }

}
#endif
