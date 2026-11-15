import SwiftUI
import UniformTypeIdentifiers
import NordPianoCore

struct ContentView: View {
    @EnvironmentObject private var model: PlayerModel
    @State private var isDropTarget = false
    /// Perform page: large scene tiles replace the mixer/keyboard for live use.
    @State private var performMode = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(NordColor.red.opacity(0.6))
            main
            footer
        }
        .background(NordColor.background.ignoresSafeArea())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            if let url = urls.first { model.load(url: url) }
            return true
        } isTargeted: { isDropTarget = $0 }
        .overlay(isDropTarget ? NordColor.red.opacity(0.15).ignoresSafeArea() : nil)
        .onOpenURL { model.load(url: $0) }
        .onAppear {
            // Open a file passed on the command line (e.g. `open -a NordPiano file.npno`).
            if CommandLine.arguments.count > 1 {
                model.load(url: URL(fileURLWithPath: CommandLine.arguments[1]))
            }
        }
    }

    /// FILES view (folder-scanned library) replaces the engine panels when on.
    @State private var showFiles = false

    /// Map a section title ("Root / subfolder") back to its library root URL.
    private func folderURL(for title: String) -> URL {
        let first = title.components(separatedBy: " / ").first ?? title
        return model.roots.first { $0.lastPathComponent == first } ?? URL(fileURLWithPath: "")
    }

    /// Loaded = red tint; highlighted (assign candidate) = fainter tint.
    private func rowBackground(for entry: PlayerModel.PianoEntry) -> Color {
        if model.selected.contains(entry) { return NordColor.red.opacity(0.18) }
        if model.highlighted == entry { return NordColor.red.opacity(0.07) }
        return NordColor.card
    }

    private func sidebarRow(_ entry: PlayerModel.PianoEntry) -> some View {
        let isSel = model.selected.contains(entry)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.callout).foregroundStyle(NordColor.text)
                Text("v\(entry.version)")
                    .font(.caption2).foregroundStyle(NordColor.subtext)
            }
            Spacer()
            if model.isFavorite(entry) {
                Image(systemName: "star.fill").font(.caption).foregroundStyle(NordColor.red)
            }
            if isSel && model.selected.count > 1,
               let channel = model.channels.first(where: { $0.entry == entry }) {
                Slider(value: Binding(
                    get: { Double(model.gains[entry.url] ?? 1) },
                    set: { model.setGain(Float($0), for: channel) }
                ), in: 0...1.5)
                .tint(NordColor.red)
                .frame(width: 70)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.select(entry) }
        .onTapGesture { model.highlighted = entry }
        .contextMenu {
            Button(model.isFavorite(entry) ? "Remove from Shortcuts" : "Send to Shortcuts") {
                model.toggleFavorite(entry)
            }
        }
    }

    /// Name prompt for saving a scene (modal field, same approach as NSOpenPanel).
    private func promptForName(title: String, initial: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(string: initial)
        field.placeholderString = "Scene name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    private func saveScene() {
        guard !model.selected.isEmpty else {
            model.status = "Select at least one sound before saving a scene"
            return
        }
        if let name = promptForName(title: "Save current setup as a scene") {
            model.saveScene(name: name)
        }
    }

    private func renameScene(_ scene: PlayerModel.Scene) {
        guard let name = promptForName(title: "Rename scene", initial: scene.name) else { return }
        model.renameScene(scene, to: name)
    }

    private var header: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(NordColor.red)
                    .frame(width: 10, height: 26)
                Text("nordpiano")
                    .font(NordFont.font(20, weight: .bold))
                    .foregroundStyle(NordColor.text)
                Text("Sample player")
                    .font(NordFont.font(9, weight: .medium))
                    .foregroundStyle(NordColor.subtext)
            }
            Spacer()
            sceneNavigator
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(model.pianoTitle).font(.headline).foregroundStyle(NordColor.text)
                if !model.version.isEmpty {
                    Text("sample library v\(model.version)")
                        .font(.caption).foregroundStyle(NordColor.subtext)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(NordColor.card)
    }

    /// Header center: ◀ SCENE n · name ▶ + SAVE (update the active scene).
    private var sceneNavigator: some View {
        HStack(spacing: 10) {
            Button { model.stepScene(-1) } label: {
                Image(systemName: "chevron.left").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.scenes.isEmpty ? NordColor.subtext.opacity(0.4) : NordColor.red)
            .disabled(model.scenes.isEmpty)

            if let index = model.activeSceneIndex {
                Text("SCENE \(index + 1) · \(model.scenes[index].name)")
                    .font(NordFont.font(11, weight: .bold))
                    .foregroundStyle(NordColor.red)
                    .lineLimit(1)
            } else {
                Text(model.scenes.isEmpty ? "NO SCENES" : "NO SCENE ACTIVE")
                    .font(NordFont.font(11, weight: .medium))
                    .foregroundStyle(NordColor.subtext)
            }

            Button { model.stepScene(1) } label: {
                Image(systemName: "chevron.right").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.scenes.isEmpty ? NordColor.subtext.opacity(0.4) : NordColor.red)
            .disabled(model.scenes.isEmpty)

            Button("SAVE") {
                if let index = model.activeSceneIndex {
                    model.updateScene(model.scenes[index])
                } else {
                    saveScene()
                }
            }
            .font(NordFont.font(9, weight: .bold))
            .buttonStyle(.bordered)
            .tint(.gray)
            .help(model.activeSceneIndex == nil
                  ? "Save the current setup as a new scene"
                  : "Overwrite the active scene with the current setup")
        }
    }

    /// Shared by the sidebar `+` button and the empty-library state.
    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Add a folder of .npno pianos and .nsmp3/.nsmp4 samples to the library"
        if panel.runModal() == .OK, let url = panel.url { model.addFolder(url) }
    }

    /// Import files into the categorized catalog (copied into the managed library).
    private func importFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["npno", "nsmp3", "nsmp4"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        panel.message = "Import sounds into the library (categorized by name — fix later via right-click)"
        if panel.runModal() == .OK { model.importSounds(panel.urls) }
    }

    private var filesList: some View {
        Group {
            if !model.sections.isEmpty {
                List(selection: .constant(Set<URL>())) {
                    ForEach(model.sections, id: \.title) { section in
                        Section(header: HStack {
                            Text(section.title)
                                .font(NordFont.font(10, weight: .bold))
                                .foregroundStyle(NordColor.red)
                            Spacer()
                            if !section.title.hasPrefix("★") {
                                Button { model.removeFolder(folderURL(for: section.title)) } label: {
                                    Image(systemName: "xmark.circle.fill").font(.caption)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(NordColor.subtext)
                                .help("Remove this folder from the library")
                            }
                        }
                        .contextMenu {
                            if !section.title.hasPrefix("★") {
                                Button("Remove folder") { model.removeFolder(folderURL(for: section.title)) }
                            }
                        }) {
                            ForEach(section.entries) { entry in
                                sidebarRow(entry)
                                    .listRowBackground(rowBackground(for: entry))
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    Text("No folders added")
                        .font(.callout).foregroundStyle(NordColor.text)
                    Button("Add Folder…") { addFolder() }
                        .buttonStyle(.bordered).tint(.gray)
                    Text("or drop a .npno / .nsmp4 file anywhere")
                        .font(.caption).foregroundStyle(NordColor.subtext)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var main: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                filesToggle
                Button { importFiles() } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .tint(.gray)
                .help("Import .npno / .nsmp3 / .nsmp4 files into the categorized library")
                Button {
                    if let highlighted = model.highlighted { model.assignToChannel(highlighted) }
                } label: {
                    Image(systemName: "arrow.right")
                }
                .buttonStyle(.bordered)
                .tint(NordColor.red)
                .disabled(model.highlighted == nil)
                .help("Assign the highlighted sound to the selected mixer channel (or a new channel)")
                Spacer()
                performToggle
                keyboardToggle
                devicesMenu
                recordButton
                Button("Open…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = ["npno", "nsmp3", "nsmp4"].compactMap { UTType(filenameExtension: $0) }
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url { model.load(url: url) }
                }
                .buttonStyle(.borderedProminent)
                .tint(NordColor.red)
                .help("Play a .npno / .nsmp3 / .nsmp4 file once, without adding it to the library")
            }
            if model.isRecording || model.lastTake != nil { takeBar }
            if performMode {
                performView
            } else if showFiles {
                filesList
                    .frame(maxHeight: .infinity)
            } else {
                enginesSection
                fxStrip
                MixerView()
                if model.showKeyboard {
                    KeyboardView()
                        .frame(height: 190)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(NordColor.red.opacity(0.35), lineWidth: 1))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .padding(16)
    }

    /// Full-width top section: scenes column + the three engine panels.
    private var enginesSection: some View {
        HStack(spacing: 12) {
            ScenesColumnView(onSave: saveScene, onRename: renameScene)
            EnginePanelView(category: .piano, title: "PIANO",
                            icons: ["grand": "piano-grand.webp", "upright": "piano-upright.webp",
                                    "ep": "piano-ep.webp"],
                            defaultIcon: "piano-grand.webp",
                            subcategories: PianoSubcategory.allCases.map { ($0.rawValue.uppercased(), $0.rawValue) })
            EnginePanelView(category: .organ, title: "ORGAN",
                            icons: ["b3": "organ-electric.webp", "farfisa": "organ-electric.webp",
                                    "pipe": "organ-pipe.webp"],
                            defaultIcon: "organ-electric.webp",
                            subcategories: OrganSubcategory.allCases.map { ($0.rawValue.uppercased(), $0.rawValue) })
            EnginePanelView(category: .synth, title: "SYNTH",
                            icons: [:], defaultIcon: "synth.png",
                            subcategories: SynthSubcategory.allCases.map { ($0.rawValue.uppercased(), $0.rawValue) })
        }
        .frame(minHeight: 320)
        .frame(maxHeight: .infinity)
        .layoutPriority(1)
    }

    /// FILES view toggle: the folder-scanned library instead of the engine panels.
    private var filesToggle: some View {
        Toggle(isOn: $showFiles) {
            Image(systemName: "folder")
        }
        .toggleStyle(PillToggleStyle(onColor: NordColor.red))
        .help(showFiles ? "Back to the engine panels" : "Browse the folder-scanned library")
    }

    /// Switch between the edit view (mixer/keyboard) and the perform page.
    private var performToggle: some View {
        Toggle(isOn: $performMode) {
            Image(systemName: "music.note.list")
        }
        .toggleStyle(PillToggleStyle(onColor: NordColor.red))
        .help(performMode ? "Back to the mixer" : "Perform page — big scene buttons for live use")
    }

    /// Perform page: a grid of large scene tiles, numbered setlist-style, plus a
    /// save tile for capturing the current setup. The recalled scene stays lit.
    private var performView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 14)], spacing: 14) {
                ForEach(Array(model.scenes.enumerated()), id: \.element.id) { index, scene in
                    sceneTile(scene, number: index + 1)
                }
                saveTile
            }
            .padding(4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sceneTile(_ scene: PlayerModel.Scene, number: Int) -> some View {
        let isActive = model.activeSceneID == scene.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(String(format: "%02d", number))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(isActive ? NordColor.red : NordColor.subtext)
                Spacer()
                if isActive {
                    Circle().fill(NordColor.red).frame(width: 8, height: 8)
                }
            }
            Spacer()
            Text(scene.name)
                .font(NordFont.font(17, weight: .bold))
                .foregroundStyle(NordColor.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text("\(scene.sounds.count) sound\(scene.sounds.count == 1 ? "" : "s")")
                .font(NordFont.font(10, weight: .medium))
                .foregroundStyle(NordColor.subtext)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
        .background(isActive ? NordColor.red.opacity(0.14) : NordColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(isActive ? NordColor.red : NordColor.red.opacity(0.25), lineWidth: isActive ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture { model.applyScene(scene) }
        .contextMenu {
            Button("Update with Current State") { model.updateScene(scene) }
            Button("Rename…") { renameScene(scene) }
            Button("Delete") { model.deleteScene(scene) }
        }
    }

    /// Dashed tile at the end of the grid: capture the current setup as a scene.
    private var saveTile: some View {
        VStack(spacing: 8) {
            Image(systemName: "plus")
                .font(NordFont.font(22, weight: .semibold))
            Text("Save current setup")
                .font(NordFont.font(11, weight: .medium))
        }
        .foregroundStyle(NordColor.subtext)
        .frame(maxWidth: .infinity, minHeight: 120)
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
            .foregroundStyle(NordColor.red.opacity(0.4)))
        .contentShape(Rectangle())
        .onTapGesture { saveScene() }
        .help("Save the current setup (sounds, mixer, FX) as a scene")
    }

    /// Show/hide the on-screen keyboard (hidden = view removed, nothing renders).
    private var keyboardToggle: some View {
        Toggle(isOn: Binding(
            get: { model.showKeyboard },
            set: { newValue in
                withAnimation(.easeInOut(duration: 0.15)) { model.showKeyboard = newValue }
            }
        )) {
            Image(systemName: "pianokeys")
        }
        .toggleStyle(PillToggleStyle(onColor: NordColor.red))
        .help(model.showKeyboard ? "Hide keyboard" : "Show keyboard")
    }

    /// Take recorder: captures the master bus (what you hear) to a WAV in
    /// ~/Music/nordpiano. Red with a running clock while a take is rolling.
    private var recordButton: some View {
        HStack(spacing: 6) {
            Button { model.toggleRecording() } label: {
                Image(systemName: model.isRecording ? "stop.circle.fill" : "record.circle")
            }
            .buttonStyle(.bordered)
            .tint(model.isRecording ? NordColor.red : .gray)
            .help(model.isRecording
                  ? "Stop recording and save the take"
                  : "Record what you play to a WAV in ~/Music/nordpiano")
        }
    }

    /// Track strip: REC clock + live waveform while recording; play/stop, name,
    /// reveal-in-Finder and dismiss once the take is done.
    private var takeBar: some View {
        HStack(spacing: 10) {
            if model.isRecording {
                Circle().fill(NordColor.red).frame(width: 8, height: 8)
                Text(String(format: "REC %d:%02d", model.recordingSeconds / 60, model.recordingSeconds % 60))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(NordColor.red)
            } else {
                Button { model.toggleTakePlayback() } label: {
                    Image(systemName: model.isPlayingTake ? "stop.fill" : "play.fill")
                        .font(NordFont.font(11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(NordColor.red)
                .help(model.isPlayingTake ? "Stop" : "Play the take")
                Text(model.lastTake?.lastPathComponent ?? "")
                    .font(NordFont.font(10, weight: .medium))
                    .foregroundStyle(NordColor.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Waveform(levels: model.recordLevels)
                .frame(height: 28)
                .frame(maxWidth: .infinity)
            if !model.isRecording {
                Button { model.revealTake() } label: {
                    Image(systemName: "magnifyingglass").font(NordFont.font(10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(NordColor.subtext)
                .help("Reveal in Finder")
                Button { model.dismissTake() } label: {
                    Image(systemName: "xmark").font(NordFont.font(10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(NordColor.subtext)
                .help("Dismiss (the file stays in ~/Music/nordpiano)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(NordColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Audio output + MIDI input pickers (audio interfaces, keyboard controllers).
    private var devicesMenu: some View {
        Menu {
            Picker("Audio Output", selection: $model.audioDeviceID) {
                ForEach(model.audioDevices) { dev in
                    Text(dev.name).tag(dev.id)
                }
            }
            .pickerStyle(.inline)
            Picker("MIDI Input", selection: $model.midiSourceID) {
                ForEach(model.midiInputs) { src in
                    Text(src.name).tag(src.id)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Refresh device list") { model.refreshDevices() }
        } label: {
            Image(systemName: "hifispeaker.and.appletv")
        }
        .menuStyle(.borderedButton)
        .tint(.gray)
        .fixedSize()
        .onAppear { model.refreshDevices() }
        .help("Audio output & MIDI input")
    }

    /// Nord-style FX row: FILTER / COMPRESSOR / REVERB — round knob(s) on top,
    /// pill toggle below, so each group stays narrow.
    private var fxStrip: some View {
        HStack(alignment: .center, spacing: 20) {
            // Velocity leads the strip: primary playing control, always live (no
            // toggle), bigger knob. The divider lives on the EFFECTS group's
            // leading edge as a background (out of layout flow, like CSS
            // height:100% of the container) so it spans the full strip height
            // — an in-flow maxHeight:.infinity line greedily stretched the strip.
            VStack(spacing: 4) {
                HStack(spacing: 14) {
                    VStack(spacing: 2) {
                        Text("\(Int(model.velocity))")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(NordColor.text)
                        Knob(value: Binding(
                            get: { (model.velocity - 1) / 126 },
                            set: { model.velocity = 1 + $0 * 126 }
                        ), label: "", diameter: 40)
                        Text("VELOCITY")
                            .font(NordFont.font(8, weight: .semibold))
                            .foregroundStyle(NordColor.red)
                    }
                    VStack(spacing: 2) {
                        Text("\(Int(model.masterVolume * 100))%")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(NordColor.text)
                        Knob(value: $model.masterVolume, label: "", diameter: 40)
                        Text("VOLUME")
                            .font(NordFont.font(8, weight: .semibold))
                            .foregroundStyle(NordColor.red)
                    }
                    VStack(spacing: 2) {
                        Text(model.boostDb <= 0.05 ? "0" : "+\(Int(model.boostDb.rounded()))")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(NordColor.text)
                        Knob(value: Binding(
                            get: { min(1, max(0, model.boostDb / 12)) },
                            set: { model.boostDb = $0 * 12 }
                        ), label: "", diameter: 40)
                        Text("BOOST")
                            .font(NordFont.font(8, weight: .semibold))
                            .foregroundStyle(NordColor.red)
                    }
                }
            }
            HStack(alignment: .top, spacing: 20) {
            fxGroup(label: "FILTER", isOn: $model.filterOn) {
                fxKnob(value: $model.filterNorm, caption: "CUT",
                       readout: model.filterNorm > 0.97 ? "∞" : "\(Int(200 * pow(90, model.filterNorm)))")
            }
            .effectDivider()
            fxGroup(label: "COMP", isOn: $model.compOn) {
                fxKnob(value: $model.compAmount, caption: "AMT",
                       readout: "\(Int(model.compAmount * 100))%")
            }
            .effectDivider()
            fxGroup(label: "DELAY", isOn: $model.delayOn) {
                HStack(spacing: 10) {
                    fxKnob(value: Binding(
                        get: { min(1, max(0, model.delayTime / 2)) },
                        set: { model.delayTime = $0 * 2 }
                    ), caption: "TIME", readout: String(format: "%.2f", model.delayTime) + "s")
                    fxKnob(value: $model.delayFeedback, caption: "FBT",
                           readout: "\(Int(model.delayFeedback * 100))%")
                    fxKnob(value: $model.delayMix, caption: "MIX",
                           readout: "\(Int(model.delayMix * 100))%")
                }
            }
            .effectDivider()
            fxGroup(label: "REVERB", isOn: $model.reverbOn) {
                HStack(spacing: 10) {
                    fxKnob(value: $model.reverbMix, caption: "MIX",
                           readout: "\(Int(model.reverbMix * 100))%")
                    fxKnob(value: $model.reverbSize, caption: "SIZE",
                           readout: String(format: "%.1f", 0.3 + model.reverbSize * 6.7) + "s")
                }
            }
            }
            .padding(.leading, 20)
            .background(alignment: .leading) {
                Rectangle()
                    .fill(NordColor.red)
                    .frame(width: 1)
                    .padding(.vertical, 8)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(NordColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// One round knob with its live value readout above the caption.
    private func fxKnob(value: Binding<Double>, caption: String, readout: String) -> some View {
        VStack(spacing: 2) {
            Text(readout)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(NordColor.subtext)
                .lineLimit(1)
                .fixedSize()
            Knob(value: value, label: caption, diameter: 38)
        }
    }

    /// Effect group: knob(s) beside a vertical pill toggle. Fixed height so
    /// every group (and therefore every divider pinned to a group) matches —
    /// the divider height must not depend on wrapped-content luck.
    private func fxGroup<Content: View>(label: String, isOn: Binding<Bool>, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 12) {
            content()
                .disabled(!isOn.wrappedValue)
                .opacity(isOn.wrappedValue ? 1 : 0.4)
            Toggle(label, isOn: isOn)
                .toggleStyle(VerticalPillToggleStyle())
        }
        .frame(height: 76)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Circle().fill(model.player == nil ? Color.gray : Color.green).frame(width: 7, height: 7)
            Text(model.status).font(.caption).foregroundStyle(NordColor.subtext)
            Spacer()
            // Current devices, so the selection is visible without opening the menu.
            HStack(spacing: 12) {
                Label(model.audioDevices.first(where: { $0.id == model.audioDeviceID })?.name ?? "System Default",
                      systemImage: "hifispeaker")
                Label(model.midiInputs.first(where: { $0.id == model.midiSourceID })?.name ?? "All Sources",
                      systemImage: "pianokeys")
            }
            .font(NordFont.font(9))
            .foregroundStyle(NordColor.subtext)
            .lineLimit(1)
            Button("Quit") {
                if model.isRecording { model.toggleRecording() } // finalize the WAV
                NSApplication.shared.terminate(nil)
            }
                .buttonStyle(.bordered).tint(.gray)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(NordColor.card)
    }
}

/// Bar-graph waveform from per-buffer peak levels; newest bars pin to the
/// right edge so a recording grows leftward from the live edge.
private struct Waveform: View {
    let levels: [Float]

    var body: some View {
        GeometryReader { geo in
            let capacity = max(1, Int(geo.size.width / 3))
            let bars = levels.suffix(capacity)
            HStack(alignment: .center, spacing: 1) {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, level in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(NordColor.red)
                        .frame(width: 2, height: max(2, CGFloat(min(1, level)) * geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
    }
}

extension View {
    /// Vertical separator between effect groups: a background pinned to the
    /// view's trailing edge (out of layout flow, like CSS height:100% of the
    /// container), so it spans the group's height without affecting layout.
    func effectDivider() -> some View {
        padding(.trailing, 10)
            .background(alignment: .trailing) {
                Rectangle()
                    .fill(NordColor.red)
                    .frame(width: 1)
                    .padding(.vertical, 8)
            }
    }
}
