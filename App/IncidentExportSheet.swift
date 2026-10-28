import AppKit
import SwiftUI
import UniformTypeIdentifiers
import HeatLensCore

/// What an incident export is built around, plus the context it needs. Built at the click so the
/// sheet shows the moment that was clicked, not whatever Live shows a tick later.
struct IncidentExportRequest: Identifiable {
    enum Trigger {
        case explanation(Explanation)
        case alert(HeatLensCore.Alert)
        case busiestMoment(TimelineAnalysis.Peak)
    }

    let id = UUID()
    let trigger: Trigger
    let timeline: HistoryWindow
    let alerts: [HeatLensCore.Alert]
    let explanations: [Explanation]
    let keepHistory: Bool
    let retentionDays: Int
}

/// "Export incident…": a read-only preview of the redacted report, an anonymise toggle, a format
/// picker and Save…. The Save panel is the only thing that writes (owner decision 5): no clipboard,
/// no automatic file, and cancelling writes nothing.
struct IncidentExportSheet: View {
    let request: IncidentExportRequest

    @Environment(\.dismiss) private var dismiss
    @State private var anonymize = false
    @State private var format: Format = .markdown
    @State private var incident: Incident?
    @State private var saveError: String?

    enum Format: String, CaseIterable, Identifiable {
        case markdown = "Markdown", json = "JSON"
        var id: String { rawValue }
        var fileExtension: String { self == .markdown ? "md" : "json" }
        var contentType: UTType { self == .markdown ? UTType(filenameExtension: "md") ?? .plainText : .json }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Export incident")
                .font(.headline)
            Text("A redacted report of this moment, saved where you choose. HeatLens leaves out \(Redactor.incidentLeftOut.joined(separator: ", ")).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Picker("Format", selection: $format) {
                    ForEach(Format.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer()
            }
            Toggle("Replace project names with Project A, B…", isOn: $anonymize)
                .font(.callout)
            ScrollView {
                Text(verbatim: preview)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(height: 240)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            if let saveError {
                Text(saveError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save…") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(incident == nil)
            }
        }
        .padding(16)
        .frame(width: 460)
        .task { await build() }
    }

    private var options: IncidentExportOptions {
        IncidentExportOptions(anonymizeProjects: anonymize)
    }

    private var preview: String {
        guard let incident else { return "Preparing…" }
        switch format {
        case .markdown:
            return Redactor.incidentMarkdown(incident, options: options)
        case .json:
            return (try? Redactor.incidentJSON(incident, options: options)).flatMap { String(data: $0, encoding: .utf8) }
                ?? "The report couldn't be prepared."
        }
    }

    private func build() async {
        let actions = await ActionLog.shared.recent(limit: 1_000, includingSaved: request.keepHistory,
                                                   retentionDays: request.retentionDays).records
        switch request.trigger {
        case .explanation(let explanation):
            incident = IncidentBuilder.incident(from: explanation, timeline: request.timeline, alerts: request.alerts,
                                                explanations: request.explanations, actions: actions)
        case .alert(let alert):
            incident = IncidentBuilder.incident(from: alert, timeline: request.timeline, alerts: request.alerts,
                                                explanations: request.explanations, actions: actions)
        case .busiestMoment(let peak):
            incident = IncidentBuilder.incident(from: peak, timeline: request.timeline, alerts: request.alerts,
                                                explanations: request.explanations, actions: actions)
        }
    }

    private func save() {
        guard incident != nil else { return }
        let data: Data
        switch format {
        case .markdown:
            data = Data(preview.utf8)
        case .json:
            guard let json = incident.flatMap({ try? Redactor.incidentJSON($0, options: options) }) else {
                saveError = "The report couldn't be prepared."
                return
            }
            data = json
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Self.defaultFileName(format: format)
        panel.message = "Choose where to save the incident report."
        // Cancel returns here without touching the disk.
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            // 4d: HeatLensLog.notice(.export, format, anonymized)
            dismiss()
        } catch {
            saveError = "Couldn't save the report: \(error.localizedDescription)"
        }
    }

    /// `HeatLens incident 2026-10-28 14.02.md`: colons aren't welcome in file names.
    static func defaultFileName(format: Format, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "HeatLens incident \(formatter.string(from: now)).\(format.fileExtension)"
    }
}
