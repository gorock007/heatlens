import SwiftUI
import HeatLensCore

/// Live mode (PRD-v2 Phase 1): refreshes every 2, 5 or 10 seconds while you watch. Nothing is
/// sampled until Start, and closing the panel stops it.
struct LiveView: View {
    let model: LiveModel

    /// The process a Top list row opened, pinned to the update it was clicked in so the detail
    /// doesn't change under the user, or lose the process when it exits.
    @State private var selection: LiveSelection?

    var body: some View {
        if let selection {
            // Live keeps ticking underneath; Back returns to the newest update.
            ProcessDetailView(identity: selection.identity, context: selection.context, stopService: LiveNoStopService(),
                              onBack: { self.selection = nil }, onRequestStop: { _ in })
        } else {
            live
        }
    }

    private var live: some View {
        VStack(alignment: .leading, spacing: 12) {
            Controls(model: model)
            if let tick = model.latest {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !tick.explanations.isEmpty {
                            ExplanationsCard(explanations: tick.explanations)
                        }
                        if !tick.alerts.isEmpty {
                            AlertBanner(alerts: tick.alerts)
                        }
                        LiveOverview(tick: tick)
                        if !tick.projects.usages.isEmpty {
                            ProjectsCard(breakdown: tick.projects, groups: tick.groups, limit: 4)
                        }
                        TimelineCard(tick: tick, keepHistory: model.settings.keepHistory)
                        TopList(title: "Top CPU", processes: tick.topByCPU, tick: tick, metric: .cpu) { inspect($0, in: tick) }
                        TopList(title: "Top memory", processes: tick.topByMemory, tick: tick, metric: .memory) { inspect($0, in: tick) }
                        HardwareCard(sample: tick.hardware)
                        // No onInspect: Live rows change under the pointer, so stops come only from a scan result (ADR-0007).
                        DockerCard(snapshot: tick.docker.availability == .disabled ? nil : tick.docker, onTurnOn: {
                            // Same switch as Settings; restart so the session picks it up.
                            model.settings.dockerEnabled = true
                            if model.isRunning { model.start() }
                        })
                        ForEach(tick.snapshot.notices, id: \.self) { notice in
                            Label(notice, systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.trailing, 8)
                }
                .frame(maxHeight: 440)
            } else {
                Text(model.isRunning
                     ? "Measuring…"
                     : "Live mode refreshes CPU, energy, memory and hardware sensors while this panel is open, and Docker if you turn it on. Nothing runs until you press Start.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func inspect(_ identity: ProcessIdentity, in tick: LiveTick) {
        // No findings, so the detail never offers Request stop: Live mode doesn't stop processes.
        let report = ScanReport(snapshot: tick.snapshot, groups: tick.groups, findings: [], reportText: "", reportJSON: "",
                                hardware: tick.hardware, docker: tick.docker, projects: tick.projects)
        selection = LiveSelection(identity: identity, context: ReportContext(report: report))
    }
}

private struct LiveSelection {
    let identity: ProcessIdentity
    let context: ReportContext
}

/// Live mode never stops or force-quits a process; the detail needs a stop service, and this one refuses.
private struct LiveNoStopService: ProcessStopping {
    func eligibility(of process: ProcessSample) -> StopEligibility {
        .denied(reason: "Live mode doesn't stop processes.")
    }

    func requestStop(_ identity: ProcessIdentity, wait: TimeInterval, context: ActionContext) async -> StopOutcome {
        .denied(reason: "Live mode doesn't stop processes.")
    }

    func forceQuit(_ identity: ProcessIdentity, context: ActionContext) async -> StopOutcome {
        .denied(reason: "Live mode doesn't stop processes.")
    }

    func stopRequestedAt(_ identity: ProcessIdentity) async -> Date? {
        nil
    }
}

private struct Controls: View {
    let model: LiveModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if model.isRunning {
                    Button("Pause", systemImage: "pause.fill") { model.stop() }
                    Button("Refresh now", systemImage: "arrow.clockwise") { model.refreshNow() }
                        .labelStyle(.iconOnly)
                        .help("Refresh now")
                } else {
                    Button("Start live", systemImage: "play.fill") { model.start() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
                Spacer()
                Picker("Interval", selection: Binding(get: { model.settings.liveInterval }, set: { model.setInterval($0) })) {
                    ForEach(LiveConfiguration.intervals, id: \.self) { Text("\(Int($0)) s").tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .fixedSize()
                .help("Refresh interval")
            }
            if case .stopped(let reason?) = model.state {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let failure = model.latest?.historyFailure, model.isRunning {
                Text("History not saved: \(failure)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if let tick = model.latest, model.isRunning {
                Text("Live · update \(tick.sequence) · \(String(format: "%.0f", tick.collectionSeconds * 1000)) ms to collect · stops when you close the panel")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if model.latest != nil {
                Text("Paused. Showing the last update.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct LiveOverview: View {
    let tick: LiveTick

    var body: some View {
        let system = tick.snapshot.system
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Overview")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                SourceBadge(text: "macOS · public", isPrivate: false)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                GridRow {
                    Text("Thermal state").foregroundStyle(.secondary)
                    Text(Format.thermal(system.thermalState))
                }
                GridRow {
                    Text("CPU load").foregroundStyle(.secondary)
                    HStack {
                        Text(String(format: "%.1f / %d cores", system.busyCores, system.coreCount))
                        Sparkline(values: tick.history.hostBusy, maximum: 1)
                            .frame(width: 60, height: 14)
                    }
                }
                GridRow {
                    Text("CPU energy").foregroundStyle(.secondary)
                    Text(Format.watts(tick.snapshot.measuredCPUWatts).map { "\($0) · your processes" } ?? "Unavailable")
                        .help("From macOS's per-process energy counters. Root and system processes aren't readable, so this is below the CPU's total power.")
                }
                GridRow {
                    Text("Memory pressure").foregroundStyle(.secondary)
                    Text(Format.pressure(system.memory.pressure))
                }
                GridRow {
                    Text("Memory used").foregroundStyle(.secondary)
                    Text(system.memory.availablePercent.map { "\(100 - min(max($0, 0), 100))%" } ?? "Unavailable")
                        .help("100 minus the kernel's available-memory level (kern.memorystatus_level). Live's memory alert checks this number.")
                }
                GridRow {
                    Text("Swap").foregroundStyle(.secondary)
                    Text("\(Format.bytes(system.memory.swapUsedBytes)) used")
                }
                PowerContextRow(context: tick.hardware.power)
            }
            .font(.callout)
        }
    }
}

/// One line for the alerts that fired on this update; gone on the next update that has none.
private struct AlertBanner: View {
    let alerts: [HeatLensCore.Alert]

    var body: some View {
        let first = alerts[0]
        let more = alerts.count > 1 ? " · +\(alerts.count - 1) more" : ""
        Label(first.title + more, systemImage: "bell.badge")
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .help(alerts.map { $0.title + " — " + $0.suggestion }.joined(separator: "\n"))
    }
}

private enum Metric { case cpu, memory }

private struct TopList: View {
    let title: String
    let processes: [ProcessSample]
    let tick: LiveTick
    let metric: Metric
    let onInspect: (ProcessIdentity) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if processes.isEmpty {
                Text("Nothing measured yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(processes.prefix(8)) { process in
                // The whole row inspects, like the Ports rows in results.
                Button { onInspect(process.identity) } label: { row(process) }
                    .buttonStyle(.plain)
                    .help("Inspect process")
            }
        }
    }

    private func row(_ process: ProcessSample) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(process.name)
                    .font(.callout)
                    .lineLimit(1)
                Text(verbatim: "PID \(process.pid) · \(group(of: process))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Sparkline(values: series(process))
                .frame(width: 44, height: 14)
            VStack(alignment: .trailing, spacing: 0) {
                Text(value(process))
                    .font(.caption.monospacedDigit())
                if metric == .cpu, let watts = Format.watts(process.cpuWatts) {
                    Text(watts)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 58, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func value(_ process: ProcessSample) -> String {
        switch metric {
        case .cpu:
            guard let cpu = process.cpuPercentOfOneCore else { return "—" }
            return cpu < 10 ? String(format: "%.1f%%", cpu) : "\(Int(cpu.rounded()))%"
        case .memory:
            return Format.bytes(process.footprintBytes ?? process.residentBytes)
        }
    }

    private func series(_ process: ProcessSample) -> [Double?] {
        switch metric {
        case .cpu: tick.history.cpu[process.identity] ?? []
        case .memory: (tick.history.memoryBytes[process.identity] ?? []).map { $0.map(Double.init) }
        }
    }

    private func group(of process: ProcessSample) -> String {
        tick.groups.first { $0.members.contains(process.identity) }?.label ?? "Ungrouped"
    }
}
