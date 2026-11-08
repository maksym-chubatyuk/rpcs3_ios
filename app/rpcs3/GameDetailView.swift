import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A game's icon (ICON0.PNG), or a symbol for games without one (ISOs).
struct GameIcon: View {
    let game: Game
    var width: CGFloat = 64

    var body: some View {
        Group {
            if let url = game.iconURL, let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: game.isISO ? "opticaldisc" : "folder")
                    .font(.system(size: width * 0.3))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
        // PS3 icons are 320x176
        .frame(width: width, height: width * 176 / 320)
        .clipShape(RoundedRectangle(cornerRadius: width / 16))
        .accessibilityHidden(true)
    }
}

/// Everything desktop RPCS3's game menu offers for one game that makes sense on a phone: the ways
/// to start it, its settings, what it stores, and its details.
struct GameDetailView: View {
    let game: Game
    let play: (BootRequest) -> Void

    @State private var emulator = Emulator.shared
    @State private var data: GameData?
    @State private var showsSettings = false
    @State private var choosingConfig = false
    @State private var confirm: Confirmation?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// A destructive action waiting for confirmation.
    struct Confirmation: Identifiable {
        let title: String
        let message: String
        let button: String
        let action: () -> Void
        var id: String { title }
    }

    var body: some View {
        NavigationStack {
            List {
                header
                playSection
                settingsSection
                storageSection
                infoSection
                librarySection
            }
            .navigationTitle(game.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear(perform: reload)
            .refreshable { reload() }
            .sheet(isPresented: $showsSettings, onDismiss: reload) {
                if let id = game.titleID {
                    SettingsView(store: SettingsStore(gameID: id, gameTitle: game.title))
                }
            }
            .fileImporter(isPresented: $choosingConfig, allowedContentTypes: [UTType(filenameExtension: "yml") ?? .data, .yaml, .data]) { result in
                if case .success(let url) = result {
                    start(BootRequest(game: game, mode: .configFile, configFile: url))
                }
            }
            .confirmationDialog(confirm?.title ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible, presenting: confirm) { item in
                Button(item.button, role: .destructive) { item.action(); reload() }
            } message: { item in
                Text(item.message)
            }
        }
    }

    private func reload() {
        data = emulator.gameData(game)
    }

    private func start(_ request: BootRequest) {
        dismiss()
        play(request)
    }

    // MARK: Sections

    private var header: some View {
        Section {
            HStack(spacing: 14) {
                GameIcon(game: game, width: 110)
                VStack(alignment: .leading, spacing: 4) {
                    Text(game.title)
                        .font(.headline)
                    Text([game.titleID, game.info["APP_VER"].map { "v\(Self.version($0))" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var playSection: some View {
        Section {
            Button("Play", systemImage: "play.fill") { start(BootRequest(game: game)) }
                .disabled(emulator.firmwareVersion.isEmpty)
            if let last = data?.lastSavestate, !last.isEmpty {
                Button("Resume Latest Savestate", systemImage: "clock.arrow.circlepath") {
                    start(BootRequest(game: game, savestate: last))
                }
            }
            if let states = data?.savestates, !states.isEmpty {
                NavigationLink {
                    SavestateList(game: game, savestates: states, play: start, onChange: reload)
                } label: {
                    Label("Savestates", systemImage: "square.stack")
                        .badge(states.count)
                }
            }
            Menu {
                if data?.customConfig == true {
                    Button("Play with Global Settings") { start(BootRequest(game: game, mode: .global)) }
                }
                Button("Play with Default Settings") { start(BootRequest(game: game, mode: .defaults)) }
                Button("Play with a Settings File…") { choosingConfig = true }
            } label: {
                Label("Play With Other Settings", systemImage: "play.circle")
            }
        } footer: {
            if emulator.firmwareVersion.isEmpty {
                Text("Install the PS3 firmware first.")
            }
        }
    }

    private var settingsSection: some View {
        Section {
            Button {
                showsSettings = true
            } label: {
                LabeledContent {
                    Text(data?.customConfig == true ? "Own settings" : "Global settings")
                } label: {
                    Label("Game Settings", systemImage: "gearshape")
                }
            }
            .disabled(game.titleID == nil)
            NavigationLink {
                PatchesView(game: game)
            } label: {
                Label("Patches", systemImage: "bandage")
            }
            .disabled(game.titleID == nil)
            NavigationLink {
                ControlsView(gameID: game.titleID, gameTitle: game.title)
                    .onDisappear(perform: reload)
            } label: {
                LabeledContent {
                    Text(data?.customInput == true ? "Own controls" : "Global controls")
                } label: {
                    Label("Controls", systemImage: "gamecontroller")
                }
            }
            .disabled(game.titleID == nil)
            if data?.customConfig == true {
                Button("Use Global Settings Only", systemImage: "arrow.uturn.backward") {
                    confirm = Confirmation(title: "Use the global settings only?",
                                           message: "This removes every setting changed for \(game.title).",
                                           button: "Remove Game Settings") { emulator.removeData("config", of: game) }
                }
            }
            if data?.customInput == true {
                Button("Use Global Controls Only", systemImage: "gamecontroller") {
                    confirm = Confirmation(title: "Use the global controls only?",
                                           message: "This removes the controller configuration made for \(game.title).",
                                           button: "Remove Game Controls") { emulator.removeData("input", of: game) }
                }
            }
        } header: {
            Text("Settings")
        } footer: {
            Text("A game follows the global settings, except for what is changed for it here.")
        }
    }

    @ViewBuilder private var storageSection: some View {
        if let data {
            Section {
                storageRow("Shader Cache", size: data.shaderCache, item: "shaders",
                           note: "Built again while playing; the game may stutter at first.")
                storageRow("PPU Cache", size: data.ppuCache, item: "ppu",
                           note: "Compiled again at the next start, which then takes longer.")
                storageRow("SPU Cache", size: data.spuCache, item: "spu",
                           note: "Compiled again while playing.")
                storageRow("HDD1 Cache", size: data.hdd1Cache, item: "hdd1",
                           note: "The game's cache on the console's internal drive; it rebuilds it.")
                if data.caches > 0 {
                    Button("Remove All Caches", systemImage: "trash", role: .destructive) {
                        confirm = Confirmation(title: "Remove all caches of \(game.title)?",
                                               message: "They are rebuilt when the game runs again; the next start takes longer.",
                                               button: "Remove Caches") { emulator.removeData("caches", of: game) }
                    }
                }
                Button("Build PPU Cache Now", systemImage: "hammer") {
                    start(BootRequest(game: game, buildsPPUCache: true))
                }
                .disabled(emulator.firmwareVersion.isEmpty)
            } header: {
                Text("Caches")
            } footer: {
                Text("Building the PPU cache ahead of time makes the first start of the game faster.")
            }

            Section("Data") {
                storageRow("Savestates", size: data.savestatesSize, item: "savestates",
                           note: "Every savestate of this game is deleted.")
                NavigationLink {
                    SaveDataView(serial: game.titleID, gameTitle: game.title)
                        .onDisappear(perform: reload)
                } label: {
                    LabeledContent("Save Data", value: data.saveData == 0 ? "None" : data.saveData.formatted(.byteCount(style: .file)))
                }
                .disabled(game.titleID == nil)
                if let trophies = game.trophyIDs.first {
                    NavigationLink {
                        TrophyListView(communicationID: trophies, title: game.title)
                    } label: {
                        Text("Trophies")
                    }
                }
                storageRow("Updates and DLC", size: data.installedData, item: "installed",
                           note: "Installed updates and downloadable content are deleted; install them again from their PKG files.")
            }
        }
    }

    private func storageRow(_ title: String, size: UInt64, item: String, note: String) -> some View {
        LabeledContent(title, value: size == 0 ? "None" : size.formatted(.byteCount(style: .file)))
            .swipeActions {
                if size > 0 {
                    Button("Remove", role: .destructive) {
                        confirm = Confirmation(title: "Remove \(title.lowercased()) of \(game.title)?", message: note, button: "Remove") {
                            emulator.removeData(item, of: game)
                        }
                    }
                }
            }
            .contextMenu {
                if size > 0 {
                    Button("Remove \(title)", systemImage: "trash", role: .destructive) {
                        confirm = Confirmation(title: "Remove \(title.lowercased()) of \(game.title)?", message: note, button: "Remove") {
                            emulator.removeData(item, of: game)
                        }
                    }
                }
            }
    }

    private var infoSection: some View {
        Section("Information") {
            LabeledContent("Serial", value: game.titleID ?? "Unknown")
            if let version = game.info["APP_VER"] { LabeledContent("Version", value: Self.version(version)) }
            if let category = game.info["CATEGORY"] { LabeledContent("Type", value: Self.category(category)) }
            if let firmware = game.info["PS3_SYSTEM_VER"] { LabeledContent("Needs Firmware", value: Self.version(firmware)) }
            if let resolution = game.numbers["RESOLUTION"], resolution != 0 { LabeledContent("Resolutions", value: Self.resolutions(resolution)) }
            if let sound = game.numbers["SOUND_FORMAT"], sound != 0 { LabeledContent("Audio", value: Self.soundFormats(sound)) }
            if let level = game.numbers["PARENTAL_LEVEL"], level != 0 { LabeledContent("Parental Level", value: "\(level)") }
            LabeledContent("Location", value: game.isExternal ? "Files: \(game.url.lastPathComponent)" : "RPCS3 › Games › \(game.url.lastPathComponent)")
            Menu {
                Button("Name") { UIPasteboard.general.string = game.title }
                if let id = game.titleID {
                    Button("Serial") { UIPasteboard.general.string = id }
                    Button("Name and Serial") { UIPasteboard.general.string = "[\(id)] \(game.title)" }
                }
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            if let id = game.titleID, let url = URL(string: "https://rpcs3.net/compatibility?g=\(id)") {
                Button("Check Compatibility", systemImage: "safari") { openURL(url) }
            }
        }
    }

    @ViewBuilder private var librarySection: some View {
        Section {
            if game.isExternal {
                Button("Remove from Library", systemImage: "minus.circle", role: .destructive) {
                    confirm = Confirmation(title: "Remove \(game.title) from the library?",
                                           message: "The game stays where it is in the Files app; its saves and settings are kept.",
                                           button: "Remove from Library") {
                        emulator.remove(game)
                        dismiss()
                    }
                }
            } else {
                Button("Delete Game", systemImage: "trash", role: .destructive) {
                    confirm = Confirmation(title: "Delete \(game.title)?",
                                           message: "The game's files are deleted from the RPCS3 folder. Its saves and settings are kept.",
                                           button: "Delete Game") {
                        emulator.deleteGameFiles(game)
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: PARAM.SFO values

    /// "01.02" -> "1.02"
    static func version(_ text: String) -> String {
        text.hasPrefix("0") && text.count > 1 && !text.hasPrefix("0.") ? String(text.dropFirst()) : text
    }

    static func category(_ code: String) -> String {
        switch code {
        case "DG": "Disc game"
        case "HG": "Game on the console's drive"
        case "GD": "Game data"
        case "AP", "AM", "AV", "AT", "CB", "HM", "SF": "Application"
        case "2P": "PlayStation 2 game"
        case "1P": "PlayStation game"
        case "MN": "PSP minis"
        case "PE", "PP": "PSP game"
        default: code
        }
    }

    static func resolutions(_ mask: Int) -> String {
        let names = [(1, "480p"), (2, "576p"), (4, "720p"), (8, "1080p"), (16, "480p wide"), (32, "576p wide")]
        return names.filter { mask & $0.0 != 0 }.map(\.1).joined(separator: ", ")
    }

    static func soundFormats(_ mask: Int) -> String {
        let names = [(1, "Stereo"), (4, "5.1"), (16, "7.1"), (256, "Dolby Digital"), (512, "DTS")]
        return names.filter { mask & $0.0 != 0 }.map(\.1).joined(separator: ", ")
    }
}

/// A game's savestates, newest first: tap to resume one, swipe to delete it.
private struct SavestateList: View {
    let game: Game
    @State var savestates: [GameData.Savestate]
    let play: (BootRequest) -> Void
    let onChange: () -> Void

    var body: some View {
        List {
            ForEach(savestates) { state in
                Button {
                    play(BootRequest(game: game, savestate: state.path))
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Date(timeIntervalSince1970: TimeInterval(state.date)).formatted(date: .abbreviated, time: .shortened))
                        Text(state.compatible ? state.size.formatted(.byteCount(style: .file)) : "Made by another RPCS3 version; it cannot be resumed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!state.compatible)
            }
            .onDelete { offsets in
                for index in offsets {
                    try? FileManager.default.removeItem(atPath: savestates[index].path)
                }
                savestates.remove(atOffsets: offsets)
                onChange()
            }
        }
        .navigationTitle("Savestates")
    }
}
