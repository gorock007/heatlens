import Darwin
import Foundation
import Testing
@testable import HeatLensCore

/// `yes >/dev/null` spawned by a test. The wrapping shell kills `yes` after 30 s, so a crashed
/// test run cannot leave it behind for long, and at once on SIGTERM. `stop()` signals only
/// that shell, our own child, by PID, then confirms the `yes` identity is gone. Every wait is
/// bounded: `waitUntilExit()` can miss the exit on a test's cooperative thread and hang.
final class BusyFixture {
    let shell: Process
    let shellIdentity: ProcessIdentity?
    let yesIdentity: ProcessIdentity
    var yesPID: Int32 { yesIdentity.pid }

    init() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "trap 'kill $y $s 2>/dev/null; exit 0' TERM; yes >/dev/null 2>&1 & y=$!; echo $y; "
                       + "sleep 30 & s=$!; wait $s; kill $y 2>/dev/null"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try p.run()
        shell = p
        shellIdentity = LibprocProcessSampler.identity(of: p.processIdentifier)
        var acc = Data()
        while !acc.contains(10) {
            let d = pipe.fileHandleForReading.availableData
            if d.isEmpty { break }
            acc.append(d)
        }
        let line = String(decoding: acc, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int32(line), let identity = LibprocProcessSampler.identity(of: pid) else {
            _ = terminateOwnChild(p, identity: shellIdentity)
            throw FixtureError.noPID(line)
        }
        yesIdentity = identity
    }

    /// true when both the shell and `yes` are confirmed gone.
    @discardableResult
    func stop() -> Bool {
        let shellGone = terminateOwnChild(shell, identity: shellIdentity)
        return waitUntilGone(yesIdentity) && shellGone
    }

    enum FixtureError: Error { case noPID(String) }
}

/// SIGTERMs `process`, a child this test spawned, only while the kernel still lists that exact
/// instance (so a reused pid is never hit), then waits up to `timeout` for it to go.
func terminateOwnChild(_ process: Process, identity: ProcessIdentity?, timeout: TimeInterval = 2) -> Bool {
    guard let identity else {
        // No identity to check against: never signal, just wait (bounded) for it to end.
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        return !process.isRunning
    }
    if process.isRunning, LibprocProcessSampler.identity(of: identity.pid) == identity { process.terminate() }
    return waitUntilGone(identity, timeout: timeout)
}

/// Polls (up to `timeout`) until no live process has this identity; never signals it.
func waitUntilGone(_ identity: ProcessIdentity, timeout: TimeInterval = 1) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while LibprocProcessSampler.identity(of: identity.pid) == identity {
        if Date() > deadline { return false }
        usleep(20_000)
    }
    return true
}

/// Thread-safe recorder for callbacks from sampler hooks.
final class Recorder<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ item: T) { lock.withLock { items.append(item) } }
    var values: [T] { lock.withLock { items } }
}

@Suite("PSTimeSampler parsing")
struct SamplerPSParsingTests {
    @Test("macOS TIME format: unbounded minutes, hundredths")
    func minutesSeconds() {
        #expect(PSTimeSampler.parseCPUTime("0:00.00") == 0)
        #expect(PSTimeSampler.parseCPUTime("0:28.32") == 28_320_000_000)
        #expect(PSTimeSampler.parseCPUTime("247:18.96") == (247 * 60 + 18) * 1_000_000_000 + 960_000_000)
    }

    @Test("hours and days forms are accepted")
    func hoursDays() {
        #expect(PSTimeSampler.parseCPUTime("1:02:03.04") == 3_723_040_000_000)
        #expect(PSTimeSampler.parseCPUTime("2-01:00:00") == (2 * 86_400 + 3_600) * 1_000_000_000)
    }

    @Test("garbage is rejected, not read as zero")
    func garbage() {
        for bad in ["", ":", "1:2:3:4", "ab:cd", "1:00.", "-1:00", "1:00.x"] {
            #expect(PSTimeSampler.parseCPUTime(bad) == nil, "\(bad)")
        }
    }

    @Test("rows: pid, cumulative CPU, RSS in KB; malformed lines skipped")
    func rows() {
        let text = """
            1  41:07.95  18560
          606   0:28.32  14880
          bad line
          777   x:yy      12
        """
        let rows = PSTimeSampler.parse(text)
        #expect(rows.count == 2)
        #expect(rows[1] == PSTimeSampler.Row(cpuNanoseconds: 2_467_950_000_000, residentBytes: 18_560 * 1024))
        #expect(rows[606]?.residentBytes == 14_880 * 1024)
    }
}

@Suite("Samplers against this Mac", .serialized)
struct SamplerLiveTests {
    @Test("libproc sampler reads own processes in full and marks root ones refused")
    func libprocOwners() throws {
        let counters = try LibprocProcessSampler().snapshot()
        let byPID = Dictionary(counters.processes.map { ($0.identity.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let me = try #require(byPID[getpid()])
        #expect(me.owner == .currentUser)
        #expect(me.detailAccess == .available)
        #expect(me.cpu != nil && me.arguments != nil && me.currentDirectory != nil && me.footprintBytes != nil)
        #expect(me.identity == LibprocProcessSampler.identity(of: getpid()))

        let launchd = try #require(byPID[1])
        #expect(launchd.owner == .root)
        #expect(launchd.detailAccess == .permissionDenied)
        #expect(launchd.cpu == nil && launchd.arguments == nil)
        #expect(byPID[0]?.detailAccess == .notSupported)
    }

    @Test("long names come from the executable when p_comm is cut at 16 bytes")
    func displayName() {
        #expect(LibprocProcessSampler.displayName(comm: "com.apple.Virtua", path: "/S/com.apple.Virtualization.VirtualMachine")
                == "com.apple.Virtualization.VirtualMachine")
        #expect(LibprocProcessSampler.displayName(comm: "launchd", path: "/sbin/launchd") == "launchd")
        #expect(LibprocProcessSampler.displayName(comm: "WindowServer", path: nil) == "WindowServer")
        #expect(LibprocProcessSampler.displayName(comm: "foo", path: "/bin/bar") == "foo")
    }

    @Test("real ps run reports root processes")
    func psRun() async throws {
        let reading = try await PSTimeSampler().snapshot()
        #expect(reading.rows[1] != nil)        // launchd
        #expect(reading.rows[0] == nil)        // ps never lists pid 0
        #expect(reading.rows.count > 100)
    }

    @Test("cancelling a running ps-style child terminates it and throws within ~1 s")
    func cancelChild() async throws {
        let launched = Recorder<ProcessIdentity>()
        let sampler = PSTimeSampler(executable: "/bin/sleep", arguments: ["30"]) { pid in
            if let identity = LibprocProcessSampler.identity(of: pid) { launched.append(identity) }
        }
        let task = Task { try await sampler.snapshot() }
        let deadline = Date().addingTimeInterval(3)
        while launched.values.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let child = try #require(launched.values.first)

        let cancelledAt = Date()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(cancelledAt) < 1)
        #expect(waitUntilGone(child))
    }

    @Test("a child past its deadline is stopped and reported as a ps failure, not a hang")
    func childDeadline() async throws {
        let launched = Recorder<ProcessIdentity>()
        let sampler = PSTimeSampler(executable: "/bin/sleep", arguments: ["30"], deadline: 1) { pid in
            if let identity = LibprocProcessSampler.identity(of: pid) { launched.append(identity) }
        }
        let startedAt = Date()
        do {
            _ = try await sampler.snapshot()
            Issue.record("a 30 s child finished inside a 1 s deadline")
        } catch let error as ChildProcess.TimedOut {
            #expect("\(error)" == "/bin/sleep did not finish within 1 s")
        }
        #expect(Date().timeIntervalSince(startedAt) < 3)
        #expect(waitUntilGone(try #require(launched.values.first)))
    }

    @Test("a pmset run past its deadline gives no pmset data and a notice")
    func pmsetDeadline() async throws {
        let sampler = HostSystemSampler(readsPmset: true, pmsetCommand: ("/bin/sleep", ["30"]), pmsetDeadline: 1)
        let startedAt = Date()
        let state = try await sampler.state()
        #expect(Date().timeIntervalSince(startedAt) < 3)
        #expect(state.pmset == nil)
        #expect(state.pmsetNotice == "pmset thermal data unavailable (/bin/sleep did not finish within 1 s).")
    }

    @Test("an already-cancelled task never launches the child")
    func preCancelled() async {
        let launched = Recorder<Int32>()
        let sampler = PSTimeSampler(executable: "/bin/sleep", arguments: ["30"]) { launched.append($0) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await sampler.snapshot()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(launched.values.isEmpty)
    }

    @Test("host sampler reads per-core ticks, memory and thermal state")
    func host() async throws {
        let sampler = HostSystemSampler()
        let counters = sampler.counters()
        #expect((counters.perCore?.count ?? 0) > 0)
        #expect(counters.swapOuts != nil)
        let state = try await sampler.state()
        #expect(state.memoryAvailable && state.totalBytes > 0)
        #expect(state.coreCount == counters.perCore?.count)
        #expect(state.pressure != .unknown)
        #expect(state.thermalState != .unavailable)
    }
}
