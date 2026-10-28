import SwiftUI
import HeatLensCore

/// Live mode (PRD-v2 Phase 1): refreshes every 2, 5 or 10 seconds while you watch. Nothing is
/// sampled until Start, and closing the panel stops it, unless "Keep watching in the background"
/// is on: then it shows the background cadence's ticks too (docs/v2/ADR-0008 §4).
struct LiveView: View {
    let model: LiveModel

    /// The process a Top list row opened, pinned to the update it was clicked in so the detail
    /// doesn't change under the user, or lose the process when it exits.
    @State private var selection: LiveSelection?
    /// The incident export sheet, set by an explanation, the alert banner or the busiest moment.
    @State private var exportRequest: IncidentExportRequest?

    var body: some View {
        if let selection {
            // Live keeps ticking underneath; Back returns to the newest update.
            ProcessDetailView(identity: selection.identity, context: selection.context, stopService: LiveNoStopService(),
                              onBack: { self.selection = nil }, onRequestStop: { _ in })
        } else {
            live
                .sheet(item: $exportRequest) { IncidentExportSheet(request: $0) }
        }
    }

    private var live: some View {
        VStack(alignment: .leading, spacing: 12) {
            Controls(model: model)
            if let tick = model.latest {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !tick.explanations.isEmpty {
                            ExplanationsCard(explanations: tick.explanations) { explanation in
                                exportRequest = exportRequest(.explanation(explanation), tick: tick)
                            }
                        }
                        if !model.recentAlerts.isEmpty {
                            AlertBanner(alerts: model.recentAlerts, onDismiss: model.dismissAlerts,
                                        onExport: { exportRequest = exportRequest(.alert(model.recentAlerts[0]), tick: tick) })
                                .task(id: model.recentAlertsExpireAt) {
                                    // Ticks also expire it; this covers a paused session.
                                    guard let expiry = model.recentAlertsExpireAt else { return }
                                    try? await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSinceNow)))
                                    if !Task.isCancelled { model.expireAlerts() }
                                }
                        }
                        LiveOverview(tick: tick)
                        if !tick.projects.usages.isEmpty {
                            ProjectsCard(breakdown: tick.projects, groups: tick.groups, limit: 4)
                        }
                        TimelineCard(tick: tick, keepHistory: model.settings.keepHistory) { peak, window in
                            exportRequest = exportRequest(.busiestMoment(peak), tick: tick, window: window)
                        }
                        TopList(title: "Top CPU", processes: tick.topByCPU, tick: tick, metric: .cpu) { inspect($0, in: tick) }
                        TopList(title: "Top memory", processes: tick.topByMemory, tick: tick, metric: .memory) { inspect($0, in: tick) }
                        HardwareCard(sample: tick.hardware)
                        // No onInspect: Live rows change under the pointer, so stops come only from a scan result (ADR-0007).
                        DockerCard(snapshot: tick.docker.availability == .disabled ? nil : tick.docker, onTurnOn: {
                            // Same switch as Settings; LiveModel restarts the session with it.
                            model.settings.dockerEnabled = true
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
                     : model.settings.keepWatchingInBackground
                        ? "Live mode refreshes CPU, energy, memory and hardware sensors, and Docker if you turn it on. Keep watching in the background is on, so after Start it goes on sampling when you close the panel, until Pause or Quit."
                        : "Live mode refreshes CPU, energy, memory and hardware sensors while this panel is open, and Docker if you turn it on. Nothing runs until you press Start.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func exportRequest(_ trigger: IncidentExportRequest.Trigger, tick: LiveTick,
                               window: HistoryWindow? = nil) -> IncidentExportRequest {
        IncidentExportRequest(trigger: trigger, timeline: window ?? tick.timeline, alerts: model.recentAlerts,
                              explanations: tick.explanations, keepHistory: model.settings.keepHistory,
                              retentionDays: model.settings.historyRetentionDays)
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
                if model.isForeground {
                    Button("Pause", systemImage: "pause.fill") { model.pause() }
                    Button("Refresh now", systemImage: "arrow.clockwise") { model.refreshNow() }
                        .labelStyle(.iconOnly)
                        .help("Refresh now")
                } else if model.isBackground {
                    Button("Watch live", systemImage: "play.fill") { model.start() }
                        .help("Refresh at the interval on the right while the panel is open")
                    Button("Pause", systemImage: "pause.fill") { model.pause() }
                        .help("Stop watching until Start live or the next launch")
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
            if model.isBackground {
                Text("Watching in the background · \(model.cadence ?? "starting")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if case .stopped(let reason?) = model.state {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let failure = model.latest?.historyFailure, model.isRunning {
                Text("History not saved: \(failure)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if let tick = model.latest, model.isRunning {
                Text("Live · update \(tick.sequence) · \(String(format: "%.0f", tick.collectionSeconds * 1000)) ms to collect · "
                     + (model.settings.keepWatchingInBackground ? "back to the background when you close the panel" : "stops when you close the panel"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if model.latest != nil || model.status.mode == .paused(.user) {
                Text(model.settings.keepWatchingInBackground && model.status.mode == .paused(.user)
                     ? "Paused until Start live or the next launch. Showing the last update."
                     : "Paused. Showing the last update.")
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

/// One line for the most recent alerts, up for 2 minutes after they fired or until ×.
private struct AlertBanner: View {
    let alerts: [HeatLensCore.Alert]
    let onDismiss: () -> Void
    let onExport: () -> Void

    var body: some View {
        let first = alerts[0]
        let more = alerts.count > 1 ? " · +\(alerts.count - 1) more" : ""
        HStack(spacing: 6) {
            Label(first.title + more, systemImage: "bell.badge")
                .font(.caption)
                .lineLimit(1)
                .help(alerts.map { $0.title + " — " + $0.suggestion }.joined(separator: "\n"))
            Spacer(minLength: 0)
            Button("Export…", action: onExport)
                .buttonStyle(.link)
                .font(.caption)
                .help("Save a redacted report of this alert")
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Dismiss. The alert stays in Timeline.")
            .accessibilityLabel("Dismiss alert")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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
