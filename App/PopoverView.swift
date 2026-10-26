import SwiftUI

/// Idle popover (PRD §7 "Popover / idle"). Holds no timers and does no work
/// until the user acts; scanning is wired in Phase 1.
struct PopoverView: View {
    @State private var scanRequested = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("HeatLens")
                    .font(.headline)
                Spacer()
                Text("Last scan: never")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button {
                scanRequested = true
            } label: {
                Text("Scan now")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            if scanRequested {
                Text("Scanning arrives in Phase 1.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("Nothing is monitored until you scan.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                Spacer()
                Button("Quit HeatLens") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

#Preview {
    PopoverView()
}
