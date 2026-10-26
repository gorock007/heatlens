import Darwin
import Foundation
import HeatLensCore

/// The probe's self-test fixture: a `yes >/dev/null` it spawns for itself. The wrapping shell
/// kills `yes` after `lifetime` seconds, so a crashed probe cannot leave it behind for long,
/// and kills it at once on SIGTERM. `stopAll()` signals only that shell, our own child, by
/// PID, then confirms the `yes` identity is gone (the FR-09 pattern).
final class Fixtures {
    let lifetime = 60
    private(set) var busyShell: Process?
    private(set) var busyPID: pid_t?
    private(set) var busyIdentity: ProcessIdentity?
    private(set) var log: [String] = []

    func startBusy() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "trap 'kill $y $s 2>/dev/null; exit 0' TERM; yes >/dev/null 2>&1 & y=$!; echo $y; "
                       + "sleep \(lifetime) & s=$!; wait $s; kill $y 2>/dev/null"]
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
            busyIdentity = LibprocProcessSampler.identity(of: pid)
            log.append("busy fixture: yes pid \(pid) under sh pid \(p.processIdentifier)")
        } else {
            log.append("busy fixture: launched sh pid \(p.processIdentifier) but did not read the yes pid")
        }
    }

    func stopAll() {
        guard let sh = busyShell else { return }
        if sh.isRunning {
            sh.terminate()
            sh.waitUntilExit()
        }
        guard let pid = busyPID, let expected = busyIdentity else { return }
        for _ in 0..<40 where LibprocProcessSampler.identity(of: pid) == expected { usleep(25_000) }
        let gone = LibprocProcessSampler.identity(of: pid) != expected
        log.append("busy fixture: sh pid \(sh.processIdentifier) stopped · yes pid \(pid) \(gone ? "confirmed exited" : "STILL RUNNING (self-terminates within \(lifetime) s)")")
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
