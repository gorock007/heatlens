import Darwin
import Foundation
import Testing
@testable import HeatLensCore

/// `BatchStop` with a fake stopper (nothing signalled), then once live through the real
/// `ProcessTerminator` against `sleep` children this test spawns itself.
@Suite("Batch stop", .serialized)
struct BatchStopTests {
    private struct Update: Equatable, Sendable {
        let index: Int
        let status: BatchStop.ItemStatus
    }

    private let ids = (1...4).map { ProcessIdentity(pid: Int32(10_000 + $0), startTimeMicros: Int64($0)) }

    @Test("Stops one at a time in order and reports each item's progress and outcome")
    func orderAndOutcomes() async {
        let calls = Recorder<ProcessIdentity>()
        let updates = Recorder<Update>()
        let outcomes: [ProcessIdentity: StopOutcome] = [
            ids[0]: .stopped, ids[1]: .identityChanged, ids[2]: .stillRunning, ids[3]: .alreadyExited,
        ]
        let batch = BatchStop { identity in
            calls.append(identity)
            return outcomes[identity] ?? .failed(errno: 0)
        }

        let result = await batch.run(ids) { index, status in updates.append(Update(index: index, status: status)) }

        #expect(calls.values == ids)
        #expect(result == [.finished(.stopped), .finished(.identityChanged), .finished(.stillRunning), .finished(.alreadyExited)])
        #expect(updates.values == [
            Update(index: 0, status: .stopping), Update(index: 0, status: .finished(.stopped)),
            Update(index: 1, status: .stopping), Update(index: 1, status: .finished(.identityChanged)),
            Update(index: 2, status: .stopping), Update(index: 2, status: .finished(.stillRunning)),
            Update(index: 3, status: .stopping), Update(index: 3, status: .finished(.alreadyExited)),
        ])
    }

    @Test("Each stop finishes before the next one starts")
    func sequential() async {
        let log = Recorder<String>()
        let batch = BatchStop { identity in
            log.append("start \(identity.pid)")
            try? await Task.sleep(for: .milliseconds(20))
            log.append("end \(identity.pid)")
            return .stopped
        }
        await batch.run(Array(ids.prefix(3)))
        #expect(log.values == ["start 10001", "end 10001", "start 10002", "end 10002", "start 10003", "end 10003"])
    }

    @Test("Cancelling lets the current item finish and leaves the rest not attempted")
    func cancellation() async throws {
        let calls = Recorder<ProcessIdentity>()
        let ids = self.ids
        let batch = BatchStop { identity in
            calls.append(identity)
            // Long enough for the test to cancel while the second item is in progress.
            if identity == ids[1] { try? await Task.sleep(for: .milliseconds(300)) }
            return .stopped
        }
        let run = Task { await batch.run(ids) }

        let deadline = Date().addingTimeInterval(5)
        while calls.values.count < 2 {
            try #require(Date() < deadline, "second stop never started")
            try await Task.sleep(for: .milliseconds(5))
        }
        run.cancel()
        let result = await run.value

        #expect(calls.values == Array(ids.prefix(2)))
        #expect(result == [.finished(.stopped), .finished(.stopped), .notAttempted, .notAttempted])
    }

    @Test("A run cancelled before it starts sends nothing")
    func cancelledUpFront() async {
        let calls = Recorder<ProcessIdentity>()
        let batch = BatchStop { identity in
            calls.append(identity)
            return .stopped
        }
        let run = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await batch.run(ids)
        }
        #expect(await run.value == Array(repeating: .notAttempted, count: 4))
        #expect(calls.values.isEmpty)
    }

    @Test("Live: three sleep children stop through ProcessTerminator; a wrong start time is skipped and lives")
    func live() async throws {
        var children: [FixtureChild] = []
        defer { children.forEach { $0.stop() } }
        for _ in 0..<4 { children.append(try FixtureChild("/bin/sleep", ["300"])) }

        let survivor = children[3]
        let impostor = ProcessIdentity(pid: survivor.identity.pid, startTimeMicros: survivor.identity.startTimeMicros - 1_000_000)
        // The impostor sits in the middle, so the run also shows it carries on past a skip.
        let targets = [children[0].identity, children[1].identity, impostor, children[2].identity]

        let terminator = ProcessTerminator()
        let result = await BatchStop { await terminator.requestStop($0, wait: 3) }.run(targets)

        #expect(result == [.finished(.stopped), .finished(.stopped), .finished(.identityChanged), .finished(.stopped)])
        for child in children.prefix(3) { #expect(waitUntilGone(child.identity)) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(survivor.isAlive)
    }
}
