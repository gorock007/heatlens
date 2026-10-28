import SwiftUI
import HeatLensCore

/// One container from a scan result, laid out like `ProcessDetailView`. The only place that
/// offers "Stop container…" (docs/v2/ADR-0007 decision 2); Live never opens it.
struct ContainerDetailView: View {
    let selection: ContainerSelection
    let settings: SettingsModel
    let onBack: () -> Void
    let onRequestStop: (ContainerSelection) -> Void

    @State private var copiedID = false

    private var container: ContainerSample { selection.container }
    private var eligibility: ContainerStopEligibility {
        selection.stopper.eligibility(of: container, project: selection.project, exclusions: settings.exclusions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Back", systemImage: "chevron.left", action: onBack)
                    .labelStyle(.titleAndIcon)
                Spacer()
                Text(container.name)
                    .font(.headline)
                    .lineLimit(1)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    detailGrid
                    projectSection
                    actionSection
                }
                .padding(.trailing, 8)
            }
            .frame(height: 440)
        }
    }

    private var detailGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
            row("Name", container.name)
            row("Image", container.image)
            row("ID", container.shortID)
            row("State", "\(container.state) · \(container.status)")
            row("Created", Format.relative(container.createdAt))
            if let compose = container.composeProject {
                row("Compose", "\(compose) / \(container.composeService ?? "?")")
            }
            if container.isRunning {
                row("CPU", Format.cpu(container.cpuPercentOfOneCore)
                    + (container.vmCPUCount.map { " (of \($0) VM CPUs)" } ?? ""))
                row("Memory", Format.bytes(container.memoryBytes))
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
            if let project = selection.project {
                Text("\(project.name) · \(ProjectFormat.path(project.root))")
                    .font(.caption)
                    .textSelection(.enabled)
                Text("From \(selection.attribution?.evidence.source ?? project.basis) · \(Format.confidence(project.confidence))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Unknown project")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let source = selection.attribution?.evidence.source {
                    Text(source)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var actionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Actions")
                .font(.subheadline.weight(.semibold))
            FlowLayout(spacing: 6) {
                Button(copiedID ? "Copied ID" : "Copy ID") {
                    Pasteboard.copy(container.containerID)
                    copiedID = true
                }
                .resetsAfterCopy($copiedID)
                if let project = selection.project {
                    Button("Open project") { openProject(project.root) }
                        .disabled(!projectExists(project.root))
                }
                if selection.isStopEnabled {
                    switch eligibility {
                    case .eligible:
                        Button("Stop container…", role: .destructive) { onRequestStop(selection) }
                    case .excluded:
                        Text("Excluded in Settings")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .denied:
                        EmptyView()
                    }
                }
            }
            .controlSize(.small)

            if !selection.isStopEnabled {
                Text(settings.dockerEnabled ? ContainerStopWording.turnOn : ContainerStopWording.turnOnDocker)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if case .denied(let reason) = eligibility {
                Text("Stop unavailable: \(reason)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
