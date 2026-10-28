import SwiftUI
import HeatLensCore

/// "What's going on" (PRD-v2 Phase 3): bursts of concurrent work explained in plain words, with
/// the recommendation and confidence up front and the observations and uncertainty behind a
/// disclosure. Advice only: nothing here acts on a process.
struct ExplanationsCard: View {
    let explanations: [Explanation]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("What's going on")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("inference")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("HeatLens's reading of what it observed, from rules. Check the observations behind it.")
            }
            ForEach(explanations) { explanation in
                ExplanationRow(explanation: explanation)
            }
        }
    }
}

private struct ExplanationRow: View {
    let explanation: Explanation

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(explanation.observations.enumerated()), id: \.offset) { _, observation in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(observation.timestamp.formatted(date: .omitted, time: .standard))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(verbatim: "\(observation.evidence.label) · \(observation.evidence.value)")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                            .help("From \(observation.evidence.source)")
                    }
                }
                ForEach(explanation.uncertainty, id: \.self) { line in
                    Label(line, systemImage: "questionmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 4)
            .padding(.top, 2)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: explanation.title)
                        .font(.callout.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    ConfidenceChip(confidence: explanation.confidence)
                }
                Text(verbatim: explanation.recommendation)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var status: String {
        let started = "Started \(explanation.startedAt.formatted(date: .omitted, time: .shortened))"
        guard let ended = explanation.endedAt else { return started + " · still running" }
        return started + " · ended \(ended.formatted(date: .omitted, time: .shortened))"
    }
}

private struct ConfidenceChip: View {
    let confidence: Confidence

    var body: some View {
        Text(Format.confidence(confidence))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.15), in: Capsule())
            .fixedSize()
    }

    private var tint: Color {
        switch confidence {
        case .high: .blue
        case .medium: .secondary
        case .low: .orange
        }
    }
}
