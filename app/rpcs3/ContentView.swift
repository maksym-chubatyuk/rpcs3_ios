import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var emulator = Emulator.shared
    /// What the Files picker is for. Kept apart from `showImporter`: SwiftUI closes the picker
    /// (setting `showImporter` to false) before it hands over the chosen file.
    @State private var importKind: ImportKind = .firmware
    @State private var showImporter = false
    @State private var playing: Emulator.Game?

    /// What the Files picker is open for.
    enum ImportKind: Identifiable {
        case firmware, gameFolder, gameISO, pairingFile
        var id: Self { self }
        var types: [UTType] {
            switch self {
            case .firmware: [UTType(filenameExtension: "pup") ?? .data, .data]
            case .gameFolder: [.folder]
            case .gameISO: [UTType(filenameExtension: "iso") ?? .diskImage, .diskImage]
            case .pairingFile: [.propertyList, UTType(filenameExtension: "mobiledevicepairing") ?? .data, .data]
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("JIT") {
                    jitRow
                }

                if emulator.coreReady {
                    Section("Firmware") {
                        firmwareRows
                    }
                    gamesSection
                } else if let error = emulator.coreError {
                    Section("Emulator") {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("RPCS3")
            .refreshable { emulator.refreshGames() }
            .toolbar {
                if emulator.coreReady {
                    Menu {
                        Button("Game folder…", systemImage: "folder") { importFile(.gameFolder) }
                        Button("ISO file…", systemImage: "opticaldisc") { importFile(.gameISO) }
                    } label: {
                        Label("Add game", systemImage: "plus")
                    }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: importKind.types) { result in
                switch result {
                case .success(let url):
                    emulator.log("picked \(url.lastPathComponent) for \(importKind)")
                    switch importKind {
                    case .firmware: emulator.installFirmware(from: url)
                    case .gameFolder, .gameISO: emulator.addGame(from: url)
                    case .pairingFile: emulator.importPairingFile(from: url)
                    }
                case .failure(let error):
                    emulator.log("file picker failed: \(error.localizedDescription)")
                }
            }
            .alert("RPCS3", isPresented: Binding(get: { emulator.lastMessage != nil }, set: { if !$0 { emulator.dismissMessage() } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(emulator.lastMessage ?? "")
            }
        }
        .onChange(of: emulator.autoBoot) { _, game in
            if let game {
                emulator.autoBoot = nil
                emulator.dismissMessage()
                playing = game
            }
        }
        .fullScreenCover(item: $playing) { game in
            GameScreen(game: game) { playing = nil }
        }
    }

    private func importFile(_ kind: ImportKind) {
        importKind = kind
        showImporter = true
    }

    private var gamesSection: some View {
        Section {
            if emulator.games.isEmpty {
                Text("Add a game with + (a game folder or ISO anywhere in the Files app), or copy it into On My iPhone › RPCS3 › Games.")
                    .foregroundStyle(.secondary)
            }
            ForEach(emulator.games) { game in
                Button {
                    playing = game
                } label: {
                    HStack {
                        Image(systemName: game.url.pathExtension.lowercased() == "iso" ? "opticaldisc" : "folder")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(game.title)
                                .foregroundStyle(.primary)
                            Text([game.titleID, game.isExternal ? "from Files" : nil].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(emulator.firmwareVersion.isEmpty)
                .swipeActions {
                    if game.isExternal {
                        Button("Remove", role: .destructive) { emulator.remove(game) }
                    }
                }
            }
        } header: {
            Text("Games")
        } footer: {
            if emulator.firmwareVersion.isEmpty && !emulator.games.isEmpty {
                Text("Install the firmware to play.")
            }
        }
    }

    @ViewBuilder private var jitRow: some View {
        switch emulator.jit {
        case .waitingForDebugger:
            VStack(alignment: .leading, spacing: 6) {
                Label("Waiting for JIT", systemImage: "hourglass")
                if let error = emulator.onDeviceJITError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Text(emulator.hasPairingFile
                     ? "Connect LocalDevVPN, then enable JIT here. Or use StikDebug, or scripts/run.sh on a Mac."
                     : "To enable JIT without a Mac, import this iPhone's pairing file and connect LocalDevVPN. Or use StikDebug, or scripts/run.sh on a Mac.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if emulator.hasPairingFile {
                Button("Enable JIT", systemImage: "bolt.fill") { emulator.enableJITOnDevice() }
            }
            Button(emulator.hasPairingFile ? "Replace Pairing File…" : "Import Pairing File…", systemImage: "key") {
                importFile(.pairingFile)
            }
        case .attaching:
            HStack {
                ProgressView()
                Text("Attaching the debugger through LocalDevVPN…")
            }
        case .acquiring:
            HStack {
                ProgressView()
                Text("Preparing \(emulator.poolMegabytes) MB of JIT memory…")
            }
        case .ready(let megabytes):
            Label("JIT ready (\(megabytes) MB)", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        case .failed(let reason):
            Label(reason, systemImage: "xmark.octagon")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder private var firmwareRows: some View {
        if let progress = emulator.firmwareProgress {
            ProgressView("Installing firmware…", value: progress)
        } else {
            if !emulator.firmwareVersion.isEmpty {
                LabeledContent("Installed", value: emulator.firmwareVersion)
            }
            if let found = emulator.firmwareInDocuments {
                Button(emulator.firmwareVersion.isEmpty ? "Install PS3UPDAT.PUP from the RPCS3 folder" : "Reinstall from PS3UPDAT.PUP in the RPCS3 folder") {
                    emulator.installFirmware(from: found)
                }
            }
            Button(emulator.firmwareVersion.isEmpty ? "Choose PS3UPDAT.PUP in Files…" : "Reinstall from Files…") {
                importFile(.firmware)
            }
        }
    }
}

#Preview {
    ContentView()
}
