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

#if canImport(Darwin) || canImport(Glibc) || canImport(Bionic) || canImport(Musl)

#if canImport(Darwin)
import Darwin
#elseif canImport(Bionic)
import Bionic
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif


/// A step in the graceful shutdown teardown sequence.
/// It consists of a signal to send to the child process and the
/// duration allowed for the child process to exit before proceeding
/// to the next step.
public struct TeardownStep: Sendable, Hashable {
    internal enum Storage: Sendable, Hashable {
        case sendSignal(Signal, allowedDuration: Duration)
        case kill
    }
    var storage: Storage

    /// Sends `signal` to the process and allows `allowedDurationToExit`
    /// for the process to exit before proceeding to the next step.
    /// The final step in the sequence will always send a `.kill` signal.
    public static func send(
        signal: Signal,
        allowedDurationToNextStep: Duration
    ) -> Self {
        return Self(
            storage: .sendSignal(
                signal,
                allowedDuration: allowedDurationToNextStep
            )
        )
    }
}

#if canImport(Darwin) || canImport(Glibc) || canImport(Bionic) || canImport(Musl)
#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
extension Execution {
    /// Performs a sequence of teardown steps on the Subprocess.
    /// Teardown sequence always ends with a `.kill` signal
    /// - Parameter sequence: The  steps to perform.
    public func teardown(using sequence: some Sequence<TeardownStep> & Sendable) async {
        await withUncancelledTask {
            await self.runTeardownSequence(sequence)
        }
    }
}
#endif // canImport(Glibc) || canImport(Bionic) || canImport(Musl)

internal enum TeardownStepCompletion {
    case processHasExited
    case processStillAlive
    case killedTheProcess
}

#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
extension Execution {
    internal func runTeardownSequence(_ sequence: some Sequence<TeardownStep> & Sendable) async {
        // First insert the `.kill` step
        let finalSequence = sequence + [TeardownStep(storage: .kill)]
        for step in finalSequence {
            let stepCompletion: TeardownStepCompletion

            guard self.isAlive() else {
                return
            }

            switch step.storage {
            case .sendSignal(let signal, let allowedDuration):
                stepCompletion = await withTaskGroup(of: TeardownStepCompletion.self) { group in
                    group.addTask {
                        do {
                            try await Task.sleep(for: allowedDuration)
                            return .processStillAlive
                        } catch {
                            // teardown(using:) cancells this task
                            // when process has exited
                            return .processHasExited
                        }
                    }
                    try? self.send(signal: signal)
                    return await group.next()!
                }
            case .kill:
                try? self.send(signal: .kill)
                stepCompletion = .killedTheProcess
            }

            switch stepCompletion {
            case .killedTheProcess, .processHasExited:
                return
            case .processStillAlive:
                // Continue to next step
                break
            }
        }
    }
}

#if SubprocessSpan
@available(SubprocessSpan, *)
#endif
extension Execution {
    private func isAlive() -> Bool {
        return kill(self.processIdentifier.value, 0) == 0
    }
}

func withUncancelledTask<Result: Sendable>(
    returning: Result.Type = Result.self,
    _ body: @Sendable @escaping () async -> Result
) async -> Result {
    // This looks unstructured but it isn't, please note that we `await` `.value` of this task.
    // The reason we need this separate `Task` is that in general, we cannot assume that code performs to our
    // expectations if the task we run it on is already cancelled. However, in some cases we need the code to
    // run regardless -- even if our task is already cancelled. Therefore, we create a new, uncancelled task here.
    await Task {
        await body()
    }.value
}

#endif // canImport(Darwin) || canImport(Glibc) || canImport(Bionic) || canImport(Musl)
