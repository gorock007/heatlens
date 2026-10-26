import Darwin
import Foundation
import Testing
@testable import HeatLensCore

/// A child this test spawns. Every signal in this file goes to one of these, by its PID, and
/// only through `ProcessTerminator` or Foundation's `terminate()` on our own `Process`.
/// Stdin is a pipe: the `read`-based children exit when it closes, so `stop()` needs no signal,
/// and a crashed test run closes the pipe too.
final class FixtureChild {
    let process: Process
    let identity: ProcessIdentity
    private let stdin = Pipe()

    /// `waitForReadyLine`: wait for the child to print a line first (e.g. after it installs a trap).
    init(_ executable: String, _ arguments: [String], waitForReadyLine: Bool = false) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        let stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        try p.run()
        process = p
        if waitForReadyLine {
            var acc = Data()
            while !acc.contains(10) {
                let d = stdout.fileHandleForReading.availableData
                if d.isEmpty { break }
                acc.append(d)
            }
        }
        guard let identity = LibprocProcessSampler.identity(of: p.processIdentifier) else {
            try? stdin.fileHandleForWriting.close()
            p.waitUntilExit()
            throw FixtureError.noIdentity
        }
        self.identity = identity
    }

    /// `/bin/sh` that ignores SIGTERM and exits when stdin closes.
    static func ignoringSIGTERM() throws -> FixtureChild {
        try FixtureChild("/bin/sh", ["-c", "trap '' TERM; echo ready; read x"], waitForReadyLine: true)
    }

    /// `/bin/sh` that waits on stdin; closing it is how the test makes it exit.
    static func waitingOnStdin() throws -> FixtureChild {
        try FixtureChild("/bin/sh", ["-c", "echo ready; read x"], waitForReadyLine: true)
    }

    var isAlive: Bool { LibprocProcessSampler.identity(of: identity.pid) == identity && process.isRunning }

    /// Closes stdin; if the child is still around after that (e.g. `sleep`), SIGTERMs our own
    /// child through Foundation. Waits for it to be reaped.
    @discardableResult
    func stop() -> Bool {
        try? stdin.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < deadline { usleep(10_000) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        return waitUntilGone(identity)
    }

    enum FixtureError: Error { case noIdentity }
}

private func liveSample(_ child: FixtureChild) throws -> ProcessSample {
    guard case .same(let bsd) = ProcessTerminator.liveState(of: child.identity) else {
        throw FixtureChild.FixtureError.noIdentity
    }
    return ProcessTerminator.liveSample(child.identity, bsd: bsd)
}

@Suite("ProcessTerminator with fixture children", .serialized)
struct SafetyTerminatorTests {
    let terminator = ProcessTerminator()

    @Test("A sleep 60 child is eligible and stops on one SIGTERM")
    func stopsSleep() async throws {
        let child = try FixtureChild("/bin/sleep", ["60"])
        defer { child.stop() }
        #expect(terminator.eligibility(of: try liveSample(child)) == .eligible)

        let outcome = await terminator.requestStop(child.identity, wait: 3)
        #expect(outcome == .stopped)
        #expect(waitUntilGone(child.identity))
    }

    @Test("A child that ignores SIGTERM is .stillRunning and is not escalated")
    func ignoresSIGTERM() async throws {
        let child = try FixtureChild.ignoringSIGTERM()
        defer { child.stop() }

        let outcome = await terminator.requestStop(child.identity, wait: 0.5)
        #expect(outcome == .stillRunning)
        // Nothing stronger followed: the same instance is still alive a moment later.
        try await Task.sleep(for: .milliseconds(200))
        #expect(child.isAlive)

        #expect(child.stop())
    }

    @Test("A child that already exited is .alreadyExited")
    func alreadyExited() async throws {
        let child = try FixtureChild.waitingOnStdin()
        #expect(child.stop())

        let outcome = await terminator.requestStop(child.identity)
        #expect(outcome == .alreadyExited)
    }

    @Test("A wrong start time is .identityChanged, nothing is sent and the child lives")
    func identityChanged() async throws {
        let child = try FixtureChild.waitingOnStdin()
        defer { child.stop() }
        let impostor = ProcessIdentity(pid: child.identity.pid, startTimeMicros: child.identity.startTimeMicros - 1_000_000)

        let outcome = await terminator.requestStop(impostor)
        #expect(outcome == .identityChanged)
        try await Task.sleep(for: .milliseconds(200))
        #expect(child.isAlive)
    }

    @Test("Live revalidation denies an Apple binary, sends nothing, and the child lives")
    func revalidationDenies() async throws {
        // /usr/bin/head reads one line from our pipe, so closing it ends the child.
        let child = try FixtureChild("/usr/bin/head", ["-n", "1"])
        defer { child.stop() }

        let outcome = await terminator.requestStop(child.identity)
        guard case .denied(let reason) = outcome else {
            Issue.record("expected .denied, got \(outcome)")
            return
        }
        #expect(reason.contains("Apple"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(child.isAlive)
    }

    @Test("pid 1, pid 0 and a negative pid are refused before any lookup", arguments: [Int32(1), 0, -1])
    func refusesLowPIDs(pid: Int32) async {
        // A fake start time as a second guard: even a lookup could only report .identityChanged.
        let outcome = await terminator.requestStop(ProcessIdentity(pid: pid, startTimeMicros: 1))
        guard case .denied = outcome else {
            Issue.record("pid \(pid): expected .denied, got \(outcome)")
            return
        }
    }

    @Test("HeatLens never offers to stop itself, live")
    func refusesSelf() throws {
        let me = try #require(LibprocProcessSampler.identity(of: getpid()))
        guard case .same(let bsd) = ProcessTerminator.liveState(of: me) else {
            Issue.record("could not read own process")
            return
        }
        guard case .denied(let reason) = terminator.eligibility(of: ProcessTerminator.liveSample(me, bsd: bsd)) else {
            Issue.record("self was eligible")
            return
        }
        #expect(reason.contains("HeatLens itself"))
    }
}
