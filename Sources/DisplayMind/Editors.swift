import SwiftUI
import DisplayMindCore

/// The arrangement on the left, everything about the chosen display and the preset on the right: nothing sits below a fold.
struct PresetEditor: View {
    @ObservedObject var store: Store
    let original: Preset
    @State private var draft: Preset
    @State private var selectedID: String
    @State private var validation: String?
    @State private var outputs: [AudioDevice]
    @State private var inputs: [AudioDevice]
    /// `selected` and `validate` open the editor on a given display or with its arrangement message showing (previews).
    init(store: Store, original: Preset, selected: String? = nil, validate: Bool = false) {
        self.store = store; self.original = original
        _outputs = State(initialValue: store.audio.outputs()); _inputs = State(initialValue: store.audio.inputs())
        _draft = State(initialValue: original)
        _selectedID = State(initialValue: selected ?? original.displays.first?.id ?? "")
        _validation = State(initialValue: validate ? Configuration.arrangementIssue(original.displays) : nil)
    }
    private var isNew: Bool { !store.settings.presets.contains { $0.id == original.id } }
    // A popup is as wide as its longest item unless told otherwise, so every control in the inspector gets one width.
    private let labelWidth: CGFloat = 76
    private let columnWidth: CGFloat = 316
    private var fieldWidth: CGFloat { columnWidth - labelWidth - 10 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Text(isNew ? "New preset" : "Edit preset").font(.title2).fontWeight(.semibold).fixedSize()
                TextField("Preset name", text: $draft.name).textFieldStyle(.roundedBorder).controlSize(.large)
            }.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 18)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                arrangement.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                ScrollView { inspector.frame(width: columnWidth, alignment: .leading).padding(20) }.frame(width: columnWidth + 40)
            }
            Divider()
            HStack(spacing: 10) {
                Text("After a preset is applied you have 10 seconds to revert it.").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button("Cancel") { store.editorPreset = nil }.keyboardShortcut(.cancelAction)
                Button("Save preset") { save() }.buttonStyle(.borderedProminent).tint(Branding.fill).keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.controlSize(.large).padding(.horizontal, 24).padding(.vertical, 14)
        }.frame(width: 980, height: 740).background(Color(nsColor: .windowBackgroundColor))
            .alert("DisplayMind", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.dismissError() } })) {
                Button("OK", role: .cancel) { store.dismissError() }
            } message: { Text(store.error ?? "") }
    }

    private func save() {
        do {
            try Configuration.validate(draft)
            if let issue = Configuration.arrangementIssue(draft.displays) { validation = issue; return }
            if draft.displays != original.displays || draft.airPlay != original.airPlay { draft.confirmed = false }
            store.save(draft)
        } catch { validation = error.localizedDescription }
    }

    // MARK: Arrangement

    private var arrangement: some View {
        let hidden = draft.displays.filter { !$0.enabled || $0.mirrorOf != nil }
        return VStack(alignment: .leading, spacing: 12) {
            DisplayDiagram(displays: draft.displays, selected: selectedID, select: { selectedID = $0 }, moved: { id, x, y in
                guard let i = draft.displays.firstIndex(where: { $0.id == id }),
                      let snapped = Configuration.snappedPosition(draft.displays, moving: id, to: (x, y)) else { return }
                draft.displays[i].x = min(100_000, max(-100_000, snapped.x)); draft.displays[i].y = min(100_000, max(-100_000, snapped.y))
                validation = nil
            }).frame(maxWidth: .infinity, maxHeight: .infinity)
            if !hidden.isEmpty {
                // Mirrors and disabled displays take no room in the arrangement, so they are chosen here.
                HStack(spacing: 8) {
                    Text("Not in the arrangement").font(.caption).foregroundStyle(.secondary).fixedSize()
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(hidden) { display in
                                Button { selectedID = display.id } label: {
                                    Label(display.name + (display.enabled ? " · mirror" : " · disabled"), systemImage: display.enabled ? "rectangle.on.rectangle" : "display.trianglebadge.exclamationmark")
                                        .font(.caption).lineLimit(1).padding(.horizontal, 9).padding(.vertical, 5)
                                        .background(selectedID == display.id ? Branding.selection : Branding.card, in: Capsule())
                                        .overlay(Capsule().strokeBorder(selectedID == display.id ? Branding.text : Branding.hairline))
                                        .contentShape(Capsule())
                                }.buttonStyle(.plain).help("Edit \(display.name)")
                            }
                        }
                    }
                }
            }
            if let validation {
                Label(validation, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Click a display to edit it. Drag an extended display to move it; it snaps to the nearest edge. The main display stays at (0, 0).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Inspector

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Display")
                PopUp(label: "Display", options: draft.displays.map { ($0.id, $0.name) }, selection: $selectedID).frame(width: columnWidth)
                if let index = draft.displays.firstIndex(where: { $0.id == selectedID }) { displayControls(index) }
            }
            Divider()
            soundControls
            Divider()
            airPlayControls
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(width: labelWidth, alignment: .leading)
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func displayControls(_ index: Int) -> some View {
        let display = draft.displays[index]
        let isMain = display.mirrorOf == nil && display.x == 0 && display.y == 0
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 12) {
            GridRow {
                label("Name")
                TextField("Display name", text: $draft.displays[index].name).textFieldStyle(.roundedBorder).frame(width: fieldWidth)
            }
            GridRow {
                label("Use as")
                if isMain {
                    Label("Main display", systemImage: "menubar.rectangle").foregroundStyle(Branding.text)
                } else {
                    PopUp(label: "Use as", options: [("", "Extended display")] + draft.displays.filter { $0.id != display.id && $0.enabled && $0.mirrorOf == nil }.map { ($0.id, "Mirror of \($0.name)") }, selection: Binding(get: { draft.displays[index].mirrorOf ?? "" }, set: { parent in
                        draft.displays[index].mirrorOf = parent.isEmpty ? nil : parent
                        if parent.isEmpty && draft.displays[index].x == 0 && draft.displays[index].y == 0,
                           let main = draft.displays.first(where: { $0.id != display.id && $0.mirrorOf == nil && $0.x == 0 && $0.y == 0 }) {
                            draft.displays[index].x = main.mode.width
                        }
                        if !parent.isEmpty {
                            for i in draft.displays.indices where draft.displays[i].mirrorOf == display.id { draft.displays[i].mirrorOf = parent }
                        }
                        validation = nil
                    }), separatesFirst: true).frame(width: fieldWidth)
                }
            }
            if display.mirrorOf == nil {
                GridRow {
                    label("Rotation")
                    Segments(label: "Rotation", options: [(0, "0°"), (90, "90°"), (180, "180°"), (270, "270°")], selection: Binding(get: { draft.displays[index].rotation }, set: { rotation in
                        let old = draft.displays[index].rotation
                        if old % 180 != rotation % 180 {
                            let width = draft.displays[index].mode.width
                            draft.displays[index].mode.width = draft.displays[index].mode.height
                            draft.displays[index].mode.height = width
                        }
                        draft.displays[index].rotation = rotation
                        validation = nil
                    })).frame(width: fieldWidth)
                }
                GridRow {
                    label("Resolution")
                    PopUp(label: "Resolution", options: availableModes(for: display).map { ($0, $0.label) }, selection: $draft.displays[index].mode).frame(width: fieldWidth)
                }
                GridRow {
                    label("Position")
                    HStack(spacing: 6) {
                        Text("X").foregroundStyle(.secondary)
                        TextField("X", value: Binding(get: { draft.displays[index].x }, set: { draft.displays[index].x = min(100_000, max(-100_000, $0)); validation = nil }), format: .number.grouping(.never))
                            .frame(width: 72).multilineTextAlignment(.trailing)
                        Text("Y").foregroundStyle(.secondary).padding(.leading, 6)
                        TextField("Y", value: Binding(get: { draft.displays[index].y }, set: { draft.displays[index].y = min(100_000, max(-100_000, $0)); validation = nil }), format: .number.grouping(.never))
                            .frame(width: 72).multilineTextAlignment(.trailing)
                    }.textFieldStyle(.roundedBorder).disabled(isMain)
                }
                if !isMain {
                    GridRow {
                        Color.clear.frame(width: labelWidth, height: 1)
                        HStack(spacing: 8) {
                            Menu("Place beside") {
                                ForEach(draft.displays.filter { $0.id != display.id && $0.mirrorOf == nil && $0.enabled }) { other in
                                    Menu(other.name) {
                                        Button("To the right") { place(index, x: other.x + other.mode.width, y: other.y) }
                                        Button("To the left") { place(index, x: other.x - display.mode.width, y: other.y) }
                                        Button("Above") { place(index, x: other.x, y: other.y - display.mode.height) }
                                        Button("Below") { place(index, x: other.x, y: other.y + other.mode.height) }
                                    }
                                }
                            }.fixedSize()
                            Button("Make main") { Configuration.makeMain(display.id, displays: &draft.displays); validation = nil }.fixedSize()
                        }
                    }
                }
            } else {
                GridRow {
                    label("Mirroring")
                    note("Resolution, rotation and position follow \(draft.displays.first { $0.id == display.mirrorOf }?.name ?? "the source display").")
                }
            }
        }
        if let connected = store.displays.first(where: { $0.id == display.id }), display.mirrorOf == nil, connected.setting.rotation != display.rotation {
            note("Resolutions are listed for the display’s current orientation. If macOS rejects a rotated one, the previous layout is restored.")
        }
        if !display.enabled { note("This display was disabled in the captured layout and stays disabled.") }
    }
    private func place(_ index: Int, x: Int, y: Int) { draft.displays[index].x = x; draft.displays[index].y = y; validation = nil }
    private func availableModes(for display: DisplaySetting) -> [DisplayMode] {
        guard let connected = store.displays.first(where: { $0.id == display.id }) else { return [display.mode] }
        let modes = connected.modes.map { mode -> DisplayMode in
            var copy = mode
            if connected.setting.rotation % 180 != display.rotation % 180 { copy.width = mode.height; copy.height = mode.width }
            return copy
        }
        return Array(Set(modes + [display.mode])).sorted(by: DisplayMode.pickerOrder)
    }

    // MARK: Sound

    private func soundPicker(_ title: String, connected: [AudioDevice], saved: AudioDevice?, set: @escaping (AudioDevice?) -> Void) -> some View {
        let options = connected + (saved.map { s in connected.contains(where: { $0.uid == s.uid }) ? [] : [s] } ?? [])
        let titles = options.map { device in (device.uid, device.name + (connected.contains(where: { $0.uid == device.uid }) ? "" : " (not connected)")) }
        return PopUp(label: title, options: [("", "Don’t change")] + titles, selection: Binding(get: { saved?.uid ?? "" }, set: { uid in set(options.first { $0.uid == uid }) }), separatesFirst: true)
            .frame(width: fieldWidth)
    }
    private func setSound(_ change: (inout AudioSelection) -> Void) {
        var selection = draft.audio ?? AudioSelection()
        change(&selection)
        draft.audio = selection.isEmpty ? nil : selection
    }
    private var soundControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Sound")
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 12) {
                GridRow {
                    label("Output")
                    soundPicker("Sound output", connected: outputs, saved: draft.audio?.output) { device in setSound { $0.output = device } }
                }
                GridRow {
                    label("Input")
                    soundPicker("Sound input", connected: inputs, saved: draft.audio?.input) { device in setSound { $0.input = device } }
                }
            }
            note("Set after the displays are arranged. Bluetooth headphones in use are left alone, and the device chosen here takes over when they disconnect. A device that is not connected is skipped.")
        }
    }

    // MARK: AirPlay

    /// Displays that can be the receiver's: the ones macOS reports as AirPlay first, then any other that is not built in.
    private var airPlayDisplays: [DisplaySetting] {
        let candidates = draft.displays.filter { display in display.enabled && !store.displays.contains(where: { $0.id == display.id && $0.builtIn }) }
        return candidates.filter { store.airPlayOnline[$0.id] != nil } + candidates.filter { store.airPlayOnline[$0.id] == nil }
    }
    private var airPlayControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("AirPlay")
            Toggle("Connect a receiver when applying", isOn: Binding(get: { draft.airPlay != nil }, set: { enabled in
                if enabled, let display = airPlayDisplays.first {
                    draft.manualAirPlay = nil
                    draft.airPlay = AirPlayDestination(receiverName: store.receiverName(for: display), displayID: display.id)
                } else { draft.airPlay = nil; draft.manualAirPlay = true }   // off by choice: not switched back on for containing an AirPlay display
            })).disabled(airPlayDisplays.isEmpty)
            if airPlayDisplays.isEmpty {
                note("Connect the receiver with macOS Screen Mirroring, then capture that layout so its display is part of a preset.")
            } else if draft.airPlay == nil {
                note("Off: this preset needs the receiver connected by hand before it can be applied.")
            }
            if let target = draft.airPlay {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 12) {
                    GridRow {
                        label("Receiver")
                        TextField("Name in Screen Mirroring", text: Binding(get: { draft.airPlay?.receiverName ?? "" }, set: {
                            draft.airPlay?.receiverName = $0; draft.airPlay?.controlIdentifier = nil
                        })).textFieldStyle(.roundedBorder).frame(width: fieldWidth)
                    }
                    GridRow {
                        Color.clear.frame(width: labelWidth, height: 1)
                        HStack(spacing: 8) {
                            if store.airPlayReceivers.isEmpty {
                                Button("Find receivers…") { Task { await store.findAirPlayReceivers() } }.fixedSize()
                            } else {
                                Menu("Choose receiver") {
                                    ForEach(store.airPlayReceivers) { receiver in
                                        Button(receiver.name + (receiver.selected == true ? " (connected)" : "")) {
                                            draft.airPlay?.receiverName = receiver.name
                                            draft.airPlay?.controlIdentifier = receiver.id
                                        }
                                    }
                                    Divider()
                                    Button("Look again…") { Task { await store.findAirPlayReceivers() } }
                                }.fixedSize()
                            }
                            if store.airPlayScanning { ProgressView().controlSize(.small) }
                        }.disabled(store.airPlayScanning)
                    }
                    GridRow {
                        label("Its display")
                        PopUp(label: "AirPlay display", options: airPlayDisplays.map { ($0.id, $0.name) }, selection: Binding(get: { target.displayID }, set: { draft.airPlay?.displayID = $0 })).frame(width: fieldWidth)
                    }
                }
                note("DisplayMind connects the receiver, waits for this display, then arranges. A preset without this display stops the stream. Finding receivers briefly opens Screen Mirroring; a first-time receiver may ask for a pairing code.")
                if !store.airPlayAuthorized {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("DisplayMind needs Accessibility access to use Screen Mirroring.").font(.callout).fixedSize(horizontal: false, vertical: true)
                            Button("Allow AirPlay control…", action: store.allowAirPlayControl)
                        }
                    }
                }
            }
        }
    }
}

struct RuleEditor: View {
    @ObservedObject var store: Store
    let original: ConnectionRule
    @State private var draft: ConnectionRule
    init(store: Store, original: ConnectionRule) { self.store = store; self.original = original; _draft = State(initialValue: original) }
    private var isNew: Bool { !store.settings.rules.contains { $0.id == original.id } }
    private var preset: Preset? { store.settings.presets.first { $0.id == draft.presetID } }
    /// Displays first, then USB devices, each by name.
    private var devices: [Device] {
        store.knownDevices.sorted { ($0.kind == .display ? 0 : 1, $0.name.lowercased(), $0.id) < ($1.kind == .display ? 0 : 1, $1.name.lowercased(), $1.id) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Text(isNew ? "New rule" : "Edit rule").font(.title2).fontWeight(.semibold).fixedSize()
                TextField("Rule name", text: $draft.name).textFieldStyle(.roundedBorder).controlSize(.large)
            }.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 18)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Text("Apply").foregroundStyle(.secondary)
                    PopUp(label: "Preset to apply", options: store.settings.presets.map { ($0.id, $0.name) }, selection: $draft.presetID).frame(width: 260)
                    Text("when all of these match").foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                if let preset, !preset.confirmed {
                    Label("Apply and keep this preset once before the rule can run.", systemImage: "info.circle").font(.callout).foregroundStyle(.orange)
                }
                if let target = preset?.airPlay {
                    Text("This preset connects \(target.receiverName) itself. Use a dock or another display as the trigger: requiring the AirPlay display to be connected would wait for you to connect it by hand.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Card {
                    ScrollView {
                        VStack(spacing: 0) {
                            if devices.isEmpty { Text("No displays or USB devices detected yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(14) }
                            ForEach(devices) { device in
                                let connected = store.devices.contains { $0.id == device.id }
                                HStack(spacing: 12) {
                                    Image(systemName: device.kind == .display ? "display" : "cable.connector").foregroundStyle(.secondary).frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(device.name).lineLimit(1).truncationMode(.middle)
                                        HStack(spacing: 6) {
                                            Text(connected ? "Connected now" : "Not connected").foregroundStyle(connected ? Branding.text : Color.secondary)
                                            if devices.filter({ $0.name == device.name }).count > 1 { Text(String(device.id.suffix(22))).monospaced().foregroundStyle(.secondary).lineLimit(1) }
                                        }.font(.caption)
                                    }
                                    Spacer(minLength: 12)
                                    Picker(device.name, selection: Binding(get: { condition(device) }, set: { setCondition(device, $0) })) {
                                        Text("Ignore").tag(0); Text("Connected").tag(1); Text("Absent").tag(2)
                                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                                }.padding(.horizontal, 14).padding(.vertical, 9)
                                if device.id != devices.last?.id { Divider().padding(.leading, 50) }
                            }
                        }
                    }.frame(minHeight: 120, maxHeight: 300)
                }
                Toggle("Only when no other display is connected", isOn: $draft.exactDisplays)
                Text("The preset’s own displays must already be connected, unless it connects one through AirPlay. A rule waits three seconds for connections to settle and runs once per change; switching by hand lasts until devices change again.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(.horizontal, 24).padding(.vertical, 18)
            Divider()
            HStack(spacing: 10) {
                Toggle("Rule is on", isOn: $draft.enabled).toggleStyle(.switch).controlSize(.small).tint(Branding.fill)
                Spacer(minLength: 12)
                Button("Cancel") { store.editorRule = nil }.keyboardShortcut(.cancelAction)
                Button("Save rule") { store.saveRule(draft) }.buttonStyle(.borderedProminent).tint(Branding.fill).keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (draft.requiredDevices.isEmpty && draft.absentDevices.isEmpty))
                    .help(draft.requiredDevices.isEmpty && draft.absentDevices.isEmpty ? "Mark at least one device Connected or Absent" : "")
            }.controlSize(.large).padding(.horizontal, 24).padding(.vertical, 14)
        }.frame(width: 660).background(Color(nsColor: .windowBackgroundColor))
    }
    private func condition(_ device: Device) -> Int {
        draft.requiredDevices.contains { $0.id == device.id } ? 1 : draft.absentDevices.contains { $0.id == device.id } ? 2 : 0
    }
    private func setCondition(_ device: Device, _ condition: Int) {
        draft.requiredDevices.removeAll { $0.id == device.id }; draft.absentDevices.removeAll { $0.id == device.id }
        if condition == 1 { draft.requiredDevices.append(device) }; if condition == 2 { draft.absentDevices.append(device) }
    }
}
