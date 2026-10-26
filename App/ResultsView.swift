import SwiftUI
import HeatLensCore

/// Read-only lookups the result views share: processes by identity and the sample's end time.
struct ReportContext {
    let report: ScanReport
    let processes: [ProcessIdentity: ProcessSample]
    /// Uptimes are shown as of the end of the sample, so they don't drift while the popover is open.
    let observedAt: Date

    init(report: ScanReport) {
        self.report = report
        processes = Dictionary(report.snapshot.processes.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        observedAt = report.snapshot.startedAt.addingTimeInterval(report.snapshot.interval)
    }

    func uptime(_ identity: ProcessIdentity) -> String {
        Format.uptime(identity.uptime(at: observedAt))
    }
}

/// PRD §3 "UI sections" for one finished scan.
struct ResultsView: View {
    let report: ScanReport
    let onScanAgain: () -> Void
    let onDone: () -> Void

    private var context: ReportContext { ReportContext(report: report) }

    var body: some View {
        let context = self.context
        let findings = report.findings.filter { $0.severity != .review }
        let leftovers = report.findings.filter { $0.severity == .review }

        VStack(alignment: .leading, spacing: 2) {
            Text(Headline.text(for: report))
                .font(.headline)
            Text("HeatLens · \(Int(report.snapshot.interval))-second sample")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                OverviewSection(snapshot: report.snapshot)

                ResultSection(title: "Findings") {
                    if findings.isEmpty {
                        EmptyNote("No findings in this sample.")
                    }
                    ForEach(findings) { FindingCard(finding: $0, context: context) }
                }

                ResultSection(title: "Potential leftovers") {
                    if leftovers.isEmpty {
                        EmptyNote("No long-running candidates found.")
                    }
                    ForEach(leftovers) { FindingCard(finding: $0, context: context) }
                }

                ResultSection(title: "What's using resources") {
                    if report.groups.isEmpty {
                        EmptyNote("No process groups.")
                    }
                    ForEach(report.groups) { GroupRow(group: $0, context: context) }
                }
            }
            .padding(.trailing, 8)
        }
        .frame(height: 440)

        HStack {
            Button("Copy report") { Pasteboard.copy(report.reportText) }
                .help("Concise redacted summary: top processes and findings")
            Button("Copy JSON") { Pasteboard.copy(report.reportJSON) }
                .help("Full redacted report with every process")
        }

        HStack {
            Button("Done", action: onDone)
            Spacer()
            Button("Scan again", action: onScanAgain)
                .keyboardShortcut(.defaultAction)
        }
    }
}

private struct ResultSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
    }
}

private struct EmptyNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}

private struct OverviewSection: View {
    let snapshot: ScanSnapshot

    var body: some View {
        let system = snapshot.system
        ResultSection(title: "Overview") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                row("Thermal state", Format.thermal(system.thermalState))
                row("CPU load", String(format: "%.1f of %d cores busy", system.busyCores, system.coreCount))
                row("Memory pressure", Format.pressure(system.memory.pressure))
                row("Swap", "\(Format.bytes(system.memory.swapUsedBytes)) of \(Format.bytes(system.memory.swapTotalBytes)) used")
            }
            .font(.callout)

            ForEach(snapshot.notices, id: \.self) { notice in
                Label(notice, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }
}

private struct GroupRow: View {
    let group: ProcessGroup
    let context: ReportContext

    private var members: [(ProcessIdentity, ProcessSample?)] {
        group.members.map { ($0, context.processes[$0]) }
    }

    /// Sum over readable members; nil when none were readable.
    private var totalCPU: Double? {
        let readable = members.compactMap { $0.1?.cpuPercentOfOneCore }
        return readable.isEmpty ? nil : readable.reduce(0, +)
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if let project = group.project {
                    Text("Project: \(project.directory) (from \(project.basis))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Unknown project")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(members, id: \.0) { identity, sample in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(sample?.name ?? "Process") · PID \(identity.pid)")
                            .font(.caption.weight(.medium))
                        Text("\(Format.measurement(sample)) · up \(context.uptime(identity))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(group.label)
                    .font(.callout)
                Text("\(Format.cpu(totalCPU)) · \(group.members.count) process\(group.members.count == 1 ? "" : "es")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

#Preview("Results") {
    VStack(alignment: .leading, spacing: 12) {
        ResultsView(report: FixtureScanService.report(startedAt: Date(), interval: 10), onScanAgain: {}, onDone: {})
    }
    .padding(16)
    .frame(width: 300)
}
