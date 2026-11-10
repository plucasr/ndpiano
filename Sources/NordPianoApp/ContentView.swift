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
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(NordColor.text)
                Text("LOCAL AUDITION · NOT AFFILIATED WITH NORD / CLAVIA")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(NordColor.subtext)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(model.pianoTitle).font(.headline).foregroundStyle(NordColor.text)
                if !model.version.isEmpty {
                    Text("piano library v\(model.version)")
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
                                .font(.system(size: 10, weight: .bold))
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
                Text("VELOCITY")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NordColor.subtext)
                Slider(value: $model.velocity, in: 1...127)
                    .tint(NordColor.red)
                    .frame(maxWidth: 260)
                Text("\(Int(model.velocity))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(NordColor.text)
                    .frame(width: 26)
                Spacer()
                Button("Folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.message = "Add a folder of .npno pianos to the library"
                    if panel.runModal() == .OK, let url = panel.url { model.addFolder(url) }
                }
                .buttonStyle(.bordered)
                .tint(.gray)
                keyboardToggle
                devicesMenu
                Button("Open…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [UTType(filenameExtension: "npno")].compactMap { $0 }
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
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { model.showKeyboard.toggle() }
        } label: {
            Image(systemName: "pianokeys")
        }
        .buttonStyle(.bordered)
        .tint(model.showKeyboard ? NordColor.red : .gray)
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
        .onAppear { model.refreshDevices() }
        .help("Audio output & MIDI input")
    }

    /// Nord-style FX row: FILTER / COMPRESSOR / REVERB.
    private var fxStrip: some View {
        HStack(spacing: 24) {
            fxGroup(label: "FILTER", isOn: $model.filterOn) {
                HStack(spacing: 6) {
                    Text("CUT").font(.system(size: 9)).foregroundStyle(NordColor.subtext)
                    Slider(value: $model.filterNorm).tint(NordColor.red).frame(maxWidth: 110)
                    Text(model.filterNorm > 0.97 ? "∞" : "\(Int(200 * pow(90, model.filterNorm)))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(NordColor.subtext).frame(width: 42, alignment: .trailing)
                }
            }
            fxGroup(label: "COMPRESSOR", isOn: $model.compOn) {
                HStack(spacing: 6) {
                    Text("AMT").font(.system(size: 9)).foregroundStyle(NordColor.subtext)
                    Slider(value: $model.compAmount).tint(NordColor.red).frame(maxWidth: 110)
                    Text("\(Int(model.compAmount * 100))%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(NordColor.subtext).frame(width: 38, alignment: .trailing)
                }
            }
            fxGroup(label: "REVERB", isOn: $model.reverbOn) {
                HStack(spacing: 10) {
                    HStack(spacing: 4) {
                        Text("MIX").font(.system(size: 9)).foregroundStyle(NordColor.subtext)
                        Slider(value: $model.reverbMix).tint(NordColor.red).frame(maxWidth: 80)
                        Text("\(Int(model.reverbMix * 100))%")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(NordColor.subtext).frame(width: 34, alignment: .trailing)
                    }
                    HStack(spacing: 4) {
                        Text("SIZE").font(.system(size: 9)).foregroundStyle(NordColor.subtext)
                        Slider(value: $model.reverbSize).tint(NordColor.red).frame(maxWidth: 80)
                        Text("\(String(format: "%.1f", 0.3 + model.reverbSize * 6.7))s")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(NordColor.subtext).frame(width: 34, alignment: .trailing)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(NordColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func fxGroup<Content: View>(label: String, isOn: Binding<Bool>, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Toggle(label, isOn: isOn)
                .toggleStyle(.checkbox)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isOn.wrappedValue ? NordColor.red : NordColor.subtext)
            content()
                .disabled(!isOn.wrappedValue)
                .opacity(isOn.wrappedValue ? 1 : 0.4)
        }
    }

    private var footer: some View {
        HStack {
            Circle().fill(model.player == nil ? Color.gray : Color.green).frame(width: 7, height: 7)
            Text(model.status).font(.caption).foregroundStyle(NordColor.subtext)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.bordered).tint(.gray)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(NordColor.card)
    }
}
