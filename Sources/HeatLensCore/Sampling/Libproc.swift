import Darwin
import Foundation

/// Thin wrappers over libproc and the process sysctls, ported from the Phase 0a probe.
/// Each returns the errno a failed call left behind; docs/FEASIBILITY.md §2 lists which
/// calls fail for which owners (EPERM for root/other users, ESRCH for exited pids).
enum Libproc {
    /// A failed libproc/sysctl call, with its errno (0 = short or zero return).
    struct Failure: Error, Hashable {
        let code: Int32
    }

    struct BSDInfo {
        let ppid: pid_t
        let uid: uid_t
        let startSec: UInt64
        let startUSec: UInt64
        /// `pbi_name`, longer than the 16-char `pbi_comm` for many processes; falls back to comm.
        let name: String
        func identity(pid: pid_t) -> ProcessIdentity {
            ProcessIdentity(pid: pid, startSeconds: startSec, startMicroseconds: startUSec)
        }
    }

    struct TaskInfo {
        let userTicks: UInt64
        let systemTicks: UInt64
        let residentSize: UInt64
        let threads: Int32
    }

    struct RusageInfo {
        let userTicks: UInt64
        let systemTicks: UInt64
        let physFootprint: UInt64
    }

    /// `kinfo_proc` fields, available for every process including the ones libproc refuses.
    struct KInfo {
        let ppid: pid_t
        let uid: uid_t
        let startSec: Int
        let startUSec: Int32
        let comm: String
        func identity(pid: pid_t) -> ProcessIdentity {
            ProcessIdentity(pid: pid, startTimeMicros: Int64(startSec) * 1_000_000 + Int64(startUSec))
        }
    }

    /// Reads a fixed-size C char array (imported as a tuple) as a String.
    static func cString<T>(_ tuple: inout T) -> String {
        withUnsafePointer(to: &tuple) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
        }
    }

    /// Every pid, including 0. Empty when the call is refused (the App Sandbox does that).
    static func listAllPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 128)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(got, 0)))).filter { $0 >= 0 }
    }

    static func bsdInfo(_ pid: pid_t) -> Result<BSDInfo, Failure> {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        errno = 0
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard n == size else { return .failure(Failure(code: errno)) }
        let name = cString(&info.pbi_name)
        return .success(BSDInfo(ppid: pid_t(info.pbi_ppid), uid: info.pbi_uid,
                                startSec: info.pbi_start_tvsec, startUSec: info.pbi_start_tvusec,
                                name: name.isEmpty ? cString(&info.pbi_comm) : name))
    }

    static func taskInfo(_ pid: pid_t) -> Result<TaskInfo, Failure> {
        var ti = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        errno = 0
        let n = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, size)
        guard n == size else { return .failure(Failure(code: errno)) }
        return .success(TaskInfo(userTicks: ti.pti_total_user, systemTicks: ti.pti_total_system,
                                 residentSize: ti.pti_resident_size, threads: ti.pti_threadnum))
    }

    static func rusageV4(_ pid: pid_t) -> Result<RusageInfo, Failure> {
        var ru = rusage_info_v4()
        errno = 0
        let r = withUnsafeMutablePointer(to: &ru) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard r == 0 else { return .failure(Failure(code: errno)) }
        return .success(RusageInfo(userTicks: ru.ri_user_time, systemTicks: ru.ri_system_time,
                                   physFootprint: ru.ri_phys_footprint))
    }

    /// Works for every owner. `PROC_PIDPATHINFO_MAXSIZE` is not importable; it is 4 * MAXPATHLEN.
    static func pidPath(_ pid: pid_t) -> Result<String, Failure> {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        errno = 0
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return .failure(Failure(code: errno)) }
        return .success(buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
    }

    static func currentDirectory(_ pid: pid_t) -> Result<String, Failure> {
        var vpi = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        errno = 0
        let n = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, size)
        guard n == size else { return .failure(Failure(code: errno)) }
        return .success(cString(&vpi.pvi_cdir.vip_path))
    }

    /// argv via `KERN_PROCARGS2`; the environment in the same buffer is never decoded.
    static func processArguments(_ pid: pid_t) -> Result<ProcessArguments, Failure> {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var len = 0
        errno = 0
        guard sysctl(&mib, 3, nil, &len, nil, 0) == 0 else { return .failure(Failure(code: errno)) }
        var buf = [UInt8](repeating: 0, count: len)
        errno = 0
        guard sysctl(&mib, 3, &buf, &len, nil, 0) == 0 else { return .failure(Failure(code: errno)) }
        guard let parsed = ProcArgsParser.parse(Data(buf.prefix(len))) else { return .failure(Failure(code: 0)) }
        return .success(parsed)
    }

    /// The pid's socket file descriptors (`PROC_PIDLISTFDS`, keeping `PROX_FDTYPE_SOCKET`).
    /// EPERM for other users' and root's processes.
    static func socketFDs(_ pid: pid_t) -> Result<[Int32], Failure> {
        let entry = MemoryLayout<proc_fdinfo>.stride
        errno = 0
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return .failure(Failure(code: errno)) }
        // Room for a few descriptors opened between the two calls.
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / entry + 16)
        errno = 0
        let n = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * entry))
        guard n > 0 else { return .failure(Failure(code: errno)) }
        return .success(fds.prefix(Int(n) / entry).filter { $0.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) }.map(\.proc_fd))
    }

    /// `PROC_PIDFDSOCKETINFO` for one descriptor; fails when it was closed in the meantime.
    static func socketInfo(_ pid: pid_t, fd: Int32) -> Result<socket_fdinfo, Failure> {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        errno = 0
        let n = proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, size)
        guard n == size else { return .failure(Failure(code: errno)) }
        return .success(info)
    }

    /// `kinfo_proc` for every process via sysctl, the facility `ps` uses.
    static func kinfoAll() -> [pid_t: KInfo] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var len = 0
        guard sysctl(&mib, 3, nil, &len, nil, 0) == 0, len > 0 else { return [:] }
        len += len / 4
        let stride = MemoryLayout<kinfo_proc>.stride
        var buf = [kinfo_proc](repeating: kinfo_proc(), count: len / stride + 1)
        guard sysctl(&mib, 3, &buf, &len, nil, 0) == 0 else { return [:] }
        var out: [pid_t: KInfo] = [:]
        out.reserveCapacity(len / stride)
        for i in 0..<(len / stride) {
            var kp = buf[i]
            out[kp.kp_proc.p_pid] = KInfo(ppid: kp.kp_eproc.e_ppid, uid: kp.kp_eproc.e_ucred.cr_uid,
                                          startSec: kp.kp_proc.p_starttime.tv_sec, startUSec: kp.kp_proc.p_starttime.tv_usec,
                                          comm: cString(&kp.kp_proc.p_comm))
        }
        return out
    }
}
