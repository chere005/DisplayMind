import SwiftUI
import DisplayMindCore

/// A persistent checklist lets several monitors be chosen without reopening a menu for every choice.
struct PresetMonitorFilter: View {
    let monitors: [PresetOrganization.Monitor]
    @Binding var selected: Set<String>
    @Binding var matching: PresetOrganization.MatchMode
    let matchCount: Int
    @State private var presented = false

    private var title: String {
        if selected.isEmpty { return "All presets" }
        if selected.count == 1, let monitor = monitors.first(where: { selected.contains($0.id) }) {
            return monitor.title
        }
        return "\(selected.count) displays · \(matching == .all ? "all" : "any")"
    }
    private var summary: String {
        selected.isEmpty ? "All presets" : "Includes \(matching == .all ? "all" : "any") of: " + monitors.filter { selected.contains($0.id) }.map(\.title).joined(separator: ", ")
    }
    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(selected.isEmpty ? Color.secondary : Branding.text)
                Text(title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.bordered).controlSize(.large)
        .help(summary).accessibilityLabel("Filter presets by included displays").accessibilityValue(summary)
        .popover(isPresented: $presented, arrowEdge: .trailing) {
            PresetMonitorFilterPanel(monitors: monitors, selected: $selected, matching: $matching, matchCount: matchCount) { presented = false }
        }
    }
}

struct PresetMonitorFilterPanel: View {
    let monitors: [PresetOrganization.Monitor]
    @Binding var selected: Set<String>
    @Binding var matching: PresetOrganization.MatchMode
    let matchCount: Int
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Included displays").font(.headline)
                Spacer()
                Button("Clear", action: { selected = [] }).buttonStyle(.link).disabled(selected.isEmpty)
                    .help("Show all presets")
            }
            Segments(label: "Match selected displays", options: [(.all, "All selected"), (.any, "Any selected")], selection: $matching)
            Text(matching == .all ? "Include every checked display." : "Include at least one checked display.")
                .font(.caption).foregroundStyle(.secondary)
            if monitors.isEmpty {
                Text("No saved or connected displays.").foregroundStyle(.secondary).padding(.vertical, 12)
            } else if monitors.count <= 5 {
                checklist
            } else {
                ScrollView { checklist }.frame(height: 260)
            }
            Divider()
            HStack {
                Text("\(matchCount) matching preset\(matchCount == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16).frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand(perform: done)
    }
    private var checklist: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(monitors) { monitor in
                Toggle(isOn: Binding(get: { selected.contains(monitor.id) }, set: { checked in
                    if checked { selected.insert(monitor.id) } else { selected.remove(monitor.id) }
                })) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(monitor.title).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
                .toggleStyle(.checkbox).padding(.vertical, 7).padding(.horizontal, 2)
                .frame(maxWidth: .infinity, alignment: .leading).help(monitor.title)
            }
        }
    }
}
