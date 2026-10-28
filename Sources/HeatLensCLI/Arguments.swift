import Foundation

/// The version `heatlens --version` and the MCP `serverInfo` report. Keep it equal to the app's
/// `CFBundleShortVersionString` (`MARKETING_VERSION` in project.yml): a release bump updates both.
public let heatlensVersion = "1.2.2"

public enum CLICommand: Equatable, Sendable {
    case help
    case version
    case scan(seconds: Int, json: Bool)
    case ports(json: Bool)
    case awake(json: Bool)
    case mcp
}

public struct CLIUsageError: Error, Equatable, CustomStringConvertible {
    public let description: String
}

public enum CLIArguments {
    public static let secondsRange = 1...15
    public static let defaultSeconds = 5

    public static let help = """
        heatlens \(heatlensVersion): see what is making this Mac hot or slow. Read-only; reports are redacted.

        Usage:
          heatlens scan [--seconds N] [--json]   Run one scan (N is 1…15, default 5) and print the
                                                 redacted text report, or the redacted JSON with --json.
          heatlens ports [--json]                List the TCP ports processes listen on right now, with
                                                 their app or project (no CPU sample; redacted).
          heatlens awake [--json]                List what is keeping this Mac awake right now (power
                                                 assertions), with their app or project (no CPU sample;
                                                 redacted).
          heatlens mcp                           Run an MCP server over stdio with three read-only tools,
                                                 scan, ports and awake.
          heatlens --help                        Show this help.
          heatlens --version                     Show the version.

        """

    /// Parses `CommandLine.arguments.dropFirst()`.
    public static func parse(_ arguments: [String]) throws -> CLICommand {
        var it = arguments.makeIterator()
        guard let first = it.next() else { return .help }
        switch first {
        case "--help", "-h", "help":
            return .help
        case "--version", "-V", "version":
            return .version
        case "mcp":
            if let extra = it.next() { throw CLIUsageError(description: "unknown argument for mcp: \(extra)") }
            return .mcp
        case "scan":
            var seconds = defaultSeconds
            var json = false
            while let a = it.next() {
                switch a {
                case "--json": json = true
                case "--seconds":
                    guard let value = it.next() else { throw CLIUsageError(description: "--seconds needs a value (1…15)") }
                    guard let n = Int(value), secondsRange.contains(n) else {
                        throw CLIUsageError(description: "--seconds must be a whole number from 1 to 15, got \(value)")
                    }
                    seconds = n
                case "--help", "-h": return .help
                default: throw CLIUsageError(description: "unknown flag for scan: \(a)")
                }
            }
            return .scan(seconds: seconds, json: json)
        case "ports", "awake":
            var json = false
            while let a = it.next() {
                switch a {
                case "--json": json = true
                case "--help", "-h": return .help
                default: throw CLIUsageError(description: "unknown flag for \(first): \(a)")
                }
            }
            return first == "ports" ? .ports(json: json) : .awake(json: json)
        default:
            throw CLIUsageError(description: "unknown command: \(first)")
        }
    }
}
