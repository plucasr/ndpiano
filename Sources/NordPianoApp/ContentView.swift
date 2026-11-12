import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: PlayerModel
    @State private var isDropTarget = false

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

    /// Map a section title ("Root / subfolder") back to its library root URL.
    private func folderURL(for title: String) -> URL {
        let first = title.components(separatedBy: " / ").first ?? title
        return model.roots.first { $0.lastPathComponent == first } ?? URL(fileURLWithPath: "")
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
            if isSel && model.selected.count > 1 {
                Slider(value: Binding(
                    get: { Double(model.gains[entry.url] ?? 1) },
                    set: { model.setGain(Float($0), for: entry) }
                ), in: 0...1.5)
                .tint(NordColor.red)
                .frame(width: 70)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.select(entry) }
        .contextMenu {
            Button(model.isFavorite(entry) ? "Remove from Shortcuts" : "Send to Shortcuts") {
                model.toggleFavorite(entry)
            }
        }
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

    private var main: some View {
        HStack(spacing: 0) {
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
                                    .listRowBackground(model.selected.contains(entry)
                                                       ? NordColor.red.opacity(0.18) : NordColor.card)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 240)
                Divider().overlay(NordColor.red.opacity(0.25))
            }
            VStack(spacing: 12) {
            HStack(spacing: 16) {
                Spacer()
                Button("Folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.message = "Add a folder of .npno pianos and .nsmp3/.nsmp4 samples to the library"
                    if panel.runModal() == .OK, let url = panel.url { model.addFolder(url) }
                }
                .buttonStyle(.bordered)
                .tint(.gray)
                keyboardToggle
                devicesMenu
                Button("Open…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = ["npno", "nsmp3", "nsmp4"].compactMap { UTType(filenameExtension: $0) }
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url { model.load(url: url) }
                }
                .buttonStyle(.borderedProminent)
                .tint(NordColor.red)
            }
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
            .padding(16)
        }
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
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.bordered).tint(.gray)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(NordColor.card)
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
