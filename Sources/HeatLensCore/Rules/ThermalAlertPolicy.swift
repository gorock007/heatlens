import Foundation

/// When the opt-in thermal alert runs its one scan, and what the notification says. The app's
/// only trigger is `ProcessInfo.thermalStateDidChangeNotification`; nothing here polls.
public struct ThermalAlertPolicy: Hashable, Sendable {
    public static let defaultCooldown: TimeInterval = 30 * 60
    static let labelLimit = 40
    static let projectLimit = 32

    /// The least time between two alert scans.
    public let cooldown: TimeInterval

    public init(cooldown: TimeInterval = ThermalAlertPolicy.defaultCooldown) {
        self.cooldown = cooldown
    }

    /// True only on a rise into serious or critical (fair → serious, serious → critical; never a
    /// fall), with the setting on, no scan running and the cooldown over since the last alert.
    public func shouldScan(previous: ThermalState, current: ThermalState, enabled: Bool,
                           lastAlert: Date?, now: Date, scanRunning: Bool) -> Bool {
        guard enabled, !scanRunning else { return false }
        guard Self.level(current) >= Self.level(.serious), Self.level(current) > Self.level(previous) else { return false }
        guard let lastAlert else { return true }
        return now.timeIntervalSince(lastAlert) >= cooldown
    }

    /// Names the top-ranked visible CPU finding's group: label, project folder name when known,
    /// and group CPU. Never argv, full paths or the user name.
    public func summary(for result: ScanResult, exclusions: ExclusionFilter = ExclusionFilter(),
                        thermalState: ThermalState = .serious,
                        homeDirectory: String = NSHomeDirectory()) -> (title: String, body: String) {
        let title = "Your Mac is running hot"
        let visible = exclusions.visibleFindings(result.findings, snapshot: result.snapshot, groups: result.groups)
        guard let finding = visible.first(where: { $0.kind == .highCPU }),
              let group = result.groups.first(where: { group in finding.affectedProcesses.contains { group.members.contains($0) } })
        else {
            let state = thermalState == .critical ? "critical" : "serious"
            return (title, "No single process stands out. macOS reports \(state) thermal pressure.")
        }
        let members = Set(group.members)
        let cpu = result.snapshot.processes
            .filter { members.contains($0.identity) }
            .compactMap(\.cpuPercentOfOneCore)
            .reduce(0, +)
        let label = Self.truncated(Self.safeLabel(group.label, homeDirectory: homeDirectory), to: Self.labelLimit)
        var body = label.isEmpty ? "One workload" : label
        if let project = group.project.flatMap({ Self.projectName($0.directory, homeDirectory: homeDirectory) }) {
            body += " in " + Self.truncated(project, to: Self.projectLimit)
        }
        body += " · \(Int(cpu.rounded()))% CPU"
        return (title, body)
    }

    private static func level(_ state: ThermalState) -> Int {
        switch state {
        case .nominal, .unavailable: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        }
    }

    /// Path-like words shrink to their last component; the user name is dropped.
    private static func safeLabel(_ label: String, homeDirectory: String) -> String {
        let user = (homeDirectory as NSString).lastPathComponent
        return label.split(separator: " ")
            .map { word in word.contains("/") ? (String(word) as NSString).lastPathComponent : String(word) }
            .filter { !$0.isEmpty && $0 != user && $0 != "/" }
            .joined(separator: " ")
    }

    /// The project's folder name, or nil when that would be the home folder (the user name) or `/`.
    private static func projectName(_ directory: String, homeDirectory: String) -> String? {
        let path = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath).standardizedFileURL.path
        let home = URL(fileURLWithPath: homeDirectory).standardizedFileURL.path
        let name = (path as NSString).lastPathComponent
        guard path != home, path != "/", !name.isEmpty, name != (home as NSString).lastPathComponent else { return nil }
        return name
    }

    private static func truncated(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }
}
