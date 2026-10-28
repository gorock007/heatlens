import Darwin
import Foundation
import Testing
@testable import HeatLensCore

private typealias F = ContainerStopFixtures

private let target = ContainerStopTarget(containerID: F.id, name: F.name, image: F.image,
                                         createdAt: Date(timeIntervalSince1970: TimeInterval(F.createdSeconds)),
                                         composeProject: "demo", projectName: "demo",
                                         projectDirectory: "/Users/someone/Developer/demo")

/// A fake Engine on a real `AF_UNIX` socket: every connection is answered on its own thread
/// and every request line is logged, so "nothing was sent" is an assertion on the log.
private final class EngineStub: @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int
        var body: String?
        /// Seconds to wait before answering.
        var delay: TimeInterval = 0
    }

    let path: String
    private let listener: Int32
    private let lock = NSLock()
    private var lines: [String] = []
    private var stopping = false
    private let group = DispatchGroup()

    init(_ handler: @escaping @Sendable (String) -> Reply) throws {
        path = NSTemporaryDirectory() + "hl-\(UUID().uuidString.prefix(8)).sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        listener = fd
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { throw UnixSocketHTTP.Failure.ioFailed(errno) }
        group.enter()
        Thread.detachNewThread { [self] in
            defer { group.leave() }
            while !isStopping {
                var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&poller, 1, 50) > 0 else { continue }
                let client = accept(fd, nil, nil)
                guard client >= 0 else { continue }
                group.enter()
                DispatchQueue.global().async { [self] in
                    defer { close(client); group.leave() }
                    var noSigPipe: Int32 = 1
                    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                    let line = Self.readRequestLine(client)
                    lock.lock(); lines.append(line); lock.unlock()
                    let reply = handler(line)
                    if reply.delay > 0 { usleep(useconds_t(reply.delay * 1_000_000)) }
                    let body = reply.body ?? ""
                    let head = "HTTP/1.1 \(reply.status) X\r\nContent-Type: application/json\r\n"
                        + (reply.body == nil ? "" : "Content-Length: \(body.utf8.count)\r\n") + "\r\n"
                    let data = Array((head + body).utf8)
                    _ = data.withUnsafeBytes { write(client, $0.baseAddress!, data.count) }
                }
            }
        }
    }

    private var isStopping: Bool { lock.lock(); defer { lock.unlock() }; return stopping }

    /// Reads until the end of the headers (requests have no body) and returns the first line.
    private static func readRequestLine(_ fd: Int32) -> String {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.range(of: Data("\r\n\r\n".utf8)) == nil {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
    }

    var requestLines: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    var posts: [String] { requestLines.filter { $0.hasPrefix("POST ") } }

    func stop() {
        lock.lock(); stopping = true; lock.unlock()
        _ = group.wait(timeout: .now() + 5)
        close(listener)
        unlink(path)
    }
}

/// Answers like Docker Desktop for `F.id`; anything else is a 404.
private func engine(inspect: EngineStub.Reply = .init(status: 200, body: F.inspect()),
                    stop: EngineStub.Reply = .init(status: 204, body: nil),
                    list: EngineStub.Reply = .init(status: 200, body: F.list(state: "running"))) -> @Sendable (String) -> EngineStub.Reply {
    { line in
        if line == "GET /version HTTP/1.1" { return .init(status: 200, body: F.version) }
        if line == "GET /v1.51/containers/\(F.id)/json HTTP/1.1" { return inspect }
        if line.hasPrefix("POST /v1.51/containers/\(F.id)/stop?t=") { return stop }
        if line == "GET /v1.51/containers/json?all=1 HTTP/1.1" { return list }
        return .init(status: 404, body: F.error("page not found"))
    }
}

private func stopper(_ server: EngineStub, ledger: StopLedger? = nil, deadlineMargin: TimeInterval = 5) -> ContainerStopper {
    ContainerStopper(transport: UnixSocketTransport(socketPath: server.path), ledger: ledger, deadlineMargin: deadlineMargin)
}

private func sample(name: String = F.name, image: String = F.image, state: String = "running",
                    labels: [String: String] = [:]) -> ContainerSample {
    ContainerSample(containerID: F.id, name: name, image: image, state: state, status: "Up 3 days",
                    createdAt: Date(timeIntervalSince1970: TimeInterval(F.createdSeconds)), labels: labels,
                    cpuPercentOfOneCore: nil, memoryBytes: nil, vmCPUCount: nil)
}

/// ADR-0007 §Tests 1–12. Only the fake Engine above is ever contacted, except by test 12.
@Suite("Container stop")
struct ContainerStopTests {
    // MARK: 1. Request builder

    @Test("1. The only POST is the stop path: full ID, t in 0…120; anything else throws before connect")
    func requestBuilder() throws {
        let api = try #require(DockerAPIVersion("1.51"))
        let full = try #require(DockerContainerID(F.id))
        let short = try #require(DockerContainerID(String(F.id.prefix(12))))
        #expect(full.isFull && !short.isFull)
        #expect(DockerEndpoint.stop(api: api, id: full, timeout: 25).path == "/v1.51/containers/\(F.id)/stop?t=25")
        #expect(DockerEndpoint.stop(api: api, id: full, timeout: 600).path.hasSuffix("/stop?t=120"))
        #expect(DockerEndpoint.stop(api: api, id: full, timeout: -1).path.hasSuffix("/stop?t=0"))
        #expect(!UnixSocketHTTP.isAllowedStopPath(DockerEndpoint.stop(api: api, id: short, timeout: 10).path))

        let base = "/v1.51/containers/\(F.id)"
        #expect(UnixSocketHTTP.isAllowedStopPath(base + "/stop?t=10"))
        let refused = [
            base + "/stop", base + "/stop?t=-1", base + "/stop?t=abc", base + "/stop?t=1000", base + "/stop?t=10&signal=SIGKILL",
            base + "/kill", base + "/kill?signal=SIGTERM", base + "/restart?t=10", base + "/json", base,
            "/v1.51/containers/\(F.id.prefix(12))/stop?t=10", "/v1.51/containers/\(F.id.uppercased())/stop?t=10",
            "/containers/\(F.id)/stop?t=10", "/v1.51/containers/json?all=1", "/v1.51/containers/prune", "/_ping",
            "/v1.51/images/\(F.id)/stop?t=10", base + "/stop?t=10/", "/v1.51/containers/\(F.id)0/stop?t=10",
        ]
        let missing = NSTemporaryDirectory() + "heatlens-missing-\(UUID().uuidString.prefix(8)).sock"
        for path in refused {
            #expect(!UnixSocketHTTP.isAllowedStopPath(path), "\(path)")
            #expect(throws: UnixSocketHTTP.Failure.invalidPath, "\(path)") { try UnixSocketHTTP.request(method: .post, path: path) }
            // invalidPath, not connectFailed(ENOENT): the socket was never touched.
            #expect(throws: UnixSocketHTTP.Failure.invalidPath, "\(path)") {
                try UnixSocketHTTP.post(path: path, socketPath: missing, timeout: 1)
            }
            #expect(throws: UnixSocketHTTP.Failure.invalidPath) { try UnixSocketTransport(socketPath: missing).post(path, timeout: 1) }
        }

        // Fuzz: one allowed character inserted anywhere; whatever still passes is a stop path.
        let valid = Array(base + "/stop?t=10")
        let allowed = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-?=&")
        for position in 0...valid.count {
            for character in allowed {
                var mutated = valid
                mutated.insert(character, at: position)
                let path = String(mutated)
                guard (try? UnixSocketHTTP.request(method: .post, path: path)) != nil else { continue }
                #expect(path.wholeMatch(of: /\/v1\.\d{1,3}\/containers\/[0-9a-f]{64}\/stop\?t=\d{1,3}/) != nil, "\(path)")
            }
        }
    }

    // MARK: 2–3. Inspect before the call

    @Test("2. Inspect mismatch (Id, Name, Created + 1 s) is .identityChanged and nothing is posted",
          arguments: [
            F.inspect(id: F.otherID),
            F.inspect(name: "/demo-db-2"),
            F.inspect(created: "2026-10-23T13:00:14.000000001Z"),
          ])
    func identityMismatch(inspect: String) async throws {
        let server = try EngineStub(engine(inspect: .init(status: 200, body: inspect)))
        defer { server.stop() }
        let ledger = StopLedger()
        #expect(await stopper(server, ledger: ledger).stop(target) == .identityChanged)
        #expect(server.posts.isEmpty)
        #expect(server.requestLines.contains("GET /v1.51/containers/\(F.id)/json HTTP/1.1"))
        let record = try #require(await ledger.records(since: .distantPast).first)
        #expect(record.action == .containerStop && record.outcome == "identityChanged" && record.signalSentAt == nil)
    }

    @Test("3. Inspect says exited → .alreadyStopped; inspect 404 → .gone; nothing is posted")
    func notRunningOrGone() async throws {
        for status in ["exited", "paused", "restarting"] {
            let server = try EngineStub(engine(inspect: .init(status: 200, body: F.inspect(status: status))))
            defer { server.stop() }
            #expect(await stopper(server).stop(target) == .alreadyStopped, "\(status)")
            #expect(server.posts.isEmpty)
        }
        let server = try EngineStub(engine(inspect: .init(status: 404, body: F.error("No such container: \(F.id)"))))
        defer { server.stop() }
        #expect(await stopper(server).stop(target) == .gone)
        #expect(server.posts.isEmpty)
        #expect(await stopper(server).preview(target) == .unavailable(.gone))
    }

    // MARK: 4–6. The stop call

    @Test("4. Stop answers: 204 → .stopped, 304 → .alreadyStopped, 404 → .gone, each one POST and recorded")
    func stopResponses() async throws {
        let cases: [(EngineStub.Reply, ContainerStopOutcome)] = [
            (.init(status: 204, body: nil), .stopped),
            (.init(status: 304, body: nil), .alreadyStopped),
            (.init(status: 404, body: F.error("No such container: \(F.id)")), .gone),
        ]
        for (reply, expected) in cases {
            let server = try EngineStub(engine(stop: reply))
            defer { server.stop() }
            let ledger = StopLedger()
            let confirmed = Date()
            let context = ActionContext(origin: .containerDetail, projectName: "demo", confirmedAt: confirmed)
            #expect(await stopper(server, ledger: ledger).stop(target, context: context) == expected)
            #expect(server.posts == ["POST /v1.51/containers/\(F.id)/stop?t=10 HTTP/1.1"])
            let records = await ledger.records(since: .distantPast)
            #expect(records.count == 1)
            let record = try #require(records.first)
            #expect(record.action == .containerStop && record.outcome == expected.caseName && record.signalSentAt != nil)
            #expect(record.target == .container(shortID: String(F.id.prefix(12)), name: F.name, image: F.image, composeProject: "demo"))
            #expect(record.origin == .containerDetail && record.confirmedAt == confirmed && record.projectName == "demo")
            #expect(record.detail == nil)
        }
    }

    @Test("4. A 500 is .failed with the Engine's message, redacted and capped at 200 characters")
    func serverError() async throws {
        let home = NSHomeDirectory()
        let message = "cannot stop container: \(home)/secret/thing --password=hunter2 " + String(repeating: "x", count: 400)
        let server = try EngineStub(engine(stop: .init(status: 500, body: F.error(message))))
        defer { server.stop() }
        let ledger = StopLedger()
        let outcome = await stopper(server, ledger: ledger).stop(target)
        guard case .failed(let text) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(text.count <= 200)
        #expect(text.hasPrefix("Docker Engine answered HTTP 500: cannot stop container: ~/secret/thing"))
        #expect(!text.contains(home) && !text.contains("hunter2"))
        #expect(server.posts.count == 1)
        let record = try #require(await ledger.records(since: .distantPast).first)
        #expect(record.outcome == "failed" && record.detail == text && record.signalSentAt != nil)
    }

    @Test("5. t comes from Config.StopTimeout: 25 → t=25, null → t=10, 600 → t=120; the plan states it")
    func timeoutFromInspect() async throws {
        let cases: [(Int?, Int)] = [(25, 25), (nil, 10), (600, 120), (0, 0), (-1, 120)]
        for (stopTimeout, expected) in cases {
            let inspect = F.inspect(stopTimeout: stopTimeout, stopSignal: stopTimeout == 25 ? "SIGINT" : nil, restartPolicy: "always")
            let server = try EngineStub(engine(inspect: .init(status: 200, body: inspect)))
            defer { server.stop() }
            let stopper = stopper(server)
            #expect(await stopper.preview(target)
                == .ready(ContainerStopPlan(stopSignal: stopTimeout == 25 ? "SIGINT" : "SIGTERM", timeoutSeconds: expected,
                                            restartPolicy: "always")))
            #expect(server.posts.isEmpty, "preview never posts")
            #expect(await stopper.stop(target) == .stopped)
            #expect(server.posts == ["POST /v1.51/containers/\(F.id)/stop?t=\(expected) HTTP/1.1"])
        }
    }

    @Test("6. An answer later than t + margin is .stillStopping: exactly one POST, then a list call")
    func deadline() async throws {
        let server = try EngineStub(engine(inspect: .init(status: 200, body: F.inspect(stopTimeout: 0)),
                                           stop: .init(status: 204, body: nil, delay: 1.5)))
        defer { server.stop() }
        let ledger = StopLedger()
        let started = Date()
        #expect(await stopper(server, ledger: ledger, deadlineMargin: 0.3).stop(target) == .stillStopping)
        #expect(Date().timeIntervalSince(started) < 1.4)
        #expect(server.posts.count == 1)
        let lines = server.requestLines
        let post = try #require(lines.firstIndex { $0.hasPrefix("POST ") })
        #expect(lines[(post + 1)...].contains("GET /v1.51/containers/json?all=1 HTTP/1.1"))
        let record = try #require(await ledger.records(since: .distantPast).first)
        #expect(record.outcome == "stillStopping" && record.signalSentAt != nil)

        // If the list no longer shows it running by then, it did stop.
        let gone = try EngineStub(engine(inspect: .init(status: 200, body: F.inspect(stopTimeout: 0)),
                                         stop: .init(status: 204, body: nil, delay: 1.5),
                                         list: .init(status: 200, body: F.list(state: "exited"))))
        defer { gone.stop() }
        #expect(await stopper(gone, deadlineMargin: 0.3).stop(target) == .stopped)
        #expect(gone.posts.count == 1)
    }

    // MARK: 7. Eligibility

    @Test("7. Never offered: not running, Docker Desktop, Dev Environments, Kubernetes, buildx")
    func infraRules() {
        let stopper = ContainerStopper(transport: UnixSocketTransport(socketPath: "/nonexistent"), ledger: nil)
        let none = ExclusionFilter()
        #expect(stopper.eligibility(of: sample(), project: nil, exclusions: none) == .eligible)
        #expect(stopper.eligibility(of: sample(state: "exited"), project: nil, exclusions: none)
            == .denied(reason: ContainerStopEligibility.notRunningReason))
        let denied: [(ContainerSample, String)] = [
            (sample(labels: ["com.docker.desktop.extension": "true"]), ContainerStopEligibility.desktopReason),
            (sample(labels: ["io.docker.desktop.helper": "1"]), ContainerStopEligibility.desktopReason),
            (sample(labels: ["com.docker.dev-environments.id": "x"]), ContainerStopEligibility.devEnvironmentReason),
            (sample(labels: ["io.kubernetes.pod.name": "coredns"]), ContainerStopEligibility.kubernetesReason),
            (sample(name: "k8s_coredns_kube-system"), ContainerStopEligibility.kubernetesReason),
            (sample(name: "buildx_buildkit_builder0"), ContainerStopEligibility.buildxReason),
            (sample(image: "moby/buildkit:buildx-stable-1"), ContainerStopEligibility.buildxReason),
        ]
        for (container, reason) in denied {
            #expect(stopper.eligibility(of: container, project: nil, exclusions: none) == .denied(reason: reason), "\(container.name)")
        }
        // Lookalikes are not infra.
        #expect(stopper.eligibility(of: sample(name: "my-k8s_tool", labels: ["com.docker.compose.project": "desktop"]),
                                    project: nil, exclusions: none) == .eligible)
    }

    @Test("7. Exclusions: process name (any case), attributed project prefix, Compose working_dir")
    func exclusionRules() {
        let stopper = ContainerStopper(transport: UnixSocketTransport(socketPath: "/nonexistent"), ledger: nil)
        let project = Project(name: "demo", root: "/Users/someone/Developer/demo", confidence: .high, basis: "git repository")
        #expect(stopper.eligibility(of: sample(), project: project, exclusions: ExclusionFilter(processNames: ["DEMO-DB-1"])) == .excluded)
        #expect(stopper.eligibility(of: sample(), project: project, exclusions: ExclusionFilter(projectPrefixes: ["/Users/someone/Developer"]))
            == .excluded)
        #expect(stopper.eligibility(of: sample(labels: F.composeLabels), project: nil,
                                    exclusions: ExclusionFilter(projectPrefixes: ["/Users/someone/Developer/demo"])) == .excluded)
        #expect(stopper.eligibility(of: sample(labels: F.composeLabels), project: project,
                                    exclusions: ExclusionFilter(processNames: ["demo-db"], projectPrefixes: ["/Users/someone/Developer/dem"]))
            == .eligible)
    }

    @Test("7. A Docker Desktop label or an exclusion seen only at inspect time still denies; nothing is posted")
    func inspectTimeRules() async throws {
        #expect(ContainerStopEligibility.evaluate(name: F.name, image: F.image, state: "running", labels: [:],
                                                  projectDirectory: nil, exclusions: ExclusionFilter()) == .eligible)
        let labelled = try EngineStub(engine(inspect: .init(status: 200,
                                                            body: F.inspect(labels: ["com.docker.desktop.extension": "true"]))))
        defer { labelled.stop() }
        #expect(await stopper(labelled).stop(target) == .denied(reason: ContainerStopEligibility.desktopReason))
        #expect(labelled.posts.isEmpty)

        let excluded = try EngineStub(engine())
        defer { excluded.stop() }
        let excludedTarget = ContainerStopTarget(containerID: F.id, name: F.name, image: F.image, createdAt: target.createdAt,
                                                 composeProject: "demo", projectName: nil,
                                                 exclusions: ExclusionFilter(projectPrefixes: ["/Users/someone/Developer/demo"]))
        let outcome = await stopper(excluded).stop(excludedTarget)
        #expect(outcome == .denied(reason: "This container is excluded in Settings, so nothing was sent."))
        #expect(excluded.posts.isEmpty)
    }

    // MARK: 8. Socket policy

    @Test("8. Socket policy: Docker Desktop's two paths when user-owned; DOCKER_HOST, root, other users and odd symlinks refused")
    func socketPolicy() {
        let home = "/Users/x"
        let desktop = home + "/.docker/run/docker.sock"
        let socket = { (owner: uid_t) in (mode: mode_t(S_IFSOCK | 0o755), owner: owner) }
        let link = (mode: mode_t(S_IFLNK | 0o755), owner: uid_t(0))
        func policy(_ path: String, env: [String: String] = [:], files: [String: (mode: mode_t, owner: uid_t)],
                    links: [String: String] = [:]) -> Result<String, DockerSocketLocator.StopRefusal> {
            DockerSocketLocator.stopPolicy(for: path, environment: env, home: home, lstat: { files[$0] }, realpath: { links[$0] ?? $0 },
                                           currentUser: 501)
        }
        #expect(policy(desktop, files: [desktop: socket(501)]) == .success(desktop))
        #expect(policy("/var/run/docker.sock", files: ["/var/run/docker.sock": link, desktop: socket(501)],
                       links: ["/var/run/docker.sock": desktop]) == .success(desktop))
        #expect(policy(desktop, env: ["DOCKER_HOST": "unix://\(desktop)"], files: [desktop: socket(501)]) == .failure(.dockerHost))
        let colima = home + "/.colima/default/docker.sock"
        #expect(policy(colima, env: ["DOCKER_HOST": "unix://\(colima)"], files: [colima: socket(501)]) == .failure(.dockerHost))
        #expect(policy(colima, files: [colima: socket(501)]) == .failure(.notDockerDesktop(colima)))
        #expect(policy(desktop, files: [desktop: socket(0)]) == .failure(.notOwned(desktop)))
        #expect(policy(desktop, files: [desktop: socket(502)]) == .failure(.notOwned(desktop)))
        #expect(policy("/var/run/docker.sock", files: ["/var/run/docker.sock": socket(0)]) == .failure(.notOwned("/var/run/docker.sock")))
        #expect(policy("/var/run/docker.sock", files: ["/var/run/docker.sock": link, "/tmp/x.sock": socket(501)],
                       links: ["/var/run/docker.sock": "/tmp/x.sock"]) == .failure(.notDockerDesktop("/var/run/docker.sock")))
        #expect(policy(desktop, files: [desktop: (mode_t(S_IFREG | 0o644), 501)]) == .failure(.notOwned(desktop)))
        #expect(policy(desktop, files: [:]) == .failure(.notOwned(desktop)))
        #expect(DockerSocketLocator.StopRefusal.dockerHost.reason == "Stopping is only supported through Docker Desktop's socket for now.")
        #expect(DockerSocketLocator.StopRefusal.notOwned(desktop).reason == "HeatLens only stops containers through a Docker socket you own.")
    }

    @Test("8. Through a DOCKER_HOST socket reads work and a stop is refused without opening it")
    func dockerHostIsReadOnly() async throws {
        let server = try EngineStub(engine())
        defer { server.stop() }
        let environment = ["DOCKER_HOST": "unix://\(server.path)"]
        let home = "/nonexistent-heatlens-home"
        let ledger = StopLedger()
        let stopper = ContainerStopper(ledger: ledger, environment: environment, home: home)
        let reason = DockerSocketLocator.StopRefusal.dockerHost.reason
        #expect(stopper.eligibility(of: sample(), project: nil, exclusions: ExclusionFilter()) == .denied(reason: reason))
        #expect(await stopper.preview(target) == .unavailable(.denied(reason: reason)))
        #expect(await stopper.stop(target) == .denied(reason: reason))
        #expect(server.requestLines.isEmpty)
        #expect(await ledger.records(since: .distantPast).map(\.outcome) == ["denied"])

        let reading = DockerEngineSampler(environment: environment, home: home).reading()
        #expect(reading.availability == .available)
        #expect(server.requestLines.first == "GET /version HTTP/1.1")
        #expect(server.posts.isEmpty)
    }

    // MARK: 9–10. Switch off, one at a time

    @Test("9. Switch off: DisabledContainerStopper refuses, records it, and opens no socket")
    func disabled() async throws {
        let server = try EngineStub(engine())
        defer { server.stop() }
        let ledger = StopLedger()
        let disabled = DisabledContainerStopper(ledger: ledger)
        let reason = DisabledContainerStopper.reason
        #expect(disabled.eligibility(of: sample(), project: nil, exclusions: ExclusionFilter()) == .denied(reason: reason))
        #expect(await disabled.preview(target) == .unavailable(.denied(reason: reason)))
        #expect(await disabled.stop(target) == .denied(reason: reason))
        #expect(server.requestLines.isEmpty)
        let record = try #require(await ledger.records(since: .distantPast).first)
        #expect(record.action == .containerStop && record.outcome == "denied" && record.signalSentAt == nil && record.detail == reason)
    }

    @Test("10. A second stop while one is in flight is .denied; one POST in total")
    func inFlight() async throws {
        let server = try EngineStub(engine(stop: .init(status: 204, body: nil, delay: 1.0)))
        defer { server.stop() }
        let ledger = StopLedger()
        let stopper = stopper(server, ledger: ledger)
        let first = Task { await stopper.stop(target) }
        let deadline = Date().addingTimeInterval(3)
        while server.posts.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(server.posts.count == 1)
        #expect(await stopper.stop(target) == .denied(reason: ContainerStopper.anotherStopReason))
        #expect(await first.value == .stopped)
        #expect(server.posts.count == 1)
        #expect(await ledger.records(since: .distantPast).map(\.outcome) == ["denied", "stopped"])
        // Free again afterwards.
        #expect(await stopper.preview(target) != .unavailable(.denied(reason: ContainerStopper.anotherStopReason)))
    }

    // MARK: 11. Source greps

    @Test("11. One \"POST \" literal in Sources/, in UnixSocketHTTP; no CLI or probe target mentions the stopper")
    func sourceGreps() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var files: [(path: String, text: String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append((String(url.path.dropFirst(sources.path.count + 1)), try String(contentsOf: url, encoding: .utf8)))
        }
        #expect(files.count > 10, "Sources/ not found at \(sources.path)")
        let needle = "\"" + "POST "
        let posts = files.flatMap { file in file.text.components(separatedBy: "\n").filter { $0.contains(needle) }.map { _ in file.path } }
        #expect(posts == ["HeatLensCore/Docker/UnixSocketHTTP.swift"])

        let cli = files.filter { !$0.path.hasPrefix("HeatLensCore/") }
        #expect(!cli.isEmpty)
        for word in ["ContainerStopper", "containerStop", "ContainerStopping", "DisabledContainerStopper", ".post("] {
            #expect(cli.filter { $0.text.contains(word) }.map(\.path).isEmpty, "\(word) in a CLI target")
        }
    }

    // MARK: 12. Live

    @Test("12. This Mac: stop a fixture container this test started, through ContainerStopper only",
          .enabled(if: ProcessInfo.processInfo.environment["HEATLENS_LIVE_CONTAINER_STOP"] == "1"
                   && FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.docker/run/docker.sock")))
    func liveStop() async throws {
        let started = try docker(["run", "-d", "--rm", "--label", "heatlens.test=fixture", "alpine", "sleep", "300"])
        let id = started.trimmingCharacters(in: .whitespacesAndNewlines)
        try #require(DockerContainerID(id)?.isFull == true, "docker run printed \(started)")
        defer {
            // Only this test's own container, and only if it is still there.
            if let listed = try? docker(["ps", "-aq", "--no-trunc", "--filter", "id=\(id)"]), listed.contains(id) {
                _ = try? docker(["rm", "-f", id])
            }
        }
        let sampler = DockerEngineSampler()
        let container = try #require(DockerAssembly.snapshot(before: nil, after: sampler.reading()).containers.first { $0.containerID == id })
        #expect(container.labels["heatlens.test"] == "fixture")
        let ledger = StopLedger()
        let stopper = ContainerStopper(ledger: ledger)
        #expect(stopper.eligibility(of: container, project: nil, exclusions: ExclusionFilter()) == .eligible)
        let outcome = await stopper.stop(ContainerStopTarget(container: container, project: nil, exclusions: ExclusionFilter()))
        #expect(outcome == .stopped)
        let after = DockerAssembly.snapshot(before: nil, after: sampler.reading())
        #expect(!after.containers.contains { $0.containerID == id && $0.isRunning })
        #expect(await ledger.records(since: .distantPast).map(\.outcome) == ["stopped"])
    }
}

/// Test 12 only: the test's own fixture container through the `docker` CLI.
private func docker(_ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["docker"] + arguments
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = "/usr/local/bin:/opt/homebrew/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}
