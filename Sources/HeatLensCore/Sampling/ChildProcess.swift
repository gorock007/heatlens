import Foundation

/// Runs one read-only tool (`ps`, `pmset`) by direct exec, never through a shell, and
/// collects its stdout. Cancelling the calling task sends SIGTERM to that child (ours, by
/// its PID) and still waits for it to exit, so a cancelled scan leaves no orphan. A child
/// that outlives its deadline is stopped the same way and reported as `TimedOut`.
enum ChildProcess {
    /// How long one run may take before it is cancelled.
    static let defaultDeadline: TimeInterval = 5

    struct Output: Sendable {
        let status: Int32
        let stdout: Data
    }

    struct LaunchError: Error, CustomStringConvertible {
        let description: String
    }

    /// The child was still running at its deadline; it has been SIGTERMed and has exited.
    struct TimedOut: Error, CustomStringConvertible {
        let executable: String
        let deadline: TimeInterval
        var description: String { "\(executable) did not finish within \(String(format: "%g", deadline)) s" }
    }

    /// `onLaunch` receives the child's PID right after it starts (tests use it to check cleanup).
    static func run(_ executable: String, _ arguments: [String], deadline: TimeInterval = defaultDeadline,
                    onLaunch: (@Sendable (Int32) -> Void)? = nil) async throws -> Output {
        let child = Child(executable: executable, arguments: arguments, deadline: deadline)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                child.start(onLaunch: onLaunch, continuation: continuation)
            }
        } onCancel: {
            child.cancel()
        }
    }

    /// Shared between the launching task, Foundation's termination callback and the
    /// cancellation handler; every mutable field is guarded by `lock`.
    private final class Child: @unchecked Sendable {
        private let lock = NSLock()
        private let process = Process()
        private let stdout = Pipe()
        private let deadline: TimeInterval
        private var launched = false
        private var cancelled = false
        private var timedOut = false
        private var finished = false
        private var collected = Data()

        init(executable: String, arguments: [String], deadline: TimeInterval) {
            self.deadline = deadline
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
        }

        func start(onLaunch: (@Sendable (Int32) -> Void)?, continuation: CheckedContinuation<Output, Error>) {
            // Finishes once both the process has exited and its stdout reached EOF.
            let done = DispatchGroup()
            done.enter()
            done.enter()
            process.terminationHandler = { _ in done.leave() }

            lock.lock()
            if cancelled {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            do {
                try process.run()
            } catch {
                lock.unlock()
                continuation.resume(throwing: LaunchError(description: "\(executable) could not launch: \(error.localizedDescription)"))
                return
            }
            launched = true
            lock.unlock()
            onLaunch?(process.processIdentifier)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + deadline) { self.expire() }

            let reader = stdout.fileHandleForReading
            DispatchQueue.global(qos: .utility).async {
                let data = reader.readDataToEndOfFile()
                self.lock.withLock { self.collected = data }
                done.leave()
            }
            done.notify(queue: .global(qos: .utility)) {
                let (wasCancelled, wasTimedOut, data) = self.lock.withLock {
                    self.finished = true
                    return (self.cancelled, self.timedOut, self.collected)
                }
                if wasCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if wasTimedOut {
                    continuation.resume(throwing: TimedOut(executable: self.executable, deadline: self.deadline))
                } else {
                    continuation.resume(returning: Output(status: self.process.terminationStatus, stdout: data))
                }
            }
        }

        func cancel() {
            lock.withLock {
                cancelled = true
                if launched, process.isRunning { process.terminate() }
            }
        }

        /// The deadline passed: stop our child, unless it already finished or was cancelled.
        private func expire() {
            lock.withLock {
                guard !finished, !cancelled else { return }
                timedOut = true
                if process.isRunning { process.terminate() }
            }
        }

        private var executable: String { process.executableURL?.path ?? "?" }
    }
}
