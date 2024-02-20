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

import Darwin
import _Shims
import SystemPackage
import FoundationEssentials

// Darwin specific implementation
extension Subprocess.Configuration {
    internal typealias StringOrRawBytes = Subprocess.StringOrRawBytes

    internal func spawn(
        withInput input: Subprocess.ExecutionInput,
        output: Subprocess.ExecutionOutput,
        error: Subprocess.ExecutionOutput
    ) throws -> Subprocess {

        let env = self.environment.createEnv()
        defer {
            for ptr in env { ptr?.deallocate() }
        }
        guard let executablePath = self.executable.resolveExecutablePath(
            withPathValue: self.environment.pathValue()) else {
            throw CocoaError(.executableNotLoadable, userInfo: [
                .debugDescriptionErrorKey : "\(self.executable.description) is not an executable"
            ])
        }
        let intendedWorkingDir = self.workingDirectory
        guard Self.pathAccessible(intendedWorkingDir.string, mode: F_OK) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                .debugDescriptionErrorKey : "Failed to set working directory to \(intendedWorkingDir)"
            ])
        }
        // Prepare args for posix_spawn
        var argv: [UnsafeMutablePointer<CChar>?] = self.arguments.storage.map { $0.createRawBytes() }
        defer {
            for ptr in argv { ptr?.deallocate() }
        }
        // argv[0] = executable path
        if let override = self.arguments.executablePathOverride {
            argv.insert(override.createRawBytes(), at: 0)
        } else {
            argv.insert(strdup(executablePath), at: 0)
        }
        argv.append(nil)
        // Setup file actions and spawn attributes
        var fileActions: posix_spawn_file_actions_t? = nil
        var spawnAttributes: posix_spawnattr_t? = nil
        // Cleanup function. Not defer because on success these file
        // handles do not need to be closed
        func cleanup() throws {
            var inputError: Error?
            var outputError: Error?
            var errorError: Error?

            do {
                try input.closeAll()
            } catch {
                inputError = error
            }

            do {
                try output.closeAll()
            } catch {
                outputError = error
            }

            do {
                try error.closeAll()
            } catch {
                errorError = error
            }

            if let inputError = inputError {
                throw inputError
            }
            if let outputError = outputError {
                throw outputError
            }
            if let errorError = errorError {
                throw errorError
            }
        }

        // Setup stdin, stdout, and stderr
        posix_spawn_file_actions_init(&fileActions)
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
        }

        var result = posix_spawn_file_actions_adddup2(&fileActions, input.getReadFileDescriptor().rawValue, 0)
        guard result == 0 else {
            try cleanup()
            throw POSIXError(.init(rawValue: result) ?? .ENODEV)
        }
        result = posix_spawn_file_actions_adddup2(&fileActions, output.getWriteFileDescriptor().rawValue, 1)
        guard result == 0 else {
            try cleanup()
            throw POSIXError(.init(rawValue: result) ?? .ENODEV)
        }
        result = posix_spawn_file_actions_adddup2(&fileActions, error.getWriteFileDescriptor().rawValue, 2)
        guard result == 0 else {
            try cleanup()
            throw POSIXError(.init(rawValue: result) ?? .ENODEV)
        }
        // Setup spawnAttributes
        posix_spawnattr_init(&spawnAttributes)
        defer {
            posix_spawnattr_destroy(&spawnAttributes)
        }
        var noSignals = sigset_t()
        var allSignals = sigset_t()
        sigemptyset(&noSignals)
        sigfillset(&allSignals)
        posix_spawnattr_setsigmask(&spawnAttributes, &noSignals)
        posix_spawnattr_setsigdefault(&spawnAttributes, &allSignals)
        // Configure spawnattr
        let flags: Int32 = POSIX_SPAWN_CLOEXEC_DEFAULT |
            POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        var spawnAttributeError = posix_spawnattr_setflags(&spawnAttributes, Int16(flags))
        // Set QualityOfService
        // spanattr_qos seems to only accept `QOS_CLASS_UTILITY` or `QOS_CLASS_BACKGROUND`
        // and returns an error of `EINVAL` if anything else is provided
        if spawnAttributeError == 0 && self.platformOptions.qualityOfService == .utility{
            spawnAttributeError = posix_spawnattr_set_qos_class_np(&spawnAttributes, QOS_CLASS_UTILITY)
        } else if spawnAttributeError == 0 && self.platformOptions.qualityOfService == .background {
            spawnAttributeError = posix_spawnattr_set_qos_class_np(&spawnAttributes, QOS_CLASS_BACKGROUND)
        }

        // Setup cwd
        let previousCWD: FileDescriptor = try .open(".", .readOnly)
        var chdirError: Int32 = 0
        if spawnAttributeError == 0 {
            chdirError = intendedWorkingDir.withCString { cString in
                if chdir(cString) == 0 {
                    return 0
                } else {
                    return errno
                }
            }
        }
        defer {
            if chdirError == 0 {
                fchdir(previousCWD.rawValue)
            }
        }
        // Error handling
        if chdirError != 0 || spawnAttributeError != 0 {
            try cleanup()
            if spawnAttributeError != 0 {
                throw POSIXError(.init(rawValue: result) ?? .ENODEV)
            }

            if chdirError != 0 {
                throw CocoaError(.fileNoSuchFile, userInfo: [
                    .debugDescriptionErrorKey: "Cannot failed to change the working directory to \(intendedWorkingDir) with errno \(chdirError)"
                ])
            }
        }
        // Run additional config
        if let spawnConfig = self.platformOptions.additionalSpawnAttributeConfiguration {
            try spawnConfig(&spawnAttributes)
        }
        if let fileAttributeConfig = self.platformOptions.additionalFileAttributeConfiguration {
            try fileAttributeConfig(&fileActions)
        }
        // Spawn
        var pid: pid_t = 0
        let spawnError: CInt = executablePath.withCString { exePath in
            return posix_spawn(&pid, exePath, &fileActions, &spawnAttributes, argv, env)
        }
        // Spawn error
        if spawnError != 0 {
            try cleanup()
            throw POSIXError(.init(rawValue: spawnError) ?? .ENODEV)
        }
        return Subprocess(
            processIdentifier: .init(value: pid),
            executionInput: input,
            executionOutput: output,
            executionError: error
        )
    }

    internal static func pathAccessible(_ path: String, mode: Int32) -> Bool {
        return path.withCString {
            return access($0, mode) == 0
        }
    }
}

@Sendable
internal func monitorProcessTermination(
    forProcessWithIdentifier pid: Subprocess.ProcessIdentifier
) -> Subprocess.TerminationStatus {
    var status: Int32 = -1
    // Block and wait
    waitpid(pid.value, &status, 0)
    if _was_process_exited(status) != 0 {
        return .exit(_get_exit_code(status))
    }
    if _was_process_signaled(status) != 0 {
        return .unhandledException(_get_signal_code(status))
    }
    fatalError("Unexpected exit status type: \(status)")
}

// Special keys used in Error's user dictionary
extension String {
    static let debugDescriptionErrorKey = "NSDebugDescription"
}

// MARK: - Platform Specific Options
extension Subprocess {
    /// The collection of platform-specific configurations
    public struct PlatformOptions: Sendable {
        public var qualityOfService: QualityOfService = .default
        // Set user ID for the subprocess
        public var userID: Int? = nil
        // Set group ID for the subprocess
        public var groupID: Int? = nil
        // Set list of supplementary group IDs for the subprocess
        public var supplementaryGroups: [Int]? = nil
        // Creates a session and sets the process group ID
        // i.e. Detach from the terminal.
        public var createSession: Bool = false
        // Create a new process group
        public var createProcessGroup: Bool = false
        public var launchRequirementData: Data? = nil
        public var additionalSpawnAttributeConfiguration: (@Sendable (inout posix_spawnattr_t?) throws -> Void)?
        public var additionalFileAttributeConfiguration: (@Sendable (inout posix_spawn_file_actions_t?) throws -> Void)?

        public init(
            qualityOfService: QualityOfService,
            userID: Int? = nil,
            groupID: Int? = nil,
            supplementaryGroups: [Int]? = nil,
            createSession: Bool,
            createProcessGroup: Bool,
            launchRequirementData: Data? = nil,
            additionalSpawnAttributeConfiguration: (@Sendable (inout posix_spawnattr_t?) throws -> Void)? = nil,
            additionalFileAttributeConfiguration: (@Sendable (inout posix_spawn_file_actions_t?) throws -> Void)? = nil
        ) {
            self.qualityOfService = qualityOfService
            self.userID = userID
            self.groupID = groupID
            self.supplementaryGroups = supplementaryGroups
            self.createSession = createSession
            self.createProcessGroup = createProcessGroup
            self.launchRequirementData = launchRequirementData
            self.additionalSpawnAttributeConfiguration = additionalSpawnAttributeConfiguration
            self.additionalFileAttributeConfiguration = additionalFileAttributeConfiguration
        }

        public static var `default`: Self {
            return .init(
                qualityOfService: .default,
                userID: nil,
                groupID: nil,
                supplementaryGroups: nil,
                createSession: false,
                createProcessGroup: false,
                launchRequirementData: nil,
                additionalSpawnAttributeConfiguration: nil,
                additionalFileAttributeConfiguration: nil
            )
        }
    }
}

// MARK: -  Executable Searching
extension Subprocess.Executable {
    internal static var defaultSearchPaths: Set<String> {
        return Set([
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "/usr/local/bin"
        ])
    }

    internal func resolveExecutablePath(withPathValue pathValue: String?) -> String? {
        switch self.storage {
        case .executable(let executableName):
            // If the executableName in is already a full path, return it directly
            if Subprocess.Configuration.pathAccessible(executableName, mode: X_OK) {
                return executableName
            }
            // Get $PATH from environment
            let searchPaths: Set<String>
            if let pathValue = pathValue {
                let localSearchPaths = pathValue.split(separator: ":").map { String($0) }
                searchPaths = Set(localSearchPaths).union(Self.defaultSearchPaths)
            } else {
                searchPaths = Self.defaultSearchPaths
            }

            for path in searchPaths {
                let fullPath = "\(path)/\(executableName)"
                let fileExists = Subprocess.Configuration.pathAccessible(fullPath, mode: X_OK)
                if fileExists {
                    return fullPath
                }
            }
        case .path(let executablePath):
            // Use path directly
            return executablePath.string
        }
        return nil
    }
}

// MARK: Environment Resolution
extension Subprocess.Environment {
    internal static let pathEnvironmentVariableName = "PATH"

    internal func pathValue() -> String? {
        switch self.config {
        case .inherit(let overrides):
            // If PATH value exists in overrides, use it
            if let value = overrides[.string(Self.pathEnvironmentVariableName)] {
                return value.stringValue
            }
            // Fall back to current process
            return ProcessInfo.processInfo.environment[Self.pathEnvironmentVariableName]
        case .custom(let fullEnvironment):
            if let value = fullEnvironment[.string(Self.pathEnvironmentVariableName)] {
                return value.stringValue
            }
            return nil
        }
    }

    // This method follows the standard "create" rule: `env` needs to be
    // manually deallocated
    internal func createEnv() -> [UnsafeMutablePointer<CChar>?] {
        func createFullCString(
            fromKey keyContainer: Subprocess.StringOrRawBytes,
            value valueContainer: Subprocess.StringOrRawBytes
        ) -> UnsafeMutablePointer<CChar> {
            let rawByteKey: UnsafeMutablePointer<CChar> = keyContainer.createRawBytes()
            let rawByteValue: UnsafeMutablePointer<CChar> = valueContainer.createRawBytes()
            defer {
                rawByteKey.deallocate()
                rawByteValue.deallocate()
            }
            /// length = `key` + `=` + `value` + `\null`
            let totalLength = keyContainer.count + 1 + valueContainer.count + 1
            let fullString: UnsafeMutablePointer<CChar> = .allocate(capacity: totalLength)
            _ = snprintf(ptr: fullString, totalLength, "%s=%s", rawByteKey, rawByteValue)
            return fullString
        }

        var env: [UnsafeMutablePointer<CChar>?] = []
        switch self.config {
        case .inherit(let updates):
            var current = ProcessInfo.processInfo.environment
            for (keyContainer, valueContainer) in updates {
                if let stringKey = keyContainer.stringValue {
                    // Remove the value from current to override it
                    current.removeValue(forKey: stringKey)
                }
                // Fast path
                if case .string(let stringKey) = keyContainer,
                   case .string(let stringValue) = valueContainer {
                    let fullString = "\(stringKey)=\(stringValue)"
                    env.append(strdup(fullString))
                    continue
                }

                env.append(createFullCString(fromKey: keyContainer, value: valueContainer))
            }
            // Add the rest of `current` to env
            for (key, value) in current {
                let fullString = "\(key)=\(value)"
                env.append(strdup(fullString))
            }
        case .custom(let customValues):
            for (keyContainer, valueContainer) in customValues {
                // Fast path
                if case .string(let stringKey) = keyContainer,
                   case .string(let stringValue) = valueContainer {
                    let fullString = "\(stringKey)=\(stringValue)"
                    env.append(strdup(fullString))
                    continue
                }
                env.append(createFullCString(fromKey: keyContainer, value: valueContainer))
            }
        }
        env.append(nil)
        return env
    }
}

#endif // canImport(Darwin)
