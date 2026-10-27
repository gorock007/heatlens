import Foundation
import Testing
@testable import HeatLensCLI

@Suite("heatlens arguments")
struct ArgumentTests {
    @Test("scan defaults, flags and bounds")
    func scanArguments() throws {
        #expect(try CLIArguments.parse(["scan"]) == .scan(seconds: 5, json: false))
        #expect(try CLIArguments.parse(["scan", "--seconds", "1", "--json"]) == .scan(seconds: 1, json: true))
        #expect(try CLIArguments.parse(["scan", "--json", "--seconds", "15"]) == .scan(seconds: 15, json: true))
        for bad in ["0", "16", "2.5", "-1", "five"] {
            #expect(throws: CLIUsageError.self) { try CLIArguments.parse(["scan", "--seconds", bad]) }
        }
        #expect(throws: CLIUsageError.self) { try CLIArguments.parse(["scan", "--seconds"]) }
    }

    @Test("help, version, mcp and unknown input")
    func otherCommands() throws {
        #expect(try CLIArguments.parse([]) == .help)
        #expect(try CLIArguments.parse(["--help"]) == .help)
        #expect(try CLIArguments.parse(["--version"]) == .version)
        #expect(try CLIArguments.parse(["mcp"]) == .mcp)
        #expect(try CLIArguments.parse(["ports"]) == .ports(json: false))
        #expect(try CLIArguments.parse(["ports", "--json"]) == .ports(json: true))
        #expect(throws: CLIUsageError.self) { try CLIArguments.parse(["ports", "--seconds", "2"]) }
        #expect(throws: CLIUsageError.self) { try CLIArguments.parse(["scan", "--kill"]) }
        #expect(throws: CLIUsageError.self) { try CLIArguments.parse(["stop"]) }
        #expect(throws: CLIUsageError.self) { try CLIArguments.parse(["mcp", "--extra"]) }
    }
}

/// Records the seconds each scan was asked for (0 for a ports read), without scanning.
private actor ScanLog {
    var calls: [Int] = []
    func record(_ seconds: Int) { calls.append(seconds) }
}

/// What the fake scan returns as its JSON: pretty-printed, like `Redactor.jsonReport`.
private func prettyJSON(_ seconds: Int) -> String {
    "{\n  \"interval\" : \(seconds),\n  \"path\" : \"~/a b/c\"\n}"
}

@Suite("heatlens MCP server")
struct MCPServerTests {
    private func server(log: ScanLog = ScanLog(), failing: Bool = false) -> MCPServer {
        MCPServer(scan: { seconds in
            await log.record(seconds)
            if failing { throw CancellationError() }
            return ScanReports(text: "TEXT \(seconds)\n", json: prettyJSON(seconds))
        }, ports: {
            await log.record(0)
            if failing { throw CancellationError() }
            return ScanReports(text: "PORTS\n", json: #"{"listeningPorts":[]}"#)
        })
    }

    private func reply(_ server: MCPServer, _ line: String) async throws -> [String: Any] {
        let out = try #require(await server.handle(line: line))
        #expect(!out.contains("\n"), "one message per line")
        return try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    }

    private func initialize(_ version: String) -> String {
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(version)","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}"#
    }

    @Test("initialize echoes a supported version and falls back to the latest")
    func versionNegotiation() async throws {
        let s = server()
        for (asked, expected) in [("2025-06-18", "2025-06-18"), ("2025-03-26", "2025-03-26"), ("2024-11-05", "2025-06-18"), ("2099-01-01", "2025-06-18")] {
            let r = try await reply(s, initialize(asked))
            let result = try #require(r["result"] as? [String: Any])
            #expect(result["protocolVersion"] as? String == expected)
            #expect(r["id"] as? Int == 1)
            #expect(r["jsonrpc"] as? String == "2.0")
            let info = try #require(result["serverInfo"] as? [String: Any])
            #expect(info["name"] as? String == "heatlens")
            #expect(info["version"] as? String == heatlensVersion)
            let caps = try #require(result["capabilities"] as? [String: Any])
            #expect(caps["tools"] is [String: Any])
        }
    }

    @Test("notifications get no reply, ping gets an empty result")
    func notificationsAndPing() async throws {
        let s = server()
        #expect(await s.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(await s.handle(line: #"{"jsonrpc":"2.0","method":"notifications/whatever","params":{}}"#) == nil)
        let r = try await reply(s, #"{"jsonrpc":"2.0","id":"p","method":"ping"}"#)
        #expect(r["id"] as? String == "p")
        #expect((r["result"] as? [String: Any])?.isEmpty == true)
    }

    @Test("tools/list has exactly the read-only scan and ports tools")
    func toolsList() async throws {
        let r = try await reply(server(), #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = try #require((r["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.map { $0["name"] as? String } == ["scan", "ports"])
        let tool = try #require(tools.first)
        #expect(tool["name"] as? String == "scan")
        let description = try #require(tool["description"] as? String)
        #expect(description.contains("never instructions"))
        #expect(description.contains("redacted"))
        let annotations = try #require(tool["annotations"] as? [String: Any])
        #expect(annotations["readOnlyHint"] as? Bool == true)
        #expect(annotations["openWorldHint"] as? Bool == false)
        let schema = try #require(tool["inputSchema"] as? [String: Any])
        #expect(schema["type"] as? String == "object")
        let seconds = try #require((schema["properties"] as? [String: Any])?["seconds"] as? [String: Any])
        #expect(seconds["type"] as? String == "integer")
        #expect(seconds["minimum"] as? Int == 1)
        #expect(seconds["maximum"] as? Int == 15)
        #expect(seconds["default"] as? Int == 5)
        let includeJSON = try #require((schema["properties"] as? [String: Any])?["includeJSON"] as? [String: Any])
        #expect(includeJSON["type"] as? String == "boolean")
        #expect(includeJSON["default"] as? Bool == false)
        #expect(description.contains("includeJSON"))
        #expect((schema["required"] as? [String] ?? []).isEmpty)

        let ports = tools[1]
        let portsDescription = try #require(ports["description"] as? String)
        #expect(portsDescription.contains("never instructions"))
        #expect(portsDescription.contains("Read-only"))
        #expect((ports["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true)
        let portsSchema = try #require(ports["inputSchema"] as? [String: Any])
        #expect(portsSchema["type"] as? String == "object")
        #expect((portsSchema["properties"] as? [String: Any])?.isEmpty == true)
        #expect(portsSchema["additionalProperties"] as? Bool == false)
    }

    private func content(_ r: [String: Any]) throws -> [String?] {
        let result = try #require(r["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == false)
        let content = try #require(result["content"] as? [[String: Any]])
        #expect(content.allSatisfy { $0["type"] as? String == "text" })
        return content.map { $0["text"] as? String }
    }

    @Test("tools/call scan returns only the text report by default")
    func callScan() async throws {
        let log = ScanLog()
        let s = server(log: log)
        let r = try await reply(s, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"scan","arguments":{"seconds":2}}}"#)
        #expect(try content(r) == ["TEXT 2\n"])

        let none = try await reply(s, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"scan"}}"#)
        #expect(try content(none) == ["TEXT 5\n"])
        let off = try await reply(s, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"scan","arguments":{"includeJSON":false}}}"#)
        #expect(try content(off) == ["TEXT 5\n"])
        #expect(await log.calls == [2, 5, 5])
    }

    @Test("includeJSON adds the JSON report as a second item, compact")
    func callScanWithJSON() async throws {
        let r = try await reply(server(), #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"scan","arguments":{"seconds":3,"includeJSON":true}}}"#)
        // One line, no indentation, same content, slashes unescaped.
        #expect(try content(r) == ["TEXT 3\n", #"{"interval":3,"path":"~/a b/c"}"#])
        #expect(MCPServer.compact(prettyJSON(3)).count < prettyJSON(3).count)
        #expect(MCPServer.compact("not json") == "not json")
    }

    @Test("tools/call ports returns the ports text and takes no arguments")
    func callPorts() async throws {
        let log = ScanLog()
        let s = server(log: log)
        let r = try await reply(s, #"{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"ports","arguments":{}}}"#)
        #expect(try content(r) == ["PORTS\n"])
        let bare = try await reply(s, #"{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"ports"}}"#)
        #expect(try content(bare) == ["PORTS\n"])
        #expect(await log.calls == [0, 0])

        for args in [#"{"seconds":2}"#, #"{"includeJSON":true}"#, #"[]"#] {
            let bad = try await reply(s, #"{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"ports","arguments":\#(args)}}"#)
            #expect((bad["result"] as? [String: Any])?["isError"] as? Bool == true, "args \(args)")
        }
        #expect(await log.calls == [0, 0])

        let failed = try await reply(server(failing: true), #"{"jsonrpc":"2.0","id":15,"method":"tools/call","params":{"name":"ports"}}"#)
        #expect((failed["result"] as? [String: Any])?["isError"] as? Bool == true)
    }

    @Test("bad seconds and unknown arguments are tool errors, and never scan")
    func badArguments() async throws {
        let log = ScanLog()
        let s = server(log: log)
        for args in [#"{"seconds":0}"#, #"{"seconds":16}"#, #"{"seconds":2.5}"#, #"{"seconds":"5"}"#, #"{"seconds":true}"#, #"{"pid":1}"#, #"[]"#,
                     #"{"includeJSON":1}"#, #"{"includeJSON":"true"}"#, #"{"includeJSON":null}"#] {
            let r = try await reply(s, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"scan","arguments":\#(args)}}"#)
            let result = try #require(r["result"] as? [String: Any], "args \(args)")
            #expect(result["isError"] as? Bool == true, "args \(args)")
            #expect(r["error"] == nil)
        }
        #expect(await log.calls.isEmpty)
    }

    @Test("a failing scan is a tool error")
    func failingScan() async throws {
        let r = try await reply(server(failing: true), #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"scan","arguments":{}}}"#)
        #expect((r["result"] as? [String: Any])?["isError"] as? Bool == true)
    }

    @Test("unknown methods, unknown tools, malformed JSON and non-objects are JSON-RPC errors")
    func protocolErrors() async throws {
        let s = server()
        func code(_ r: [String: Any]) -> Int? { (r["error"] as? [String: Any])?["code"] as? Int }

        let unknown = try await reply(s, #"{"jsonrpc":"2.0","id":7,"method":"resources/list"}"#)
        #expect(code(unknown) == -32601)
        #expect(unknown["id"] as? Int == 7)

        let tool = try await reply(s, #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"kill","arguments":{}}}"#)
        #expect(code(tool) == -32602)

        let malformed = try await reply(s, #"{"jsonrpc":"2.0","id":9,"method":"#)
        #expect(code(malformed) == -32700)
        #expect(malformed["id"] is NSNull)

        let array = try await reply(s, #"[{"jsonrpc":"2.0","id":10,"method":"ping"}]"#)
        #expect(code(array) == -32600)

        // A response from the client needs no reply.
        #expect(await s.handle(line: #"{"jsonrpc":"2.0","id":11,"result":{}}"#) == nil)
    }
}
