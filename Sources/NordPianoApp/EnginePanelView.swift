import SwiftUI
import NordPianoCore

/// Nord-Stage-style engine panel: header (count · size), the loaded-slot card,
/// subcategory pills, and the catalog list for one engine.
/// Click a row to highlight it (the "→" assign target); double-click to layer
/// it right away; right-click for assign/recategorize/info.
struct EnginePanelView: View {
    @EnvironmentObject private var model: PlayerModel

    let category: SoundCategory
    /// Display title ("PIANO") and subcategory pills.
    let title: String
    let subcategories: [(label: String, raw: String)]

    @State private var filter: String? // nil = ALL
    /// Compact mode (header "+"): narrow panel, no version column. Default —
    /// sample details live in the row's right-click Info… instead.
    @State private var compact = true
    /// Per-panel name search.
    @State private var searchText = ""

    private var allEntries: [CatalogEntry] { model.catalog.entries(in: category) }

    private var entries: [CatalogEntry] {
        var result = allEntries
        if let filter { result = result.filter { $0.subcategory == filter } }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            result = result.filter { $0.name.range(of: query, options: .caseInsensitive) != nil }
        }
        return result
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
            pills
            searchField
            list
        }
        .background(NordColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(width: compact ? 190 : 300)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle().fill(NordColor.red).frame(width: 7, height: 7)
            Text(title)
                .font(NordFont.font(13, weight: .bold))
                .foregroundStyle(NordColor.text)
            Spacer()
            if !compact {
                Text("\(allEntries.count) SAMPLES · \(totalSize)")
                    .font(NordFont.font(8, weight: .medium))
                    .foregroundStyle(NordColor.subtext)
            }
            Button { withAnimation(.easeInOut(duration: 0.15)) { compact.toggle() } } label: {
                Image(systemName: compact ? "plus" : "minus")
                    .font(NordFont.font(11, weight: .bold))
                    .foregroundStyle(NordColor.text)
                    .frame(width: 28, height: 22)
                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(compact ? "Expand panel (show versions, wider)" : "Compact panel (hide versions, narrower)")
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

    private var pills: some View {
        WrapLayout(spacing: 6) {
            pill("ALL", active: filter == nil) { filter = nil }
            ForEach(subcategories, id: \.raw) { sub in
                pill(sub.label, active: filter == sub.raw) { filter = sub.raw }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// Name filter: matches anywhere in the sound name, case-insensitive.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(NordFont.font(9))
                .foregroundStyle(NordColor.subtext)
            TextField("Search \(title.lowercased())…", text: $searchText)
                .textFieldStyle(.plain)
                .font(NordFont.font(10))
                .foregroundStyle(NordColor.text)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(NordFont.font(9))
                        .foregroundStyle(NordColor.subtext)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(NordColor.background)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    /// Small badge marking open-format (non-Nord) sounds, e.g. "SFZ".
    private func formatBadge(for entry: CatalogEntry) -> some View {
        let ext = URL(fileURLWithPath: entry.path).pathExtension.lowercased()
        let isNord = ["npno", "nsmp3", "nsmp4"].contains(ext)
        return Group {
            if !isNord {
                Text(ext.uppercased())
                    .font(NordFont.font(7, weight: .bold))
                    .foregroundStyle(NordColor.red)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(NordColor.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
            }
        }
    }

    /// Sample details on demand (right-click → Info…), replacing the always-on
    /// display area: name, category/type, version, format, size and file path.
    private func showInfo(for entry: CatalogEntry) {
        let url = URL(fileURLWithPath: entry.path)
        let size = ByteCountFormatter.string(fromByteCount: entry.sizeBytes, countStyle: .file)
        let alert = NSAlert()
        alert.messageText = entry.name
        alert.informativeText = """
            Category: \(entry.category.rawValue.capitalized)
            Type: \(entry.subcategory?.capitalized ?? "—")
            Version: v\(entry.version)
            Format: \(url.pathExtension.uppercased())
            Size: \(size)
            File: \(entry.path)
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
            formatBadge(for: entry)
            Spacer()
            if !compact {
                Text("\(entry.subcategory?.uppercased() ?? "—")  v\(entry.version)")
                    .font(NordFont.font(8, weight: .medium))
                    .foregroundStyle(NordColor.subtext.opacity(0.8))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isHighlighted ? NordColor.red.opacity(0.10) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.select(pianoEntry) }
        .onTapGesture { model.highlighted = pianoEntry }
        .contextMenu {
            Button("Info…") { showInfo(for: entry) }
            Divider()
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

/// Horizontal flow layout: lays subviews left-to-right, wrapping to a new row
/// when the next one would overflow the proposed width (the subcategory pills).
private struct WrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var height: CGFloat = 0
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                height += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: height + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Left column: numbered scene slots + the master fader, like the panel mock.
struct ScenesColumnView: View {
    @EnvironmentObject private var model: PlayerModel
    var onSave: () -> Void
    var onRename: (PlayerModel.Scene) -> Void
    /// Wide mode (header ↔ button): more room for scene names, 3 columns.
    @State private var wide = false

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
                Button { withAnimation(.easeInOut(duration: 0.15)) { wide.toggle() } } label: {
                    Image(systemName: "arrow.left.and.right")
                        .font(NordFont.font(11, weight: .bold))
                        .foregroundStyle(NordColor.text)
                        .frame(width: 28, height: 22)
                        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(wide ? "Narrow the scenes column" : "Widen the scenes column")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: wide ? 3 : 2), spacing: 8) {
                    ForEach(Array(model.userScenes.enumerated()), id: \.element.id) { index, scene in
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
        .frame(width: wide ? 300 : 190)
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
