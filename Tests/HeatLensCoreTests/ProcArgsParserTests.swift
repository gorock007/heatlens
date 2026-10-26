import Foundation
import Testing
@testable import HeatLensCore

@Suite("ProcArgsParser")
struct ProcArgsParserTests {
    /// Builds a KERN_PROCARGS2-shaped buffer the way the kernel lays it out.
    private func buffer(argc: Int32, exec: String, padding: Int = 3, args: [String], env: [String] = []) -> Data {
        var d = Data()
        withUnsafeBytes(of: argc.littleEndian) { d.append(contentsOf: $0) }
        d.append(contentsOf: Array(exec.utf8)); d.append(0)
        d.append(contentsOf: [UInt8](repeating: 0, count: padding))
        for a in args { d.append(contentsOf: Array(a.utf8)); d.append(0) }
        for e in env { d.append(contentsOf: Array(e.utf8)); d.append(0) }
        return d
    }

    @Test("exec path, argv and nothing from the environment")
    func basic() throws {
        let data = buffer(argc: 3, exec: "/usr/local/bin/node",
                          args: ["node", "scripts/worker.js", "--port=3100"],
                          env: ["SECRET_TOKEN=abc", "HOME=/Users/someone"])
        let parsed = try #require(ProcArgsParser.parse(data))
        #expect(parsed.executablePath == "/usr/local/bin/node")
        #expect(parsed.arguments == ["node", "scripts/worker.js", "--port=3100"])
        #expect(parsed.reportedArgumentCount == 3)
        #expect(!parsed.isTruncated)
        #expect(!parsed.arguments.contains { $0.contains("SECRET_TOKEN") })
    }

    @Test("no padding between exec path and argv")
    func noPadding() throws {
        let parsed = try #require(ProcArgsParser.parse(buffer(argc: 1, exec: "/bin/sleep", padding: 0, args: ["sleep"])))
        #expect(parsed.arguments == ["sleep"])
    }

    @Test("rewritten argv[0] (next-server style) comes through as-is")
    func rewrittenTitle() throws {
        let parsed = try #require(ProcArgsParser.parse(buffer(argc: 1, exec: "/opt/node/bin/node", args: ["next-server (v15.3.1)"])))
        #expect(parsed.arguments == ["next-server (v15.3.1)"])
    }

    @Test("truncated buffer: partial argv is reported as truncated, no garbage argument")
    func truncated() throws {
        var data = buffer(argc: 3, exec: "/bin/x", args: ["x", "alpha", "beta"])
        data = data.prefix(data.count - 3) // cut inside "beta"
        let parsed = try #require(ProcArgsParser.parse(data))
        #expect(parsed.arguments == ["x", "alpha"])
        #expect(parsed.isTruncated)
    }

    @Test("garbage input returns nil instead of crashing")
    func garbage() {
        #expect(ProcArgsParser.parse(Data()) == nil)
        #expect(ProcArgsParser.parse(Data([1, 0])) == nil)
        #expect(ProcArgsParser.parse(Data([0xFF, 0xFF, 0xFF, 0xFF, 0x41])) == nil) // argc = -1
        #expect(ProcArgsParser.parse(Data([1, 0, 0, 0, 0x41, 0x42])) == nil)        // exec path never terminated
    }
}
