import Foundation
import HeatLensCore

/// `--docker`: reads the local Docker Engine twice, `interval` seconds apart (GET requests only,
/// docs/v2/ADR-0002), and prints each container with CPU over the interval and memory.
func printDocker(interval: TimeInterval) {
    let sampler = DockerEngineSampler()
    let clock = ContinuousClock()
    let started = clock.now
    let before = sampler.reading()
    let firstRead = started.duration(to: clock.now)
    Thread.sleep(forTimeInterval: interval)
    let snapshot = DockerAssembly.snapshot(before: before, after: sampler.reading())
    guard snapshot.availability.isAvailable else {
        print("Docker: \(snapshot.availability)")
        snapshot.notices.forEach { print("  notice: \($0)") }
        return
    }
    print("Docker Engine \(snapshot.engineVersion ?? "?") · API \(snapshot.apiVersion ?? "?") · \(snapshot.containers.count) containers · first read \(firstRead)")
    let home = NSHomeDirectory()
    for container in snapshot.containers {
        let cpu = container.cpuPercentOfOneCore.map { String(format: "%6.1f%%", $0) } ?? "     — "
        let memory = container.memoryBytes.map { String(format: "%8.1f MB", Double($0) / 1_048_576) } ?? "       — "
        var line = "\(container.shortID) \(cpu) \(memory)  \(container.state.padding(toLength: 8, withPad: " ", startingAt: 0)) \(container.name) · \(container.image)"
        if let project = container.composeProject {
            line += " · compose \(project)/\(container.composeService ?? "?")"
        }
        if let dir = container.composeWorkingDirectory {
            line += " · " + (dir.hasPrefix(home) ? "~" + dir.dropFirst(home.count) : dir)
        }
        print(line)
    }
    if let vm = snapshot.containers.compactMap(\.vmCPUCount).first {
        print("CPU: 100% = one core; the Docker VM has \(vm) CPUs")
    }
    snapshot.notices.forEach { print("notice: \($0)") }
}
