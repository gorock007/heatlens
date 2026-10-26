import Foundation

/// Runs one read-only tool (`ps`, `pmset`) by direct exec, never through a shell, and
/// collects its stdout. Cancelling the calling task sends SIGTERM to that child (ours, by
/// its PID) and still waits for it to exit, so a cancelled scan leaves no orphan.
enum ChildProcess {
    struct Output: Sendable {
        let status: Int32
        let stdout: Data
    }

    struct LaunchError: Error, CustomStringConvertible {
        let description: String
    }

    /// `onLaunch` receives the child's PID right after it starts (tests use it to check cleanup).
    static func run(_ executable: String, _ arguments: [String],
                    onLaunch: (@Sendable (Int32) -> Void)? = nil) async throws -> Output {
        let child = Child(executable: executable, arguments: arguments)
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
        private var launched = false
        private var cancelled = false
        private var collected = Data()

        init(executable: String, arguments: [String]) {
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

            let reader = stdout.fileHandleForReading
            DispatchQueue.global(qos: .utility).async {
                let data = reader.readDataToEndOfFile()
                self.lock.withLock { self.collected = data }
                done.leave()
            }
            done.notify(queue: .global(qos: .utility)) {
                let (wasCancelled, data) = self.lock.withLock { (self.cancelled, self.collected) }
                if wasCancelled {
                    continuation.resume(throwing: CancellationError())
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

        private var executable: String { process.executableURL?.path ?? "?" }
    }
}
