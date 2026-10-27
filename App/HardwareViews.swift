import SwiftUI
import HeatLensCore

/// Hardware readings with their provenance: private SMC readings carry a "private interface"
/// badge, so they can't be mistaken for the OS's public thermal state. A missing reading says
/// why; it is never shown as zero.
struct HardwareCard: View {
    let sample: HardwareSample

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Hardware sensors")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                SourceBadge(text: "SMC · private interface", isPrivate: true)
            }
            if sample.cpuTemperature.availability == .disabled {
                Text("Off. Turn on “Hardware sensors” in Settings to see temperatures, fans and system power.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    row("CPU", temperature(sample.cpuTemperature))
                    row("GPU", temperature(sample.gpuTemperature))
                    row("Fans", HardwareFormat.fans(sample.fans))
                    row("System power", HardwareFormat.watts(sample.systemPowerWatts))
                    row("CPU / GPU power", HardwareFormat.watts(sample.cpuPowerWatts))
                }
                .font(.callout)
                Text("SMC sensor readings, \(sample.chip ?? "this Mac"). Hottest is the hottest sensor read, not a measured die hotspot.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func temperature(_ reading: SensorReading<TemperatureSummary>) -> String {
        guard let value = reading.value else { return HardwareFormat.unavailable(reading.availability) }
        return String(format: "%.0f °C avg · %.0f °C hottest", value.averageCelsius, value.hottestCelsius)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Public context: what macOS itself reports.
struct PowerContextRow: View {
    let context: PowerContext?

    var body: some View {
        GridRow {
            Text("Power").foregroundStyle(.secondary)
            Text(HardwareFormat.power(context))
        }
    }
}

struct DockerCard: View {
    let snapshot: DockerSnapshot?
    /// When set, the "Off" state offers a button that turns the switch on (Live mode).
    var onTurnOn: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Docker containers")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let snapshot, snapshot.availability.isAvailable {
                    SourceBadge(text: "Engine \(snapshot.engineVersion ?? "") · read-only", isPrivate: false)
                }
            }
            if let snapshot {
                content(snapshot)
            } else {
                Text(onTurnOn == nil
                     ? "Off. Turn on “Docker containers” in Settings. HeatLens only reads the local Docker socket and never starts Docker."
                     : "Off. HeatLens only reads the local Docker socket and never starts Docker.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let onTurnOn {
                    Button("Show Docker containers", systemImage: "shippingbox", action: onTurnOn)
                        .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ snapshot: DockerSnapshot) -> some View {
        if !snapshot.availability.isAvailable {
            Text(HardwareFormat.docker(snapshot.availability))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if snapshot.containers.isEmpty {
            Text("No containers.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            ForEach(snapshot.containers.prefix(8)) { container in
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text(container.name)
                            .font(.callout)
                            .lineLimit(1)
                        Spacer()
                        Text(container.isRunning ? Format.cpu(container.cpuPercentOfOneCore) : container.state)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(([container.image] + [container.composeProject.map { "compose \($0)/\(container.composeService ?? "?")" }]
                        .compactMap { $0 } + [container.isRunning ? Format.bytes(container.memoryBytes) : nil].compactMap { $0 })
                        .joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if snapshot.containers.count > 8 {
                Text("and \(snapshot.containers.count - 8) more")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let vm = snapshot.containers.compactMap(\.vmCPUCount).first {
                Text("Container CPU is part of the Docker VM's CPU (\(vm) VM CPUs), not extra load.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        ForEach(snapshot.notices, id: \.self) { notice in
            Label(notice, systemImage: "info.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct SourceBadge: View {
    let text: String
    let isPrivate: Bool

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(isPrivate ? Color.orange : Color.secondary)
            .background((isPrivate ? Color.orange : Color.secondary).opacity(0.12), in: Capsule())
            .help(isPrivate ? "Read from an undocumented macOS interface. It may stop working after a macOS update." : text)
    }
}

/// A small line chart over the live window; gaps where a value was missing.
struct Sparkline: View {
    let values: [Double?]
    var maximum: Double?

    var body: some View {
        GeometryReader { geometry in
            let top = max(maximum ?? (values.compactMap { $0 }.max() ?? 1), 0.0001)
            let step = values.count > 1 ? geometry.size.width / CGFloat(values.count - 1) : 0
            Path { path in
                var drawing = false
                for (index, value) in values.enumerated() {
                    guard let value else { drawing = false; continue }
                    let point = CGPoint(x: CGFloat(index) * step,
                                        y: geometry.size.height * (1 - CGFloat(min(value, top) / top)))
                    if drawing { path.addLine(to: point) } else { path.move(to: point) }
                    drawing = true
                }
            }
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

enum HardwareFormat {
    static func unavailable(_ availability: SensorAvailability) -> String {
        switch availability {
        case .available: "—"
        case .disabled: "Off"
        case .unsupported(let reason), .failed(let reason): "Unavailable (\(reason))"
        }
    }

    static func watts(_ reading: SensorReading<Double>) -> String {
        reading.value.map { String(format: "%.1f W", $0) } ?? unavailable(reading.availability)
    }

    static func fans(_ reading: SensorReading<[FanReading]>) -> String {
        guard let fans = reading.value else { return unavailable(reading.availability) }
        if fans.isEmpty { return "No fans reported" }
        return fans.map { "\(Int($0.rpm)) RPM" }.joined(separator: " · ")
    }

    static func power(_ context: PowerContext?) -> String {
        guard let context else { return "Unavailable" }
        var parts: [String] = [context.source == .ac ? "Power adapter" : context.source == .battery ? "Battery" : "Unknown source"]
        if context.hasBattery, let percent = context.batteryPercent {
            parts.append("\(percent)%" + (context.isCharging == true ? " charging" : ""))
        }
        if context.lowPowerMode { parts.append("Low Power Mode") }
        return parts.joined(separator: " · ")
    }

    static func docker(_ availability: DockerAvailability) -> String {
        switch availability {
        case .available: "Available"
        case .disabled: "Off in Settings."
        case .socketNotFound: "Docker isn't running (no Docker socket found). HeatLens never starts it."
        case .permissionDenied: "This user can't open the Docker socket."
        case .daemonNotResponding: "Docker didn't answer. It may be starting or stopping."
        case .unsupportedAPI(let version): "Docker Engine API \(version) is too old (1.41 or later needed)."
        case .error(let message): message
        }
    }
}
