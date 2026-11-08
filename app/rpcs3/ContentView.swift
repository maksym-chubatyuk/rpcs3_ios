import SwiftUI
import UniformTypeIdentifiers

/// The library, laid out like desktop RPCS3's main window: its toolbar, the game list with desktop's
/// columns (a table in landscape), the icon size slider and search. Tap a game to play it;
/// long-press it for desktop's right-click menu.
struct ContentView: View {
    @State private var emulator = Emulator.shared
    @State private var compatibility = CompatibilityDatabase.shared
    @State private var sizes = GameSizes.shared
    /// What the Files picker is for. Kept apart from `showImporter`: SwiftUI closes the picker
    /// (setting `showImporter` to false) before it hands over the chosen file.
    @State private var importKind: ImportKind = .firmware
    @State private var showImporter = false
    @State private var playing: BootRequest?
    @State private var started: Date?
    @State private var history = PlayHistory.all()
    @State private var settingsFor: SettingsTarget?
    @State private var detailsFor: Game?
    @State private var managing: Manager?
    @State private var tool: GameTool?
    @State private var pickingPackages = false
    @State private var installing: PackageInstaller?
    @State private var uninstalling: Game?
    @State private var userName = ""
    @State private var query = ""
    @AppStorage("gameList.iconSize") private var iconSize = 0.35
    @AppStorage("gameList.sort") private var sort = GameColumn.name
    @AppStorage("gameList.ascending") private var ascending = true
    @AppStorage("gameList.columns") private var shownColumns = GameColumn.defaultShown
    @Environment(\.openURL) private var openURL

    /// Whose settings are open: the global ones, or a game's own.
    struct SettingsTarget: Identifiable {
        let gameID: String?
        let title: String?
        var id: String { gameID ?? "" }
    }

    /// The console's data and the global tools the toolbar opens.
    enum Manager: String, Identifiable {
        case saves, trophies, users, rpcn, pads, logs
        var id: Self { self }
    }

    /// A game's own pads or patches, from its context menu.
    struct GameTool: Identifiable {
        enum Kind { case pads, patches }
        let kind: Kind
        let game: Game
        var id: String { "\(kind)\(game.id)" }
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

    private var canPlay: Bool { !emulator.firmwareVersion.isEmpty }
    private var jitReady: Bool { if case .ready = emulator.jit { true } else { false } }
    private var columns: Set<GameColumn> { Set(shownColumns.split(separator: ",").compactMap { GameColumn(rawValue: String($0)) }) }
    /// The slider's 0...1 as an icon width, as desktop's slider scales the icons
    private var iconWidth: CGFloat { 64 + iconSize * 96 }

    private var entries: [GameEntry] {
        let found = query.isEmpty ? emulator.games : emulator.games.filter {
            $0.title.localizedCaseInsensitiveContains(query) || ($0.titleID ?? "").localizedCaseInsensitiveContains(query)
        }
        let list = found.map { game in
            GameEntry(game: game, history: history[PlayHistory.key(for: game)],
                      compatibility: compatibility.status(of: game.titleID), size: sizes.bytes[game.id])
        }
        .sorted { GameEntry.ordered($0, $1, by: .name) }
        .sorted { GameEntry.ordered($0, $1, by: sort) }
        return ascending ? list : list.reversed()
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let wide = geo.size.width > 700
                ScrollView {
                    VStack(spacing: 12) {
                        setupPanel
                        if emulator.coreReady {
                            if emulator.games.isEmpty {
                                noGames
                            } else if entries.isEmpty {
                                ContentUnavailableView.search(text: query)
                            } else if wide {
                                table
                            } else {
                                list
                            }
                        } else if emulator.coreError == nil {
                            ProgressView().padding(.top, 40)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.immediately)
                .refreshable { refresh() }
                .safeAreaInset(edge: .top, spacing: 8) { header(wide: wide) }
                .background(Color(.systemGroupedBackground))
            }
            .toolbar(.hidden, for: .navigationBar)
            .fullScreenCover(isPresented: $emulator.showsLayoutEditorTest) { TouchLayoutEditor() }
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
        .onAppear {
            compatibility.load()
            userName = UserList.load().activeUser?.name ?? ""
        }
        .onChange(of: emulator.games, initial: true) { _, games in sizes.measure(games) }
        .onChange(of: emulator.coreReady) { _, ready in if ready { userName = UserList.load().activeUser?.name ?? "" } }
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
        // Desktop's Last Played and Time Played
        .onChange(of: playing) { old, new in
            if let old, let started {
                PlayHistory.stopped(old.game, after: Date.now.timeIntervalSince(started))
                self.started = nil
            }
            if let new, !new.buildsPPUCache {
                PlayHistory.started(new.game)
                started = .now
            }
            history = PlayHistory.all()
        }
        // Saved every minute too, so a crash or a kill loses at most that
        .task(id: playing?.id) {
            while playing != nil, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if let game = playing?.game, let start = started, !Task.isCancelled {
                    PlayHistory.stopped(game, after: Date.now.timeIntervalSince(start))
                    started = .now
                }
            }
        }
        .fullScreenCover(item: $playing) { request in
            GameScreen(request: request) { playing = nil }
        }
        .sheet(item: $detailsFor, onDismiss: { history = PlayHistory.all() }) { game in
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
                    case .pads: ControlsView()
                    case .logs: LogView()
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { managing = nil } }
                }
            }
        }
        .sheet(item: $tool) { tool in
            NavigationStack {
                Group {
                    switch tool.kind {
                    case .pads: ControlsView(gameID: tool.game.titleID, gameTitle: tool.game.title)
                    case .patches: PatchesView(game: tool.game)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { self.tool = nil } }
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

    private func refresh() {
        emulator.refreshGames()
        sizes.reset()
        sizes.measure(emulator.games)
        compatibility.refresh()
        history = PlayHistory.all()
    }

    private func play(_ request: BootRequest) {
        guard canPlay else {
            emulator.show("Install the PS3 firmware first: Open › Install Firmware.")
            return
        }
        playing = request
    }

    // MARK: Toolbar

    private func header(wide: Bool) -> some View {
        GlassEffectContainer {
            VStack(spacing: 8) {
                if wide {
                    // Landscape: one row, like desktop's toolbar
                    HStack(spacing: 10) {
                        tools.frame(width: 345)
                        slider(width: 80)
                        search.frame(minWidth: 160)
                    }
                } else {
                    tools
                    search
                }
                HStack(spacing: 10) {
                    statusLine
                    Spacer(minLength: 8)
                    if !wide { slider(width: 110) }
                }
                .padding(.horizontal, 6)
            }
            .padding(.horizontal, 12)
        }
    }

    private var tools: some View {
        HStack(spacing: 0) {
            Menu {
                Button("Game Folder…", systemImage: "folder") { importFile(.gameFolder) }
                Button("ISO File…", systemImage: "opticaldisc") { importFile(.gameISO) }
                Button("Install Packages (PKG, RAP, EDAT)…", systemImage: "shippingbox") { pickingPackages = true }
                Divider()
                Button(emulator.firmwareVersion.isEmpty ? "Install Firmware…" : "Reinstall Firmware…", systemImage: "cpu") { importFile(.firmware) }
                Button(emulator.hasPairingFile ? "Replace Pairing File…" : "Import Pairing File…", systemImage: "key") { importFile(.pairingFile) }
            } label: {
                ToolLabel(title: "Open", symbol: "plus.rectangle.on.folder")
            }
            .buttonStyle(.plain)
            ToolButton("Refresh", "arrow.clockwise") { refresh() }
            ToolButton("Config", "switch.2") { settingsFor = SettingsTarget(gameID: nil, title: nil) }
            ToolButton("Pads", "gamecontroller.fill") { managing = .pads }
            ToolButton("RPCN", "network") { managing = .rpcn }
            Menu {
                Section(userName.isEmpty ? "User" : "Logged in as \(userName)") {
                    Button("User Accounts", systemImage: "person.2") { managing = .users }
                    Button("Save Data", systemImage: "externaldrive") { managing = .saves }
                    Button("Trophies", systemImage: "trophy") { managing = .trophies }
                }
                Button("Logs", systemImage: "doc.text.magnifyingglass") { managing = .logs }
            } label: {
                ToolLabel(title: "Manage", symbol: "person.crop.circle")
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.primary)
        .disabled(!emulator.coreReady)
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search…", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !query.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .glassEffect(.regular, in: .capsule)
    }

    /// Desktop's icon size slider
    private func slider(width: CGFloat) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "photo").font(.caption2).foregroundStyle(.secondary)
            Slider(value: $iconSize).frame(width: width)
            Image(systemName: "photo").font(.callout).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Icon Size")
    }

    private var statusLine: some View {
        HStack(spacing: 10) {
            status(jitReady ? "JIT" : "No JIT", ok: jitReady)
            status(emulator.firmwareVersion.isEmpty ? "No Firmware" : "Firmware \(emulator.firmwareVersion)", ok: !emulator.firmwareVersion.isEmpty)
            Text(emulator.games.count == 1 ? "1 game" : "\(emulator.games.count) games").foregroundStyle(.secondary)
        }
        .font(.caption.weight(.medium))
        .lineLimit(1)
    }

    private func status(_ text: String, ok: Bool) -> some View {
        HStack(spacing: 4) {
            Circle().fill(ok ? Color.green : Color.orange).frame(width: 7, height: 7)
            Text(text)
        }
    }

    // MARK: Setup

    /// Only while something is missing: the emulator failed to load, JIT is off, or there is no firmware.
    @ViewBuilder private var setupPanel: some View {
        let firmwareMissing = emulator.coreReady && (emulator.firmwareVersion.isEmpty || emulator.firmwareProgress != nil)
        if emulator.coreError != nil || !jitReady || firmwareMissing {
            VStack(alignment: .leading, spacing: 10) {
                if let error = emulator.coreError {
                    SetupRow(symbol: "exclamationmark.triangle.fill", title: "The emulator did not load", detail: error, tint: .red) { EmptyView() }
                }
                if !jitReady { jitRow }
                if !jitReady && firmwareMissing { Divider() }
                if firmwareMissing { firmwareRow }
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    @ViewBuilder private var jitRow: some View {
        switch emulator.jit {
        case .waitingForDebugger:
            SetupRow(symbol: "bolt.slash.fill", title: "JIT is off",
                     detail: emulator.onDeviceJITError ?? (emulator.hasPairingFile
                        ? "Connect LocalDevVPN, then enable it. Or use StikDebug."
                        : "Import this iPhone's pairing file and connect LocalDevVPN. Or use StikDebug.")) {
                if emulator.hasPairingFile {
                    Button("Enable") { emulator.enableJITOnDevice() }
                        .contextMenu {
                            Button("Replace Pairing File…", systemImage: "key") { importFile(.pairingFile) }
                        }
                } else {
                    Button("Import…") { importFile(.pairingFile) }
                }
            }
        case .attaching:
            SetupRow(symbol: "bolt.fill", title: "Enabling JIT", detail: "Attaching the debugger through LocalDevVPN…") { ProgressView() }
        case .acquiring:
            SetupRow(symbol: "bolt.fill", title: "Enabling JIT", detail: "Preparing \(emulator.poolMegabytes) MB of JIT memory…") { ProgressView() }
        case .ready:
            EmptyView()
        case .failed(let reason):
            SetupRow(symbol: "xmark.octagon.fill", title: "JIT failed", detail: reason, tint: .red) { EmptyView() }
        }
    }

    @ViewBuilder private var firmwareRow: some View {
        if let progress = emulator.firmwareProgress {
            SetupRow(symbol: "cpu", title: "Installing the firmware", detail: "\(Int(progress * 100)) %", tint: .blue) {
                ProgressView(value: progress).frame(width: 80)
            }
        } else if let found = emulator.firmwareInDocuments {
            SetupRow(symbol: "cpu", title: "No firmware", detail: "PS3UPDAT.PUP is in the RPCS3 folder.") {
                Button("Install") { emulator.installFirmware(from: found) }
            }
        } else {
            SetupRow(symbol: "cpu", title: "No firmware", detail: "Install PS3UPDAT.PUP from PlayStation's website to play.") {
                Button("Choose…") { importFile(.firmware) }
            }
        }
    }

    // MARK: Game list

    /// Portrait: desktop's columns folded into each row
    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Divider().padding(.leading, iconWidth + 22) }
                gameButton(entry.game) { GameListRow(entry: entry, iconWidth: iconWidth) }
            }
        }
        .padding(.vertical, 4)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// Landscape: desktop's table, every column sortable
    private var table: some View {
        let shown = columns
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Icon")
                    .foregroundStyle(.secondary)
                    .frame(width: iconWidth, alignment: .leading)
                ForEach(GameColumn.allCases.filter { $0 == .name || shown.contains($0) }) { column in
                    Button {
                        if sort == column { ascending.toggle() } else { sort = column; ascending = true }
                    } label: {
                        HStack(spacing: 3) {
                            Text(column.title).lineLimit(1)
                            if sort == column { Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.caption2.bold()) }
                        }
                        .frame(width: column.width, alignment: .leading)
                        .frame(maxWidth: column.width == nil ? .infinity : nil, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(sort == column ? Color.primary : Color.secondary)
                }
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            // Desktop hides columns from the header's right-click menu
            .contextMenu {
                Section("Columns") {
                    ForEach(GameColumn.allCases.filter { $0 != .name }) { column in
                        Toggle(column.title, isOn: Binding(get: { shown.contains(column) }, set: { show in
                            let set = show ? shown.union([column]) : shown.subtracting([column])
                            shownColumns = GameColumn.allCases.filter(set.contains).map(\.rawValue).joined(separator: ",")
                        }))
                    }
                }
            }
            Divider()
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Divider().padding(.leading, 12) }
                gameButton(entry.game) { GameTableRow(entry: entry, iconWidth: iconWidth, columns: shown) }
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// Tap plays; long-press is desktop's right-click menu.
    private func gameButton(_ game: Game, @ViewBuilder label: () -> some View) -> some View {
        Button { play(BootRequest(game: game)) } label: { label() }
            .buttonStyle(RowPress())
            .contextMenu {
                gameMenu(game)
            } preview: {
                VStack(alignment: .leading, spacing: 8) {
                    GameIcon(game: game, width: 240)
                    Text(game.title).font(.headline)
                    if let id = game.titleID { Text(id).font(.subheadline).foregroundStyle(.secondary) }
                }
                .padding()
            }
            .accessibilityHint("Plays the game. Touch and hold for more.")
    }

    @ViewBuilder private func gameMenu(_ game: Game) -> some View {
        let data = emulator.gameData(game)
        Section {
            Button("Play", systemImage: "play.fill") { play(BootRequest(game: game)) }
            if let last = data?.lastSavestate, !last.isEmpty {
                Button("Resume Latest Savestate", systemImage: "clock.arrow.circlepath") {
                    play(BootRequest(game: game, savestate: last))
                }
            }
            if data?.customConfig == true {
                Button("Play with Global Settings", systemImage: "play.circle") { play(BootRequest(game: game, mode: .global)) }
            }
            Button("Play with Default Settings", systemImage: "play.circle") { play(BootRequest(game: game, mode: .defaults)) }
        }
        Section {
            if let id = game.titleID {
                Button("Game Settings", systemImage: "gearshape") { settingsFor = SettingsTarget(gameID: id, title: game.title) }
                Button("Game Controls", systemImage: "gamecontroller") { tool = GameTool(kind: .pads, game: game) }
                Button("Patches", systemImage: "bandage") { tool = GameTool(kind: .patches, game: game) }
            }
            Button("Build PPU Cache", systemImage: "hammer") { play(BootRequest(game: game, buildsPPUCache: true)) }
            Button("Details", systemImage: "info.circle") { detailsFor = game }
        }
        Section {
            if let id = game.titleID {
                if let url = URL(string: "https://rpcs3.net/compatibility?g=\(id)") {
                    Button("Check Compatibility", systemImage: "safari") { openURL(url) }
                }
                Menu("Copy Info", systemImage: "doc.on.doc") {
                    Button("Name") { UIPasteboard.general.string = game.title }
                    Button("Serial") { UIPasteboard.general.string = id }
                    Button("Name and Serial") { UIPasteboard.general.string = "[\(id)] \(game.title)" }
                }
            }
            if game.isExternal {
                Button("Remove from Library", systemImage: "minus.circle", role: .destructive) { emulator.remove(game) }
            } else if game.isInstalled {
                Button("Uninstall…", systemImage: "trash", role: .destructive) { uninstalling = game }
            }
        }
    }

    private var noGames: some View {
        ContentUnavailableView {
            Label("No Games", systemImage: "opticaldisc")
        } description: {
            Text("Open a game folder or ISO anywhere in the Files app, install PKG files, or copy games into On My iPhone › RPCS3 › Games.")
        } actions: {
            Menu {
                Button("Game Folder…", systemImage: "folder") { importFile(.gameFolder) }
                Button("ISO File…", systemImage: "opticaldisc") { importFile(.gameISO) }
                Button("Install Packages (PKG, RAP, EDAT)…", systemImage: "shippingbox") { pickingPackages = true }
            } label: {
                Label("Open…", systemImage: "plus.rectangle.on.folder")
            }
            .buttonStyle(.glassProminent)
        }
        .padding(.top, 40)
    }
}

#Preview {
    ContentView()
}
