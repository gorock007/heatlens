import Darwin
import Foundation
import HeatLensCore

/// Processes the probe spawns for itself, each self-terminating after `lifetime` seconds
/// so a crashed probe cannot leave them behind for long. Everything is also stopped by
/// PID, after re-checking identity, in `stopAll()` (the FR-09 pattern).
final class Fixtures {
    let lifetime = 60
    private(set) var busyShell: Process?
    private(set) var busyPID: pid_t?
    private(set) var busyIdentity: ProcessIdentity?
    private(set) var orphanPID: pid_t?
    private(set) var orphanIdentity: ProcessIdentity?
    private(set) var log: [String] = []

    /// `yes > /dev/null` under a shell that kills it after `lifetime`. The shell prints the
    /// `yes` PID first, so we can address it directly.
    func startBusy() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "yes >/dev/null 2>&1 & p=$!; echo $p; sleep \(lifetime); kill $p 2>/dev/null"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch {
            log.append("busy fixture: could not launch /bin/sh: \(error)")
            return
        }
        busyShell = p
        if let pid = Self.readFirstPID(pipe) {
            busyPID = pid
            busyIdentity = try? bsdInfo(pid).get().identity
            log.append("busy fixture: yes pid \(pid) under sh pid \(p.processIdentifier)")
        } else {
            log.append("busy fixture: launched sh pid \(p.processIdentifier) but did not read the yes pid")
        }
    }

    /// `nohup sleep N &` from a shell that exits at once, so the sleep is adopted by launchd (PPID 1).
    func startOrphan() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "nohup sleep \(lifetime) >/dev/null 2>&1 & echo $!"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch {
            log.append("orphan fixture: could not launch /bin/sh: \(error)")
            return
        }
        let pid = Self.readFirstPID(pipe)
        p.waitUntilExit()
        guard let pid else { log.append("orphan fixture: no pid read"); return }
        orphanPID = pid
        // Give launchd a moment to adopt it.
        for _ in 0..<20 {
            if case .success(let info) = bsdInfo(pid), info.ppid == 1 { break }
            usleep(50_000)
        }
        if case .success(let info) = bsdInfo(pid) {
            orphanIdentity = info.identity
            log.append("orphan fixture: sleep pid \(pid), ppid now \(info.ppid), comm \(info.comm)")
        }
    }

    /// Stops each fixture by PID only after its (pid, start time) still matches what we spawned.
    func stopAll() {
        if let pid = busyPID {
            stop(pid: pid, expected: busyIdentity, label: "busy yes")
        }
        if let sh = busyShell, sh.isRunning {
            sh.terminate()
            sh.waitUntilExit()
            log.append("busy fixture: sh pid \(sh.processIdentifier) terminated")
        }
        if let pid = orphanPID {
            stop(pid: pid, expected: orphanIdentity, label: "orphan sleep")
        }
    }

    private func stop(pid: pid_t, expected: ProcessIdentity?, label: String) {
        guard case .success(let now) = bsdInfo(pid) else {
            log.append("\(label) pid \(pid): already gone")
            return
        }
        guard let expected, now.identity == expected else {
            log.append("\(label) pid \(pid): identity changed (\(now.comm), start \(now.identity.startDate)); NOT signalled")
            return
        }
        let r = kill(pid, SIGTERM)
        log.append("\(label) pid \(pid): identity verified, SIGTERM \(r == 0 ? "sent" : "failed errno \(errno)")")
        for _ in 0..<40 {
            if case .failure = bsdInfo(pid) { break }
            if case .success(let i) = bsdInfo(pid), i.identity != expected { break }
            usleep(25_000)
        }
        if case .success(let i) = bsdInfo(pid), i.identity == expected {
            log.append("\(label) pid \(pid): still running after 1 s (zombie or ignoring SIGTERM)")
        } else {
            log.append("\(label) pid \(pid): confirmed exited")
        }
    }

    private static func readFirstPID(_ pipe: Pipe) -> pid_t? {
        var acc = Data()
        let h = pipe.fileHandleForReading
        while !acc.contains(10) {
            let d = h.availableData
            if d.isEmpty { break }
            acc.append(d)
        }
        let line = String(decoding: acc, as: UTF8.self).split(whereSeparator: \.isNewline).first ?? ""
        return pid_t(line.trimmingCharacters(in: .whitespaces))
    }
}
