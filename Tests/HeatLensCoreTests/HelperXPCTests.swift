import Foundation
import Testing
@testable import HeatLensCore

/// One process whose CPU time grows each call; counts calls.
private final class CountingProcessSampler: ProcessSampling, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int { lock.withLock { calls } }

    func snapshot() throws -> ProcessCounters {
        let call = lock.withLock { calls += 1; return calls }
        let base = HelperFixtures.base
        let start = Int64(base.timeIntervalSince1970 * 1_000_000) - 3_600_000_000
        let process = ProcessReading(identity: ProcessIdentity(pid: 10, startTimeMicros: start), parentPID: 1, owner: .currentUser,
                                     name: "proc-10", cpu: CPUTime(userNanoseconds: UInt64(call) * 10_000_000, systemNanoseconds: 0),
                                     residentBytes: 64 << 20, footprintBytes: 64 << 20, detailAccess: .available)
        return ProcessCounters(monotonicNanoseconds: UInt64(call) * 1_000_000_000,
                               wallClock: base.addingTimeInterval(TimeInterval(call)), processes: [process])
    }
}

/// A quiet host whose used memory goes 50%, 10%, 50%… per tick, so a memory rule at 40% (clears
/// below 30%, no sustain, clear or cooldown) fires every other tick.
private final class AlternatingSystemSampler: SystemSampling, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func counters() -> HostCounters {
        HostCounters(perCore: [CPULoadTicks(user: 0, system: 0, idle: 0, nice: 0)], swapOuts: 0)
    }

    func state() async throws -> HostState {
        let call = lock.withLock { calls += 1; return calls }
        return HostState(coreCount: 1, totalBytes: 1 << 30, freeBytes: 0, activeBytes: 0, inactiveBytes: 0, wiredBytes: 0,
                         compressedBytes: 0, swapUsedBytes: 0, swapTotalBytes: 0, memoryAvailable: true, pressure: .normal,
                         availablePercent: call.isMultiple(of: 2) ? 90 : 50, thermalState: .nominal, pmset: nil)
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_900_000_000)

    var now: @Sendable () -> Date {
        { [self] in lock.withLock { date } }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { date = date.addingTimeInterval(seconds) }
    }
}

private final class Log<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element] = []

    func append(_ item: Element) {
        lock.withLock { items.append(item) }
    }

    var all: [Element] { lock.withLock { items } }
}

/// `NSXPCListenerEndpoint` isn't `Sendable`; it's only handed to new connections.
private struct Endpoint: @unchecked Sendable {
    let endpoint: NSXPCListenerEndpoint

    func connection() -> NSXPCConnection {
        NSXPCConnection(listenerEndpoint: endpoint)
    }
}

/// A second of every wait or backoff takes a millisecond.
private let fastSleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .milliseconds($0)) }

/// A `HelperServer` on two anonymous listeners (no code-signing requirement), with fake samplers,
/// a hand-moved clock and its history in a temporary folder.
private final class Harness: @unchecked Sendable {
    let clock = Clock()
    let exits = Log<HelperServer.ExitReason>()
    let processes = CountingProcessSampler()
    let monitor: BackgroundMonitor
    let server: HelperServer
    let historyURL: URL
    private let folder: URL
    private let controlListener = NSXPCListener.anonymous()
    private let readListener = NSXPCListener.anonymous()
    private let controlDelegate: HelperListenerDelegate
    private let readDelegate: HelperListenerDelegate

    init(build: String = "100") {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("helper-xpc-\(UUID().uuidString)", isDirectory: true)
        historyURL = folder.appendingPathComponent("history.sqlite")
        let live = LiveMonitor(processSampler: processes, systemSampler: AlternatingSystemSampler(), sleep: fastSleep)
        monitor = BackgroundMonitor(monitor: live, now: clock.now)
        let exits = self.exits
        server = HelperServer(helperBuild: build, monitor: monitor, historyURL: historyURL, projectLocator: nil,
                              hardware: { _ in DisabledHardwareProvider() }, docker: { _ in DisabledDockerSampler() },
                              now: clock.now, sleep: fastSleep, onExit: { exits.append($0) })
        controlDelegate = HelperListenerDelegate(server: server, service: .control)
        readDelegate = HelperListenerDelegate(server: server, service: .read)
        controlListener.delegate = controlDelegate
        readListener.delegate = readDelegate
        controlListener.resume()
        readListener.resume()
    }

    var controlEndpoint: Endpoint { Endpoint(endpoint: controlListener.endpoint) }

    func client(build: String = "100") -> HelperClient {
        let endpoint = controlEndpoint
        return HelperClient(appBuild: build, timeout: 10, connect: { endpoint.connection() }, sleep: fastSleep)
    }

    func reader() -> HelperReadClient {
        let endpoint = Endpoint(endpoint: readListener.endpoint)
        return HelperReadClient(build: "100", timeout: 10) { endpoint.connection() }
    }

    /// A raw control connection, to send envelopes `HelperClient` never would.
    func rawControl() -> XPCPeer {
        let connection = controlEndpoint.connection()
        connection.remoteObjectInterface = NSXPCInterface(with: HelperControlXPC.self)
        connection.resume()
        return XPCPeer(connection, id: 0)
    }

    func finish() async {
        await monitor.pause()
        controlListener.invalidate()
        readListener.invalidate()
        try? FileManager.default.removeItem(at: folder)
    }
}

private func settings(keepHistory: Bool = false, mcp: Bool = false, alerts: AlertConfiguration = .off) -> BackgroundSettings {
    BackgroundSettings(alerts: alerts, keepHistory: keepHistory, mcpReadEnabled: mcp)
}

private let memoryAlerts = AlertConfiguration(isEnabled: true, rules: [AlertRule(kind: .memory, on: 0.4, off: 0.3, sustain: 0, clear: 0, cooldown: 0)])

private func collect(_ client: HelperClient, into log: Log<HelperClient.Event>) -> Task<Void, Never> {
    Task {
        for await event in client.events { log.append(event) }
    }
}

private func ticks(_ log: Log<HelperClient.Event>) -> Int {
    log.all.filter { if case .helper(.tick) = $0 { true } else { false } }.count
}

private func summaries(_ log: Log<HelperClient.Event>) -> [(status: BackgroundStatus, alerts: [HeatLensCore.Alert])] {
    log.all.compactMap { if case .helper(.summary(let status, let alerts, _)) = $0 { (status, alerts) } else { nil } }
}

private func connections(_ log: Log<HelperClient.Event>) -> Int {
    log.all.filter { if case .connected = $0 { true } else { false } }.count
}

private func eventually(_ seconds: Double = 5, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

private func caught(_ body: () async throws -> Void) async -> HelperFailure? {
    do {
        try await body()
        return nil
    } catch {
        return error as? HelperFailure
    }
}

@Suite("Helper XPC")
struct HelperXPCTests {
    @Test("hello answers the build, version and status; configure starts background sampling")
    func helloAndConfigure() async throws {
        let harness = Harness()
        let client = harness.client()
        let hello = try await client.connect()
        #expect(hello.helperBuild == "100")
        #expect(hello.protocolVersion == HelperProtocol.protocolVersion)
        #expect(hello.status.mode == .paused(.notConfigured))
        #expect(harness.processes.callCount == 0)

        try await client.configure(settings())
        #expect(try await client.status().mode == .background)
        #expect(await eventually { harness.processes.callCount >= 3 })
        try await client.setViewer(attached: true, interval: 5)
        #expect(try await client.status().mode == .foreground(5))
        try await client.setViewer(attached: false)
        #expect(try await client.status().mode == .background)
        guard case .invalidArgument = await caught({ try await client.setViewer(attached: true, interval: nil) }) else {
            Issue.record("a viewer without an interval was accepted")
            return
        }
        await client.disconnect()
        await harness.finish()
    }

    @Test("A .full subscription gets ticks; a .summary one gets only summaries, alerts included")
    func subscriptions() async throws {
        let harness = Harness()
        let full = harness.client()
        let summary = harness.client()
        let fullLog = Log<HelperClient.Event>()
        let summaryLog = Log<HelperClient.Event>()
        let collectors = [collect(full, into: fullLog), collect(summary, into: summaryLog)]
        try await full.connect()
        try await summary.connect()
        try await full.subscribe(.full)
        try await summary.subscribe(.summary)
        try await full.configure(settings(alerts: memoryAlerts))
        #expect(await eventually { ticks(fullLog) >= 3 })
        #expect(await eventually { summaries(summaryLog).contains { !$0.alerts.isEmpty } })
        #expect(ticks(summaryLog) == 0)
        #expect(!summaries(summaryLog).isEmpty)
        #expect(summaries(fullLog).contains { !$0.alerts.isEmpty })
        let alerts = try await summary.recentAlerts()
        #expect(!alerts.isEmpty)
        #expect(alerts.allSatisfy { $0.rule == .memory })
        #expect(try await summary.recentAlerts(since: alerts.last?.firedAt).isEmpty)

        // Switching .full → .summary keeps the viewer (the new subscription is made first).
        try await full.setViewer(attached: true, interval: 2)
        try await full.subscribe(.summary)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(try await full.status().mode == .foreground(2))
        let ticksSoFar = ticks(fullLog)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(ticks(fullLog) <= ticksSoFar + 1)

        collectors.forEach { $0.cancel() }
        await full.disconnect()
        await summary.disconnect()
        await harness.finish()
    }

    @Test("Reads answer .notRunning unless configured, sampling and the MCP switch is on; a read never changes the mode")
    func reads() async throws {
        let harness = Harness()
        let reader = harness.reader()
        #expect(try await reader.send(.liveStatus) == .notRunning(HelperProtocol.notRunningMessage))
        #expect(try await reader.send(.recentAlerts(limit: 5)) == .notRunning(HelperProtocol.notRunningMessage))
        #expect(try await reader.send(.explanations) == .notRunning(HelperProtocol.notRunningMessage))
        #expect(await harness.monitor.status.mode == .paused(.notConfigured))
        #expect(harness.processes.callCount == 0)

        let client = harness.client()
        try await client.connect()
        try await client.configure(settings(mcp: false))
        #expect(await eventually { harness.processes.callCount >= 2 })
        #expect(try await reader.send(.liveStatus) == .notRunning(HelperProtocol.notRunningMessage))

        try await client.configure(settings(mcp: true, alerts: memoryAlerts))
        guard case .liveStatus(let status) = try await reader.send(.liveStatus) else {
            Issue.record("no live status with the switch on")
            return
        }
        #expect(status.mode == .background)
        #expect(await eventually { await harness.monitor.recentAlerts().count >= 2 })
        guard case .recentAlerts(let alerts) = try await reader.send(.recentAlerts(limit: 1)) else {
            Issue.record("no alerts")
            return
        }
        #expect(alerts.count == 1)
        #expect(alerts.first == (await harness.monitor.recentAlerts()).last)
        guard case .explanations = try await reader.send(.explanations) else {
            Issue.record("no explanations")
            return
        }
        for limit in [0, -1, 51, Int.max] {
            guard case .failure(.invalidArgument) = try await reader.send(.recentAlerts(limit: limit)) else {
                Issue.record("limit \(limit) was accepted")
                continue
            }
        }
        #expect(await harness.monitor.status.mode == .background)

        try await client.pause()
        #expect(try await reader.send(.liveStatus) == .notRunning(HelperProtocol.notRunningMessage))
        #expect(await harness.monitor.status.mode == .paused(.user))
        await reader.close()
        await client.disconnect()
        await harness.finish()
    }

    @Test("A control envelope on the read service is refused and changes nothing")
    func controlOnReadRefused() async throws {
        let harness = Harness()
        let client = harness.client()
        try await client.connect()
        try await client.configure(settings(mcp: true))
        let reader = harness.reader()
        for request in [HelperControlRequest.pause, .shutdown, .deleteHistory, .recentAlerts(since: nil), .hello(appBuild: "100"),
                        .configure(settings())] {
            let reply = try HelperCodec.decode(HelperReadReply.self, from: try await reader.exchange(HelperCodec.encode(request, build: "100"))).body
            guard case .failure(.malformed) = reply else {
                Issue.record("\(request) on the read service got \(reply)")
                continue
            }
        }
        #expect(await harness.monitor.status.mode == .background)
        #expect(await harness.monitor.isSampling)
        #expect(harness.exits.all.isEmpty)
        await reader.close()
        await client.disconnect()
        await harness.finish()
    }

    @Test("Another build gets .restartRequired and the helper exits; another protocol version is refused")
    func versionSkew() async throws {
        let harness = Harness(build: "100")
        let client = harness.client(build: "101")
        #expect(await caught { try await client.connect() } == .restartRequired(helperBuild: "100"))
        #expect(await eventually { harness.exits.all == [.restartRequired] })
        #expect(await !client.isConnected)

        let other = Harness()
        let peer = other.rawControl()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let v2 = try encoder.encode(HelperEnvelope(protocolVersion: 2, build: "200", body: HelperControlRequest.hello(appBuild: "200")))
        let reply = try HelperCodec.decode(HelperControlReply.self, from: try await peer.send(v2, to: .control, timeout: 10)).body
        #expect(reply == .failure(.versionMismatch(received: 2, expected: 1)))
        #expect(await eventually { other.exits.all == [.restartRequired] })
        peer.connection.invalidate()
        await harness.finish()
        await other.finish()
    }

    @Test("Nothing but hello is answered before hello; junk is an error reply")
    func helloFirst() async throws {
        let harness = Harness()
        let peer = harness.rawControl()
        for request in [HelperControlRequest.status, .configure(settings()), .shutdown] {
            let reply = try HelperCodec.decode(HelperControlReply.self,
                                               from: try await peer.send(HelperCodec.encode(request, build: "100"), to: .control, timeout: 10)).body
            #expect(reply == .failure(.helloRequired), "\(request)")
        }
        let junk = try HelperCodec.decode(HelperControlReply.self, from: try await peer.send(Data("hello".utf8), to: .control, timeout: 10)).body
        guard case .failure(.malformed) = junk else {
            Issue.record("junk got \(junk)")
            return
        }
        #expect(await harness.monitor.status.mode == .paused(.notConfigured))
        #expect(harness.exits.all.isEmpty)
        peer.connection.invalidate()
        await harness.finish()
    }

    @Test("With no app for an hour after a crash, sampling pauses; the app's next hello resumes it")
    func orphanPause() async throws {
        let harness = Harness()
        let client = harness.client()
        try await client.connect()
        try await client.configure(settings())
        try await client.setViewer(attached: true, interval: 5)
        await client.disconnect()
        // A crash: the connection goes without pauseUntilAppOpens. Background cadence goes on.
        #expect(await eventually { await harness.monitor.status.mode == .background })
        harness.clock.advance(HelperServer.orphanLimit - 1)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(await harness.monitor.isSampling)

        harness.clock.advance(2)
        #expect(await eventually { await !harness.monitor.isSampling })
        let paused = harness.processes.callCount
        try? await Task.sleep(for: .milliseconds(100))
        #expect(harness.processes.callCount == paused)

        let again = harness.client()
        try await again.connect()
        #expect(await eventually { await harness.monitor.isSampling })
        #expect(await eventually { harness.processes.callCount > paused })
        await again.disconnect()
        await harness.finish()
    }

    @Test("pauseUntilAppOpens stops sampling with no orphan clock; the helper is then idle")
    func pauseUntilAppOpens() async throws {
        let harness = Harness()
        let client = harness.client()
        try await client.connect()
        try await client.configure(settings())
        #expect(await harness.monitor.isSampling)
        try await client.pauseUntilAppOpens()
        #expect(await !harness.monitor.isSampling)
        #expect(await !harness.server.isIdle())
        await client.disconnect()
        #expect(await eventually { await harness.server.isIdle() })
        harness.clock.advance(2 * HelperServer.orphanLimit)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await !harness.monitor.isSampling)

        let again = harness.client()
        try await again.connect()
        #expect(await eventually { await harness.monitor.isSampling })
        await again.disconnect()
        await harness.finish()
    }

    @Test("A lost connection reconnects and replays configure, the viewer and the subscription")
    func reconnectReplays() async throws {
        let harness = Harness()
        let client = harness.client()
        let log = Log<HelperClient.Event>()
        let collector = collect(client, into: log)
        try await client.connect()
        try await client.configure(settings())
        try await client.setViewer(attached: true, interval: 5)
        try await client.subscribe(.full)
        #expect(await eventually { ticks(log) >= 2 })

        await harness.server.dropControlConnections()
        #expect(await eventually { log.all.contains { if case .disconnected = $0 { true } else { false } } })
        #expect(await eventually { connections(log) == 2 })
        #expect(await client.isConnected)
        #expect(await harness.monitor.status.mode == .foreground(5))
        let before = ticks(log)
        #expect(await eventually { ticks(log) >= before + 2 })
        collector.cancel()
        await client.disconnect()
        await harness.finish()
    }

    @Test("recordActions lands in the store; saved actions, size and Delete history go through the helper")
    func history() async throws {
        let harness = Harness()
        let client = harness.client()
        try await client.connect()
        #expect(try await client.historySize() == 0)
        #expect(try await client.savedActions(since: .distantPast).isEmpty)
        #expect(try await client.historyWindow(since: .distantPast) == .empty)
        #expect(!FileManager.default.fileExists(atPath: harness.historyURL.path))

        try await client.configure(settings(keepHistory: true))
        try await client.recordActions([HelperFixtures.action])
        try await client.recordActions([HelperFixtures.action])
        #expect(try await client.savedActions(since: .distantPast) == [HelperFixtures.action])
        #expect(try await client.historySize() > 0)
        #expect(await eventually { (try? await client.historyWindow(since: .distantPast).points.isEmpty) == false })
        try await client.setRetention(days: 30)
        guard case .invalidArgument = await caught({ try await client.setRetention(days: 3) }) else {
            Issue.record("3 days was accepted")
            return
        }

        try await client.deleteHistory()
        #expect(!FileManager.default.fileExists(atPath: harness.historyURL.path))
        #expect(try await client.savedActions(since: .distantPast).isEmpty)
        await client.disconnect()
        await harness.finish()
    }

    @Test("shutdown stops sampling and the helper exits; the client doesn't reconnect")
    func shutdown() async throws {
        let harness = Harness()
        let client = harness.client()
        let log = Log<HelperClient.Event>()
        let collector = collect(client, into: log)
        try await client.connect()
        try await client.configure(settings(keepHistory: true))
        try await client.shutdown()
        #expect(await !harness.monitor.isSampling)
        #expect(await eventually { harness.exits.all == [.shutdown] })
        await harness.server.dropControlConnections()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(connections(log) == 1)
        collector.cancel()
        await client.disconnect()
        await harness.finish()
    }
}
