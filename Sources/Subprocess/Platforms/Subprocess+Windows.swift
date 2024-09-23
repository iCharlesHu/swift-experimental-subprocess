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
import SystemPackage
import FoundationEssentials

// Windows specific implementation
extension Subprocess.Configuration {
    internal func spawn(
        withInput input: Subprocess.ExecutionInput,
        output: Subprocess.ExecutionOutput,
        error: Subprocess.ExecutionOutput
    ) throws -> Subprocess {
        // Spawn differently depending on whether
        // we need to spawn as a user
        if let userInfo = self.platformOptions.userInfo {
            return try self.spawnAsUser(
                withInput: input,
                output: output,
                error: error,
                userInfo: userInfo
            )
        } else {
            return try self.spawnDirect(
                withInput: input,
                output: output,
                error: error
            )
        }
    }

    internal func spawnDirect(
        withInput input: Subprocess.ExecutionInput,
        output: Subprocess.ExecutionOutput,
        error: Subprocess.ExecutionOutput
    ) throws -> Subprocess {
        let (
            applicationName,
            commandAndArgs,
            environment,
            intendedWorkingDir
        ) = try self.preSpawn()
        var (startupInfo, handlesToReset) = try self.generateStartupInfo(
            withInput: input,
            output: output,
            error: error
        )
        defer {
            for handleToReset in handlesToReset {
                SetHandleInformation(
                    handleToReset.handle,
                    DWORD(HANDLE_FLAG_INHERIT),
                    handleToReset.prevValue
                )
            }
        }
        var processInfo: PROCESS_INFORMATION = PROCESS_INFORMATION()
        var createProcessFlags = self.generateCreateProcessFlag()
        // Give calling process a chance to modify flag and startup info
        if let configurator = self.platformOptions.preSpawnProcessConfigurator {
            try configurator(&createProcessFlags, &startupInfo)
        }
        // Spawn!
        try applicationName.withOptionalNTPathRepresentation { applicationNameW in
            try commandAndArgs.withNTPathRepresentation { commandAndArgsW in
                try environment.withCString(encodedAs: UTF16.self) { environmentW in
                    try intendedWorkingDir.withNTPathRepresentation { intendedWorkingDirW in
                        let created = CreateProcessW(
                            applicationNameW,
                            UnsafeMutablePointer<WCHAR>(mutating: commandAndArgsW),
                            nil,    // lpProcessAttributes
                            nil,    // lpThreadAttributes
                            false,  // bInheritHandles
                            createProcessFlags,
                            UnsafeMutableRawPointer(mutating: environmentW),
                            intendedWorkingDirW,
                            &startupInfo,
                            &processInfo
                        )
                        guard created else {
                            try self.cleanupAll(
                                input: input,
                                output: output,
                                error: error
                            )
                            throw CocoaError.windowsError(
                                underlying: GetLastError(),
                                errorCode: .fileWriteUnknown
                            )
                        }
                    }
                }
            }
        }
        // Close parent side
        self.closeParentSide(
            withInput: input,
            output: output,
            error: error
        )
        // We don't need hThread object, so close it right away
        guard CloseHandle(processInfo.hThread) else {
            try self.cleanupAll(
                input: input,
                output: output,
                error: error
            )
            throw CocoaError.windowsError(
                underlying: GetLastError(),
                errorCode: .fileReadUnknown
            )
        }
        let pid = Subprocess.ProcessIdentifier(
            processID: processInfo.dwProcessId,
            threadID: processInfo.dwThreadId,
            processHandle: processInfo.hProcess
        )
        return Subprocess(
            processIdentifier: pid,
            executionInput: input,
            executionOutput: output,
            executionError: error,
            consoleBehavior: self.platformOptions.consoleBehavior
        )
    }

    internal func spawnAsUser(
        withInput input: Subprocess.ExecutionInput,
        output: Subprocess.ExecutionOutput,
        error: Subprocess.ExecutionOutput,
        userInfo: Subprocess.PlatformOptions.UserInfo
    ) throws -> Subprocess {
        let (
            applicationName,
            commandAndArgs,
            environment,
            intendedWorkingDir
        ) = try self.preSpawn()
        var (startupInfo, handlesToReset) = try self.generateStartupInfo(
            withInput: input,
            output: output,
            error: error
        )
        defer {
            for handleToReset in handlesToReset {
                SetHandleInformation(
                    handleToReset.handle,
                    DWORD(HANDLE_FLAG_INHERIT),
                    handleToReset.prevValue
                )
            }
        }
        var processInfo: PROCESS_INFORMATION = PROCESS_INFORMATION()
        var createProcessFlags = self.generateCreateProcessFlag()
        // Give calling process a chance to modify flag and startup info
        if let configurator = self.platformOptions.preSpawnProcessConfigurator {
            try configurator(&createProcessFlags, &startupInfo)
        }
        // Spawn (featuring pyamid!)
        try userInfo.username.withCString(
            encodedAs: UTF16.self
        ) { usernameW in
            try userInfo.password.withCString(
                encodedAs: UTF16.self
            ) { passwordW in
                try userInfo.domain.withOptionalCString(
                    encodedAs: UTF16.self
                ) { domainW in
                    try applicationName.withOptionalNTPathRepresentation { applicationNameW in
                        try commandAndArgs.withNTPathRepresentation { commandAndArgsW in
                            try environment.withCString(
                                encodedAs: UTF16.self
                            ) { environmentW in
                                try intendedWorkingDir.withNTPathRepresentation { intendedWorkingDirW in
                                    let created = CreateProcessWithLogonW(
                                        usernameW,
                                        domainW,
                                        passwordW,
                                        DWORD(LOGON_WITH_PROFILE),
                                        applicationNameW,
                                        UnsafeMutablePointer<WCHAR>(mutating: commandAndArgsW),
                                        createProcessFlags,
                                        UnsafeMutableRawPointer(mutating: environmentW),
                                        intendedWorkingDirW,
                                        &startupInfo,
                                        &processInfo
                                    )
                                    guard created else {
                                        try self.cleanupAll(
                                            input: input,
                                            output: output,
                                            error: error
                                        )
                                        throw CocoaError.windowsError(
                                            underlying: GetLastError(),
                                            errorCode: .fileWriteUnknown
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        // Close parent side
        self.closeParentSide(
            withInput: input,
            output: output,
            error: error
        )
        // We don't need hThread object, so close it right away
        guard CloseHandle(processInfo.hThread) else {
            try self.cleanupAll(
                input: input,
                output: output,
                error: error
            )
            throw CocoaError.windowsError(
                underlying: GetLastError(),
                errorCode: .fileReadUnknown
            )
        }
        let pid = Subprocess.ProcessIdentifier(
            processID: processInfo.dwProcessId,
            threadID: processInfo.dwThreadId,
            processHandle: processInfo.hProcess
        )
        return Subprocess(
            processIdentifier: pid,
            executionInput: input,
            executionOutput: output,
            executionError: error,
            consoleBehavior: self.platformOptions.consoleBehavior
        )
    }
}

// MARK: - Platform Specific Options
extension Subprocess {
    public struct PlatformOptions: Sendable {
        public struct UserInfo: Sendable {
            public var username: String
            public var password: String
            public var domain: String?
        }

        public enum ConsoleBehavior: Sendable {
            case createNew
            case detatch
            case inherit
        }

        public enum WindowStyle: Sendable {
            case normal
            case hidden
            case maximized
            case minimized

            var platformStyle: WORD {
                switch self {
                case .hidden: return WORD(SW_HIDE)
                case .maximized: return WORD(SW_SHOWMAXIMIZED)
                case .minimized: return WORD(SW_SHOWMINIMIZED)
                default: return WORD(SW_SHOWNORMAL)
                }
            }
        }

        // Sets user info when starting the process
        public var userInfo: UserInfo? = nil
        // What's the console behavior of the new process,
        // default to inheriting the console from parent process
        public var consoleBehavior: ConsoleBehavior = .inherit
        // Window state to use when the process is started
        public var windowStyle: WindowStyle = .normal
        // Whether to create a new process group for the new
        // process. The process group includes all processes
        // that are descendants of this root process.
        // The process identifier of the new process group
        // is the same as the process identifier.
        public var createProcessGroup: Bool = false

        public var preSpawnProcessConfigurator: (@Sendable (inout DWORD, inout STARTUPINFOW) throws -> Void)? = nil

        public static var `default`: Self {
            return .init(
                userInfo: nil,
                consoleBehavior: .inherit,
                windowStyle: .normal,
                createProcessGroup: false,
                preSpawnProcessConfigurator: nil
            )
        }
    }
}

// MARK: - Process Monitoring
@Sendable
internal func monitorProcessTermination(
    forProcessWithIdentifier pid: Subprocess.ProcessIdentifier
) async -> Subprocess.TerminationStatus {
    // Once the continuation resumes, it will need to unregister the wait, so
    // yield the wait handle back to the calling scope.
    var waitHandle: HANDLE?
    defer {
        if let waitHandle {
            _ = UnregisterWait(waitHandle)
        }
    }

    try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        // Set up a callback that immediately resumes the continuation and does no
        // other work.
        let context = Unmanaged.passRetained(continuation as AnyObject).toOpaque()
        let callback: WAITORTIMERCALLBACK = { context, _ in
            let continuation = Unmanaged<AnyObject>.fromOpaque(context!).takeRetainedValue() as! CheckedContinuation<Void, any Error>
            continuation.resume()
        }

        // We only want the callback to fire once (and not be rescheduled.) Waiting
        // may take an arbitrarily long time, so let the thread pool know that too.
        let flags = ULONG(WT_EXECUTEONLYONCE | WT_EXECUTELONGFUNCTION)
        guard RegisterWaitForSingleObject(
            &waitHandle, pid.processHandle, callback, context, INFINITE, flags
        ) else {
            continuation.resume(throwing: CocoaError.windowsError(
                underlying: GetLastError(),
                errorCode: .fileWriteUnknown)
            )
            return
        }
    }

    var status: DWORD = 0
    guard GetExitCodeProcess(pid.processHandle, &status) else {
        // The child process terminated but we couldn't get its status back.
        // Assume generic failure.
        return .exited(1)
    }
    // Close the handle now we are finished monitoring
    _ = CloseHandle(pid.processHandle)
    let exitCodeValue = CInt(bitPattern: .init(status))
    if exitCodeValue >= 0 {
        return .exited(status)
    } else {
        return .unhandledException(status)
    }
}

// MARK: - Console Control Events
extension Subprocess {
    public struct ConsoleControlEvent: Hashable, Sendable {
        public let rawValue: DWORD

        private init(rawValue: DWORD) {
            self.rawValue = rawValue
        }

        public static let controlC: Self = .init(rawValue: DWORD(CTRL_C_EVENT))
        public static let controlBreak: Self = .init(rawValue: DWORD(CTRL_BREAK_EVENT))
    }

    public func sendConsoleControlEvent(_ event: ConsoleControlEvent) throws {
        try self.withRestoringConsole {
            guard GenerateConsoleCtrlEvent(
                event.rawValue, self.processIdentifier.processID
            ) else {
                throw CocoaError.windowsError(
                    underlying: GetLastError(),
                    errorCode: .fileWriteUnknown
                )
            }
        }
    }

    internal func tryTerminate() -> Error? {
        do {
            try self.sendConsoleControlEvent(.controlC)
        } catch {
            return error
        }
        return nil
    }

    private func withRestoringConsole(
        _ work: () throws -> Void
    ) throws {
        switch self.consoleBehavior {
        case .inherit:
            // Easy case: we share the same console as child process
            try work()
        case .createNew:
            // The child process has a different console. We need to
            // save the current console and restore later.
            let stdin: HANDLE = GetStdHandle(STD_INPUT_HANDLE)
            let stdout: HANDLE = GetStdHandle(STD_OUTPUT_HANDLE)
            let stderr: HANDLE = GetStdHandle(STD_ERROR_HANDLE)

            // On Windows:
            // If the function fails, the return value is zero.
            guard FreeConsole() else {
                throw CocoaError.windowsError(
                    underlying: GetLastError(),
                    errorCode: .fileReadUnknown
                )
            }
            // Attach to child process' console
            guard AttachConsole(self.processIdentifier.processID) else {
                throw CocoaError.windowsError(
                    underlying: GetLastError(),
                    errorCode: .fileReadUnknown
                )
            }
            // Finally, work
            try work()
            // Detach from child's console
            guard FreeConsole() else {
                throw CocoaError.windowsError(
                    underlying: GetLastError(),
                    errorCode: .fileReadUnknown
                )
            }
            // Create a new console and reset the stdin/out/err
            guard AllocConsole() else {
                throw CocoaError.windowsError(
                    underlying: GetLastError(),
                    errorCode: .fileWriteUnknown
                )
            }
            SetStdHandle(STD_OUTPUT_HANDLE, stdin);
            SetStdHandle(STD_INPUT_HANDLE, stdout);
            SetStdHandle(STD_ERROR_HANDLE, stderr);
        case .detatch:
            throw CocoaError(.featureUnsupported)
        }
    }
}

// MARK: - Executable Searching
extension Subprocess.Executable {
    // Technically not needed for CreateProcess since
    // it takes process name. It's here to support
    // Executable.resolveExecutablePath
    internal func resolveExecutablePath(withPathValue pathValue: String?) -> String? {
        switch self.storage {
        case .executable(let executableName):
            return executableName.withCString(
                encodedAs: UTF16.self
            ) { exeName -> String? in
                return pathValue.withOptionalCString(
                    encodedAs: UTF16.self
                ) { path -> String? in
                    let pathLenth = SearchPathW(
                        path,
                        exeName,
                        nil, 0, nil, nil
                    )
                    guard pathLenth > 0 else {
                        return nil
                    }
                    return withUnsafeTemporaryAllocation(
                        of: WCHAR.self, capacity: Int(pathLenth) + 1
                    ) {
                        _ = SearchPathW(
                            path,
                            exeName, nil,
                            pathLenth + 1,
                            $0.baseAddress, nil
                        )
                        return String(decodingCString: $0.baseAddress!, as: UTF16.self)
                    }
                }
            }
        case .path(let executablePath):
            // Use path directly
            return executablePath.string
        }
    }
}

// MARK: - Environment Resolution
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
}

// MARK: - ProcessIdentifier
extension Subprocess {
    public struct ProcessIdentifier: Sendable, Hashable {
        let processID: DWORD
        let threadID: DWORD
        internal let processHandle: HANDLE

        internal init(
            processID: DWORD,
            threadID: DWORD,
            processHandle: HANDLE
        ) {
            self.processID = processID
            self.threadID = threadID
            self.processHandle = processHandle
        }
    }
}

// MARK: - Private Utils
extension Subprocess.Configuration {
    private func preSpawn() throws -> (
        applicationName: String?,
        commandAndArgs: String,
        environment: String,
        intendedWorkingDir: String
    ) {
        // Prepare environment
        var env: [String : String] = [:]
        switch self.environment.config {
        case .custom(let customValues):
            // Use the custom values directly
            for customKey in customValues.keys {
                guard case .string(let stringKey) = customKey,
                      let valueContainer = customValues[customKey],
                      case .string(let stringValue) = valueContainer else {
                    fatalError("Windows does not support non unicode String as environments")
                }
                env.updateValue(stringValue, forKey: stringKey)
            }
        case .inherit(let updateValues):
            // Combine current environment
            env = ProcessInfo.processInfo.environment
            for updatingKey in updateValues.keys {
                // Override the current environment values
                guard case .string(let stringKey) = updatingKey,
                      let valueContainer = updateValues[updatingKey],
                      case .string(let stringValue) = valueContainer else {
                    fatalError("Windows does not support non unicode String as environments")
                }
                env.updateValue(stringValue, forKey: stringKey)
            }
        }
        // On Windows, the PATH is required in order to locate dlls needed by
        // the process so we should also pass that to the child
        let pathVariableName = Subprocess.Environment.pathEnvironmentVariableName
        if env[pathVariableName] == nil,
           let parentPath = ProcessInfo.processInfo.environment[pathVariableName] {
            env[pathVariableName] = parentPath
        }
        // The environment string must be terminated by a double
        // null-terminator.  Otherwise, CreateProcess will fail with
        // INVALID_PARMETER.
        let environmentString = env.map {
            $0.key + "=" + $0.value
        }.joined(separator: "\0") + "\0\0"

        // Prepare arguments
        let (applicationName, commandAndArgs) = generateWindowsCommandAndAgruments()
        // Validate workingDir
        guard Self.pathAccessible(self.workingDirectory.string) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                .debugDescriptionErrorKey : "Failed to set working directory to \(self.workingDirectory)"
            ])
        }
        return (
            applicationName: applicationName,
            commandAndArgs: commandAndArgs,
            environment: environmentString,
            intendedWorkingDir: self.workingDirectory.string
        )
    }

    private func generateCreateProcessFlag() -> DWORD {
        var flags = CREATE_UNICODE_ENVIRONMENT
        switch self.platformOptions.consoleBehavior {
        case .createNew:
            flags |= CREATE_NEW_CONSOLE
        case .detatch:
            flags |= DETACHED_PROCESS
        case .inherit:
            break
        }
        if self.platformOptions.createProcessGroup {
            flags |= CREATE_NEW_PROCESS_GROUP
        }
        return DWORD(flags)
    }

    private func generateStartupInfo(
        withInput input: Subprocess.ExecutionInput,
        output: Subprocess.ExecutionOutput,
        error: Subprocess.ExecutionOutput
    ) throws -> (
        info: STARTUPINFOW,
        handlesToReset: [(handle: HANDLE, prevValue: DWORD)]
    ) {
        var info: STARTUPINFOW = STARTUPINFOW()
        info.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
        info.dwFlags = DWORD(STARTF_USESTDHANDLES)
        if self.platformOptions.windowStyle != .normal {
            info.wShowWindow = self.platformOptions.windowStyle.platformStyle
            info.dwFlags |= DWORD(STARTF_USESHOWWINDOW)
        }
        // Bind IOs
        var handlesToReset: [(handle: HANDLE, prevValue: DWORD)] = []

        func deferReset(handle: HANDLE) throws {
            var handleInfo: DWORD = 0
            guard GetHandleInformation(handle, &handleInfo) else {
                try self.cleanupAll(
                    input: input,
                    output: output,
                    error: error
                )
                throw CocoaError.windowsError(
                    underlying: GetLastError(),
                    errorCode: .fileReadUnknown
                )
            }
            handlesToReset.append((handle: handle, prevValue: handleInfo & DWORD(HANDLE_FLAG_INHERIT)))
        }

        if let inputRead = input.getReadFileDescriptor() {
            let readHandle = inputRead.platformDescriptor
            info.hStdInput = readHandle
            try deferReset(handle: readHandle)
            SetHandleInformation(
                readHandle,
                DWORD(HANDLE_FLAG_INHERIT),
                0
            )
        }

        if let outputWrite = output.getWriteFileDescriptor() {
            let writeHandle = outputWrite.platformDescriptor
            info.hStdOutput = writeHandle
            try deferReset(handle: writeHandle)
            SetHandleInformation(
                writeHandle,
                DWORD(HANDLE_FLAG_INHERIT),
                0
            )
        }
        if let errorWrite = error.getWriteFileDescriptor() {
            let errorHandle = errorWrite.platformDescriptor
            info.hStdError = errorHandle
            try deferReset(handle: errorHandle)
            SetHandleInformation(
                errorHandle,
                DWORD(HANDLE_FLAG_INHERIT),
                0
            )
        }
        return (
            info: info,
            handlesToReset: handlesToReset
        )
    }

    private func generateWindowsCommandAndAgruments() -> (
        applicationName: String?,
        commandAndArgs: String
    ) {
        // CreateProcess accepts partial names
        let executableNameOrPath: String
        switch self.executable.storage {
        case .path(let path):
            executableNameOrPath = path.string
        case .executable(let name):
            executableNameOrPath = name
        }
        var args = self.arguments.storage.map {
            guard case .string(let stringValue) = $0 else {
                // We should never get here since the API
                // is guaded off
                fatalError("Windows does not support non unicode String as arguments")
            }
            return stringValue
        }
        // The first parameter of CreateProcessW, `lpApplicationName`
        // is optional. If it's nil, CreateProcessW uses argument[0]
        // as the execuatble name.
        // We should only set lpApplicationName if it's different from
        // argument[0] (i.e. executablePathOverride)
        var applicationName: String? = nil
        if case .string(let overrideName) = self.arguments.executablePathOverride {
            // Use the override as argument0 and set applicationName
            args.insert(overrideName, at: 0)
            applicationName = executableNameOrPath
        } else {
            // Set argument[0] to be executableNameOrPath
            args.insert(executableNameOrPath, at: 0)
        }
        return (
            applicationName: applicationName,
            commandAndArgs: self.quoteWindowsCommandLine(args)
        )
    }

    private func closeParentSide(
        withInput input: Subprocess.ExecutionInput,
        output: Subprocess.ExecutionOutput,
        error: Subprocess.ExecutionOutput
    ) {
        if let inputWrite = input.getWriteFileDescriptor() {
            try? inputWrite.close()
        }
        if let outputRead = output.getReadFileDescriptor() {
            try? outputRead.close()
        }
        if let errorRead = error.getReadFileDescriptor() {
            try? errorRead.close()
        }
    }

    // Taken from SCF
    private func quoteWindowsCommandLine(_ commandLine: [String]) -> String {
        func quoteWindowsCommandArg(arg: String) -> String {
            // Windows escaping, adapted from Daniel Colascione's "Everyone quotes
            // command line arguments the wrong way" - Microsoft Developer Blog
            if !arg.contains(where: {" \t\n\"".contains($0)}) {
                return arg
            }

            // To escape the command line, we surround the argument with quotes. However
            // the complication comes due to how the Windows command line parser treats
            // backslashes (\) and quotes (")
            //
            // - \ is normally treated as a literal backslash
            //     - e.g. foo\bar\baz => foo\bar\baz
            // - However, the sequence \" is treated as a literal "
            //     - e.g. foo\"bar => foo"bar
            //
            // But then what if we are given a path that ends with a \? Surrounding
            // foo\bar\ with " would be "foo\bar\" which would be an unterminated string

            // since it ends on a literal quote. To allow this case the parser treats:
            //
            // - \\" as \ followed by the " metachar
            // - \\\" as \ followed by a literal "
            // - In general:
            //     - 2n \ followed by " => n \ followed by the " metachar
            //     - 2n+1 \ followed by " => n \ followed by a literal "
            var quoted = "\""
            var unquoted = arg.unicodeScalars

            while !unquoted.isEmpty {
                guard let firstNonBackslash = unquoted.firstIndex(where: { $0 != "\\" }) else {
                    // String ends with a backslash e.g. foo\bar\, escape all the backslashes
                    // then add the metachar " below
                    let backslashCount = unquoted.count
                    quoted.append(String(repeating: "\\", count: backslashCount * 2))
                    break
                }
                let backslashCount = unquoted.distance(from: unquoted.startIndex, to: firstNonBackslash)
                if (unquoted[firstNonBackslash] == "\"") {
                    // This is  a string of \ followed by a " e.g. foo\"bar. Escape the
                    // backslashes and the quote
                    quoted.append(String(repeating: "\\", count: backslashCount * 2 + 1))
                    quoted.append(String(unquoted[firstNonBackslash]))
                } else {
                    // These are just literal backslashes
                    quoted.append(String(repeating: "\\", count: backslashCount))
                    quoted.append(String(unquoted[firstNonBackslash]))
                }
                // Drop the backslashes and the following character
                unquoted.removeFirst(backslashCount + 1)
            }
            quoted.append("\"")
            return quoted
        }
        return commandLine.map(quoteWindowsCommandArg).joined(separator: " ")
    }

    private static func pathAccessible(_ path: String) -> Bool {
        return path.withCString(encodedAs: UTF16.self) {
            let attrs = GetFileAttributesW($0)
            return attrs != INVALID_FILE_ATTRIBUTES
        }
    }
}

// MARK: - PlatformFileDescriptor Type
extension Subprocess {
    internal typealias PlatformFileDescriptor = HANDLE
}

// MARK: - Read Buffer Size
extension Subprocess {
    @inline(__always)
    internal static var readBufferSize: Int {
        // FIXME: Use Platform.pageSize here
        var sysInfo: SYSTEM_INFO = SYSTEM_INFO()
        GetSystemInfo(&sysInfo)
        return Int(sysInfo.dwPageSize)
    }
}

// MARK: - Pipe Support
extension FileDescriptor {
    internal static func pipe() throws -> (
        readEnd: FileDescriptor,
        writeEnd: FileDescriptor
    ) {
        var saAttributes: SECURITY_ATTRIBUTES = SECURITY_ATTRIBUTES()
        saAttributes.nLength = DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size)
        saAttributes.bInheritHandle = true
        saAttributes.lpSecurityDescriptor = nil

        var readHandle: HANDLE? = nil
        var writeHandle: HANDLE? = nil
        guard CreatePipe(&readHandle, &writeHandle, &saAttributes, 0),
              readHandle != INVALID_HANDLE_VALUE,
              writeHandle != INVALID_HANDLE_VALUE,
           let readHandle: HANDLE = readHandle,
           let writeHandle: HANDLE = writeHandle else {
            throw CocoaError.windowsError(
                underlying: GetLastError(),
                errorCode: .fileReadUnknown
            )
        }
        let readFd = _open_osfhandle(
            intptr_t(bitPattern: readHandle),
            FileDescriptor.AccessMode.readOnly.rawValue
        )
        let writeFd = _open_osfhandle(
            intptr_t(bitPattern: writeHandle),
            FileDescriptor.AccessMode.writeOnly.rawValue
        )

        return (
            readEnd: FileDescriptor(rawValue: readFd),
            writeEnd: FileDescriptor(rawValue: readFd)
        )
    }

    internal static func openDevNull(
        withAcessMode mode: FileDescriptor.AccessMode
    ) throws -> FileDescriptor {
        return try "NUL".withPlatformString {
            let handle = CreateFileW(
                $0,
                DWORD(GENERIC_WRITE),
                DWORD(FILE_SHARE_WRITE),
                nil,
                DWORD(OPEN_EXISTING),
                DWORD(FILE_ATTRIBUTE_NORMAL),
                nil
            )
            guard let handle = handle,
                  handle != INVALID_HANDLE_VALUE else {
                throw CocoaError.windowsError(
                    underlying: GetLastError(),
                    errorCode: .fileReadUnknown
                )
            }
            let devnull = _open_osfhandle(
                intptr_t(bitPattern: handle),
                mode.rawValue
            )
            return FileDescriptor(rawValue: devnull)
        }
    }

    var platformDescriptor: Subprocess.PlatformFileDescriptor {
        return HANDLE(bitPattern: _get_osfhandle(self.rawValue))!
    }
}

extension String {
    static let debugDescriptionErrorKey = "DebugDescription"
}

// MARK: - CocoaError + Win32
internal let NSUnderlyingErrorKey = "NSUnderlyingError"

extension CocoaError {
    static func windowsError(underlying: DWORD, errorCode: Code) -> CocoaError {
        let userInfo = [
            NSUnderlyingErrorKey : Win32Error(underlying)
        ]
        return CocoaError(errorCode, userInfo: userInfo)
    }
}

private extension Optional where Wrapped == String {
    func withOptionalCString<Result, Encoding>(
        encodedAs targetEncoding: Encoding.Type,
        _ body: (UnsafePointer<Encoding.CodeUnit>?) throws -> Result
    ) rethrows -> Result where Encoding : _UnicodeEncoding {
        switch self {
        case .none:
            return try body(nil)
        case .some(let value):
            return try value.withCString(encodedAs: targetEncoding, body)
        }
    }

    func withOptionalNTPathRepresentation<Result>(
        _ body: (UnsafePointer<WCHAR>?) throws -> Result
    ) throws -> Result {
        switch self {
        case .none:
            return try body(nil)
        case .some(let value):
            return try value.withNTPathRepresentation(body)
        }
    }
}

// MARK: - Remove these when merging back to SwiftFoundation
extension String {
    internal func withNTPathRepresentation<Result>(
        _ body: (UnsafePointer<WCHAR>) throws -> Result
    ) throws -> Result {
        guard !isEmpty else {
            throw CocoaError(.fileReadInvalidFileName)
        }

        var iter = self.utf8.makeIterator()
        let bLeadingSlash = if [._slash, ._backslash].contains(iter.next()), iter.next()?.isLetter ?? false, iter.next() == ._colon { true } else { false }

        // Strip the leading `/` on a RFC8089 path (`/[drive-letter]:/...` ).  A
        // leading slash indicates a rooted path on the drive for the current
        // working directory.
        return try Substring(self.utf8.dropFirst(bLeadingSlash ? 1 : 0)).withCString(encodedAs: UTF16.self) { pwszPath in
            // 1. Normalize the path first.
            let dwLength: DWORD = GetFullPathNameW(pwszPath, 0, nil, nil)
            return try withUnsafeTemporaryAllocation(of: WCHAR.self, capacity: Int(dwLength)) {
                guard GetFullPathNameW(pwszPath, DWORD($0.count), $0.baseAddress, nil) > 0 else {
                    throw CocoaError.windowsError(
                        underlying: GetLastError(),
                        errorCode: .fileReadUnknown
                    )
                }

                // 2. Perform the operation on the normalized path.
                return try body($0.baseAddress!)
            }
        }
    }
}

struct Win32Error: Error {
    public typealias Code = DWORD
    public let code: Code

    public static var errorDomain: String {
        return "NSWin32ErrorDomain"
    }

    public init(_ code: Code) {
        self.code = code
    }
}

internal extension UInt8 {
    static var _slash: UInt8 { UInt8(ascii: "/") }
    static var _backslash: UInt8 { UInt8(ascii: "\\") }
    static var _colon: UInt8 { UInt8(ascii: ":") }

    var isLetter: Bool? {
        return (0x41 ... 0x5a) ~= self || (0x61 ... 0x7a) ~= self
    }
}

#endif // canImport(WinSDK)
