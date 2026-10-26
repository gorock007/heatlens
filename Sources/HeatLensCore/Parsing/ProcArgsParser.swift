import Foundation

/// argv of a process as recovered from `sysctl(KERN_PROCARGS2)`.
public struct ProcessArguments: Hashable, Sendable {
    /// The executable path as the kernel recorded it at exec (may differ from `proc_pidpath`).
    public let executablePath: String
    /// argv[0...]. Processes that rewrite their title (e.g. `next-server (v15)`) show the rewritten argv[0].
    public let arguments: [String]
    /// `argc` as stored in the buffer. Larger than `arguments.count` when the buffer was cut short.
    public let reportedArgumentCount: Int

    public init(executablePath: String, arguments: [String], reportedArgumentCount: Int) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.reportedArgumentCount = reportedArgumentCount
    }

    public var isTruncated: Bool { arguments.count < reportedArgumentCount }
}

/// Parses the `KERN_PROCARGS2` buffer layout: a native-endian `Int32` argc, the exec
/// path NUL-terminated, NUL padding, then argc NUL-terminated argv strings, then the
/// environment. The environment is deliberately never decoded (PRD §4.1: no env vars).
public enum ProcArgsParser {
    public static func parse(_ data: Data) -> ProcessArguments? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        let argc = Int(Int32(littleEndian: bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }))
        guard argc >= 0 else { return nil }

        var cursor = 4
        guard let exec = readCString(bytes, &cursor) else { return nil }
        while cursor < bytes.count, bytes[cursor] == 0 { cursor += 1 }

        var args: [String] = []
        args.reserveCapacity(min(argc, 256))
        while args.count < argc, let s = readCString(bytes, &cursor) {
            args.append(s)
        }
        return ProcessArguments(executablePath: exec, arguments: args, reportedArgumentCount: argc)
    }

    /// Reads one NUL-terminated string. A string cut off by the end of the buffer is
    /// dropped (returns nil) so callers see truncation rather than a mangled argument.
    private static func readCString(_ bytes: [UInt8], _ cursor: inout Int) -> String? {
        guard cursor < bytes.count else { return nil }
        guard let end = bytes[cursor...].firstIndex(of: 0) else { return nil }
        let s = String(decoding: bytes[cursor..<end], as: UTF8.self)
        cursor = end + 1
        return s
    }
}
