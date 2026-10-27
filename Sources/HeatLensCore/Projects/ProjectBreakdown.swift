import Foundation

/// CPU and memory of one project, the Docker VM's remainder, or everything unattributed
/// (brief 2b). Host CPU is measured per process; container CPU comes from Docker stats and is
/// *moved* out of the Docker VM row, so adding up every row never counts container work twice.
public struct ProjectUsage: Identifiable, Hashable, Sendable {
    public enum Bucket: Hashable, Sendable {
        case project(Project)
        /// Docker's VM process, minus the container CPU attributed to projects.
        case dockerVM
        case unattributed
    }

    public var id: String {
        switch bucket {
        case .project(let project): "project:" + project.id
        case .dockerVM: "docker-vm"
        case .unattributed: "unattributed"
        }
    }

    public let bucket: Bucket
    /// Groups with at least one member in this row, busiest first.
    public let groupRoots: [ProcessIdentity]
    /// Processes in this row that were alive at the end of the interval.
    public let processes: [ProcessIdentity]
    /// For a project: its containers. For the Docker VM row: the containers no project claimed.
    public let containers: [ContainerSample]
    /// Measured host-process CPU, 100 = one core; nil when no process here had a CPU figure.
    public let hostCPUPercent: Double?
    /// Container CPU moved here from the Docker VM (projects only); nil when none had stats.
    public let containerCPUPercent: Double?
    /// Footprint (RSS when no footprint) of the host processes.
    public let memoryBytes: UInt64
    /// Memory inside the Docker VM, shown beside `memoryBytes`, never added to it: the VM's own
    /// footprint already holds it.
    public let containerMemoryBytes: UInt64?
    /// Host processes' CPU energy over the interval. Container energy can't be split from the VM's.
    public let cpuWatts: Double?

    public var project: Project? {
        if case .project(let project) = bucket { return project }
        return nil
    }

    public var name: String {
        switch bucket {
        case .project(let project): project.name
        case .dockerVM: "Docker VM"
        case .unattributed: "Unattributed"
        }
    }

    /// Host CPU plus moved container CPU (for the Docker VM row, what's left of the VM).
    public var totalCPUPercent: Double { (hostCPUPercent ?? 0) + (containerCPUPercent ?? 0) }
}

public struct ProjectBreakdown: Hashable, Sendable {
    /// Projects busiest first, then the Docker VM row, then Unattributed. Empty rows are left out.
    public let usages: [ProjectUsage]
    /// How each container was (or wasn't) attributed, by container ID.
    public let containerAttributions: [String: ContainerAttribution]
    public let notices: [String]

    public static let empty = ProjectBreakdown(usages: [], containerAttributions: [:], notices: [])

    /// The row holding `identity`, for a process's "Project" line.
    public func usage(containing identity: ProcessIdentity) -> ProjectUsage? {
        usages.first { $0.processes.contains(identity) }
    }
}

extension ProjectAttributor {
    /// Buckets every live process by its group's project (Docker's VM process into its own row
    /// when Docker answered), attributes containers, and moves their CPU from the VM row to their
    /// projects. When the VM process can't be found (another runtime), container CPU is reported
    /// per project but not counted in totals, and a notice says so.
    public static func breakdown(snapshot: ScanSnapshot, groups: [ProcessGroup], docker: DockerSnapshot?,
                                 mappings: [ProjectMapping], locator: ProjectRootLocator,
                                 home: String = NSHomeDirectory()) -> ProjectBreakdown {
        let processes = Dictionary(snapshot.processes.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        let dockerAnswered = docker?.availability.isAvailable == true
        var projectsByDirectory: [String: Project] = [:]
        var projectsByID: [String: Project] = [:]

        struct Accumulator {
            var groupRoots: [ProcessIdentity] = []
            var groupSet: Set<ProcessIdentity> = []
            var processes: [ProcessIdentity] = []
            var containers: [ContainerSample] = []
            var hostCPU: Double?
            var containerCPU: Double?
            var memory: UInt64 = 0
            var containerMemory: UInt64?
            var energy: UInt64?
        }
        var rows: [String: Accumulator] = [:]
        var vmCount = 0

        func add(_ sample: ProcessSample, group: ProcessIdentity, to key: String) {
            var row = rows[key, default: Accumulator()]
            if row.groupSet.insert(group).inserted { row.groupRoots.append(group) }
            row.processes.append(sample.identity)
            if let cpu = sample.cpuPercentOfOneCore { row.hostCPU = (row.hostCPU ?? 0) + cpu }
            row.memory += sample.footprintBytes ?? sample.residentBytes ?? 0
            if let energy = sample.cpuEnergyNanojoules { row.energy = (row.energy ?? 0) + energy }
            rows[key] = row
        }

        for group in groups {
            var key = "unattributed"
            if let directory = group.project?.directory {
                let project = projectsByDirectory[directory] ?? project(forDirectory: directory, attribution: group.project?.confidence ?? .low,
                                                                         mappings: mappings, locator: locator)
                projectsByDirectory[directory] = project
                projectsByID[project.id] = project
                key = "project:" + project.id
            }
            for member in group.members {
                guard let sample = processes[member], sample.detailAccess != .processExited else { continue }
                if dockerAnswered, isVirtualMachine(sample) {
                    vmCount += 1
                    add(sample, group: group.root, to: "docker-vm")
                } else {
                    add(sample, group: group.root, to: key)
                }
            }
        }

        var attributions: [String: ContainerAttribution] = [:]
        var movedCPU = 0.0
        for container in (dockerAnswered ? docker?.containers ?? [] : []) where container.isRunning {
            let attribution = attribute(container, mappings: mappings, locator: locator, home: home)
            attributions[container.containerID] = attribution
            let key: String
            if let project = attribution.project {
                let known = projectsByID[project.id] ?? project
                projectsByID[known.id] = known
                key = "project:" + known.id
            } else {
                key = "docker-vm"
            }
            var row = rows[key, default: Accumulator()]
            row.containers.append(container)
            if let memory = container.memoryBytes { row.containerMemory = (row.containerMemory ?? 0) + memory }
            if key != "docker-vm", let cpu = container.cpuPercentOfOneCore {
                row.containerCPU = (row.containerCPU ?? 0) + cpu
                movedCPU += cpu
            }
            rows[key] = row
        }

        var notices: [String] = []
        if vmCount > 1 {
            notices.append("\(vmCount) virtual machines are running. HeatLens can't tell which one is Docker's, so all of them are in the Docker VM row.")
        }
        if movedCPU > 0 {
            if vmCount > 0, var vm = rows["docker-vm"] {
                let vmCPU = vm.hostCPU ?? 0
                if movedCPU > vmCPU + 1 {
                    notices.append(String(format: "Container CPU attributed to projects (%.0f%%) exceeded the Docker VM's measured CPU (%.0f%%); "
                                          + "Docker reads its stats at slightly different moments. The Docker VM row shows 0%%.", movedCPU, vmCPU))
                }
                vm.hostCPU = max(0, vmCPU - movedCPU)
                rows["docker-vm"] = vm
            } else {
                notices.append("Docker's VM process wasn't found, so container CPU is shown per project but not added to project totals.")
                for key in rows.keys where key.hasPrefix("project:") {
                    rows[key]?.containerCPU = nil
                }
            }
        }

        let interval = snapshot.interval
        let groupCPU = Dictionary(groups.map { group in
            (group.root, group.members.compactMap { processes[$0]?.cpuPercentOfOneCore }.reduce(0, +))
        }, uniquingKeysWith: { first, _ in first })
        func usage(_ key: String, _ row: Accumulator) -> ProjectUsage? {
            let bucket: ProjectUsage.Bucket
            if key == "docker-vm" { bucket = .dockerVM }
            else if key == "unattributed" { bucket = .unattributed }
            else if let project = projectsByID[String(key.dropFirst("project:".count))] { bucket = .project(project) }
            else { return nil }
            let roots = row.groupRoots.sorted { (groupCPU[$0] ?? 0) > (groupCPU[$1] ?? 0) }
            return ProjectUsage(bucket: bucket, groupRoots: roots, processes: row.processes, containers: row.containers,
                                hostCPUPercent: row.hostCPU, containerCPUPercent: row.containerCPU, memoryBytes: row.memory,
                                containerMemoryBytes: row.containerMemory,
                                cpuWatts: row.energy.flatMap { interval > 0 ? Double($0) / (interval * 1e9) : nil })
        }
        let all = rows.compactMap { usage($0.key, $0.value) }
        let projects = all.filter { $0.project != nil }
            .sorted { ($0.totalCPUPercent, $1.name) > ($1.totalCPUPercent, $0.name) }
        let rest = all.filter { $0.bucket == .dockerVM } + all.filter { $0.bucket == .unattributed }
        return ProjectBreakdown(usages: projects + rest, containerAttributions: attributions, notices: notices)
    }

    static func isVirtualMachine(_ sample: ProcessSample) -> Bool {
        let executable = sample.executablePath.map { ($0 as NSString).lastPathComponent } ?? sample.name
        return executable == virtualMachineExecutable || sample.name == virtualMachineExecutable
    }
}
