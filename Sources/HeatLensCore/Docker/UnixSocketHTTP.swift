import Darwin
import Foundation

/// A minimal HTTP/1.1 GET over an `AF_UNIX` socket, for the local Docker Engine API.
/// `URLSession` cannot reach a Unix socket. There is deliberately no way to send any verb but
/// GET, a body, or custom headers (docs/v2/ADR-0002).
enum UnixSocketHTTP {
    struct Response: Equatable, Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    enum Failure: Error, Equatable {
        case invalidPath
        case socketPathTooLong
        /// `connect` failed with this errno (ENOENT, ECONNREFUSED, EACCES, …).
        case connectFailed(Int32)
        case ioFailed(Int32)
        case timedOut
        case responseTooLarge
        case malformed(String)
    }

    /// `sun_path` is 104 bytes, including the terminating NUL.
    static let maxSocketPathBytes = 103
    static let defaultMaxResponseBytes = 4 << 20

    /// Only these characters may appear in a request path: no spaces, CR or LF.
    static func isAllowedPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 512 && path.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "/._-?=&".unicodeScalars.contains(scalar))
        }
    }

    static func request(path: String) throws -> Data {
        guard isAllowedPath(path) else { throw Failure.invalidPath }
        return Data("GET \(path) HTTP/1.1\r\nHost: docker\r\nUser-Agent: HeatLens\r\nAccept: application/json\r\nConnection: close\r\n\r\n".utf8)
    }

    /// Blocks for at most `timeout` seconds in total.
    static func get(path: String, socketPath: String, timeout: TimeInterval = 2,
                    maxResponseBytes: Int = defaultMaxResponseBytes) throws -> Response {
        let request = try request(path: path)
        let deadline = Date().addingTimeInterval(timeout)
        let fd = try connect(socketPath)
        defer { close(fd) }
        try send(request, fd: fd, deadline: deadline)
        let raw = try receive(fd: fd, deadline: deadline, maxBytes: maxResponseBytes)
        return try parse(raw, maxBodyBytes: maxResponseBytes)
    }

    // MARK: Socket I/O

    private static func connect(_ socketPath: String) throws -> Int32 {
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count <= maxSocketPathBytes else { throw Failure.socketPathTooLong }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.ioFailed(errno) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw Failure.connectFailed(code)
        }
        return fd
    }

    private static func waitUntil(_ fd: Int32, _ events: Int16, deadline: Date) throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw Failure.timedOut }
            var poller = pollfd(fd: fd, events: events, revents: 0)
            let ready = poll(&poller, 1, Int32(min(remaining * 1000, 60_000).rounded(.up)))
            if ready > 0 { return }
            if ready == 0 { throw Failure.timedOut }
            if errno != EINTR { throw Failure.ioFailed(errno) }
        }
    }

    private static func send(_ data: Data, fd: Int32, deadline: Date) throws {
        var offset = 0
        while offset < data.count {
            try waitUntil(fd, Int16(POLLOUT), deadline: deadline)
            let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, data.count - offset) }
            if written < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw Failure.ioFailed(errno)
            }
            offset += written
        }
    }

    private static func receive(fd: Int32, deadline: Date, maxBytes: Int) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            try waitUntil(fd, Int16(POLLIN), deadline: deadline)
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw Failure.ioFailed(errno)
            }
            if count == 0 { return result }
            result.append(buffer, count: count)
            // Headers are small; allow a little on top of the body cap.
            if result.count > maxBytes + 16 * 1024 { throw Failure.responseTooLarge }
            // Stop early once a complete Content-Length or chunked response is in.
            if isComplete(result) { return result }
        }
    }

    /// Cheap completeness check, so `receive` doesn't re-parse a growing buffer on every read.
    static func isComplete(_ raw: Data) -> Bool {
        guard let headerEnd = raw.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: raw[raw.startIndex..<headerEnd.lowerBound], encoding: .utf8)?.lowercased() else {
            return false
        }
        let bodyCount = raw.distance(from: headerEnd.upperBound, to: raw.endIndex)
        for line in head.components(separatedBy: "\r\n") {
            if line.hasPrefix("content-length:"), let length = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) {
                return bodyCount >= length
            }
            if line.hasPrefix("transfer-encoding:"), line.contains("chunked") {
                let body = raw[headerEnd.upperBound...]
                return body.starts(with: Data("0\r\n\r\n".utf8)) || body.suffix(7) == Data("\r\n0\r\n\r\n".utf8)
            }
        }
        return false
    }

    // MARK: Parsing (pure)

    /// Parses a full response: Content-Length, chunked, or a body that runs to connection close.
    static func parse(_ raw: Data, maxBodyBytes: Int = defaultMaxResponseBytes) throws -> Response {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = raw.range(of: separator) else { throw Failure.malformed("no end of headers") }
        guard let head = String(data: raw[raw.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            throw Failure.malformed("headers are not UTF-8")
        }
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst().split(separator: " ", maxSplits: 2)
        guard statusLine.count >= 2, statusLine[0].hasPrefix("HTTP/1."), let status = Int(statusLine[1]), (100...599).contains(status) else {
            throw Failure.malformed("bad status line")
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { throw Failure.malformed("bad header line") }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        let rest = raw[headerEnd.upperBound...]
        let body: Data
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            body = try dechunk(Data(rest), maxBytes: maxBodyBytes)
        } else if let lengthText = headers["content-length"] {
            guard let length = Int(lengthText), length >= 0 else { throw Failure.malformed("bad content-length") }
            guard length <= maxBodyBytes else { throw Failure.responseTooLarge }
            guard rest.count >= length else { throw Failure.malformed("truncated body") }
            body = Data(rest.prefix(length))
        } else {
            guard rest.count <= maxBodyBytes else { throw Failure.responseTooLarge }
            body = Data(rest)
        }
        return Response(status: status, headers: headers, body: body)
    }

    static func dechunk(_ data: Data, maxBytes: Int) throws -> Data {
        var body = Data()
        var index = data.startIndex
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = data.range(of: crlf, in: index..<data.endIndex) else { throw Failure.malformed("truncated chunk size") }
            guard let sizeLine = String(data: data[index..<lineEnd.lowerBound], encoding: .ascii),
                  let size = Int(sizeLine.split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "", radix: 16),
                  size >= 0 else {
                throw Failure.malformed("bad chunk size")
            }
            index = lineEnd.upperBound
            if size == 0 { return body }
            guard body.count + size <= maxBytes else { throw Failure.responseTooLarge }
            guard data.distance(from: index, to: data.endIndex) >= size + 2 else { throw Failure.malformed("truncated chunk") }
            let chunkEnd = data.index(index, offsetBy: size)
            body.append(data[index..<chunkEnd])
            guard data[chunkEnd..<data.index(chunkEnd, offsetBy: 2)] == crlf else { throw Failure.malformed("chunk not followed by CRLF") }
            index = data.index(chunkEnd, offsetBy: 2)
        }
    }
}
