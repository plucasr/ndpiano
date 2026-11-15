import SwiftUI
import NordPianoCore

/// Nord-Stage-style engine panel: header (count · size), the loaded-slot card,
/// a display area, subcategory pills, and the catalog list for one engine.
/// Click a row to highlight it (the "→" assign target); double-click to layer
/// it right away; right-click for assign/recategorize.
struct EnginePanelView: View {
    @EnvironmentObject private var model: PlayerModel

    let category: SoundCategory
    /// Display title ("PIANO"), SF Symbol for the display area, subcategory pills.
    let title: String
    let icon: String
    let subcategories: [(label: String, raw: String)]

    @State private var filter: String? // nil = ALL

    private var allEntries: [CatalogEntry] { model.catalog.entries(in: category) }

    private var entries: [CatalogEntry] {
        guard let filter else { return allEntries }
        return allEntries.filter { $0.subcategory == filter }
    }

    private var loaded: PlayerModel.ChannelState? { model.loadedChannel(in: category) }

    private var totalSize: String {
        let bytes = allEntries.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            .replacingOccurrences(of: " ", with: " ")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            loadedCard
            displayArea
            pills
            list
        }
        .background(NordColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle().fill(NordColor.red).frame(width: 7, height: 7)
            Text(title)
                .font(NordFont.font(13, weight: .bold))
                .foregroundStyle(NordColor.text)
            Spacer()
            Text("\(allEntries.count) SAMPLES · \(totalSize)")
                .font(NordFont.font(8, weight: .medium))
                .foregroundStyle(NordColor.subtext)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Which sound of this engine is in a channel right now (empty state like
    /// the hardware's "NO SAMPLE LOADED"). Tap to select that channel.
    private var loadedCard: some View {
        Button {
            if let loaded { model.selectedChannelID = loaded.id }
        } label: {
            HStack {
                if let loaded {
                    Circle().fill(NordColor.red).frame(width: 6, height: 6)
                    Text(loaded.entry.name)
                        .font(NordFont.font(12, weight: .semibold))
                        .foregroundStyle(NordColor.text)
                        .lineLimit(1)
                    Spacer()
                    Text("\(model.catalogEntry(for: loaded.entry.url)?.subcategory?.uppercased() ?? "—") · v\(loaded.entry.version)")
                        .font(NordFont.font(8, weight: .medium))
                        .foregroundStyle(NordColor.subtext)
                } else {
                    Text("—")
                        .font(NordFont.font(12, weight: .semibold))
                        .foregroundStyle(NordColor.subtext)
                    Spacer()
                    Text("NO SAMPLE LOADED")
                        .font(NordFont.font(8, weight: .medium))
                        .foregroundStyle(NordColor.subtext)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(NordColor.background)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
    }

    private var displayArea: some View {
        Image(systemName: icon)
            .font(.system(size: 44, weight: .thin))
            .foregroundStyle(NordColor.subtext.opacity(0.8))
            .frame(maxWidth: .infinity, minHeight: 90)
            .background(NordColor.background)
            .padding(.horizontal, 10)
            .padding(.top, 6)
    }

    private var pills: some View {
        HStack(spacing: 6) {
            pill("ALL", active: filter == nil) { filter = nil }
            ForEach(subcategories, id: \.raw) { sub in
                pill(sub.label, active: filter == sub.raw) { filter = sub.raw }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func pill(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(NordFont.font(8, weight: .semibold))
                .foregroundStyle(active ? Color.black : NordColor.subtext)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(active ? NordColor.red : NordColor.background)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(entries) { entry in
                    row(entry)
                    if entry.id != entries.last?.id {
                        Divider().overlay(Color.white.opacity(0.05)).padding(.leading, 24)
                    }
                }
            }
            .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ entry: CatalogEntry) -> some View {
        let pianoEntry = model.pianoEntry(for: entry)
        let isLoaded = model.selected.contains(pianoEntry)
        let isHighlighted = model.highlighted == pianoEntry
        return HStack(spacing: 8) {
            Circle()
                .fill(isLoaded ? NordColor.red : NordColor.subtext.opacity(0.5))
                .frame(width: 5, height: 5)
            Text(entry.name)
                .font(NordFont.font(11, weight: isLoaded ? .semibold : .regular))
                .foregroundStyle(isHighlighted || isLoaded ? NordColor.text : NordColor.subtext)
                .lineLimit(1)
            Spacer()
            Text("\(entry.subcategory?.uppercased() ?? "—")  v\(entry.version)")
                .font(NordFont.font(8, weight: .medium))
                .foregroundStyle(NordColor.subtext.opacity(0.8))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isHighlighted ? NordColor.red.opacity(0.10) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.select(pianoEntry) }
        .onTapGesture { model.highlighted = pianoEntry }
        .contextMenu {
            Button("Assign to Selected Channel") { model.assignToChannel(pianoEntry) }
            Divider()
            Menu("Move to…") {
                ForEach(SoundCategory.allCases, id: \.self) { cat in
                    if cat != entry.category {
                        Button(cat.rawValue.capitalized) { model.recategorize(entry, to: cat) }
                    }
                }
            }
            if !subcategories.isEmpty {
                Menu("\(title.capitalized) type…") {
                    ForEach(subcategories, id: \.raw) { sub in
                        if sub.raw != entry.subcategory {
                            Button(sub.label.capitalized) {
                                model.recategorize(entry, to: entry.category, subcategory: sub.raw)
                            }
                        }
                    }
                }
            }
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
            }
        }
    }
}

/// Left column: numbered scene slots + the master fader, like the panel mock.
struct ScenesColumnView: View {
    @EnvironmentObject private var model: PlayerModel
    var onSave: () -> Void
    var onRename: (PlayerModel.Scene) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SCENES")
                    .font(NordFont.font(10, weight: .bold))
                    .foregroundStyle(NordColor.subtext)
                Spacer()
                Button(action: onSave) {
                    Image(systemName: "plus").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(NordColor.red)
                .help("Save the current setup (channels, mixer, FX) as a scene")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(Array(model.scenes.enumerated()), id: \.element.id) { index, scene in
                        sceneSlot(scene, number: index + 1)
                    }
                }
                .padding(.horizontal, 10)
            }
            .frame(maxHeight: .infinity)

            // MASTER fader, like the mock's bottom-left strip.
            VStack(spacing: 4) {
                Fader(value: $model.masterVolume, range: 0...1)
                    .frame(height: 90)
                Text("MASTER")
                    .font(NordFont.font(7, weight: .medium))
                    .foregroundStyle(NordColor.subtext)
            }
            .padding(.vertical, 8)
        }
        .frame(width: 190)
        .background(NordColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func sceneSlot(_ scene: PlayerModel.Scene, number: Int) -> some View {
        let isActive = model.activeSceneID == scene.id
        return VStack(alignment: .leading, spacing: 2) {
            Text("SCENE \(number)")
                .font(NordFont.font(7, weight: .bold))
                .foregroundStyle(isActive ? NordColor.red : NordColor.subtext)
            Text(scene.name)
                .font(NordFont.font(9, weight: .semibold))
                .foregroundStyle(NordColor.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
        .padding(6)
        .background(isActive ? NordColor.red.opacity(0.14) : NordColor.background)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5)
            .stroke(isActive ? NordColor.red : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { model.applyScene(scene) }
        .contextMenu {
            Button("Update with Current State") { model.updateScene(scene) }
            Button("Rename…") { onRename(scene) }
            Button("Delete") { model.deleteScene(scene) }
        }
    }
}
