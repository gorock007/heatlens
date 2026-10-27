import Foundation
import Testing
@testable import HeatLensCore

/// A fake filesystem for `ProjectRootLocator`: the paths that exist, and every path it checked.
private final class FakeFiles: @unchecked Sendable {
    private let lock = NSLock()
    private let existing: Set<String>
    private(set) var checked: [String] = []
    init(_ existing: [String]) { self.existing = Set(existing) }
    func exists(_ path: String) -> Bool {
        lock.withLock { checked.append(path) }
        return existing.contains(path)
    }
}

private let home = SyntheticSnapshots.home

private func locator(_ files: FakeFiles, now: @escaping @Sendable () -> Date = Date.init) -> ProjectRootLocator {
    ProjectRootLocator(home: home, exists: { files.exists($0) }, now: now)
}

private func container(_ id: Character, name: String, labels: [String: String] = [:], binds: [String] = [],
                       cpu: Double? = nil, memory: UInt64? = nil) -> ContainerSample {
    ContainerSample(containerID: String(repeating: id, count: 64), name: name, image: "postgres:17", state: "running",
                    status: "Up 1 hour", createdAt: Date(timeIntervalSince1970: 1_900_000_000), labels: labels,
                    cpuPercentOfOneCore: cpu, memoryBytes: memory, vmCPUCount: 6, bindMountSources: binds)
}

@Suite("Project roots (stat only)")
struct ProjectRootLocatorTests {
    @Test("the nearest .git wins over a nearer package.json, so a monorepo package maps to its repository")
    func gitWins() {
        let files = FakeFiles([home + "/Developer/mono/.git", home + "/Developer/mono/packages/web/package.json"])
        let root = locator(files).root(for: home + "/Developer/mono/packages/web/src")
        #expect(root == ProjectRootLocator.Root(path: home + "/Developer/mono", marker: ".git"))
    }

    @Test("without a repository, the nearest manifest is the root")
    func manifestFallback() {
        let files = FakeFiles([home + "/Developer/scratch/api/pyproject.toml"])
        #expect(locator(files).root(for: home + "/Developer/scratch/api/app")?.path == home + "/Developer/scratch/api")
        #expect(locator(files).root(for: home + "/Developer/scratch/api/app")?.marker == "pyproject.toml")
    }

    @Test("the walk never checks the home directory itself, so a dotfiles ~/.git claims nothing")
    func stopsBelowHome() {
        let files = FakeFiles([home + "/.git"])
        #expect(locator(files).root(for: home + "/Developer/loose") == nil)
        #expect(!files.checked.contains { ($0 as NSString).deletingLastPathComponent == home })
        #expect(files.checked.allSatisfy { $0.hasPrefix(home + "/Developer/") })
    }

    @Test("privacy-protected folders, other volumes and system paths are never touched")
    func protectedFolders() {
        let files = FakeFiles([home + "/Documents/thesis/.git", "/Volumes/ssd/repo/.git"])
        let finder = locator(files)
        for path in [home + "/Documents/thesis", home + "/Desktop/x", home + "/Downloads/y", home + "/Library/Mobile Documents/z",
                     "/Volumes/ssd/repo", "/Network/share", "/System/Library", "/private/tmp/a", home] {
            #expect(finder.root(for: path) == nil, "\(path)")
        }
        #expect(files.checked.isEmpty)
        #expect(finder.root(for: "relative/path") == nil)
    }

    @Test("results, including misses, are cached until they expire")
    func caching() {
        let files = FakeFiles([home + "/Developer/app/.git"])
        let clock = Clock()
        let finder = locator(files, now: { clock.now })
        _ = finder.root(for: home + "/Developer/app/src")
        _ = finder.root(for: home + "/Developer/none")
        let first = files.checked.count
        _ = finder.root(for: home + "/Developer/app/src")
        _ = finder.root(for: home + "/Developer/none")
        #expect(files.checked.count == first)
        clock.now = clock.now.addingTimeInterval(ProjectRootLocator.cacheLifetime + 1)
        _ = finder.root(for: home + "/Developer/app/src")
        #expect(files.checked.count > first)
    }

    @Test("against this Mac: this repository's checkout is found by its .git")
    func liveRepository() throws {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
        let root = try #require(ProjectRootLocator().root(for: here))
        #expect(root.marker == ".git")
        #expect(here.hasPrefix(root.path))
        #expect(FileManager.default.fileExists(atPath: root.path + "/Package.swift"))
    }
}

private final class Clock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 2_000_000_000)
}

@Suite("Project attribution")
struct ProjectAttributorTests {
    @Test("mappings: ~ expands, a name is optional, comments and bad lines are skipped, home and / are refused")
    func mappingParse() {
        let (mappings, invalid) = ProjectMapping.parse("""
            # comment
            ~/Developer/FDA = FDA
            /opt/work/site
            relative/path = Nope
            ~ = Everything
            / = Root
            """, home: home)
        #expect(mappings == [ProjectMapping(root: home + "/Developer/FDA", name: "FDA"), ProjectMapping(root: "/opt/work/site", name: "site")])
        #expect(invalid == ["relative/path = Nope", "~ = Everything", "/ = Root"])
    }

    @Test("a directory maps to a user mapping (longest wins), else its repository, else itself at lower confidence")
    func directoryProject() {
        let files = FakeFiles([home + "/Developer/FDA/.git"])
        let finder = locator(files)
        let mappings = [ProjectMapping(root: home + "/Developer", name: "All"), ProjectMapping(root: home + "/Developer/FDA/web", name: "FDA web")]
        #expect(ProjectAttributor.project(forDirectory: home + "/Developer/FDA/web/src", attribution: .high, mappings: mappings, locator: finder)
                == Project(name: "FDA web", root: home + "/Developer/FDA/web", confidence: .high, basis: "user mapping"))
        #expect(ProjectAttributor.project(forDirectory: home + "/Developer/FDA/api", attribution: .high, mappings: [], locator: finder)
                == Project(name: "FDA", root: home + "/Developer/FDA", confidence: .high, basis: "git repository"))
        #expect(ProjectAttributor.project(forDirectory: home + "/Developer/loose", attribution: .high, mappings: [], locator: finder)
                == Project(name: "loose", root: home + "/Developer/loose", confidence: .medium, basis: "working directory"))
        // "FDA2" is not inside "FDA".
        #expect(!ProjectAttributor.isPath(home + "/Developer/FDA2", inside: home + "/Developer/FDA"))
    }

    @Test("the FDA Compose container maps to ~/Developer/FDA from its working_dir label")
    func composeWorkingDirectory() {
        let files = FakeFiles([home + "/Developer/FDA/.git"])
        let db = container("a", name: "fda-db-1", labels: [
            "com.docker.compose.project": "fda",
            "com.docker.compose.project.working_dir": home + "/Developer/FDA",
            "com.docker.compose.project.config_files": home + "/Developer/FDA/docker-compose.yml",
        ])
        let attribution = ProjectAttributor.attribute(db, mappings: [], locator: locator(files), home: home)
        #expect(attribution.project?.root == home + "/Developer/FDA")
        #expect(attribution.project?.name == "FDA")
        #expect(attribution.evidence.source == "Compose working_dir label")
    }

    @Test("without working_dir: the Compose file's folder, then bind mounts into one project; else unattributed with the reason")
    func otherContainerEvidence() {
        let files = FakeFiles([home + "/Developer/shop/.git", home + "/Developer/blog/.git"])
        let finder = locator(files)
        let configOnly = container("b", name: "shop-api-1", labels: ["com.docker.compose.project.config_files": home + "/Developer/shop/compose.yaml"])
        #expect(ProjectAttributor.attribute(configOnly, mappings: [], locator: finder, home: home).evidence.source == "Compose config_files label")

        let bound = container("c", name: "dev", binds: [home + "/Developer/shop/src", "/var/run/docker.sock", home + "/.ssh"])
        let boundAttribution = ProjectAttributor.attribute(bound, mappings: [], locator: finder, home: home)
        #expect(boundAttribution.project?.name == "shop" && boundAttribution.project?.confidence == .medium)
        #expect(boundAttribution.evidence.source == "bind mount")

        let split = container("d", name: "both", binds: [home + "/Developer/shop", home + "/Developer/blog"])
        let splitAttribution = ProjectAttributor.attribute(split, mappings: [], locator: finder, home: home)
        #expect(splitAttribution.project == nil && splitAttribution.evidence.source == "bind mounts point into 2 projects")

        let bare = container("e", name: "redis", labels: ["com.docker.compose.project": "cache"])
        let bareAttribution = ProjectAttributor.attribute(bare, mappings: [], locator: finder, home: home)
        #expect(bareAttribution.project == nil)
        #expect(bareAttribution.evidence.source == "Compose project \"cache\" has no working_dir label")
    }

    @Test("a user mapping beats the Compose label")
    func mappingBeatsCompose() {
        let files = FakeFiles([home + "/Developer/FDA/.git"])
        let db = container("f", name: "fda-db-1", labels: ["com.docker.compose.project.working_dir": home + "/Developer/FDA/infra"])
        let attribution = ProjectAttributor.attribute(db, mappings: [ProjectMapping(root: home + "/Developer/FDA/infra", name: "FDA infra")],
                                                      locator: locator(files), home: home)
        #expect(attribution.project?.name == "FDA infra" && attribution.project?.basis == "user mapping")
    }
}

@Suite("Per-project breakdown")
struct ProjectBreakdownTests {
    private let vmPath = "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"

    private func group(_ processes: [ProcessSample], directory: String?) -> ProcessGroup {
        ProcessGroup(root: processes[0].identity, members: processes.map(\.identity), kind: "test", label: processes[0].name,
                     project: directory.map { ProjectAttribution(directory: $0, basis: "cwd", confidence: .high) },
                     confidence: .high, evidence: [])
    }

    private func docker(_ containers: [ContainerSample]) -> DockerSnapshot {
        DockerSnapshot(availability: .available, engineVersion: "28.5.1", apiVersion: "1.51", containers: containers, notices: [])
    }

    private var fixture: (snapshot: ScanSnapshot, groups: [ProcessGroup], containers: [ContainerSample], finder: ProjectRootLocator) {
        let vm = SyntheticSnapshots.process(pid: 500, name: "com.apple.Virtualization.VirtualMachine", executablePath: vmPath, cpu: 200)
        let web = SyntheticSnapshots.process(pid: 600, name: "node", currentDirectory: home + "/Developer/FDA/web", cpu: 50, cpuWatts: 1.5)
        let other = SyntheticSnapshots.process(pid: 700, name: "Finder", cpu: 10)
        let snapshot = SyntheticSnapshots.snapshot([vm, web, other])
        let groups = [group([vm], directory: nil), group([web], directory: home + "/Developer/FDA/web"), group([other], directory: nil)]
        let containers = [
            container("a", name: "fda-db-1", labels: ["com.docker.compose.project.working_dir": home + "/Developer/FDA"], cpu: 120, memory: 300 << 20),
            container("b", name: "loose", cpu: 30, memory: 100 << 20),
        ]
        return (snapshot, groups, containers, locator(FakeFiles([home + "/Developer/FDA/.git"])))
    }

    @Test("container CPU moves from the Docker VM to its project, so the rows add up to the host's CPU, not more")
    func noDoubleCounting() throws {
        let (snapshot, groups, containers, finder) = fixture
        let breakdown = ProjectAttributor.breakdown(snapshot: snapshot, groups: groups, docker: docker(containers),
                                                    mappings: [], locator: finder, home: home)
        #expect(breakdown.usages.map(\.name) == ["FDA", "Docker VM", "Unattributed"])
        let fda = breakdown.usages[0], vm = breakdown.usages[1], rest = breakdown.usages[2]
        #expect(fda.hostCPUPercent == 50 && fda.containerCPUPercent == 120 && fda.totalCPUPercent == 170)
        #expect(fda.containers.map(\.name) == ["fda-db-1"])
        #expect(fda.containerMemoryBytes == 300 << 20 && fda.memoryBytes == 96 << 20)
        #expect(fda.cpuWatts == 1.5)
        // The VM's 200% held both containers; 120% moved to FDA, the unclaimed 30% stays.
        #expect(vm.totalCPUPercent == 80 && vm.containers.map(\.name) == ["loose"])
        #expect(rest.totalCPUPercent == 10)
        let hostTotal = snapshot.processes.compactMap(\.cpuPercentOfOneCore).reduce(0, +)
        #expect(breakdown.usages.map(\.totalCPUPercent).reduce(0, +) == hostTotal)
        #expect(breakdown.notices.isEmpty)
        #expect(breakdown.usage(containing: groups[1].root)?.name == "FDA")
    }

    @Test("more container CPU than the VM measured: the VM row is 0, never negative, and a notice explains the skew")
    func overAttribution() {
        let (snapshot, groups, _, finder) = fixture
        let hot = container("a", name: "fda-db-1", labels: ["com.docker.compose.project.working_dir": home + "/Developer/FDA"], cpu: 260)
        let breakdown = ProjectAttributor.breakdown(snapshot: snapshot, groups: groups, docker: docker([hot]), mappings: [], locator: finder, home: home)
        #expect(breakdown.usages.first { $0.bucket == .dockerVM }?.totalCPUPercent == 0)
        #expect(breakdown.notices.first?.contains("exceeded the Docker VM's measured CPU") == true)
    }

    @Test("no VM process (another runtime): container CPU is listed but kept out of project totals")
    func noVirtualMachine() throws {
        let web = SyntheticSnapshots.process(pid: 600, name: "node", currentDirectory: home + "/Developer/FDA/web", cpu: 50)
        let snapshot = SyntheticSnapshots.snapshot([web])
        let db = container("a", name: "fda-db-1", labels: ["com.docker.compose.project.working_dir": home + "/Developer/FDA"], cpu: 120)
        let breakdown = ProjectAttributor.breakdown(snapshot: snapshot, groups: [group([web], directory: home + "/Developer/FDA/web")],
                                                    docker: docker([db]), mappings: [], locator: locator(FakeFiles([home + "/Developer/FDA/.git"])), home: home)
        let fda = try #require(breakdown.usages.first)
        #expect(fda.totalCPUPercent == 50 && fda.containerCPUPercent == nil && fda.containers.count == 1)
        #expect(breakdown.notices == ["Docker's VM process wasn't found, so container CPU is shown per project but not added to project totals."])
    }

    @Test("two Virtualization VMs (Docker and, say, UTM) share the Docker VM row, with a notice")
    func twoVirtualMachines() {
        let (snapshot, groups, containers, finder) = fixture
        let second = SyntheticSnapshots.process(pid: 501, name: "com.apple.Virtualization.VirtualMachine", executablePath: vmPath, cpu: 40)
        let more = SyntheticSnapshots.snapshot(snapshot.processes + [second])
        let breakdown = ProjectAttributor.breakdown(snapshot: more, groups: groups + [group([second], directory: nil)],
                                                    docker: docker(containers), mappings: [], locator: finder, home: home)
        #expect(breakdown.usages.first { $0.bucket == .dockerVM }?.totalCPUPercent == 120)
        #expect(breakdown.notices.contains { $0.hasPrefix("2 virtual machines are running") })
    }

    @Test("Docker off: the VM process stays with its group and no container is attributed")
    func dockerOff() {
        let (snapshot, groups, _, finder) = fixture
        let breakdown = ProjectAttributor.breakdown(snapshot: snapshot, groups: groups, docker: nil, mappings: [], locator: finder, home: home)
        #expect(breakdown.usages.map(\.name) == ["FDA", "Unattributed"])
        #expect(breakdown.usages.last?.totalCPUPercent == 210)
        #expect(breakdown.containerAttributions.isEmpty)
    }
}

@Suite("Per-project breakdown at scale")
struct ProjectBreakdownScaleTests {
    @Test("1,000 processes in 300 groups across 100 projects take well under 50 ms")
    func scale() {
        var processes: [ProcessSample] = []
        var groups: [ProcessGroup] = []
        for g in 0..<300 {
            let directory = g < 200 ? home + "/Developer/p\(g % 100)/src" : nil
            let members = (0..<(g < 100 ? 4 : 3)).map { i in
                SyntheticSnapshots.process(pid: Int32(10_000 + g * 10 + i), name: "w", currentDirectory: directory, cpu: Double(i), cpuWatts: 0.1)
            }
            processes += members
            groups.append(ProcessGroup(root: members[0].identity, members: members.map(\.identity), kind: "test", label: "g\(g)",
                                       project: directory.map { ProjectAttribution(directory: $0, basis: "cwd", confidence: .high) },
                                       confidence: .high, evidence: []))
        }
        let snapshot = SyntheticSnapshots.snapshot(processes)
        let finder = ProjectRootLocator(home: home, exists: { $0.hasSuffix("/.git") && !$0.contains("/src/") })
        let start = ContinuousClock.now
        let breakdown = ProjectAttributor.breakdown(snapshot: snapshot, groups: groups, docker: nil, mappings: [], locator: finder, home: home)
        let elapsed = start.duration(to: .now)
        #expect(processes.count == 1_000)
        #expect(breakdown.usages.filter { $0.project != nil }.count == 100)
        #expect(elapsed < .milliseconds(50), "took \(elapsed)")
    }
}

@Suite("Project attribution against this Mac", .serialized)
struct ProjectAttributionLiveTests {
    @Test("running Compose containers with a working_dir label get a project with a real root")
    func liveDocker() throws {
        let sampler = DockerEngineSampler()
        let snapshot = DockerAssembly.snapshot(before: nil, after: sampler.reading())
        guard snapshot.availability.isAvailable else { return }
        let finder = ProjectRootLocator()
        for container in snapshot.containers where container.isRunning && container.composeWorkingDirectory != nil {
            let attribution = ProjectAttributor.attribute(container, mappings: [], locator: finder)
            let project = try #require(attribution.project, "\(container.name)")
            #expect(FileManager.default.fileExists(atPath: project.root))
            #expect(container.composeWorkingDirectory!.hasPrefix(project.root))
        }
    }
}
