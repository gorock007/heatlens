import Darwin
import Foundation
import Testing
@testable import HeatLensCore

private struct FakeTransport: DockerTransport {
    let handler: @Sendable (String) throws -> UnixSocketHTTP.Response
    func get(_ path: String) throws -> UnixSocketHTTP.Response { try handler(path) }
}

private func ok(_ json: String) -> UnixSocketHTTP.Response {
    UnixSocketHTTP.Response(status: 200, headers: ["content-type": "application/json"], body: Data(json.utf8))
}

private let dbID = String(repeating: "2b9aeb6c80e3", count: 5) + "d19e"
private let webID = String(repeating: "a1b2c3d4e5f6", count: 5) + "0123"
private let oldID = String(repeating: "ffeeddccbbaa", count: 5) + "9876"

/// Shaped like Docker Desktop 28.5.1's answers; names and paths are synthetic.
private func engine(dbTotal: UInt64, webTotal: UInt64 = 10_000_000_000, apiVersion: String = "1.51",
                    log: (@Sendable (String) -> Void)? = nil) -> FakeTransport {
    FakeTransport { path in
        log?(path)
        switch path {
        case "/version":
            return ok(#"{"Version":"28.5.1","ApiVersion":"\#(apiVersion)","MinAPIVersion":"1.24","Os":"linux"}"#)
        case "/v\(apiVersion)/containers/json?all=1":
            return ok("""
            [{"Id":"\(dbID)","Names":["/demo-db-1"],"Image":"postgres:17","State":"running","Status":"Up 3 days","Created":1792760413,
              "Labels":{"com.docker.compose.project":"demo","com.docker.compose.service":"db",
                        "com.docker.compose.project.working_dir":"/Users/someone/Developer/demo"}},
             {"Id":"\(oldID)","Names":["/build-cache"],"Image":"alpine","State":"exited","Status":"Exited (0) 2 days ago","Created":1792700000,"Labels":null},
             {"Id":"\(webID)","Names":["/demo-web-1"],"Image":"node:22","State":"running","Status":"Up 1 hour","Created":1792790000,"Labels":{}}]
            """)
        case "/v\(apiVersion)/containers/\(dbID)/stats?stream=false&one-shot=true":
            return ok(#"{"read":"2026-10-27T10:00:00Z","cpu_stats":{"cpu_usage":{"total_usage":\#(dbTotal)},"system_cpu_usage":1,"online_cpus":6},"precpu_stats":{"cpu_usage":{"total_usage":0}},"memory_stats":{"usage":246607872,"stats":{"inactive_file":100245504}}}"#)
        case "/v\(apiVersion)/containers/\(webID)/stats?stream=false&one-shot=true":
            return ok(#"{"cpu_stats":{"cpu_usage":{"total_usage":\#(webTotal)},"online_cpus":6},"memory_stats":{"usage":1000}}"#)
        default:
            return UnixSocketHTTP.Response(status: 404, headers: [:], body: Data("{\"message\":\"page not found\"}".utf8))
        }
    }
}

private final class PathLog: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func append(_ path: String) { lock.lock(); paths.append(path); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return paths }
}

@Suite("Docker Engine adapter")
struct DockerEngineTests {
    // MARK: Request building

    @Test("Requests are GET only, to allowlisted characters; CR, LF, spaces and non-ASCII are refused")
    func requestBuilding() throws {
        let request = String(decoding: try UnixSocketHTTP.request(path: "/v1.51/containers/json?all=1"), as: UTF8.self)
        #expect(request.hasPrefix("GET /v1.51/containers/json?all=1 HTTP/1.1\r\n"))
        #expect(request.hasSuffix("Connection: close\r\n\r\n"))
        for bad in ["containers/json", "/a b", "/a\r\nX-Evil: 1", "/é", "/a#b", "/a%0d", "/a;rm"] {
            #expect(throws: UnixSocketHTTP.Failure.invalidPath) { try UnixSocketHTTP.request(path: bad) }
        }
    }

    @Test("Container IDs must be 12–64 lowercase hex characters")
    func containerIDs() {
        #expect(DockerContainerID(dbID)?.value == dbID)
        #expect(DockerContainerID("2b9aeb6c80e3") != nil)
        for bad in ["2B9AEB6C80E3", "2b9aeb6c80e", "../../etc/passwd", "2b9aeb6c80e3?x=1", String(repeating: "a", count: 65), "fda-db-1"] {
            #expect(DockerContainerID(bad) == nil, "\(bad)")
        }
    }

    @Test("Every endpoint path is fixed and passes the path allowlist")
    func endpoints() throws {
        let api = try #require(DockerAPIVersion("1.51"))
        let id = try #require(DockerContainerID(dbID))
        #expect(DockerEndpoint.containers(api: api).path == "/v1.51/containers/json?all=1")
        #expect(DockerEndpoint.stats(api: api, id: id).path == "/v1.51/containers/\(dbID)/stats?stream=false&one-shot=true")
        for endpoint in [DockerEndpoint.ping, .version, .containers(api: api), .stats(api: api, id: id)] {
            #expect(UnixSocketHTTP.isAllowedPath(endpoint.path))
        }
    }

    @Test("API versions parse strictly and compare numerically")
    func apiVersions() throws {
        #expect(try #require(DockerAPIVersion("1.51")) > DockerAPIVersion.minimum)
        #expect(try #require(DockerAPIVersion("1.9")) < DockerAPIVersion.minimum)
        #expect(DockerAPIVersion("1.41") == DockerAPIVersion.minimum)
        for bad in ["", "1", "1.51.2", "v1.51", "1.a", "1.-1", "1.5 1"] {
            #expect(DockerAPIVersion(bad) == nil, "\(bad)")
        }
    }

    // MARK: Response parsing

    @Test("Parses Content-Length, chunked (with extensions) and connection-close bodies")
    func parsing() throws {
        let plain = try UnixSocketHTTP.parse(Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n[]".utf8))
        #expect(plain.status == 200 && plain.body == Data("[]".utf8) && plain.headers["content-type"] == "application/json")
        let chunked = try UnixSocketHTTP.parse(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4;ext=1\r\n[{\"a\r\n4\r\n\":1}\r\n1\r\n]\r\n0\r\n\r\n".utf8))
        #expect(String(decoding: chunked.body, as: UTF8.self) == "[{\"a\":1}]")
        let closeDelimited = try UnixSocketHTTP.parse(Data("HTTP/1.0 404 Not Found\r\n\r\nnope".utf8))
        #expect(closeDelimited.status == 404 && closeDelimited.body == Data("nope".utf8))
    }

    @Test("Malformed, truncated and oversized responses are errors")
    func badResponses() {
        let cases: [(String, UnixSocketHTTP.Failure)] = [
            ("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n", .malformed("no end of headers")),
            ("SMTP 220 hi\r\n\r\n", .malformed("bad status line")),
            ("HTTP/1.1 200 OK\r\nno colon here\r\n\r\n", .malformed("bad header line")),
            ("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort", .malformed("truncated body")),
            ("HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n", .malformed("bad content-length")),
            ("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n", .malformed("bad chunk size")),
            ("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nabcdXX0\r\n\r\n", .malformed("chunk not followed by CRLF")),
            ("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n10\r\nabc", .malformed("truncated chunk")),
        ]
        for (raw, failure) in cases {
            #expect(throws: failure) { try UnixSocketHTTP.parse(Data(raw.utf8)) }
        }
        #expect(throws: UnixSocketHTTP.Failure.responseTooLarge) {
            try UnixSocketHTTP.parse(Data("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n".utf8) + Data(count: 100), maxBodyBytes: 99)
        }
        #expect(throws: UnixSocketHTTP.Failure.responseTooLarge) {
            try UnixSocketHTTP.parse(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n64\r\n".utf8) + Data(count: 100) + Data("\r\n0\r\n\r\n".utf8),
                                     maxBodyBytes: 99)
        }
    }

    @Test("Completeness check recognises full Content-Length and chunked responses only")
    func completeness() {
        #expect(UnixSocketHTTP.isComplete(Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n[]".utf8)))
        #expect(!UnixSocketHTTP.isComplete(Data("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n[]".utf8)))
        #expect(UnixSocketHTTP.isComplete(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n[]\r\n0\r\n\r\n".utf8)))
        #expect(!UnixSocketHTTP.isComplete(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n[]\r\n".utf8)))
        #expect(!UnixSocketHTTP.isComplete(Data("HTTP/1.1 200 OK\r\n\r\nbody".utf8)))
    }

    // MARK: Real sockets

    @Test("Over a real Unix socket: a chunked answer written in pieces is read in full")
    func realSocket() throws {
        let server = try TestSocketServer { fd in
            TestSocketServer.write(fd, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n")
            usleep(50_000)
            TestSocketServer.write(fd, "6\r\n world\r\n0\r\n\r\n")
        }
        defer { server.stop() }
        let response = try UnixSocketHTTP.get(path: "/_ping", socketPath: server.path, timeout: 2)
        #expect(response.status == 200 && String(decoding: response.body, as: UTF8.self) == "hello world")
        #expect(server.receivedRequest().hasPrefix("GET /_ping HTTP/1.1\r\n"))
    }

    @Test("A server that never answers times out within the deadline")
    func timeout() throws {
        let server = try TestSocketServer { _ in usleep(1_500_000) }
        defer { server.stop() }
        let started = Date()
        #expect(throws: UnixSocketHTTP.Failure.timedOut) {
            try UnixSocketHTTP.get(path: "/_ping", socketPath: server.path, timeout: 0.3)
        }
        #expect(Date().timeIntervalSince(started) < 1.2)
    }

    @Test("A missing socket is ENOENT, mapped to socketNotFound; refused and timeouts are daemonNotResponding")
    func connectFailures() {
        let missing = NSTemporaryDirectory() + "heatlens-missing-\(UUID().uuidString.prefix(8)).sock"
        #expect(throws: UnixSocketHTTP.Failure.connectFailed(ENOENT)) { try UnixSocketHTTP.get(path: "/_ping", socketPath: missing) }
        #expect(throws: UnixSocketHTTP.Failure.socketPathTooLong) {
            try UnixSocketHTTP.get(path: "/_ping", socketPath: "/" + String(repeating: "a", count: 200))
        }
        #expect(DockerEngineSampler.availability(for: UnixSocketHTTP.Failure.connectFailed(ENOENT)) == .socketNotFound)
        #expect(DockerEngineSampler.availability(for: UnixSocketHTTP.Failure.connectFailed(EACCES)) == .permissionDenied)
        #expect(DockerEngineSampler.availability(for: UnixSocketHTTP.Failure.connectFailed(ECONNREFUSED)) == .daemonNotResponding)
        #expect(DockerEngineSampler.availability(for: UnixSocketHTTP.Failure.timedOut) == .daemonNotResponding)
    }

    // MARK: Socket discovery

    @Test("DOCKER_HOST is used only for unix://; Docker Desktop's path comes next, then /var/run")
    func candidates() {
        #expect(DockerSocketLocator.candidates(environment: ["DOCKER_HOST": "unix:///tmp/d.sock"], home: "/Users/x")
            == ["/tmp/d.sock", "/Users/x/.docker/run/docker.sock", "/var/run/docker.sock"])
        #expect(DockerSocketLocator.candidates(environment: ["DOCKER_HOST": "tcp://10.0.0.5:2375"], home: "/Users/x")
            == ["/Users/x/.docker/run/docker.sock", "/var/run/docker.sock"])
    }

    @Test("The locator skips missing paths and refuses non-sockets and sockets owned by another user")
    func locator() {
        let socket = (mode: mode_t(S_IFSOCK | 0o755), owner: uid_t(501))
        let home = "/Users/x"
        let desktop = home + "/.docker/run/docker.sock"
        #expect(DockerSocketLocator.locate(environment: [:], home: home, stat: { $0 == "/var/run/docker.sock" ? socket : nil },
                                           currentUser: 501) == .success("/var/run/docker.sock"))
        #expect(DockerSocketLocator.locate(environment: [:], home: home, stat: { $0 == desktop ? (mode_t(S_IFREG | 0o644), 501) : nil },
                                           currentUser: 501) == .failure(.notASocket(desktop)))
        #expect(DockerSocketLocator.locate(environment: [:], home: home, stat: { $0 == desktop ? (mode_t(S_IFSOCK), 502) : nil },
                                           currentUser: 501) == .failure(.untrustedOwner(desktop)))
        #expect(DockerSocketLocator.locate(environment: [:], home: home, stat: { $0 == desktop ? (mode_t(S_IFSOCK), 0) : nil },
                                           currentUser: 501) == .success(desktop))
        #expect(DockerSocketLocator.locate(environment: [:], home: home, stat: { _ in nil }, currentUser: 501) == .failure(.notFound))
    }

    // MARK: Sampling and assembly

    @Test("Two readings give containers with CPU from the usage delta (100 = one core), memory without page cache")
    func interval() throws {
        let before = DockerEngineSampler(transport: engine(dbTotal: 561_000_000_000)).reading()
        let after = DockerEngineSampler(transport: engine(dbTotal: 561_000_000_000 + 400_000_000)).reading()
        // Pin the interval so the expectation is exact.
        let elapsed: UInt64 = 1_000_000_000
        let pinned = DockerReading(availability: after.availability, engineVersion: after.engineVersion, apiVersion: after.apiVersion,
                                   containers: after.containers, stats: after.stats,
                                   monotonicNanoseconds: before.monotonicNanoseconds + elapsed, notices: after.notices)
        let snapshot = DockerAssembly.snapshot(before: before, after: pinned)
        #expect(snapshot.availability == .available && snapshot.engineVersion == "28.5.1" && snapshot.apiVersion == "1.51")
        #expect(snapshot.containers.map(\.name) == ["demo-db-1", "demo-web-1", "build-cache"])
        let db = try #require(snapshot.containers.first)
        #expect(db.cpuPercentOfOneCore == 40)
        #expect(db.memoryBytes == 246_607_872 - 100_245_504)
        #expect(db.vmCPUCount == 6)
        #expect(db.composeProject == "demo" && db.composeService == "db" && db.composeWorkingDirectory == "/Users/someone/Developer/demo")
        #expect(db.shortID == "2b9aeb6c80e3" && db.isRunning)
        #expect(snapshot.containers[1].cpuPercentOfOneCore == 0)
        let stopped = snapshot.containers[2]
        #expect(stopped.cpuPercentOfOneCore == nil && stopped.memoryBytes == nil && stopped.labels.isEmpty)
    }

    @Test("CPU is nil without a previous reading, after a restart (counter went backwards), or with no elapsed time")
    func cpuEdgeCases() {
        let a = DockerStatsCounters(totalUsageNanoseconds: 2_000, onlineCPUs: 6, memoryBytes: nil)
        let b = DockerStatsCounters(totalUsageNanoseconds: 1_000, onlineCPUs: 6, memoryBytes: nil)
        #expect(DockerAssembly.cpuPercent(before: nil, after: a, elapsedNanoseconds: 1_000) == nil)
        #expect(DockerAssembly.cpuPercent(before: a, after: b, elapsedNanoseconds: 1_000) == nil)
        #expect(DockerAssembly.cpuPercent(before: b, after: a, elapsedNanoseconds: 0) == nil)
        #expect(DockerAssembly.cpuPercent(before: b, after: a, elapsedNanoseconds: 1_000) == 100)
    }

    @Test("Stats are requested only for running containers, through fixed paths")
    func requestedPaths() {
        let log = PathLog()
        _ = DockerEngineSampler(transport: engine(dbTotal: 1, log: { log.append($0) })).reading()
        #expect(log.all == ["/version", "/v1.51/containers/json?all=1",
                            "/v1.51/containers/\(dbID)/stats?stream=false&one-shot=true",
                            "/v1.51/containers/\(webID)/stats?stream=false&one-shot=true"])
    }

    @Test("An Engine older than API 1.41 is unsupported; HTTP errors and bad JSON are errors, not crashes")
    func engineFailures() {
        #expect(DockerEngineSampler(transport: engine(dbTotal: 1, apiVersion: "1.40")).reading().availability
            == .unsupportedAPI(version: "1.40"))
        let failing = FakeTransport { _ in UnixSocketHTTP.Response(status: 500, headers: [:], body: Data()) }
        #expect(DockerEngineSampler(transport: failing).reading().availability == .error(message: "Docker Engine answered HTTP 500"))
        let garbage = FakeTransport { _ in ok("not json") }
        #expect(DockerEngineSampler(transport: garbage).reading().availability
            == .error(message: "Docker Engine sent a response HeatLens couldn't read"))
        let refused = FakeTransport { _ in throw UnixSocketHTTP.Failure.connectFailed(ECONNREFUSED) }
        let snapshot = DockerAssembly.snapshot(before: nil, after: DockerEngineSampler(transport: refused).reading())
        #expect(snapshot.availability == .daemonNotResponding && snapshot.containers.isEmpty)
        #expect(DockerAssembly.snapshot(before: nil, after: DisabledDockerSampler().reading()).availability == .disabled)
    }

    @Test("More running containers than the cap: stats for the first 20 and a notice; odd IDs are skipped")
    func cap() {
        let ids = (0..<23).map { String(format: "%064x", $0 + 1) }
        let transport = FakeTransport { path in
            if path == "/version" { return ok(#"{"Version":"28.5.1","ApiVersion":"1.51"}"#) }
            if path.hasSuffix("/containers/json?all=1") {
                let rows = ids.map { #"{"Id":"\#($0)","Names":["/c"],"Image":"x","State":"running","Created":0}"# }
                    + [#"{"Id":"NOT-HEX","Names":["/odd"],"Image":"x","State":"running","Created":0}"#]
                return ok("[" + rows.joined(separator: ",") + "]")
            }
            return ok(#"{"cpu_stats":{"cpu_usage":{"total_usage":5}},"memory_stats":{}}"#)
        }
        let reading = DockerEngineSampler(transport: transport).reading()
        #expect(reading.stats.count == 20)
        #expect(reading.containers.count == 23)
        #expect(reading.notices.contains("CPU and memory for 20 of 23 running containers"))
        #expect(reading.notices.contains("1 container(s) with an unexpected ID were skipped"))
    }

    @Test("This Mac: the local Docker Engine lists containers", .enabled(if: {
        if case .success = DockerSocketLocator.locate(environment: [:], home: NSHomeDirectory()) { return true }
        return false
    }()))
    func liveDocker() {
        let sampler = DockerEngineSampler()
        let first = sampler.reading()
        // Docker Desktop may be quitting or starting; anything but a crash is acceptable then.
        guard first.availability.isAvailable else { return }
        let snapshot = DockerAssembly.snapshot(before: first, after: sampler.reading())
        #expect(snapshot.availability == .available)
        #expect(snapshot.containers.allSatisfy { DockerContainerID($0.containerID) != nil })
        for container in snapshot.containers where container.isRunning {
            #expect(container.memoryBytes != nil)
        }
    }
}

/// A one-connection `AF_UNIX` server on a background thread. `respond` gets the accepted fd.
private final class TestSocketServer: @unchecked Sendable {
    let path: String
    private let listener: Int32
    private let lock = NSLock()
    private var request = Data()
    private let done = DispatchSemaphore(value: 0)

    init(respond: @escaping @Sendable (Int32) -> Void) throws {
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
        guard bound == 0, listen(fd, 1) == 0 else { throw UnixSocketHTTP.Failure.ioFailed(errno) }
        DispatchQueue.global().async { [self] in
            let client = accept(fd, nil, nil)
            if client >= 0 {
                var buffer = [UInt8](repeating: 0, count: 4096)
                let count = read(client, &buffer, buffer.count)
                if count > 0 {
                    lock.lock(); request.append(buffer, count: count); lock.unlock()
                }
                respond(client)
                close(client)
            }
            done.signal()
        }
    }

    static func write(_ fd: Int32, _ text: String) {
        let data = Array(text.utf8)
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, data.count) }
    }

    func receivedRequest() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: request, as: UTF8.self)
    }

    func stop() {
        _ = done.wait(timeout: .now() + 3)
        close(listener)
        unlink(path)
    }
}
