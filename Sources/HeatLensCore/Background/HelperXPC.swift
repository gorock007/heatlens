import Foundation

// The background helper's XPC surfaces (docs/v2/ADR-0008 §2). One method per direction, each
// carrying a `HelperCodec` envelope, so NSSecureCoding only ever sees `NSData`. Nothing here
// registers or starts a helper: `heatlens-helper` (brief 4k) makes the two Mach-service listeners
// with their code-signing requirements and hands each connection to a `HelperServer`; tests use
// `NSXPCListener.anonymous()`.

/// The app's control service, exported by the helper.
@objc public protocol HelperControlXPC {
    func handle(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
}

/// The CLI's read-only service, exported by the helper. Decodes `HelperReadRequest` only.
@objc public protocol HelperReadXPC {
    func handle(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
}

/// Pushes, exported by the app on its control connection.
@objc public protocol HelperEventsXPC {
    func receive(_ event: Data)
}

/// Which of the helper's two services a connection came in on.
public enum HelperService: Sendable {
    case control
    case read
}

/// Hands each new connection on one listener to a `HelperServer`. `NSXPCListener.delegate` is
/// weak: keep this alive as long as the listener.
public final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate, Sendable {
    public let server: HelperServer
    public let service: HelperService

    public init(server: HelperServer, service: HelperService) {
        self.server = server
        self.service = service
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        server.accept(newConnection, service: service)
        return true
    }
}

// MARK: - Server

/// The helper's side (ADR-0008 §2–§4): control requests from the app go to one `BackgroundMonitor`
/// and the history store, reads from the CLI are answered only while configured, sampling and the
/// MCP switch is on, and with no app connected for an hour sampling pauses until the app opens.
/// It never signals anything, never writes to Docker and never posts notifications.
///
/// Each connection's messages are handled one at a time, in the order they arrived.
public actor HelperServer {
    public enum ExitReason: Sendable, Equatable {
        /// The app is a different build or protocol version: launchd starts the bundle's own
        /// binary on its next message.
        case restartRequired
        case shutdown
    }

    /// No app connected this long, after one was: pause until the app opens (owner decision 3).
    public static let orphanLimit: TimeInterval = 60 * 60
    static let orphanCheckInterval: TimeInterval = 60
    /// Between a reply that ends the helper and `onExit`, so the reply can leave first.
    public static let exitGrace: TimeInterval = 1
    /// Messages queued on one connection before more are answered `.busy`.
    static let inboxDepth = 64

    public nonisolated let helperBuild: String
    private let monitor: BackgroundMonitor
    private let historyURL: URL
    private let projectLocator: ProjectRootLocator?
    private let hardware: @Sendable (Bool) -> any HardwareSensorProviding
    private let docker: @Sendable (Bool) -> any DockerSampling
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let onExit: @Sendable (ExitReason) -> Void

    private struct Control {
        let peer: XPCPeer
        var greeted = false
        var subscription: Task<Void, Never>?
    }

    private var controls: [Int: Control] = [:]
    private var readers = 0
    private var nextConnection = 0
    private var settings: BackgroundSettings?
    private var retentionDays = HistoryStore.defaultRetentionDays
    private var store: HistoryStore?
    /// The store the running session writes to, so a reopened store restarts it.
    private var sessionStore: HistoryStore?
    /// Paused by `pauseUntilAppOpens`, `shutdown` or the orphan limit: the next `hello` resumes.
    private var heldForApp = false
    private var orphanSince: Date?
    private var orphanTimer: Task<Void, Never>?
    private var exiting = false

    /// - Parameter onExit: called once, `exitGrace` after the reply to a `hello` from another
    ///   build or a `shutdown`; the helper's `main` exits there.
    public init(helperBuild: String, monitor: BackgroundMonitor = BackgroundMonitor(),
                historyURL: URL = HistoryStore.defaultURL, projectLocator: ProjectRootLocator? = .shared,
                onExit: @escaping @Sendable (ExitReason) -> Void) {
        self.init(helperBuild: helperBuild, monitor: monitor, historyURL: historyURL, projectLocator: projectLocator,
                  hardware: { $0 ? SMCSensorProvider() as any HardwareSensorProviding : DisabledHardwareProvider() },
                  docker: { $0 ? DockerEngineSampler() as any DockerSampling : DisabledDockerSampler() },
                  now: { Date() }, sleep: { try await Task.sleep(for: .seconds($0)) }, onExit: onExit)
    }

    /// Tests inject the sources, the orphan clock and a fast sleep.
    init(helperBuild: String, monitor: BackgroundMonitor, historyURL: URL, projectLocator: ProjectRootLocator?,
         hardware: @escaping @Sendable (Bool) -> any HardwareSensorProviding,
         docker: @escaping @Sendable (Bool) -> any DockerSampling,
         now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (TimeInterval) async throws -> Void,
         onExit: @escaping @Sendable (ExitReason) -> Void) {
        self.helperBuild = helperBuild
        self.monitor = monitor
        self.historyURL = historyURL
        self.projectLocator = projectLocator
        self.hardware = hardware
        self.docker = docker
        self.now = now
        self.sleep = sleep
        self.onExit = onExit
    }

    /// Exports the service's protocol on `connection` and resumes it. Called by
    /// `HelperListenerDelegate`; the listener's code-signing requirement has already been checked.
    public nonisolated func accept(_ connection: NSXPCConnection, service: HelperService) {
        let (inbox, continuation) = AsyncStream<XPCMessage>.makeStream(bufferingPolicy: .bufferingOldest(Self.inboxDepth))
        let busy = (try? HelperCodec.encode(HelperControlReply.failure(.busy), build: helperBuild)) ?? Data()
        switch service {
        case .control:
            connection.exportedInterface = NSXPCInterface(with: HelperControlXPC.self)
            connection.exportedObject = ControlEndpoint(continuation, busy: busy)
            connection.remoteObjectInterface = NSXPCInterface(with: HelperEventsXPC.self)
        case .read:
            connection.exportedInterface = NSXPCInterface(with: HelperReadXPC.self)
            connection.exportedObject = ReadEndpoint(continuation, busy: busy)
        }
        connection.invalidationHandler = { continuation.finish() }
        connection.interruptionHandler = { continuation.finish() }
        let peer = XPCPeer(connection, id: 0)
        Task { await self.serve(peer, service: service, inbox: inbox) }
        connection.resume()
    }

    /// Nothing samples and nobody is connected: the helper's `main` exits after 60 s of this.
    public func isIdle() async -> Bool {
        let sampling = await monitor.isSampling
        return controls.isEmpty && readers == 0 && !sampling
    }

    /// Ends every app connection, as if the app had crashed (tests).
    func dropControlConnections() {
        for control in controls.values { control.peer.connection.invalidate() }
    }

    // MARK: - Connections

    private func serve(_ peer: XPCPeer, service: HelperService, inbox: AsyncStream<XPCMessage>) async {
        nextConnection += 1
        let id = nextConnection
        switch service {
        case .control: controls[id] = Control(peer: peer)
        case .read: readers += 1
        }
        for await message in inbox {
            switch service {
            case .control:
                let (reply, exit) = await control(message.data, connection: id)
                message.reply(reply)
                if let exit { scheduleExit(exit) }
            case .read:
                message.reply(await read(message.data))
            }
        }
        await closed(id, service: service)
    }

    private func closed(_ id: Int, service: HelperService) async {
        guard service == .control else {
            readers -= 1
            return
        }
        guard let control = controls.removeValue(forKey: id) else { return }
        control.subscription?.cancel()
        guard control.greeted, !controls.values.contains(where: \.greeted) else { return }
        // The last app connection went away. Without `pauseUntilAppOpens` that's a crash or a
        // kill: keep sampling in the background, for an hour at most.
        await monitor.viewerDetached()
        if !heldForApp { startOrphanClock() }
    }

    private func scheduleExit(_ reason: ExitReason) {
        guard !exiting else { return }
        exiting = true
        let sleep = self.sleep
        let onExit = self.onExit
        Task {
            try? await sleep(Self.exitGrace)
            onExit(reason)
        }
    }

    // MARK: - Control

    private func control(_ data: Data, connection id: Int) async -> (Data, ExitReason?) {
        let request: HelperControlRequest
        do {
            request = try HelperCodec.decode(HelperControlRequest.self, from: data).body
        } catch {
            let failure = error as? HelperFailure ?? .malformed("\(error)")
            // Another version's app: make way for the bundle's own helper.
            if case .versionMismatch = failure { return (encode(HelperControlReply.failure(failure)), .restartRequired) }
            return (encode(HelperControlReply.failure(failure)), nil)
        }
        guard controls[id] != nil else { return (encode(HelperControlReply.failure(.disconnected("closed"))), nil) }
        if case .hello(let appBuild) = request {
            guard appBuild == helperBuild else {
                return (encode(HelperControlReply.restartRequired(helperBuild: helperBuild)), .restartRequired)
            }
            controls[id]?.greeted = true
            await appArrived()
            return (encode(HelperControlReply.hello(HelperHello(helperBuild: helperBuild, status: await monitor.status))), nil)
        }
        guard controls[id]?.greeted == true else { return (encode(HelperControlReply.failure(.helloRequired)), nil) }
        let reply = await perform(request, connection: id)
        return (encode(reply), request == .shutdown ? .shutdown : nil)
    }

    private func perform(_ request: HelperControlRequest, connection id: Int) async -> HelperControlReply {
        switch request {
        case .hello:
            return .done
        case .configure(let settings):
            return await configure(settings)
        case .setViewer(let attached, let interval):
            if attached {
                guard let interval, interval.isFinite, interval > 0 else {
                    return .failure(.invalidArgument("an attached viewer needs an interval"))
                }
                await monitor.viewerAttached(interval: interval)
            } else {
                await monitor.viewerDetached()
            }
            return .done
        case .subscribe(let kind):
            await subscribe(kind, connection: id)
            return .done
        case .refreshNow:
            await monitor.refreshNow()
            return .done
        case .pause:
            await monitor.pause()
            return .done
        case .resume:
            heldForApp = false
            await monitor.resume()
            return .done
        case .pauseUntilAppOpens:
            heldForApp = true
            stopOrphanClock()
            await monitor.pause()
            return .done
        case .status:
            return .status(await monitor.status)
        case .recentAlerts(let since):
            return .alerts(await monitor.recentAlerts(since: since))
        case .historyWindow(let since):
            do {
                return .historyWindow(try await existingStore()?.window(since: since) ?? .empty)
            } catch {
                return .failure(.history("History couldn't be read: \(error)"))
            }
        case .savedActions(let since):
            do {
                return .savedActions(try await existingStore()?.actions(since: since) ?? [])
            } catch {
                return .failure(.history("Saved actions couldn't be read: \(error)"))
            }
        case .historySize:
            return .historySize(historySize)
        case .recordActions(let records):
            guard records.count <= HistoryStore.maximumActions else {
                return .failure(.invalidArgument("at most \(HistoryStore.maximumActions) records at once"))
            }
            do {
                try await openStore().record(actions: records)
                return .done
            } catch {
                return .failure(.history("Action not saved to history: \(error)"))
            }
        case .setRetention(let days):
            guard HistoryStore.retentionChoices.contains(days) else {
                return .failure(.invalidArgument("retention must be one of \(HistoryStore.retentionChoices) days"))
            }
            retentionDays = days
            settings?.historyRetentionDays = days
            do {
                try await store?.setRetention(days: days)
                return .done
            } catch {
                return .failure(.history("Retention couldn't be applied: \(error)"))
            }
        case .deleteHistory:
            do {
                // As in the app today, a running session stops saving until the next configure.
                try await HistoryStore.deleteHistory(at: historyURL, closing: store)
                store = nil
                return .done
            } catch {
                return .failure(.history("History couldn't be deleted: \(error)"))
            }
        case .shutdown:
            heldForApp = true
            stopOrphanClock()
            await monitor.pause()
            await store?.close()
            store = nil
            return .done
        }
    }

    /// Applies the app's settings. Only alerts, the MCP switch or retention changed: applied
    /// without restarting, so the timeline and cooldowns are kept. Anything else restarts the
    /// session, as closing Settings does in the app.
    private func configure(_ new: BackgroundSettings) async -> HelperControlReply {
        guard HistoryStore.retentionChoices.contains(new.historyRetentionDays) else {
            return .failure(.invalidArgument("retention must be one of \(HistoryStore.retentionChoices) days"))
        }
        let previous = settings
        retentionDays = new.historyRetentionDays
        var failure: HelperFailure?
        var history: HistoryStore?
        if new.keepHistory {
            do {
                history = try openStore()
            } catch {
                failure = .history("History couldn't be opened: \(error)")
            }
        }
        if let previous, previous.historyRetentionDays != new.historyRetentionDays {
            try? await store?.setRetention(days: new.historyRetentionDays)
        }
        settings = new
        var unchanged = previous
        unchanged?.alerts = new.alerts
        unchanged?.mcpReadEnabled = new.mcpReadEnabled
        unchanged?.historyRetentionDays = new.historyRetentionDays
        if unchanged == new, history === sessionStore {
            if previous?.alerts != new.alerts { await monitor.setAlerts(new.alerts) }
        } else {
            sessionStore = history
            let configuration = LiveConfiguration(hardware: hardware(new.hardwareSensors), docker: docker(new.docker),
                                                  userRules: new.userRules, projectLocator: projectLocator,
                                                  projectMappings: new.projectMappings, history: history, alerts: new.alerts)
            // The helper only runs with "Keep watching in the background" on.
            await monitor.configure(configuration, keepWatching: true)
        }
        return failure.map(HelperControlReply.failure) ?? .done
    }

    /// Replaces this connection's subscription. The new one is made before the old one ends, so
    /// switching between `.full` and `.summary` never leaves the monitor without a subscriber
    /// (which would detach the viewer).
    private func subscribe(_ kind: BackgroundMonitor.Subscription, connection id: Int) async {
        let stream = await monitor.subscribe(kind)
        let monitor = self.monitor
        let build = helperBuild
        guard let peer = controls[id]?.peer else { return }
        let task = Task.detached {
            for await event in stream {
                let message: HelperEvent
                switch event {
                case .tick(let tick):
                    message = .tick(tick)
                case .status(let status):
                    message = .summary(status: status, newAlerts: [], explanations: await monitor.explanations)
                case .alerts(let alerts):
                    message = .summary(status: await monitor.status, newAlerts: alerts, explanations: await monitor.explanations)
                case .stopped:
                    // A status follows with the pause and its reason.
                    continue
                }
                guard let data = try? HelperCodec.encode(message, build: build) else { continue }
                peer.push(data)
            }
        }
        guard controls[id] != nil else {
            task.cancel()
            return
        }
        let previous = controls[id]?.subscription
        controls[id]?.subscription = task
        previous?.cancel()
    }

    // MARK: - Orphan pause

    private func appArrived() async {
        stopOrphanClock()
        if heldForApp {
            heldForApp = false
            await monitor.resume()
        }
    }

    private func startOrphanClock() {
        orphanSince = now()
        orphanTimer?.cancel()
        let sleep = self.sleep
        orphanTimer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep(Self.orphanCheckInterval) } catch { return }
                guard let self, await self.checkOrphan() else { return }
            }
        }
    }

    private func stopOrphanClock() {
        orphanTimer?.cancel()
        orphanTimer = nil
        orphanSince = nil
    }

    /// Pauses once no app has been connected for `orphanLimit`. False when there's nothing left
    /// to wait for.
    func checkOrphan() async -> Bool {
        guard !controls.values.contains(where: \.greeted), let since = orphanSince else { return false }
        guard now().timeIntervalSince(since) >= Self.orphanLimit else { return true }
        orphanTimer = nil
        orphanSince = nil
        heldForApp = true
        await monitor.pause()
        return false
    }

    // MARK: - Reads

    private func read(_ data: Data) async -> Data {
        let reply: HelperReadReply
        do {
            reply = await answer(try HelperCodec.decode(HelperReadRequest.self, from: data).body)
        } catch {
            reply = .failure(error as? HelperFailure ?? .malformed("\(error)"))
        }
        return encode(reply)
    }

    /// Reads only: nothing here changes the mode, starts sampling or touches history.
    private func answer(_ request: HelperReadRequest) async -> HelperReadReply {
        let status = await monitor.status
        guard settings?.mcpReadEnabled == true, status.isSampling else { return .notRunning(HelperProtocol.notRunningMessage) }
        switch request {
        case .liveStatus:
            return .liveStatus(status)
        case .recentAlerts(let limit):
            guard (1...BackgroundMonitor.recentAlertLimit).contains(limit) else {
                return .failure(.invalidArgument("limit must be 1...\(BackgroundMonitor.recentAlertLimit)"))
            }
            return .recentAlerts(Array(await monitor.recentAlerts().suffix(limit)))
        case .explanations:
            return .explanations(await monitor.explanations)
        }
    }

    // MARK: - History

    private func openStore() throws -> HistoryStore {
        if let store { return store }
        let opened = try HistoryStore(url: historyURL, retentionDays: retentionDays)
        store = opened
        return opened
    }

    /// The store if the file exists, without creating one (as the app's `existingStore`).
    private func existingStore() throws -> HistoryStore? {
        if store == nil, historySize == 0 { return nil }
        return try openStore()
    }

    private var historySize: UInt64 {
        ["", "-wal"].reduce(0) { total, suffix in
            let size = (try? FileManager.default.attributesOfItem(atPath: historyURL.path + suffix)[.size] as? UInt64) ?? nil
            return total + (size ?? 0)
        }
    }

    private func encode(_ reply: some Codable) -> Data {
        do {
            return try HelperCodec.encode(reply, build: helperBuild)
        } catch {
            let failure = error as? HelperFailure ?? .malformed("\(error)")
            return (try? HelperCodec.encode(HelperControlReply.failure(failure), build: helperBuild)) ?? Data()
        }
    }
}

// MARK: - App client

/// The app's side (ADR-0008 §2, §4): connects to the helper's control service, checks it against
/// `HelperProtocol.helperRequirement`, and keeps what it needs to replay. When an established
/// connection is lost it reconnects after 1, 2, 5, then every 10 s, and replays `hello`, Pause,
/// `configure`, the viewer and the subscription. Three refusals in a row (another build or
/// protocol version) end the retries with `.refused`: watch inside the app instead.
public actor HelperClient {
    public enum Event: Sendable {
        /// A connection was made and replayed.
        case connected(HelperHello)
        case helper(HelperEvent)
        /// The connection was lost; reconnecting.
        case disconnected(String)
        /// Retries ended: the helper keeps answering as another version.
        case refused(String)
    }

    public static let backoff: [TimeInterval] = [1, 2, 5, 10]
    static let refusalLimit = 3

    /// Pushes and connection changes, across reconnects.
    public nonisolated let events: AsyncStream<Event>
    private nonisolated let sink: AsyncStream<Event>.Continuation
    public nonisolated let appBuild: String
    private let makeConnection: @Sendable () -> NSXPCConnection
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let timeout: TimeInterval
    private var connection: XPCPeer?
    private var nextPeer = 0
    private var reconnecting: Task<Void, Never>?
    private var closed = false

    // Replayed on every reconnect.
    private var settings: BackgroundSettings?
    private var viewer: (attached: Bool, interval: TimeInterval?)?
    private var subscription: BackgroundMonitor.Subscription?
    private var paused = false

    /// The helper's control service, checked against `HelperProtocol.helperRequirement`.
    public static func helper(appBuild: String) -> HelperClient {
        HelperClient(appBuild: appBuild) {
            let connection = NSXPCConnection(machServiceName: HelperProtocol.controlServiceName, options: [])
            connection.setCodeSigningRequirement(HelperProtocol.helperRequirement)
            return connection
        }
    }

    /// - Parameter connect: makes a new, unresumed connection each time it's called.
    public init(appBuild: String, timeout: TimeInterval = 30, connect: @escaping @Sendable () -> NSXPCConnection) {
        self.init(appBuild: appBuild, timeout: timeout, connect: connect, sleep: { try await Task.sleep(for: .seconds($0)) })
    }

    /// Tests inject a fast sleep for the backoff.
    init(appBuild: String, timeout: TimeInterval, connect: @escaping @Sendable () -> NSXPCConnection,
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void) {
        self.appBuild = appBuild
        self.timeout = timeout
        makeConnection = connect
        self.sleep = sleep
        (events, sink) = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingNewest(32))
    }

    public var isConnected: Bool { connection != nil }

    /// One attempt: connect, `hello`, replay. Throws `.restartRequired` when the helper is another
    /// build (it exits; try again shortly) and `.versionMismatch` for another protocol version.
    @discardableResult
    public func connect() async throws -> HelperHello {
        closed = false
        return try await establish()
    }

    /// Ends the connection and any reconnecting. Nothing is sent.
    public func disconnect() {
        closed = true
        reconnecting?.cancel()
        reconnecting = nil
        connection?.connection.invalidate()
        connection = nil
    }

    /// Replayed on reconnect. A `.history` failure means the settings applied but history is off.
    public func configure(_ settings: BackgroundSettings) async throws {
        self.settings = settings
        try await expectDone(.configure(settings))
    }

    public func setViewer(attached: Bool, interval: TimeInterval? = nil) async throws {
        viewer = (attached, interval)
        try await expectDone(.setViewer(attached: attached, interval: interval))
    }

    public func subscribe(_ kind: BackgroundMonitor.Subscription) async throws {
        subscription = kind
        try await expectDone(.subscribe(kind))
    }

    public func refreshNow() async throws {
        try await expectDone(.refreshNow)
    }

    public func pause() async throws {
        paused = true
        try await expectDone(.pause)
    }

    public func resume() async throws {
        paused = false
        try await expectDone(.resume)
    }

    /// From `applicationWillTerminate`.
    public func pauseUntilAppOpens() async throws {
        try await expectDone(.pauseUntilAppOpens)
    }

    /// The helper stops and exits; this client doesn't reconnect.
    public func shutdown() async throws {
        closed = true
        reconnecting?.cancel()
        try await expectDone(.shutdown)
    }

    public func status() async throws -> BackgroundStatus {
        guard case .status(let status) = try await send(.status) else { throw HelperFailure.unexpectedReply("status") }
        return status
    }

    public func recentAlerts(since: Date? = nil) async throws -> [Alert] {
        guard case .alerts(let alerts) = try await send(.recentAlerts(since: since)) else { throw HelperFailure.unexpectedReply("alerts") }
        return alerts
    }

    public func historyWindow(since: Date) async throws -> HistoryWindow {
        guard case .historyWindow(let window) = try await send(.historyWindow(since: since)) else {
            throw HelperFailure.unexpectedReply("historyWindow")
        }
        return window
    }

    public func savedActions(since: Date) async throws -> [ActionRecord] {
        guard case .savedActions(let records) = try await send(.savedActions(since: since)) else {
            throw HelperFailure.unexpectedReply("savedActions")
        }
        return records
    }

    public func historySize() async throws -> UInt64 {
        guard case .historySize(let size) = try await send(.historySize) else { throw HelperFailure.unexpectedReply("historySize") }
        return size
    }

    public func recordActions(_ records: [ActionRecord]) async throws {
        try await expectDone(.recordActions(records))
    }

    public func setRetention(days: Int) async throws {
        settings?.historyRetentionDays = days
        try await expectDone(.setRetention(days: days))
    }

    public func deleteHistory() async throws {
        try await expectDone(.deleteHistory)
    }

    /// Any request over the current connection. A `.failure` reply is thrown.
    public func send(_ request: HelperControlRequest) async throws -> HelperControlReply {
        guard let connection else { throw HelperFailure.disconnected("not connected") }
        return try await call(request, on: connection)
    }

    private func expectDone(_ request: HelperControlRequest) async throws {
        let reply = try await send(request)
        guard reply == .done else { throw HelperFailure.unexpectedReply("\(reply)".prefix(80).description) }
    }

    private func call(_ request: HelperControlRequest, on peer: XPCPeer) async throws -> HelperControlReply {
        let data = try HelperCodec.encode(request, build: appBuild)
        let reply = try HelperCodec.decode(HelperControlReply.self, from: try await peer.send(data, to: .control, timeout: timeout)).body
        if case .failure(let failure) = reply { throw failure }
        return reply
    }

    // MARK: - Connecting

    private func open() -> XPCPeer {
        nextPeer += 1
        let id = nextPeer
        let raw = makeConnection()
        raw.remoteObjectInterface = NSXPCInterface(with: HelperControlXPC.self)
        raw.exportedInterface = NSXPCInterface(with: HelperEventsXPC.self)
        raw.exportedObject = HelperEventReceiver(sink)
        let lost: @Sendable () -> Void = { [weak self] in
            Task { await self?.lost(id) }
        }
        raw.invalidationHandler = lost
        raw.interruptionHandler = lost
        raw.resume()
        return XPCPeer(raw, id: id)
    }

    /// The connection is kept only once `hello` and the replay succeeded; a failed attempt's
    /// connection is invalidated and its loss ignored.
    private func establish() async throws -> HelperHello {
        connection?.connection.invalidate()
        connection = nil
        let peer = open()
        do {
            let hello: HelperHello
            switch try await call(.hello(appBuild: appBuild), on: peer) {
            case .hello(let reply): hello = reply
            case .restartRequired(let build): throw HelperFailure.restartRequired(helperBuild: build)
            case let other: throw HelperFailure.unexpectedReply("\(other)".prefix(80).description)
            }
            if paused { _ = try await call(.pause, on: peer) }
            if let settings {
                do {
                    _ = try await call(.configure(settings), on: peer)
                } catch HelperFailure.history {
                    // Applied; the session samples without saving.
                }
            }
            if let viewer { _ = try await call(.setViewer(attached: viewer.attached, interval: viewer.interval), on: peer) }
            if let subscription { _ = try await call(.subscribe(subscription), on: peer) }
            guard !closed else { throw HelperFailure.disconnected("disconnected") }
            connection = peer
            sink.yield(.connected(hello))
            return hello
        } catch {
            peer.connection.invalidate()
            throw error
        }
    }

    private func lost(_ id: Int) {
        guard let current = connection, current.id == id else { return }
        connection = nil
        current.connection.invalidate()
        sink.yield(.disconnected("The connection to the background helper was lost"))
        guard !closed, reconnecting == nil else { return }
        reconnecting = Task { await self.reconnect() }
    }

    private func reconnect() async {
        defer { reconnecting = nil }
        var attempt = 0
        var refusals = 0
        while !closed, !Task.isCancelled {
            let delay = Self.backoff[min(attempt, Self.backoff.count - 1)]
            attempt += 1
            do { try await sleep(delay) } catch { return }
            guard !closed else { return }
            do {
                _ = try await establish()
                return
            } catch let failure as HelperFailure {
                switch failure {
                case .restartRequired, .versionMismatch:
                    refusals += 1
                    if refusals >= Self.refusalLimit {
                        sink.yield(.refused(failure.description))
                        return
                    }
                default:
                    refusals = 0
                }
            } catch {
                refusals = 0
            }
        }
    }
}

// MARK: - CLI client

/// The CLI's side: the three reads, over the helper's read service, checked against
/// `HelperProtocol.helperRequirement`. One connection, made again after it's lost.
public actor HelperReadClient {
    public nonisolated let build: String
    private let makeConnection: @Sendable () -> NSXPCConnection
    private let timeout: TimeInterval
    private var connection: XPCPeer?
    private var nextPeer = 0

    public static func helper(build: String) -> HelperReadClient {
        HelperReadClient(build: build) {
            let connection = NSXPCConnection(machServiceName: HelperProtocol.readServiceName, options: [])
            connection.setCodeSigningRequirement(HelperProtocol.helperRequirement)
            return connection
        }
    }

    /// - Parameter connect: makes a new, unresumed connection each time it's called.
    public init(build: String, timeout: TimeInterval = 5, connect: @escaping @Sendable () -> NSXPCConnection) {
        self.build = build
        self.timeout = timeout
        makeConnection = connect
    }

    public func send(_ request: HelperReadRequest) async throws -> HelperReadReply {
        try HelperCodec.decode(HelperReadReply.self, from: try await exchange(try HelperCodec.encode(request, build: build))).body
    }

    public func close() {
        connection?.connection.invalidate()
        connection = nil
    }

    /// Raw bytes in and out (tests send other envelopes through this).
    func exchange(_ data: Data) async throws -> Data {
        let peer = connection ?? open()
        do {
            return try await peer.send(data, to: .read, timeout: timeout)
        } catch {
            if connection?.id == peer.id { close() }
            throw error
        }
    }

    private func open() -> XPCPeer {
        nextPeer += 1
        let id = nextPeer
        let raw = makeConnection()
        raw.remoteObjectInterface = NSXPCInterface(with: HelperReadXPC.self)
        raw.invalidationHandler = { [weak self] in
            Task { await self?.lost(id) }
        }
        raw.resume()
        let peer = XPCPeer(raw, id: id)
        connection = peer
        return peer
    }

    private func lost(_ id: Int) {
        if connection?.id == id { connection = nil }
    }
}

// MARK: - Plumbing

/// One request and where its reply goes.
struct XPCMessage: Sendable {
    let data: Data
    let reply: @Sendable (Data) -> Void
}

/// Queues a connection's requests in arrival order; more than the queue holds are answered `.busy`.
class XPCInbox: NSObject, @unchecked Sendable {
    private let continuation: AsyncStream<XPCMessage>.Continuation
    private let busy: Data

    init(_ continuation: AsyncStream<XPCMessage>.Continuation, busy: Data) {
        self.continuation = continuation
        self.busy = busy
    }

    func enqueue(_ data: Data, reply: @escaping @Sendable (Data) -> Void) {
        switch continuation.yield(XPCMessage(data: data, reply: reply)) {
        case .dropped: reply(busy)
        default: break
        }
    }
}

final class ControlEndpoint: XPCInbox, HelperControlXPC, @unchecked Sendable {
    func handle(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        enqueue(request, reply: reply)
    }
}

final class ReadEndpoint: XPCInbox, HelperReadXPC, @unchecked Sendable {
    func handle(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        enqueue(request, reply: reply)
    }
}

/// Decodes pushes in the order they arrive; anything that doesn't decode is dropped.
final class HelperEventReceiver: NSObject, HelperEventsXPC, Sendable {
    private let sink: AsyncStream<HelperClient.Event>.Continuation

    init(_ sink: AsyncStream<HelperClient.Event>.Continuation) {
        self.sink = sink
    }

    func receive(_ event: Data) {
        guard let decoded = try? HelperCodec.decode(HelperEvent.self, from: event).body else { return }
        sink.yield(.helper(decoded))
    }
}

/// `NSXPCConnection` is thread-safe but not `Sendable`.
final class XPCPeer: @unchecked Sendable {
    let connection: NSXPCConnection
    let id: Int

    init(_ connection: NSXPCConnection, id: Int) {
        self.connection = connection
        self.id = id
    }

    /// A push to the app; dropped if the app has gone.
    func push(_ data: Data) {
        (connection.remoteObjectProxyWithErrorHandler { _ in } as? HelperEventsXPC)?.receive(data)
    }

    /// One request and its reply, or `.disconnected` / `.timedOut`.
    func send(_ data: Data, to service: HelperService, timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            let once = ReplyOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(with: .failure(HelperFailure.disconnected(error.localizedDescription)))
            }
            let reply: @Sendable (Data) -> Void = { once.resume(with: .success($0)) }
            switch service {
            case .control:
                guard let handler = proxy as? HelperControlXPC else {
                    once.resume(with: .failure(HelperFailure.disconnected("no control interface")))
                    return
                }
                handler.handle(data, reply: reply)
            case .read:
                guard let handler = proxy as? HelperReadXPC else {
                    once.resume(with: .failure(HelperFailure.disconnected("no read interface")))
                    return
                }
                handler.handle(data, reply: reply)
            }
            once.startTimer(timeout)
        }
    }
}

/// Resumes a continuation exactly once: the reply, the error handler or the timeout, whichever
/// comes first.
private final class ReplyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?
    private var timer: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<Data, any Error>) {
        self.continuation = continuation
    }

    func startTimer(_ seconds: TimeInterval) {
        // Holds this until it fires or is cancelled, so a reply that never comes still resumes.
        let timer = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self.resume(with: .failure(HelperFailure.timedOut))
        }
        let done = lock.withLock {
            self.timer = timer
            return continuation == nil
        }
        if done { timer.cancel() }
    }

    func resume(with result: Result<Data, any Error>) {
        let (continuation, timer) = lock.withLock {
            defer {
                self.continuation = nil
                self.timer = nil
            }
            return (self.continuation, self.timer)
        }
        timer?.cancel()
        continuation?.resume(with: result)
    }
}
