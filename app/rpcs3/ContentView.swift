import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var emulator = Emulator.shared
    /// What the Files picker is for. Kept apart from `showImporter`: SwiftUI closes the picker
    /// (setting `showImporter` to false) before it hands over the chosen file.
    @State private var importKind: ImportKind = .firmware
    @State private var showImporter = false
    @State private var playing: BootRequest?
    @State private var settingsFor: SettingsTarget?
    @State private var detailsFor: Game?
    @State private var managing: Manager?
    @State private var pickingPackages = false
    @State private var installing: PackageInstaller?
    @State private var uninstalling: Game?
    @State private var userName = ""
    @Environment(\.openURL) private var openURL

    /// Whose settings are open: the global ones, or a game's own.
    struct SettingsTarget: Identifiable {
        let gameID: String?
        let title: String?
        var id: String { gameID ?? "" }
    }

    /// The console's data: its users, and the logged-in user's saves and trophies.
    enum Manager: String, Identifiable {
        case saves, trophies, users, rpcn
        var id: Self { self }
    }

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
            .fullScreenCover(isPresented: $emulator.showsLayoutEditorTest) { TouchLayoutEditor() }
            .refreshable { emulator.refreshGames() }
            .toolbar {
                if emulator.coreReady {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Settings", systemImage: "gearshape") { settingsFor = SettingsTarget(gameID: nil, title: nil) }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Section(userName.isEmpty ? "User" : "Logged in as \(userName)") {
                                Button("Save Data", systemImage: "externaldrive") { managing = .saves }
                                Button("Trophies", systemImage: "trophy") { managing = .trophies }
                                Button("Users", systemImage: "person.2") { managing = .users }
                                Button("RPCN (Online)", systemImage: "network") { managing = .rpcn }
                            }
                        } label: {
                            Label("User", systemImage: "person.crop.circle")
                        }
                        .onAppear { userName = UserList.load().activeUser?.name ?? "" }
                    }
                }
                if emulator.coreReady {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Game folder…", systemImage: "folder") { importFile(.gameFolder) }
                            Button("ISO file…", systemImage: "opticaldisc") { importFile(.gameISO) }
                            Divider()
                            Button("Install Packages (PKG, RAP, EDAT)…", systemImage: "shippingbox") { pickingPackages = true }
                        } label: {
                            Label("Add game", systemImage: "plus")
                        }
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
        .fileImporter(isPresented: $pickingPackages, allowedContentTypes: PackageInstaller.fileTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result, !urls.isEmpty { installing = PackageInstaller(urls: urls) }
        }
        .sheet(item: $installing) { installer in
            PackageInstallView(installer: installer)
        }
        .confirmationDialog("Uninstall \(uninstalling?.title ?? "")?", isPresented: Binding(get: { uninstalling != nil }, set: { if !$0 { uninstalling = nil } }),
                            titleVisibility: .visible, presenting: uninstalling) { game in
            Button("Uninstall", role: .destructive) { emulator.uninstall(game) }
        } message: { _ in
            Text("The game is deleted together with its updates and add-ons. Its saves and settings are kept.")
        }
        .onChange(of: emulator.autoBoot) { _, request in
            if let request {
                emulator.autoBoot = nil
                emulator.dismissMessage()
                playing = request
            }
        }
        .fullScreenCover(item: $playing) { request in
            GameScreen(request: request) { playing = nil }
        }
        .sheet(item: $detailsFor) { game in
            GameDetailView(game: game) { request in
                // After the sheet has gone, so the game screen can come up
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { playing = request }
            }
        }
        .sheet(item: $managing, onDismiss: { userName = UserList.load().activeUser?.name ?? "" }) { manager in
            NavigationStack {
                Group {
                    switch manager {
                    case .saves: SaveDataView()
                    case .trophies: TrophyGamesView()
                    case .users: UsersView()
                    case .rpcn: RPCNView()
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { managing = nil } }
                }
            }
        }
        .sheet(item: $settingsFor) { target in
            SettingsView(store: SettingsStore(gameID: target.gameID, gameTitle: target.title))
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
                gameRow(game)
            }
        } header: {
            Text("Games")
        } footer: {
            if emulator.firmwareVersion.isEmpty && !emulator.games.isEmpty {
                Text("Install the firmware to play.")
            }
        }
    }

    private func gameRow(_ game: Game) -> some View {
        let canPlay = !emulator.firmwareVersion.isEmpty
        return HStack(spacing: 12) {
            Button {
                playing = BootRequest(game: game)
            } label: {
                HStack(spacing: 12) {
                    GameIcon(game: game)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(game.title)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Text([game.titleID, game.isExternal ? "from Files" : game.isInstalled ? "installed" : nil].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canPlay)

            Button {
                detailsFor = game
            } label: {
                Image(systemName: "info.circle")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Details of \(game.title)")
        }
        .swipeActions {
            if game.isExternal {
                Button("Remove", role: .destructive) { emulator.remove(game) }
            } else if game.isInstalled {
                Button("Uninstall", role: .destructive) { uninstalling = game }
            }
        }
        .swipeActions(edge: .leading) {
            if let id = game.titleID {
                Button("Settings", systemImage: "gearshape") { settingsFor = SettingsTarget(gameID: id, title: game.title) }
                    .tint(.gray)
            }
        }
        .contextMenu {
            gameMenu(game, canPlay: canPlay)
        } preview: {
            VStack(alignment: .leading, spacing: 8) {
                GameIcon(game: game, width: 240)
                Text(game.title).font(.headline)
                if let id = game.titleID { Text(id).font(.subheadline).foregroundStyle(.secondary) }
            }
            .padding()
        }
    }

    /// The quick actions of desktop's game menu; everything else is on the game's page.
    @ViewBuilder private func gameMenu(_ game: Game, canPlay: Bool) -> some View {
        let data = emulator.gameData(game)
        Section {
            Button("Play", systemImage: "play.fill") { playing = BootRequest(game: game) }
                .disabled(!canPlay)
            if let last = data?.lastSavestate, !last.isEmpty {
                Button("Resume Latest Savestate", systemImage: "clock.arrow.circlepath") {
                    playing = BootRequest(game: game, savestate: last)
                }
                .disabled(!canPlay)
            }
            if data?.customConfig == true {
                Button("Play with Global Settings", systemImage: "play.circle") { playing = BootRequest(game: game, mode: .global) }
                    .disabled(!canPlay)
            }
            Button("Play with Default Settings", systemImage: "play.circle") { playing = BootRequest(game: game, mode: .defaults) }
                .disabled(!canPlay)
        }
        Section {
            if let id = game.titleID {
                Button("Game Settings", systemImage: "gearshape") { settingsFor = SettingsTarget(gameID: id, title: game.title) }
            }
            Button("Details", systemImage: "info.circle") { detailsFor = game }
        }
        Section {
            if let id = game.titleID {
                Button("Copy Serial", systemImage: "doc.on.doc") { UIPasteboard.general.string = id }
                if let url = URL(string: "https://rpcs3.net/compatibility?g=\(id)") {
                    Button("Check Compatibility", systemImage: "safari") { openURL(url) }
                }
            }
            if game.isExternal {
                Button("Remove from Library", systemImage: "minus.circle", role: .destructive) { emulator.remove(game) }
            } else if game.isInstalled {
                Button("Uninstall…", systemImage: "trash", role: .destructive) { uninstalling = game }
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
