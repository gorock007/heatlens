import Darwin
import Foundation
import HeatLensCLI

// heatlens: user-facing CLI and stdio MCP server. Read-only, redacted output only; the logic lives in
// HeatLensCLI so it is testable. stdout carries only reports (scan) or protocol messages (mcp).

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("heatlens: \(message)\n".utf8))
    exit(code)
}

let command: CLICommand
do {
    command = try CLIArguments.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    fail("\(error)\nRun `heatlens --help` for usage.", code: 2)
}

switch command {
case .help:
    print(CLIArguments.help, terminator: "")
case .version:
    print("heatlens \(heatlensVersion)")
case let .scan(seconds, json):
    let showProgress = isatty(STDERR_FILENO) == 1
    do {
        let reports = try await LiveScan.run(seconds: seconds) { elapsed in
            guard showProgress else { return }
            FileHandle.standardError.write(Data(String(format: "\rscanning… %.0fs of %d", elapsed, seconds).utf8))
        }
        if showProgress { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }
        print(json ? reports.json : reports.text, terminator: json ? "\n" : "")
    } catch {
        if showProgress { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }
        fail("scan failed: \(error)", code: 1)
    }
case let .ports(json):
    do {
        let reports = try await LiveScan.ports()
        print(json ? reports.json : reports.text, terminator: json ? "\n" : "")
    } catch {
        fail("reading ports failed: \(error)", code: 1)
    }
case .mcp:
    let server = MCPServer(scan: { seconds in try await LiveScan.run(seconds: seconds) },
                           ports: { try await LiveScan.ports() })
    do {
        for try await line in FileHandle.standardInput.bytes.lines {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let reply = await server.handle(line: line) {
                FileHandle.standardOutput.write(Data((reply + "\n").utf8))
            }
        }
    } catch {
        fail("reading stdin failed: \(error)", code: 1)
    }
}
