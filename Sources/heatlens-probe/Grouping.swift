import Foundation
import HeatLensCore

/// One process as the grouping step sees it (only fields the probe could read).
struct ProcRow {
    let pid: pid_t
    let ppid: pid_t
    let uid: uid_t
    let comm: String
    let name: String
    let path: String?
    let cwd: String?
    let args: ProcessArguments?
    let start: Date
    let cpuPercent: Double?
    let footprint: UInt64?

    var exeBase: String { ((path ?? args?.executablePath) as NSString?)?.lastPathComponent ?? comm }
    var argv: [String] { args?.arguments ?? [] }
}

/// A spike version of PRD §4.2's hints. Returns (kind, confidence, basis).
func classify(_ r: ProcRow) -> (kind: String, confidence: String, basis: String) {
    let exe = r.exeBase
    let argv = r.argv
    let argvBases = argv.map { ($0 as NSString).lastPathComponent }
    let joined = argv.joined(separator: " ")
    let fullPath = r.path ?? r.args?.executablePath ?? ""

    if fullPath.contains("Superset.app") || fullPath.contains("/Superset/") { return ("superset", "high", "exe path") }
    if exe == "claude" || argvBases.first == "claude" || joined.contains("@anthropic-ai/claude-code") { return ("claude", "high", exe == "claude" ? "exe name" : "argv") }
    if exe.hasPrefix("opencode") || (argvBases.first ?? "").hasPrefix("opencode") { return ("opencode", "high", "exe/argv") }
    if (argv.first ?? "").hasPrefix("next-server") { return ("next-server", "high", "argv[0] title") }
    if argvBases.contains("next") { return (argv.contains("dev") ? "next dev" : "next \(argv.last ?? "")", "high", "argv") }
    for tool in ["vitest", "jest", "vite", "turbo", "webpack", "astro", "esbuild", "nodemon", "ts-node", "tsx"] where argvBases.contains(tool) {
        return (tool, "high", "argv")
    }
    if argvBases.contains("tsc") { return (argv.contains("--watch") || argv.contains("-w") ? "tsc --watch" : "tsc", "high", "argv") }
    if joined.contains("/bin/jarvis") { return ("jarvis watcher", "high", "argv") }
    if ["node", "bun", "deno"].contains(exe) {
        if let script = argv.dropFirst().first(where: { !$0.hasPrefix("-") && [".js", ".mjs", ".cjs", ".ts", ".mts"].contains(where: $0.hasSuffix) }) {
            return ("\(exe) script: \((script as NSString).lastPathComponent)", "medium", "argv script path")
        }
        return ("\(exe) (unclassified)", "low", argv.isEmpty ? "argv unavailable" : "argv has no script")
    }
    if ["pnpm", "npm", "yarn", "npx"].contains(exe) || argvBases.first.map({ ["pnpm", "npm", "yarn", "npx"].contains($0) }) == true {
        return ("\(exe) \(argv.dropFirst().prefix(2).joined(separator: " "))", "medium", "argv")
    }
    if exe.lowercased().hasPrefix("docker") || exe.hasPrefix("com.docker") { return ("docker", "high", "exe name") }
    if exe.hasPrefix("python") || exe.hasPrefix("Python") { return ("python", "medium", "exe name") }
    if ["swift-build", "swift-frontend", "swift-test", "swift", "xcodebuild", "SourceKitService", "swift-driver", "clang"].contains(exe) { return ("swift/xcode build", "high", "exe name") }
    if ["zsh", "bash", "sh", "fish", "login", "-zsh"].contains(exe) { return ("shell", "high", "exe name") }
    return ("other", "—", "no rule")
}

/// Project directory guess from cwd first, then an absolute script path in argv.
func projectGuess(_ r: ProcRow) -> (dir: String?, basis: String) {
    let home = homeDirectory
    if let cwd = r.cwd {
        if cwd.hasPrefix(home + "/") { return (redact(cwd), "cwd") }
        if cwd == home { return (nil, "cwd is home") }
        if cwd == "/" { return (nil, "cwd is /") }
        return (redact(cwd), "cwd outside home")
    }
    if let script = r.argv.dropFirst().first(where: { $0.hasPrefix(home + "/") }) {
        return (redact((script as NSString).deletingLastPathComponent), "argv path")
    }
    return (nil, r.args == nil ? "cwd+argv unavailable" : "no path evidence")
}

/// Parent chain by comm, nearest parent first, stopping at launchd.
func ancestry(of pid: pid_t, in table: [pid_t: (ppid: pid_t, comm: String)], max: Int = 10) -> [String] {
    var out: [String] = []
    var cur = table[pid]?.ppid ?? 0
    var seen: Set<pid_t> = [pid]
    while cur > 0, !seen.contains(cur), out.count < max {
        seen.insert(cur)
        guard let info = table[cur] else { out.append("?\(cur)"); break }
        out.append(info.comm + "(\(cur))")
        if cur == 1 { break }
        cur = info.ppid
    }
    return out
}
