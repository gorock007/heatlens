import Foundation

nonisolated(unsafe) var lastLaunchError: String?

/// Runs one executable directly (no shell) and captures its output. nil = could not launch (see `lastLaunchError`).
func runTool(_ path: String, _ arguments: [String]) -> (status: Int32, stdout: String, stderr: String)? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = arguments
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { lastLaunchError = "\(error)"; return nil }
    let o = out.fileHandleForReading.readDataToEndOfFile()
    let e = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
}

let homeDirectory: String = {
    if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) }
    return NSHomeDirectory()
}()

/// Replaces the home directory with `~` (reports never need the username).
func redact(_ s: String) -> String {
    s.replacingOccurrences(of: homeDirectory, with: "~")
}

func fmtBytes(_ b: UInt64) -> String {
    let d = Double(b)
    if d >= 1_073_741_824 { return String(format: "%.2f GB", d / 1_073_741_824) }
    if d >= 1_048_576 { return String(format: "%.0f MB", d / 1_048_576) }
    if d >= 1024 { return String(format: "%.0f KB", d / 1024) }
    return "\(b) B"
}

func fmtDuration(_ s: TimeInterval) -> String {
    let t = Int(s)
    if t >= 86_400 { return "\(t / 86_400)d \(t % 86_400 / 3_600)h" }
    if t >= 3_600 { return "\(t / 3_600)h \(t % 3_600 / 60)m" }
    if t >= 60 { return "\(t / 60)m \(t % 60)s" }
    return "\(t)s"
}

func pad(_ s: String, _ n: Int, right: Bool = false) -> String {
    if s.count >= n { return s }
    let fill = String(repeating: " ", count: n - s.count)
    return right ? fill + s : s + fill
}

func truncate(_ s: String, _ n: Int) -> String {
    s.count <= n ? s : String(s.prefix(n - 1)) + "…"
}
