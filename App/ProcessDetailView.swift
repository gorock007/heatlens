import SwiftUI
import HeatLensCore

struct ProcessDetailView: View {
    let identity: ProcessIdentity
    let context: ReportContext
    let stopService: any ProcessStopping
    let onBack: () -> Void
    let onRequestStop: (StopTarget) -> Void
    /// Scan results pass it for "Ignore this process/project"; Live passes none and stays read-only.
    var settings: SettingsModel? = nil

    @State private var copiedPID = false
    @State private var copiedCommand = false
    @State private var ignoredProcess = false
    @State private var ignoredProject = false

    private var process: ProcessSample? { context.processes[identity] }
    private var project: ProjectAttribution? { context.project(for: identity) }
    private var findings: [DiagnosticFinding] { context.findings(for: identity) }
    private var offeredStop: Bool { context.offersStop(for: identity) }
    /// The project as the Projects card shows it: the repository root when there is one, else the
    /// attributed directory. Ignoring it excludes this directory and everything under it.
    private var ignorableProject: (directory: String, name: String)? {
        if let repository = context.report.projects.usage(containing: identity)?.project {
            return (repository.root, repository.name)
        }
        return project.map { ($0.directory, ($0.directory as NSString).lastPathComponent) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Back", systemImage: "chevron.left", action: onBack)
                    .labelStyle(.titleAndIcon)
                Spacer()
                Text(process?.name ?? "Process")
                    .font(.headline)
                    .lineLimit(1)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    detailGrid
                    projectSection
                    findingsSection
                    actionSection
                }
                .padding(.trailing, 8)
            }
            .frame(height: 440)
        }
    }

    private var detailGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
            row("PID", "\(identity.pid)")
            row("Parent chain", context.parentChain(for: identity))
            row("Children", context.children(of: identity))
            row("Owner", Format.owner(process?.owner))
            row("Uptime", context.uptime(identity))
            row("Executable", process?.executablePath ?? Format.notAccessible)
            row("Command", Format.command(process?.arguments) ?? Format.notAccessible)
            row("Directory", process?.currentDirectory ?? Format.notAccessible)
            let ports = context.report.snapshot.ports(for: identity)
            if !ports.isEmpty {
                row("Listening on", ports.map { ":\($0.port) (\($0.scopeLabel))" }.joined(separator: ", "))
            }
            let assertions = context.report.snapshot.assertions(for: identity)
            if !assertions.isEmpty {
                row("Preventing sleep", assertions.map { $0.detailText(at: context.observedAt) }.joined(separator: "\n"))
            }
            if process?.detailAccess == .processExited {
                row("Status", Format.exited)
            } else {
                row("CPU", Format.cpu(process?.cpuPercentOfOneCore) + sourceSuffix)
                row("CPU energy", Format.watts(process?.cpuWatts)
                    ?? (process?.owner == .currentUser ? "Unavailable" : "Not accessible (only your own processes report energy)"))
                row("Memory", Format.bytes(process?.footprintBytes ?? process?.residentBytes) + sourceSuffix)
            }
        }
        .font(.caption)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var projectSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Project attribution")
                .font(.subheadline.weight(.semibold))
            if let project {
                if let repository = context.report.projects.usage(containing: identity)?.project {
                    Text("\(repository.name) · \(ProjectFormat.path(repository.root)) (\(repository.basis))")
                        .font(.caption)
                        .textSelection(.enabled)
                }
                Text(project.directory)
                    .font(.caption)
                    .textSelection(.enabled)
                Text("From \(project.basis) · \(Format.confidence(project.confidence))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let settings, let ignorable = ignorableProject {
                    if ignoredProject {
                        ignoredNote
                    } else if !settings.isProjectExcluded(ignorable.directory) {
                        Button("Ignore this project") {
                            ActionRecording.ignoreProject(directory: ignorable.directory, name: ignorable.name,
                                                          origin: .processDetail, settings: settings)
                            ignoredProject = true
                        }
                        .controlSize(.small)
                        .help("Add \(ProjectFormat.path(ignorable.directory)) to the excluded projects in Settings")
                    }
                }
            } else {
                Text("Unknown project")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var findingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Findings for this process")
                .font(.subheadline.weight(.semibold))
            if findings.isEmpty {
                Text("No finding named this process.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(findings) { finding in
                VStack(alignment: .leading, spacing: 4) {
                    Text(finding.title)
                        .font(.caption.weight(.semibold))
                    ForEach(Array(finding.evidence.enumerated()), id: \.offset) { _, evidence in
                        Text("\(evidence.label): \(evidence.value) · \(evidence.source)")
                            .font(.caption)
                    }
                    ForEach(Array(finding.limitations.enumerated()), id: \.offset) { _, limitation in
                        Text(limitation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    @ViewBuilder private var actionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Actions")
                .font(.subheadline.weight(.semibold))
            FlowLayout(spacing: 6) {
                Button(copiedPID ? "Copied PID" : "Copy PID") {
                    Pasteboard.copy("\(identity.pid)")
                    copiedPID = true
                }
                .resetsAfterCopy($copiedPID)
                Button(copiedCommand ? "Copied command" : "Copy command") {
                    if let command = Format.command(process?.arguments) {
                        Pasteboard.copy(command)
                        copiedCommand = true
                    }
                }
                .disabled(Format.command(process?.arguments) == nil)
                .resetsAfterCopy($copiedCommand)
                if let project {
                    Button("Open project") { openProject(project.directory) }
                        .disabled(!projectExists(project.directory))
                }
                Button("Activity Monitor", action: openActivityMonitor)
                if let settings, let process, !ignoredProcess, !settings.isProcessExcluded(process.name) {
                    Button("Ignore this process") {
                        ActionRecording.ignoreProcess(identity, name: process.name,
                                                      projectName: project.map { ($0.directory as NSString).lastPathComponent },
                                                      origin: .processDetail, settings: settings)
                        ignoredProcess = true
                    }
                    .help("Add \(process.name) to the excluded processes in Settings")
                }
                if offeredStop, context.isExcluded(identity) {
                    Text("Excluded in Settings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if offeredStop, let process {
                    switch stopService.eligibility(of: process) {
                    case .eligible:
                        Button("Request stop", role: .destructive) {
                            onRequestStop(StopTarget(identity: identity, process: process, project: project))
                        }
                    case .denied:
                        EmptyView()
                    }
                }
            }
            .controlSize(.small)

            if ignoredProcess {
                ignoredNote
            }

            if offeredStop, !context.isExcluded(identity), let process, case .denied(let reason) = stopService.eligibility(of: process) {
                Text("Stop unavailable: \(reason)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var ignoredNote: some View {
        Text(ActionRecording.ignoredNote)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var sourceSuffix: String { process?.measurementSource == .ps ? " (via ps)" : "" }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

func projectExists(_ path: String) -> Bool {
    FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath)
}

func openProject(_ path: String) {
    NSWorkspace.shared.open(URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true))
}

func openActivityMonitor() {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") else { return }
    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
}
