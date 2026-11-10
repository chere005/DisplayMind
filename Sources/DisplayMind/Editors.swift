import SwiftUI
import DisplayMindCore

struct PresetEditor: View {
    @ObservedObject var store: Store
    let original: Preset
    @State private var draft: Preset
    @State private var selectedID: String
    @State private var validation: String?
    init(store: Store, original: Preset) {
        self.store = store; self.original = original
        _draft = State(initialValue: original)
        _selectedID = State(initialValue: original.displays.first?.id ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Edit display preset").font(.title2).fontWeight(.semibold)
                Spacer()
                Text("Changes apply when you choose Apply preset.").font(.caption).foregroundStyle(.secondary)
            }
            TextField("Preset name", text: $draft.name).textFieldStyle(.roundedBorder).font(.title3)
            ScrollView {
            VStack(alignment: .leading, spacing: 18) {
            airPlayControls
            DisplayDiagram(displays: draft.displays, moved: { id, x, y in
                if let i = draft.displays.firstIndex(where: { $0.id == id }) {
                    guard let snapped = Configuration.snappedPosition(draft.displays, moving: id, to: (x, y)) else { return }
                    draft.displays[i].x = min(100_000, max(-100_000, snapped.x)); draft.displays[i].y = min(100_000, max(-100_000, snapped.y))
                    validation = nil
                }
            }).frame(height: 210)
            Text("Drag extended displays to arrange them, or use exact positions below. The main display stays at (0, 0).")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Display", selection: $selectedID) { ForEach(draft.displays) { Text($0.name).tag($0.id) } }
            if let index = draft.displays.firstIndex(where: { $0.id == selectedID }) {
                displayControls(index)
            }
            if let validation { Text(validation).foregroundStyle(.red).font(.callout) }
            }
            }.frame(maxHeight: .infinity)
            Divider()
            HStack {
                Text("Applying a new layout gives you 20 seconds to keep it.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { store.editorPreset = nil }.keyboardShortcut(.cancelAction)
                Button("Save preset") {
                    do {
                        try Configuration.validate(draft)
                        if let issue = Configuration.arrangementIssue(draft.displays) { validation = issue; return }
                        if draft.displays != original.displays || draft.airPlay != original.airPlay { draft.confirmed = false }
                        store.save(draft)
                    } catch { validation = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(26).frame(width: 740, height: 720).background(Color(nsColor: .windowBackgroundColor))
            .alert("DisplayMind", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
                Button("OK", role: .cancel) { store.error = nil }
            } message: { Text(store.error ?? "") }
    }
    private var airPlayDisplays: [DisplaySetting] {
        draft.displays.filter { display in display.enabled && !store.displays.contains(where: { $0.id == display.id && $0.builtIn }) }
    }
    private var airPlayControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Connect AirPlay when applying this preset", isOn: Binding(get: { draft.airPlay != nil }, set: { enabled in
                if enabled, let display = airPlayDisplays.first {
                    draft.airPlay = AirPlayDestination(receiverName: display.name, displayID: display.id)
                } else { draft.airPlay = nil }
            })).fontWeight(.medium).disabled(airPlayDisplays.isEmpty)
            if airPlayDisplays.isEmpty {
                Text("Connect the receiver using macOS Screen Mirroring, then capture that layout to include its display in a preset.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let target = draft.airPlay {
                HStack {
                    TextField("Receiver name in Screen Mirroring", text: Binding(get: { draft.airPlay?.receiverName ?? "" }, set: {
                        draft.airPlay?.receiverName = $0; draft.airPlay?.controlIdentifier = nil
                    })).textFieldStyle(.roundedBorder)
                    if store.airPlayReceivers.isEmpty {
                        Button("Find receivers…") { Task { await store.findAirPlayReceivers() } }
                    } else {
                        Menu("Choose receiver") {
                            ForEach(store.airPlayReceivers) { receiver in
                                Button(receiver.name + (receiver.selected == true ? " (connected)" : "")) {
                                    draft.airPlay?.receiverName = receiver.name
                                    draft.airPlay?.controlIdentifier = receiver.id
                                }
                            }
                            Divider()
                            Button("Refresh receivers…") { Task { await store.findAirPlayReceivers() } }
                        }.fixedSize()
                    }
                    if store.airPlayScanning { ProgressView().controlSize(.small) }
                }.disabled(store.airPlayScanning)
                Picker("Saved AirPlay display", selection: Binding(get: { target.displayID }, set: { draft.airPlay?.displayID = $0 })) {
                    ForEach(airPlayDisplays) { Text($0.name).tag($0.id) }
                }
                HStack(alignment: .top) {
                    Text("Choose the receiver’s display captured in this preset. DisplayMind connects it before arranging your displays.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !store.airPlayAuthorized { Button("Allow AirPlay control…", action: store.allowAirPlayControl).font(.caption) }
                }
                Text("Find receivers briefly opens Screen Mirroring. A first-time receiver may ask for a pairing code.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(14).background(Color.accentColor.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }
    @ViewBuilder private func displayControls(_ index: Int) -> some View {
        let display = draft.displays[index]
        let isMain = display.mirrorOf == nil && display.x == 0 && display.y == 0
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 14) {
            GridRow {
                Text("Name").foregroundStyle(.secondary)
                TextField("Display name", text: $draft.displays[index].name).textFieldStyle(.roundedBorder)
            }
            GridRow {
                Text("Use as").foregroundStyle(.secondary)
                HStack {
                    Picker("Use as", selection: Binding(get: { draft.displays[index].mirrorOf ?? "" }, set: { parent in
                        draft.displays[index].mirrorOf = parent.isEmpty ? nil : parent
                        if parent.isEmpty && draft.displays[index].x == 0 && draft.displays[index].y == 0,
                           let main = draft.displays.first(where: { $0.id != display.id && $0.mirrorOf == nil && $0.x == 0 && $0.y == 0 }) {
                            draft.displays[index].x = main.mode.width
                        }
                        if !parent.isEmpty {
                            for i in draft.displays.indices where draft.displays[i].mirrorOf == display.id { draft.displays[i].mirrorOf = parent }
                        }
                    })) {
                        Text("Extended display").tag("")
                        ForEach(draft.displays.filter { $0.id != display.id && $0.enabled && $0.mirrorOf == nil && $0.mirrorOf != display.id }) { source in
                            Text("Mirror \(source.name)").tag(source.id)
                        }
                    }.labelsHidden().disabled(isMain)
                    if isMain { Label("Main", systemImage: "menubar.rectangle").font(.caption).foregroundStyle(Color.accentColor) }
                    else if display.mirrorOf == nil {
                        Button("Make main") { Configuration.makeMain(display.id, displays: &draft.displays) }
                    }
                }
            }
            if display.mirrorOf == nil {
                GridRow {
                    Text("Rotation").foregroundStyle(.secondary)
                    Picker("Rotation", selection: Binding(get: { draft.displays[index].rotation }, set: { rotation in
                        let old = draft.displays[index].rotation
                        if old % 180 != rotation % 180 {
                            let width = draft.displays[index].mode.width
                            draft.displays[index].mode.width = draft.displays[index].mode.height
                            draft.displays[index].mode.height = width
                        }
                        draft.displays[index].rotation = rotation
                    })) {
                        Text("0°").tag(0); Text("90°").tag(90); Text("180°").tag(180); Text("270°").tag(270)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 300)
                }
                GridRow {
                    Text("Resolution").foregroundStyle(.secondary)
                    Picker("Resolution", selection: $draft.displays[index].mode) {
                        ForEach(availableModes(for: display)) { mode in Text(mode.label).tag(mode) }
                    }.labelsHidden()
                }
                GridRow {
                    Text("Position").foregroundStyle(.secondary)
                    HStack {
                        Text("X").font(.caption)
                        TextField("X", value: Binding(get: { draft.displays[index].x }, set: { draft.displays[index].x = min(100_000, max(-100_000, $0)) }), format: .number.grouping(.never)).frame(width: 80)
                        Text("Y").font(.caption)
                        TextField("Y", value: Binding(get: { draft.displays[index].y }, set: { draft.displays[index].y = min(100_000, max(-100_000, $0)) }), format: .number.grouping(.never)).frame(width: 80)
                        if !isMain {
                            Menu("Place beside…") {
                                ForEach(draft.displays.filter { $0.id != display.id && $0.mirrorOf == nil && $0.enabled }) { other in
                                    Menu(other.name) {
                                        Button("To the right") { place(index, x: other.x + other.mode.width, y: other.y) }
                                        Button("To the left") { place(index, x: other.x - display.mode.width, y: other.y) }
                                        Button("Above") { place(index, x: other.x, y: other.y - display.mode.height) }
                                        Button("Below") { place(index, x: other.x, y: other.y + other.mode.height) }
                                    }
                                }
                            }.fixedSize()
                        }
                    }.textFieldStyle(.roundedBorder).disabled(isMain)
                }
            } else {
                GridRow {
                    Text("Mirroring").foregroundStyle(.secondary)
                    Text("Resolution, rotation, and position follow the source display.").font(.callout)
                }
            }
        }
        if let connected = store.displays.first(where: { $0.id == display.id }), connected.setting.rotation != display.rotation {
            Text("Modes are based on the display’s current orientation. If macOS rejects a rotated mode, the previous layout is restored.").font(.caption).foregroundStyle(.secondary)
        }
        if !display.enabled { Text("This display was disabled in the captured layout.").font(.caption).foregroundStyle(.secondary) }
    }
    private func place(_ index: Int, x: Int, y: Int) { draft.displays[index].x = x; draft.displays[index].y = y }
    private func availableModes(for display: DisplaySetting) -> [DisplayMode] {
        guard let connected = store.displays.first(where: { $0.id == display.id }) else { return [display.mode] }
        let modes = connected.modes.map { mode -> DisplayMode in
            var copy = mode
            if connected.setting.rotation % 180 != display.rotation % 180 { copy.width = mode.height; copy.height = mode.width }
            return copy
        }
        return Array(Set(modes + [display.mode])).sorted(by: DisplayMode.pickerOrder)
    }
}

struct RuleEditor: View {
    @ObservedObject var store: Store
    let original: ConnectionRule
    @State private var draft: ConnectionRule
    init(store: Store, original: ConnectionRule) { self.store = store; self.original = original; _draft = State(initialValue: original) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Connection rule").font(.title2).fontWeight(.semibold)
            TextField("Rule name", text: $draft.name).textFieldStyle(.roundedBorder)
            Picker("Apply preset", selection: $draft.presetID) { ForEach(store.settings.presets) { Text($0.name).tag($0.id) } }
            if let preset = store.settings.presets.first(where: { $0.id == draft.presetID }), !preset.confirmed {
                Label("Apply and keep this preset once before the rule can run.", systemImage: "info.circle").font(.callout).foregroundStyle(.orange)
            }
            if let preset = store.settings.presets.first(where: { $0.id == draft.presetID }), let target = preset.airPlay {
                Text("This preset connects \(target.receiverName) automatically. Use a dock or another display as the trigger; requiring the AirPlay display to be connected would wait for a manual connection.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("WHEN ALL THESE CONDITIONS MATCH").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(store.knownDevices) { device in
                        HStack {
                            Image(systemName: device.kind == .display ? "display" : "cable.connector").frame(width: 22).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(device.name)
                                Text(store.devices.contains(where: { $0.id == device.id }) ? "Connected now" : "Disconnected").font(.caption).foregroundStyle(.secondary)
                                if store.knownDevices.filter({ $0.name == device.name }).count > 1 { Text(String(device.id.suffix(22))).font(.caption2.monospaced()).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Picker(device.name, selection: Binding(get: { condition(device) }, set: { setCondition(device, $0) })) {
                                Text("Ignore").tag(0); Text("Connected").tag(1); Text("Absent").tag(2)
                            }.labelsHidden().frame(width: 150)
                        }
                    }
                }.padding(.vertical, 4)
            }.frame(minHeight: 120, maxHeight: 260)
            Toggle("Require exactly this preset’s displays (no additional displays)", isOn: $draft.exactDisplays)
            Text("Displays must already be connected unless this preset connects them through AirPlay. Rules wait for connections to settle, then apply once per connection change. Manual switching lasts until devices change again.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Toggle("Enabled", isOn: $draft.enabled)
                Spacer()
                Button("Cancel") { store.editorRule = nil }.keyboardShortcut(.cancelAction)
                Button("Save rule") { store.saveRule(draft) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (draft.requiredDevices.isEmpty && draft.absentDevices.isEmpty))
            }
        }.padding(26).frame(width: 620).background(Color(nsColor: .windowBackgroundColor))
    }
    private func condition(_ device: Device) -> Int {
        draft.requiredDevices.contains { $0.id == device.id } ? 1 : draft.absentDevices.contains { $0.id == device.id } ? 2 : 0
    }
    private func setCondition(_ device: Device, _ condition: Int) {
        draft.requiredDevices.removeAll { $0.id == device.id }; draft.absentDevices.removeAll { $0.id == device.id }
        if condition == 1 { draft.requiredDevices.append(device) }; if condition == 2 { draft.absentDevices.append(device) }
    }
}
