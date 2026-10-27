import SwiftUI
import HeatLensCore

/// CPU and memory per project, then the Docker VM's remainder and Unattributed (PRD-v2 Phase 2).
/// Each row opens to the process groups and containers behind it, with the evidence for each.
struct ProjectsCard: View {
    let breakdown: ProjectBreakdown
    let groups: [ProcessGroup]
    /// Projects shown before "Show all".
    var limit = 5
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Projects")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            let projects = breakdown.usages.filter { $0.project != nil }
            let others = breakdown.usages.filter { $0.project == nil }
            if projects.isEmpty {
                Text("No process or container could be tied to a project folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(showAll ? projects : Array(projects.prefix(limit))) { usage in
                ProjectRow(usage: usage, groups: groups, attributions: breakdown.containerAttributions)
            }
            if projects.count > limit {
                Button(showAll ? "Show fewer" : "Show all \(projects.count) projects") { showAll.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            ForEach(others) { usage in
                ProjectRow(usage: usage, groups: groups, attributions: breakdown.containerAttributions)
            }
            ForEach(breakdown.notices, id: \.self) { notice in
                Label(notice, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ProjectRow: View {
    let usage: ProjectUsage
    let groups: [ProcessGroup]
    let attributions: [String: ContainerAttribution]

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                if let project = usage.project {
                    Text("\(ProjectFormat.path(project.root)) · from \(project.basis), \(Format.confidence(project.confidence))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if usage.bucket == .dockerVM {
                    Text("Docker's Linux VM, minus the container CPU counted under projects.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(usage.groupRoots.prefix(8), id: \.self) { root in
                    if let group = groups.first(where: { $0.root == root }) {
                        Text(verbatim: "\(group.label) · \(group.members.count) process\(group.members.count == 1 ? "" : "es")")
                            .font(.caption)
                    }
                }
                if usage.groupRoots.count > 8 {
                    Text("\(usage.groupRoots.count - 8) more groups")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ForEach(usage.containers) { container in
                    let source = attributions[container.containerID]?.evidence.source
                    Text(verbatim: (["Container \(container.name)", ProjectFormat.cpu(container.cpuPercentOfOneCore)].compactMap { $0 }
                                    + [source.map { "from \($0)" }].compactMap { $0 }).joined(separator: " · "))
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 4)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(usage.name)
                        .font(.callout.weight(usage.project == nil ? .regular : .semibold))
                        .foregroundStyle(usage.project == nil ? .secondary : .primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Text(ProjectFormat.cpu(usage.totalCPUPercent) ?? "—")
                    .font(.callout.monospacedDigit())
            }
        }
    }

    private var detail: String {
        var parts: [String] = []
        if let containers = usage.containerCPUPercent, containers > 0 {
            parts.append("incl. \(ProjectFormat.cpu(containers) ?? "") in containers")
        }
        if let watts = Format.watts(usage.cpuWatts) { parts.append(watts) }
        parts.append(Format.bytes(usage.memoryBytes))
        if let containerMemory = usage.containerMemoryBytes {
            parts.append("+ \(Format.bytes(containerMemory)) in Docker")
        }
        return parts.joined(separator: " · ")
    }
}

enum ProjectFormat {
    /// "170%", "4.5%": compact, for rows that already say CPU.
    static func cpu(_ percent: Double?) -> String? {
        guard let percent else { return nil }
        return percent < 10 && percent > 0 ? String(format: "%.1f%%", percent) : "\(Int(percent.rounded()))%"
    }

    /// The home directory as `~`.
    static func path(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path == home ? "~" : (path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path)
    }
}
