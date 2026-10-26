import Darwin
import Foundation

/// Cumulative host counters, read at both ends of the interval.
public struct HostCounters: Hashable, Sendable {
    /// Per-core scheduler ticks; nil when `host_processor_info` failed.
    public let perCore: [CPULoadTicks]?
    /// Cumulative swap-outs since boot (`vm_statistics64.swapouts`); nil when unreadable.
    public let swapOuts: UInt64?

    public init(perCore: [CPULoadTicks]?, swapOuts: UInt64?) {
        self.perCore = perCore
        self.swapOuts = swapOuts
    }
}

/// Point-in-time host state, read once at the end of the interval.
public struct HostState: Hashable, Sendable {
    public let coreCount: Int
    /// Byte counts are 0 when `host_statistics64` failed; `memoryAvailable` says which.
    public let totalBytes: UInt64
    public let freeBytes: UInt64
    public let activeBytes: UInt64
    public let inactiveBytes: UInt64
    public let wiredBytes: UInt64
    public let compressedBytes: UInt64
    public let swapUsedBytes: UInt64
    public let swapTotalBytes: UInt64
    public let memoryAvailable: Bool
    public let pressure: MemoryPressureLevel
    public let availablePercent: Int?
    public let thermalState: ThermalState
    /// nil when `pmset` was not run, could not launch or timed out.
    public let pmset: PmsetThermalReport?
    /// Why `pmset` gave no data (it failed to launch or missed its deadline); a scan notice.
    public let pmsetNotice: String?

    public init(coreCount: Int, totalBytes: UInt64, freeBytes: UInt64, activeBytes: UInt64, inactiveBytes: UInt64,
                wiredBytes: UInt64, compressedBytes: UInt64, swapUsedBytes: UInt64, swapTotalBytes: UInt64,
                memoryAvailable: Bool, pressure: MemoryPressureLevel, availablePercent: Int?,
                thermalState: ThermalState, pmset: PmsetThermalReport?, pmsetNotice: String? = nil) {
        self.coreCount = coreCount
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.activeBytes = activeBytes
        self.inactiveBytes = inactiveBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.swapUsedBytes = swapUsedBytes
        self.swapTotalBytes = swapTotalBytes
        self.memoryAvailable = memoryAvailable
        self.pressure = pressure
        self.availablePercent = availablePercent
        self.thermalState = thermalState
        self.pmset = pmset
        self.pmsetNotice = pmsetNotice
    }
}

/// Whole-machine readings. The coordinator calls `counters()` at both ends of the interval
/// and `state()` once at the end, then composes the `SystemSample`.
public protocol SystemSampling: Sendable {
    func counters() -> HostCounters
    /// May run a subprocess (`pmset`); throws `CancellationError` when the task is cancelled.
    func state() async throws -> HostState
}

/// `host_processor_info`, `host_statistics64`, the swap and pressure sysctls,
/// `ProcessInfo.thermalState`, and optionally `pmset -g therm` notes.
public struct HostSystemSampler: SystemSampling {
    let readsPmset: Bool
    let pmsetCommand: (executable: String, arguments: [String])
    let pmsetDeadline: TimeInterval

    public init(readsPmset: Bool = true) {
        self.init(readsPmset: readsPmset, pmsetCommand: ("/usr/bin/pmset", ["-g", "therm"]))
    }

    /// Tests substitute a slow stand-in for `pmset` to exercise the deadline.
    init(readsPmset: Bool, pmsetCommand: (executable: String, arguments: [String]),
         pmsetDeadline: TimeInterval = ChildProcess.defaultDeadline) {
        self.readsPmset = readsPmset
        self.pmsetCommand = pmsetCommand
        self.pmsetDeadline = pmsetDeadline
    }

    public func counters() -> HostCounters {
        HostCounters(perCore: Self.hostCPUTicks(), swapOuts: Self.vmStatistics()?.swapouts)
    }

    public func state() async throws -> HostState {
        let vm = Self.vmStatistics()
        let page = Self.sysctlUInt64("hw.pagesize") ?? 16384
        let swap = Self.swapUsage()
        var pmset: PmsetThermalReport?
        var pmsetNotice: String?
        if readsPmset {
            do {
                let output = try await ChildProcess.run(pmsetCommand.executable, pmsetCommand.arguments, deadline: pmsetDeadline)
                if output.status == 0 { pmset = PmsetThermParser.parse(String(decoding: output.stdout, as: UTF8.self)) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                pmset = nil
                pmsetNotice = "pmset thermal data unavailable (\(error))."
            }
        }
        return HostState(coreCount: Int(Self.sysctlUInt64("hw.ncpu") ?? 0),
                         totalBytes: Self.sysctlUInt64("hw.memsize") ?? 0,
                         freeBytes: (vm.map { UInt64($0.free_count) } ?? 0) * page,
                         activeBytes: (vm.map { UInt64($0.active_count) } ?? 0) * page,
                         inactiveBytes: (vm.map { UInt64($0.inactive_count) } ?? 0) * page,
                         wiredBytes: (vm.map { UInt64($0.wire_count) } ?? 0) * page,
                         compressedBytes: (vm.map { UInt64($0.compressor_page_count) } ?? 0) * page,
                         swapUsedBytes: swap?.xsu_used ?? 0, swapTotalBytes: swap?.xsu_total ?? 0,
                         memoryAvailable: vm != nil,
                         pressure: Self.sysctlInt32("kern.memorystatus_vm_pressure_level").map(MemoryPressureLevel.init(sysctlLevel:)) ?? .unknown,
                         availablePercent: Self.sysctlInt32("kern.memorystatus_level").map(Int.init),
                         thermalState: Self.thermalState(ProcessInfo.processInfo.thermalState),
                         pmset: pmset, pmsetNotice: pmsetNotice)
    }

    static func thermalState(_ state: ProcessInfo.ThermalState) -> ThermalState {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .unavailable
        }
    }

    /// Per-core scheduler ticks from `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`.
    static func hostCPUTicks() -> [CPULoadTicks]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t? = nil
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))
        }
        let stride = Int(CPU_STATE_MAX)
        return (0..<Int(cpuCount)).map { i in
            let base = i * stride
            // The kernel's counters are 32-bit and wrap; read them unsigned.
            func ticks(_ state: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[base + Int(state)])) }
            return CPULoadTicks(user: ticks(CPU_STATE_USER), system: ticks(CPU_STATE_SYSTEM),
                                idle: ticks(CPU_STATE_IDLE), nice: ticks(CPU_STATE_NICE))
        }
    }

    static func vmStatistics() -> vm_statistics64_data_t? {
        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? vm : nil
    }

    static func swapUsage() -> xsw_usage? {
        var sw = xsw_usage()
        var len = MemoryLayout<xsw_usage>.size
        return sysctlbyname("vm.swapusage", &sw, &len, nil, 0) == 0 ? sw : nil
    }

    static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &len, nil, 0) == 0 else { return nil }
        if len == 4 { return UInt64(UInt32(truncatingIfNeeded: value)) }
        return value
    }

    static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var len = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &len, nil, 0) == 0 ? value : nil
    }
}
