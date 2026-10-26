import Darwin
import Foundation

/// Whether the UI may offer "Request stop" for a process (FR-09, PRD §4.4).
public enum StopEligibility: Equatable, Sendable {
    case eligible
    /// `reason` is plain words the UI shows next to the disabled control.
    case denied(reason: String)
}

/// What one `requestStop` call did.
public enum StopOutcome: Equatable, Sendable {
    /// SIGTERM sent and the process exited within the wait.
    case stopped
    /// SIGTERM sent, still alive after the wait. Never escalated.
    case stillRunning
    /// Gone before anything was sent.
    case alreadyExited
    /// The pid now belongs to a different process; nothing was sent.
    case identityChanged
    /// Failed eligibility when re-checked against live data; nothing was sent.
    case denied(reason: String)
    /// `kill()` failed (e.g. EPERM).
    case failed(errno: Int32)
}

/// Sends at most one SIGTERM to one validated process instance (FR-09).
///
/// Invariants, each enforced in `requestStop`: the target is exactly the `(pid, startTime)`
/// passed in, re-read from the kernel immediately before signalling; the signal is SIGTERM and
/// nothing stronger, ever; the pid is > 1, never a process group; one pid per call; no shell
/// or command-line tool. A process that ignores SIGTERM is reported as `.stillRunning` and
/// left alone.
public struct ProcessTerminator: Sendable {
    /// Names macOS needs running; matched against the process name and the executable's file name.
    static let protectedNames: Set<String> = [
        "kernel_task", "windowserver", "launchd", "loginwindow", "finder", "dock",
        "systemuiserver", "controlcenter", "coreaudiod", "cfprefsd",
    ]
    /// `mds`, `mds_stores` and the rest of Spotlight's metadata server family.
    static let protectedNamePrefixes = ["mds"]
    /// Apple binaries live here; HeatLens never stops them.
    static let appleDirectories = ["/System/", "/Library/Apple/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/usr/bin/", "/bin/"]

    /// Delay between exit checks after the signal.
    static let pollInterval: Duration = .milliseconds(50)
    /// Longer `wait` values are clamped to this.
    static let maximumWait: TimeInterval = 60

    public init() {}

    /// Pure: decides from a scan sample whether the UI may offer "Request stop".
    public func eligibility(of sample: ProcessSample) -> StopEligibility {
        let pid = sample.pid
        if pid <= 1 {
            return .denied(reason: "This is a core macOS process (PID \(pid)). HeatLens never stops it.")
        }
        if pid == getpid() {
            return .denied(reason: "This is HeatLens itself. Quit it from its menu instead.")
        }
        if let name = protectedName(of: sample) {
            return .denied(reason: "\(name) is part of macOS. Stopping it can freeze the Mac or log you out, so HeatLens never offers it.")
        }
        switch sample.owner {
        case .currentUser: break
        case .root:
            return .denied(reason: "This process runs as root (system). HeatLens only stops processes you own.")
        case .otherUser:
            return .denied(reason: "This process belongs to another user account. HeatLens only stops processes you own.")
        case .unknown:
            return .denied(reason: "HeatLens couldn't confirm who owns this process, so it won't stop it.")
        }
        guard let path = sample.executablePath, !path.isEmpty else {
            return .denied(reason: "HeatLens couldn't read this process's executable path, so it can't confirm what it is. Use Activity Monitor if you need to stop it.")
        }
        if let directory = Self.appleDirectories.first(where: { path.hasPrefix($0) }) {
            return .denied(reason: "This is an Apple system program (in \(directory)). HeatLens doesn't stop those.")
        }
        switch sample.detailAccess {
        case .available:
            return .eligible
        case .permissionDenied:
            return .denied(reason: "macOS didn't let HeatLens read this process's details, so its identity can't be verified. Use Activity Monitor if you need to stop it.")
        case .processExited:
            return .denied(reason: "This process exited during the scan.")
        case .notSupported:
            return .denied(reason: "HeatLens can't read this process, so it won't stop it.")
        }
    }

    /// Revalidates identity, owner and denylist right before kill(pid, SIGTERM); then polls until exit or `wait`.
    public func requestStop(_ identity: ProcessIdentity, wait: TimeInterval = 3) async -> StopOutcome {
        let pid = identity.pid
        guard pid > 1 else { return .denied(reason: "This is a core macOS process (PID \(pid)). HeatLens never stops it.") }

        // 1. The pid still names the same process instance.
        switch Self.liveState(of: identity) {
        case .exited: return .alreadyExited
        case .replaced: return .identityChanged
        case .unreadable:
            return .denied(reason: "macOS didn't let HeatLens re-check this process, so nothing was sent. Use Activity Monitor if you need to stop it.")
        case .same(let bsd):
            // 2. Every eligibility rule, against what the kernel says now rather than the scan.
            if bsd.uid == 0 || bsd.uid != getuid() {
                return .denied(reason: "This process is no longer owned by you, so nothing was sent.")
            }
            if case .denied(let reason) = eligibility(of: Self.liveSample(identity, bsd: bsd)) {
                return .denied(reason: reason)
            }
        }

        // 3. Last identity check, as close to the signal as the API allows.
        switch Self.liveState(of: identity) {
        case .exited: return .alreadyExited
        case .replaced: return .identityChanged
        case .unreadable:
            return .denied(reason: "macOS didn't let HeatLens re-check this process, so nothing was sent. Use Activity Monitor if you need to stop it.")
        case .same: break
        }

        // 4. Exactly one signal, to exactly this positive pid.
        if kill(pid, SIGTERM) != 0 {
            let code = errno
            return code == ESRCH ? .alreadyExited : .failed(errno: code)
        }

        // 5. Watch for exit; never signal again. A cancelled task stops watching early.
        let deadline = ContinuousClock.now + .seconds(wait.isFinite ? min(max(wait, 0), Self.maximumWait) : 0)
        while true {
            if Self.hasExited(identity) { return .stopped }
            if ContinuousClock.now >= deadline || Task.isCancelled { return .stillRunning }
            try? await Task.sleep(for: Self.pollInterval)
        }
    }
}

extension ProcessTerminator {
    enum LiveState {
        case same(Libproc.BSDInfo)
        case replaced
        case exited
        /// The pid is the same instance but libproc refused its details (another user's process).
        case unreadable
    }

    /// Reads `identity.pid` now. A zombie counts as exited: libproc returns ESRCH for it while
    /// `sysctl` still lists it.
    static func liveState(of identity: ProcessIdentity) -> LiveState {
        guard let current = LibprocProcessSampler.identity(of: identity.pid) else { return .exited }
        guard current == identity else { return .replaced }
        switch Libproc.bsdInfo(identity.pid) {
        case .success(let bsd):
            return bsd.identity(pid: identity.pid) == identity ? .same(bsd) : .replaced
        case .failure(let failure):
            return failure.code == ESRCH ? .exited : .unreadable
        }
    }

    static func hasExited(_ identity: ProcessIdentity) -> Bool {
        switch liveState(of: identity) {
        case .exited, .replaced: true
        case .same, .unreadable: false
        }
    }

    /// The fields `eligibility(of:)` reads, taken from the kernel now.
    static func liveSample(_ identity: ProcessIdentity, bsd: Libproc.BSDInfo) -> ProcessSample {
        let detailsReadable = (try? Libproc.taskInfo(identity.pid).get()) != nil
        return ProcessSample(identity: identity, parentPID: bsd.ppid,
                             owner: bsd.uid == getuid() ? .currentUser : (bsd.uid == 0 ? .root : .otherUser),
                             name: bsd.name, executablePath: try? Libproc.pidPath(identity.pid).get(),
                             arguments: nil, currentDirectory: nil, cpu: nil, cpuPercentOfOneCore: nil,
                             residentBytes: nil, footprintBytes: nil, threadCount: nil,
                             detailAccess: detailsReadable ? .available : .permissionDenied)
    }

    /// The protected name this sample matches, as the user would recognise it; nil when none.
    func protectedName(of sample: ProcessSample) -> String? {
        let candidates = [sample.name, sample.executablePath.map { ($0 as NSString).lastPathComponent }].compactMap { $0 }
        return candidates.first { candidate in
            let lower = candidate.lowercased()
            return Self.protectedNames.contains(lower) || Self.protectedNamePrefixes.contains { lower.hasPrefix($0) }
        }
    }
}
