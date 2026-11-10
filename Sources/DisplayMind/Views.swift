import AppKit
import SwiftUI
import DisplayMindCore

struct MainView: View {
    @ObservedObject var store: Store
    @State private var deleting: Preset?
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 224)
            Divider()
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(store.showRules ? "Connection rules" : store.selectedPreset?.name ?? "Your displays, arranged.")
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                        Text(store.showRules ? "The right setup, whenever you connect." : "Save a layout. Switch in a click.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.busy { ProgressView().controlSize(.small) }
                    if store.showRules {
                        Button { newRule() } label: { Label("New rule", systemImage: "plus") }
                            .disabled(store.settings.presets.isEmpty || store.busy || store.pending != nil)
                    } else {
                        Button { Task { await store.capture() } } label: { Label("Capture current", systemImage: "plus.viewfinder") }
                            .disabled(store.busy || store.pending != nil)
                    }
                }.padding(28)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if store.pending != nil { confirmation }
                        if store.showRules { rulesContent }
                        else if let preset = store.selectedPreset { presetContent(preset) }
                        else { welcome }
                    }.padding(28)
                }
                Divider()
                HStack {
                    Circle().fill(store.busy ? Color.orange : Color.accentColor).frame(width: 7, height: 7)
                    Text(store.status).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!) } label: {
                        Image(systemName: "gearshape")
                    }.buttonStyle(.plain).help("Open macOS Display Settings")
                    Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).help("Refresh displays").disabled(store.busy || store.pending != nil)
                }.padding(.horizontal, 24).padding(.vertical, 12)
            }
        }
        .frame(minWidth: 980, minHeight: 660)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $store.editorPreset) { PresetEditor(store: store, original: $0) }
        .sheet(item: $store.editorRule) { RuleEditor(store: store, original: $0) }
        .alert("DisplayMind", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
        .alert("Delete \(deleting?.name ?? "preset")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let deleting { store.delete(deleting) }; deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("Connection rules using this preset will also be removed.") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: Branding.logo).resizable().frame(width: 32, height: 32).accessibilityHidden(true)
                Text("DisplayMind").font(.system(size: 18, weight: .semibold, design: .rounded))
            }.padding(22).padding(.top, 8)
            Text("PRESETS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 22).padding(.bottom, 10)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(store.settings.presets) { preset in
                        Button {
                            store.selectedPresetID = preset.id; store.showRules = false
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: preset.displays.count > 1 ? "display.2" : "display")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(preset.name).fontWeight(.medium).lineLimit(1)
                                    Text("\(preset.displays.count) display\(preset.displays.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }.padding(11).contentShape(Rectangle())
                                .background(!store.showRules && store.selectedPresetID == preset.id ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain)
                    }
                    if store.settings.presets.isEmpty { Text("Capture your first layout to get started.").font(.callout).foregroundStyle(.secondary).padding(12) }
                }.padding(.horizontal, 10)
            }
            Divider().padding(.horizontal, 18).padding(.vertical, 16)
            Button { store.showRules = true } label: {
                HStack { Image(systemName: "bolt.horizontal.circle"); Text("Connection rules"); Spacer() }
                    .padding(12).background(store.showRules ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain).padding(.horizontal, 10)
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Automatic switching", isOn: Binding(get: { store.settings.automationEnabled }, set: store.toggleAutomation))
                    .toggleStyle(.switch).controlSize(.small)
                Toggle("Open at login", isOn: Binding(get: { store.loginEnabled }, set: store.setLogin))
                    .toggleStyle(.switch).controlSize(.small)
                Button("Open data folder") { try? FileManager.default.createDirectory(at: store.settingsFile.directory, withIntermediateDirectories: true); NSWorkspace.shared.open(store.settingsFile.directory) }
                    .font(.caption).buttonStyle(.link)
            }.font(.caption).padding(22)
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private var confirmation: some View {
        HStack(spacing: 16) {
            Image(systemName: "timer").font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text("Keep this layout?").fontWeight(.semibold)
                Text("Restoring your previous layout in \(store.secondsRemaining) seconds.").font(.callout)
            }
            Spacer()
            Button("Revert", action: store.revert).keyboardShortcut(.cancelAction)
            Button("Keep changes", action: store.keep).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }.padding(18).background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
    }

    private func presetContent(_ preset: Preset) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label(store.unavailable(preset) == nil ? "Ready to use" : "Displays disconnected", systemImage: store.unavailable(preset) == nil ? "checkmark.circle.fill" : "cable.connector.slash")
                    .foregroundStyle(store.unavailable(preset) == nil ? Color.teal : Color.secondary).font(.callout)
                Spacer()
                if !preset.confirmed { Label("Apply once to enable rules", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
            }
            DisplayDiagram(displays: preset.displays).frame(height: 260)
            if let target = preset.airPlay {
                Label("AirPlay → \(target.receiverName)" + (store.connectedIDs.contains(target.displayID) ? " · Connected" : " · Connects when applied"), systemImage: "airplayvideo")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button { Task { await store.apply(preset) } } label: { Label("Apply preset", systemImage: "play.fill").padding(.horizontal, 8) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(store.busy || store.pending != nil || store.unavailable(preset) != nil)
                Button("Edit layout") { store.editorPreset = preset }.controlSize(.large).disabled(store.busy || store.pending != nil)
                Menu {
                    Button("Duplicate") { store.duplicate(preset) }
                    Button("Create connection rule") { store.editorRule = ConnectionRule(name: "Use \(preset.name)", presetID: preset.id, requiredDevices: store.defaultRuleDevices(for: preset)) }
                    Divider()
                    Button("Delete preset…", role: .destructive) { deleting = preset }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24).disabled(store.busy || store.pending != nil)
                Spacer()
            }
            if let reason = store.unavailable(preset) { Text(reason).font(.callout).foregroundStyle(.secondary) }
            VStack(spacing: 0) {
                ForEach(preset.displays) { display in
                    HStack(spacing: 12) {
                        Image(systemName: display.rotation % 180 == 0 ? "display" : "rectangle.portrait").font(.title3).foregroundStyle(.secondary).frame(width: 28)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(display.name).fontWeight(.medium)
                            Text(display.mode.label + " · \(display.rotation)°").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(role(display, in: preset.displays)).font(.caption).foregroundStyle(.secondary)
                    }.padding(14)
                    if display.id != preset.displays.last?.id { Divider().padding(.leading, 54) }
                }
            }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        }
    }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 24) {
            DisplayDiagram(displays: store.displays.map(\.setting)).frame(height: 270)
            Text("A setup for every way you work.").font(.title2).fontWeight(.semibold)
            Text("Capture your current displays, then edit their rotation, resolution, position, and mirroring. Your presets are always one click away in the menu bar.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button { Task { await store.capture() } } label: { Label("Save my current layout", systemImage: "plus") }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(store.busy || store.displays.isEmpty)
        }
    }
    private var rulesContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Rules run from top to bottom. The first matching rule wins.", systemImage: "arrow.down").font(.callout).foregroundStyle(.secondary)
            if !store.settings.automationEnabled { Label("Automatic switching is paused.", systemImage: "pause.circle").foregroundStyle(.orange) }
            if store.settings.rules.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "cable.connector").font(.system(size: 36)).foregroundStyle(Color.accentColor)
                    Text("Connect your dock. Get your layout.").font(.title3).fontWeight(.semibold)
                    Text("Choose displays or USB devices, then the preset to use when they are present or absent.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Create a rule", action: newRule).disabled(store.settings.presets.isEmpty)
                }.frame(maxWidth: .infinity).padding(32).background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
            }
            ForEach(Array(store.settings.rules.enumerated()), id: \.element.id) { index, rule in
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Toggle(rule.name, isOn: Binding(get: { rule.enabled }, set: { enabled in var copy = rule; copy.enabled = enabled; store.saveRule(copy) })).toggleStyle(.switch).controlSize(.small)
                        Spacer()
                        Button { store.moveRule(rule, by: -1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0)
                        Button { store.moveRule(rule, by: 1) } label: { Image(systemName: "arrow.down") }.disabled(index == store.settings.rules.count - 1)
                        Button("Edit") { store.editorRule = rule }
                        Button { store.deleteRule(rule) } label: { Image(systemName: "trash") }.help("Delete rule")
                    }
                    Text(ruleSummary(rule)).font(.callout).foregroundStyle(.secondary)
                    if let preset = store.settings.presets.first(where: { $0.id == rule.presetID }) {
                        HStack {
                            Label(preset.name, systemImage: "arrow.turn.down.right")
                            Spacer()
                            Text(!preset.confirmed ? "Apply and keep this preset first" : RuleEngine.match(settings: store.settings, devices: store.devices)?.id == rule.id ? "Matches now" : "Waiting for devices")
                                .font(.caption).foregroundStyle(!preset.confirmed ? Color.orange : Color.secondary)
                        }
                    }
                }.padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            }
            Text("CONNECTED NOW").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 12)
            ForEach(store.devices) { device in
                HStack { Label(device.name, systemImage: device.kind == .display ? "display" : "cable.connector"); Spacer(); Text(device.kind == .display ? "Display" : "USB").foregroundStyle(.secondary) }.font(.callout)
            }
            Text("USB devices without serial numbers are remembered by their port. DisplayMind stays in the menu bar when you close this window.")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
        }.disabled(store.busy || store.pending != nil)
    }
    private func newRule() {
        guard let preset = store.selectedPreset ?? store.settings.presets.first else { return }
        store.editorRule = ConnectionRule(name: "Use \(preset.name)", presetID: preset.id, requiredDevices: store.defaultRuleDevices(for: preset))
    }
    private func ruleSummary(_ rule: ConnectionRule) -> String {
        var parts: [String] = []
        if !rule.requiredDevices.isEmpty { parts.append("Connected: " + rule.requiredDevices.map(\.name).joined(separator: ", ")) }
        if !rule.absentDevices.isEmpty { parts.append("Absent: " + rule.absentDevices.map(\.name).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

func role(_ display: DisplaySetting, in displays: [DisplaySetting]) -> String {
    if !display.enabled { return "Disabled" }
    if let source = display.mirrorOf { return "Mirrors " + (displays.first { $0.id == source }?.name ?? "display") }
    return display.x == 0 && display.y == 0 ? "Main display" : "Extended"
}

struct DisplayDiagram: View {
    let displays: [DisplaySetting]
    var moved: ((String, Int, Int) -> Void)?
    @State private var dragging: String?
    @State private var translation = CGSize.zero
    var body: some View {
        GeometryReader { proxy in
            let roots = displays.filter { $0.enabled && $0.mirrorOf == nil }
            let minX = roots.map(\.x).min() ?? 0
            let minY = roots.map(\.y).min() ?? 0
            let maxX = roots.map { $0.x + $0.mode.width }.max() ?? 1
            let maxY = roots.map { $0.y + $0.mode.height }.max() ?? 1
            let scale = max(0.001, min((proxy.size.width - 80) / CGFloat(max(1, maxX - minX)), (proxy.size.height - 60) / CGFloat(max(1, maxY - minY))))
            let offsetX = (proxy.size.width - CGFloat(maxX - minX) * scale) / 2
            let offsetY = (proxy.size.height - CGFloat(maxY - minY) * scale) / 2
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(Color.accentColor.opacity(0.045))
                Canvas { context, size in
                    for x in stride(from: 12.0, to: size.width, by: 20) {
                        for y in stride(from: 12.0, to: size.height, by: 20) {
                            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)), with: .color(.secondary.opacity(0.15)))
                        }
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 16))
                ForEach(roots) { display in
                    let isMain = display.x == 0 && display.y == 0
                    let width = max(44, CGFloat(display.mode.width) * scale - 5)
                    let height = max(30, CGFloat(display.mode.height) * scale - 5)
                    VStack(spacing: 6) {
                        if isMain { Capsule().fill(.white.opacity(0.85)).frame(width: min(width - 16, 58), height: 4) }
                        Spacer(minLength: 0)
                        Text(display.name).font(.system(size: 12, weight: .medium)).lineLimit(2).multilineTextAlignment(.center)
                        if height > 70 { Text("\(display.mode.width) × \(display.mode.height)").font(.system(size: 10)).opacity(0.75) }
                        if displays.contains(where: { $0.mirrorOf == display.id }), height > 90 { Label("Mirrored", systemImage: "rectangle.on.rectangle").font(.system(size: 10)) }
                        Spacer(minLength: 0)
                    }.padding(8).frame(width: width, height: height)
                        .foregroundStyle(.white)
                        .background(LinearGradient(colors: isMain ? [Color(red: 0.16, green: 0.55, blue: 0.68), Color(red: 0.11, green: 0.34, blue: 0.51)] : [Color(red: 0.32, green: 0.48, blue: 0.64), Color(red: 0.23, green: 0.32, blue: 0.48)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.2)))
                        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                        .offset(x: dragging == display.id ? translation.width : 0, y: dragging == display.id ? translation.height : 0)
                        .position(x: offsetX + CGFloat(display.x - minX) * scale + CGFloat(display.mode.width) * scale / 2,
                                  y: offsetY + CGFloat(display.y - minY) * scale + CGFloat(display.mode.height) * scale / 2)
                        .gesture(DragGesture().onChanged { value in
                            guard moved != nil, !isMain else { return }; dragging = display.id; translation = value.translation
                        }.onEnded { value in
                            if !isMain { moved?(display.id, display.x + Int((value.translation.width / scale / 10).rounded()) * 10, display.y + Int((value.translation.height / scale / 10).rounded()) * 10) }
                            dragging = nil; translation = .zero
                        })
                        .accessibilityLabel("\(display.name), \(role(display, in: displays)), \(display.rotation) degrees")
                }
                if roots.isEmpty { Text("No displays available").foregroundStyle(.secondary) }
            }
        }
    }
}
