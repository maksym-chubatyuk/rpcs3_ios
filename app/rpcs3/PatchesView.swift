import Observation
import SwiftUI
import UniformTypeIdentifiers

/// One patch for one game, as the core lists it (rpcs3_ios_patches in core/rpcs3_ios.h).
struct GamePatch: Decodable, Identifiable, Hashable {
    struct Option: Decodable, Hashable {
        let label: String
        let value: Double
    }

    /// A value the patch lets the player adjust, a list of choices or a range.
    struct ConfigValue: Decodable, Hashable {
        let name: String
        let value: Double
        let min: Double
        let max: Double
        let isList: Bool
        let isInteger: Bool
        let options: [Option]
    }

    // The keys of the entry: which patch, for which title, serial and app version ("All" is a wildcard)
    let hash: String
    let description: String
    let title: String
    let serial: String
    let appVersion: String

    let enabled: Bool
    let author: String
    let notes: String
    let version: String
    let group: String
    let file: String
    let configValues: [ConfigValue]

    var id: String { [hash, description, title, serial, appVersion].joined(separator: "\n") }
    /// Made for any game (often SPU code found by its content) rather than this game in particular
    var isForAllGames: Bool { serial == "All" || title == "All" }
}

/// The patches of one game, and the patch files they come from.
@Observable
@MainActor
final class PatchStore {
    let game: Game
    /// The version the game runs as: an installed update's, otherwise the disc's.
    let appVersion: String

    private(set) var patches: [GamePatch] = []
    private(set) var isDownloading = false
    var message: String?

    init(game: Game) {
        self.game = game
        appVersion = Emulator.shared.appVersion(of: game)
        reload()
    }

    func reload() {
        guard let id = game.titleID, let pointer = core_patches(id, appVersion) else { return }
        defer { core_free(pointer) }
        let list = (try? JSONDecoder().decode([GamePatch].self, from: Data(String(cString: pointer).utf8))) ?? []
        patches = list.sorted { ($0.group, $0.description) < ($1.group, $1.description) }
    }

    func setEnabled(_ patch: GamePatch, _ enabled: Bool) {
        if core_patch_enable(patch.hash, patch.description, patch.title, patch.serial, patch.appVersion, enabled ? 1 : 0) != 0 {
            message = "The patch could not be changed. See RPCS3.log."
        }
        reload()
    }

    func setValue(_ patch: GamePatch, _ value: GamePatch.ConfigValue, to number: Double) {
        if core_patch_set_value(patch.hash, patch.description, patch.title, patch.serial, patch.appVersion, value.name, number) != 0 {
            message = "The value could not be changed. See RPCS3.log."
        }
        reload()
    }

    /// The official patch file from rpcs3.net, as RPCS3's desktop patch manager downloads it.
    func downloadLatest() async {
        guard let pointer = core_patch_download_url() else { return }
        let address = String(cString: pointer)
        core_free(pointer)
        guard let url = URL(string: address) else { return }

        isDownloading = true
        defer { isDownloading = false }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                message = "rpcs3.net sent an answer the app does not understand."
                return
            }
            switch reply["return_code"] as? Int ?? -255 {
            case 1:
                message = "The patches are already up to date."
            case -1:
                message = "rpcs3.net has no patches for this version of RPCS3."
            case -2:
                message = "rpcs3.net is under maintenance. Try again later."
            case 0:
                guard reply["version"] as? String == String(cString: core_patch_engine_version()),
                      let sha256 = reply["sha256"] as? String,
                      let content = reply["patch"] as? String, !content.isEmpty else {
                    message = "rpcs3.net sent patches for another version of RPCS3."
                    return
                }
                var text = [CChar](repeating: 0, count: 2048)
                if core_patch_install(content, sha256, &text, text.count) == 0 {
                    message = "Downloaded the latest patches."
                } else {
                    message = String(cString: text)
                }
            default:
                message = "rpcs3.net could not send the patches."
            }
        } catch {
            message = "The patches could not be downloaded: \(error.localizedDescription)"
        }
        reload()
    }

    func importFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var text = [CChar](repeating: 0, count: 2048)
        _ = core_patch_import(url.path, &text, text.count)
        message = String(cString: text)
        reload()
    }
}

/// A game's patches. The patch files are read when the page opens (the official one is large).
struct PatchesView: View {
    let game: Game
    @State private var store: PatchStore?

    var body: some View {
        Group {
            if let store {
                PatchList(store: store)
            } else {
                ProgressView("Reading patches…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Patches")
        .task {
            if store == nil { store = PatchStore(game: game) }
        }
    }
}

/// Switches for a game's patches, their adjustable values, and getting more patches.
private struct PatchList: View {
    @State var store: PatchStore
    @State private var importing = false
    @State private var notesFor: GamePatch?

    var body: some View {
        List {
            if store.patches.isEmpty {
                ContentUnavailableView {
                    Label("No Patches", systemImage: "bandage")
                } description: {
                    Text("No patches for \(store.game.title) (version \(GameDetailView.version(store.appVersion))). Download the latest ones from rpcs3.net, or import a patch file.")
                } actions: {
                    Button("Download Latest Patches") { Task { await store.downloadLatest() } }
                        .disabled(store.isDownloading)
                }
            }
            let own = store.patches.filter { !$0.isForAllGames }
            let shared = store.patches.filter(\.isForAllGames)
            if own.isEmpty && !store.patches.isEmpty {
                Section {
                    Text("No patches are made for \(store.game.title) itself.")
                        .foregroundStyle(.secondary)
                }
            }
            let groups = Dictionary(grouping: own, by: \.group)
            ForEach(groups.keys.sorted(), id: \.self) { group in
                Section {
                    ForEach(groups[group] ?? []) { patch in
                        PatchRow(store: store, patch: patch) { notesFor = patch }
                    }
                } header: {
                    if !group.isEmpty { Text(group) }
                } footer: {
                    if !group.isEmpty { Text("Only one patch of this group can be on.") }
                }
            }
            if !shared.isEmpty {
                Section {
                    DisclosureGroup("Patches for All Games (\(shared.count))") {
                        ForEach(shared) { patch in
                            PatchRow(store: store, patch: patch) { notesFor = patch }
                        }
                    }
                } footer: {
                    Text("These apply to any game whose code matches them; most are made for other games.")
                }
            }
            Section {
            } footer: {
                Text("Patches change the game's code. Changes take effect the next time the game starts.")
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Download Latest Patches", systemImage: "arrow.down.circle") { Task { await store.downloadLatest() } }
                        .disabled(store.isDownloading)
                    Button("Import Patch File…", systemImage: "square.and.arrow.down") { importing = true }
                } label: {
                    if store.isDownloading {
                        ProgressView()
                    } else {
                        Label("Get Patches", systemImage: "arrow.down.circle")
                    }
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "yml") ?? .data, .yaml, .data]) { result in
            if case .success(let url) = result { store.importFile(url) }
        }
        .alert("Patches", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.message ?? "")
        }
        .sheet(item: $notesFor) { patch in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !patch.notes.isEmpty { Text(patch.notes) }
                        LabeledContent("Author", value: patch.author.isEmpty ? "Unknown" : patch.author)
                        LabeledContent("Patch version", value: patch.version.isEmpty ? "–" : patch.version)
                        LabeledContent("For", value: "\(patch.serial == "All" ? "every serial" : patch.serial), \(patch.appVersion == "All" ? "every version" : "version \(patch.appVersion)")")
                        LabeledContent("From", value: patch.file)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                .navigationTitle(patch.description)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { notesFor = nil }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

private struct PatchRow: View {
    let store: PatchStore
    let patch: GamePatch
    let showNotes: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { patch.enabled }, set: { store.setEnabled(patch, $0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(patch.description)
                        Button(action: showNotes) {
                            Image(systemName: "info.circle").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("About \(patch.description)")
                    }
                    Text([patch.author.isEmpty ? nil : patch.author, patch.version.isEmpty ? nil : "v\(patch.version)"]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if patch.enabled {
                ForEach(patch.configValues, id: \.name) { value in
                    PatchValueRow(value: value) { store.setValue(patch, value, to: $0) }
                }
            }
        }
    }
}

/// An adjustable patch value: a picker for a list, a stepper or slider for a range.
private struct PatchValueRow: View {
    let value: GamePatch.ConfigValue
    let commit: (Double) -> Void

    @State private var draft: Double = 0

    var body: some View {
        if value.isList {
            Picker(value.name, selection: Binding(get: { value.value }, set: commit)) {
                ForEach(value.options, id: \.self) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .font(.subheadline)
        } else if value.isInteger, value.max - value.min <= 100 {
            Stepper(value: Binding(get: { value.value }, set: commit), in: value.min...max(value.min, value.max), step: 1) {
                LabeledContent(value.name, value: "\(Int(value.value))")
            }
            .font(.subheadline)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                LabeledContent(value.name, value: value.isInteger ? "\(Int(draft))" : draft.formatted(.number.precision(.fractionLength(0...3))))
                Slider(value: $draft, in: value.min...max(value.min, value.max), step: value.isInteger ? 1 : (value.max - value.min) / 1000) { editing in
                    if !editing { commit(draft) }
                }
            }
            .font(.subheadline)
            .onAppear { draft = value.value }
            .onChange(of: value.value) { _, new in draft = new }
        }
    }
}
