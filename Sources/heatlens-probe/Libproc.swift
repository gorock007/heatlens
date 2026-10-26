import Darwin
import Foundation
import HeatLensCore

/// A failed libproc/sysctl call, with the errno it left behind (0 = short/zero return).
struct Failure: Hashable, Error, CustomStringConvertible {
    let code: Int32
    var description: String {
        code == 0 ? "short-return" : "\(String(cString: strerror(code)))(\(code))"
    }
}

/// Reads a fixed-size C char array (imported as a tuple) as a String.
func cString<T>(_ tuple: inout T) -> String {
    withUnsafePointer(to: &tuple) {
        $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
    }
}

func listAllPIDs() -> [pid_t] {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(count) + 128)
    let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    return Array(pids.prefix(Int(max(got, 0)))).filter { $0 >= 0 }
}

struct BSDInfo {
    let pid: pid_t
    let ppid: pid_t
    let uid: uid_t
    let startSec: UInt64
    let startUSec: UInt64
    let comm: String   // 16-char truncated
    let name: String   // longer name (pbi_name)
    let flags: UInt32
    var identity: ProcessIdentity { ProcessIdentity(pid: pid, startSeconds: startSec, startMicroseconds: startUSec) }
}

func bsdInfo(_ pid: pid_t) -> Result<BSDInfo, Failure> {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    errno = 0
    let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
    guard n == size else { return .failure(Failure(code: errno)) }
    return .success(BSDInfo(pid: pid, ppid: pid_t(info.pbi_ppid), uid: info.pbi_uid,
                            startSec: info.pbi_start_tvsec, startUSec: info.pbi_start_tvusec,
                            comm: cString(&info.pbi_comm), name: cString(&info.pbi_name), flags: info.pbi_flags))
}

struct TaskSample {
    let userTicks: UInt64
    let systemTicks: UInt64
    let residentSize: UInt64
    let virtualSize: UInt64
    let threads: Int32
}

func taskInfo(_ pid: pid_t) -> Result<TaskSample, Failure> {
    var ti = proc_taskinfo()
    let size = Int32(MemoryLayout<proc_taskinfo>.size)
    errno = 0
    let n = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, size)
    guard n == size else { return .failure(Failure(code: errno)) }
    return .success(TaskSample(userTicks: ti.pti_total_user, systemTicks: ti.pti_total_system,
                               residentSize: ti.pti_resident_size, virtualSize: ti.pti_virtual_size,
                               threads: ti.pti_threadnum))
}

struct RusageSample {
    let userTicks: UInt64
    let systemTicks: UInt64
    let physFootprint: UInt64
    let startAbsTicks: UInt64
    let diskBytesRead: UInt64
    let diskBytesWritten: UInt64
}

func rusageV4(_ pid: pid_t) -> Result<RusageSample, Failure> {
    var ru = rusage_info_v4()
    errno = 0
    let r = withUnsafeMutablePointer(to: &ru) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    guard r == 0 else { return .failure(Failure(code: errno)) }
    return .success(RusageSample(userTicks: ru.ri_user_time, systemTicks: ru.ri_system_time,
                                 physFootprint: ru.ri_phys_footprint, startAbsTicks: ru.ri_proc_start_abstime,
                                 diskBytesRead: ru.ri_diskio_bytesread, diskBytesWritten: ru.ri_diskio_byteswritten))
}

func pidPath(_ pid: pid_t) -> Result<String, Failure> {
    var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    errno = 0
    let n = proc_pidpath(pid, &buf, UInt32(buf.count))
    guard n > 0 else { return .failure(Failure(code: errno)) }
    return .success(String(cString: buf))
}

func currentDirectory(_ pid: pid_t) -> Result<String, Failure> {
    var vpi = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    errno = 0
    let n = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, size)
    guard n == size else { return .failure(Failure(code: errno)) }
    return .success(cString(&vpi.pvi_cdir.vip_path))
}

func processArguments(_ pid: pid_t) -> Result<ProcessArguments, Failure> {
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

/// `kinfo_proc` for every process via sysctl, the facility `ps` uses. Fallback source for
/// ppid/uid/start time when `proc_pidinfo` refuses a pid.
struct KInfo {
    let pid: pid_t
    let ppid: pid_t
    let uid: uid_t
    let startSec: Int
    let startUSec: Int32
    let comm: String
}

func kinfoAll() -> [pid_t: KInfo] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
    var len = 0
    guard sysctl(&mib, 3, nil, &len, nil, 0) == 0, len > 0 else { return [:] }
    len += len / 4
    let stride = MemoryLayout<kinfo_proc>.stride
    var buf = [kinfo_proc](repeating: kinfo_proc(), count: len / stride + 1)
    guard sysctl(&mib, 3, &buf, &len, nil, 0) == 0 else { return [:] }
    var out: [pid_t: KInfo] = [:]
    for i in 0..<(len / stride) {
        var kp = buf[i]
        out[kp.kp_proc.p_pid] = KInfo(pid: kp.kp_proc.p_pid, ppid: kp.kp_eproc.e_ppid, uid: kp.kp_eproc.e_ucred.cr_uid,
                                      startSec: kp.kp_proc.p_starttime.tv_sec, startUSec: kp.kp_proc.p_starttime.tv_usec,
                                      comm: cString(&kp.kp_proc.p_comm))
    }
    return out
}
