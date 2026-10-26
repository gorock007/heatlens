import Darwin
import Foundation
import HeatLensCore

/// Per-core scheduler ticks from `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`.
func hostCPUTicks() -> [CPULoadTicks]? {
    var cpuCount: natural_t = 0
    var info: processor_info_array_t? = nil
    var infoCount: mach_msg_type_number_t = 0
    let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
    guard kr == KERN_SUCCESS, let info else { return nil }
    defer {
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))
    }
    let stride = Int(CPU_STATE_MAX)
    return (0..<Int(cpuCount)).map { i in
        let base = i * stride
        return CPULoadTicks(user: UInt64(info[base + Int(CPU_STATE_USER)]),
                            system: UInt64(info[base + Int(CPU_STATE_SYSTEM)]),
                            idle: UInt64(info[base + Int(CPU_STATE_IDLE)]),
                            nice: UInt64(info[base + Int(CPU_STATE_NICE)]))
    }
}

struct VMSnapshot {
    let pageSize: UInt64
    let free, active, inactive, wired, compressor, speculative: UInt64   // pages
    let swapins, swapouts, compressions, decompressions: UInt64            // cumulative
    func bytes(_ pages: UInt64) -> UInt64 { pages * pageSize }
}

func vmSnapshot() -> VMSnapshot? {
    var vm = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &vm) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
    }
    guard kr == KERN_SUCCESS else { return nil }
    return VMSnapshot(pageSize: UInt64(sysctlUInt64("hw.pagesize") ?? 16384),
                      free: UInt64(vm.free_count), active: UInt64(vm.active_count), inactive: UInt64(vm.inactive_count),
                      wired: UInt64(vm.wire_count), compressor: UInt64(vm.compressor_page_count), speculative: UInt64(vm.speculative_count),
                      swapins: vm.swapins, swapouts: vm.swapouts, compressions: vm.compressions, decompressions: vm.decompressions)
}

func sysctlUInt64(_ name: String) -> UInt64? {
    var value: UInt64 = 0
    var len = MemoryLayout<UInt64>.size
    guard sysctlbyname(name, &value, &len, nil, 0) == 0 else { return nil }
    if len == 4 { return UInt64(UInt32(truncatingIfNeeded: value)) }
    return value
}

func sysctlInt32(_ name: String) -> (value: Int32?, failure: Failure?) {
    var value: Int32 = 0
    var len = MemoryLayout<Int32>.size
    errno = 0
    guard sysctlbyname(name, &value, &len, nil, 0) == 0 else { return (nil, Failure(code: errno)) }
    return (value, nil)
}

struct SwapUsage { let total, used, free: UInt64; let encrypted: Bool }

func swapUsage() -> (SwapUsage?, Failure?) {
    var sw = xsw_usage()
    var len = MemoryLayout<xsw_usage>.size
    errno = 0
    guard sysctlbyname("vm.swapusage", &sw, &len, nil, 0) == 0 else { return (nil, Failure(code: errno)) }
    return (SwapUsage(total: sw.xsu_total, used: sw.xsu_used, free: sw.xsu_avail, encrypted: sw.xsu_encrypted != 0), nil)
}

func memoryPressureName(_ level: Int32) -> String {
    switch level {
    case 1: return "normal"
    case 2: return "warning"
    case 4: return "critical"
    default: return "unknown(\(level))"
    }
}

func thermalStateName(_ s: ProcessInfo.ThermalState) -> String {
    switch s {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown(\(s.rawValue))"
    }
}
