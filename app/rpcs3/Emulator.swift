import Foundation
import Observation

/// App-wide state: JIT, the emulator core, firmware and the game library.
@Observable
final class Emulator {
    enum JITState: Equatable {
        case waitingForDebugger
        case attaching
        case acquiring
        case ready(megabytes: Int)
        case failed(String)
    }

    typealias Game = rpcs3.Game

    static let shared = Emulator()

    private(set) var jit: JITState = .waitingForDebugger
    private(set) var coreReady = false
    private(set) var coreError: String?
    private(set) var firmwareVersion = ""
    private(set) var games: [Game] = []
    private(set) var firmwareProgress: Double?
    private(set) var lastMessage: String?
    /// Why the last attempt to enable JIT on the iPhone itself failed.
    private(set) var onDeviceJITError: String?
    private(set) var hasPairingFile = OnDeviceJIT.hasPairingFile
    var isRunning = false

    /// Set by the test hook (RPCS3_AUTO_BOOT, RPCS3_AUTO_BOOT_MODE): the library starts this by itself.
    var autoBoot: BootRequest?

    /// JIT pool size, from the RPCS3_JIT_POOL_MB environment variable or 1 GiB.
    let poolMegabytes: Int = {
        if let text = ProcessInfo.processInfo.environment["RPCS3_JIT_POOL_MB"], let value = Int(text), value >= 128 {
            return value
        }
        return 1024
    }()

    /// Games go here (visible in the Files app): folders with PS3_GAME/USRDIR/EBOOT.BIN, or ISOs.
    let gamesDirectory: URL = URL.documentsDirectory.appending(path: "Games", directoryHint: .isDirectory)

    /// A PS3UPDAT.PUP put into Documents (Files app, or copied from a Mac), offered for install.
    var firmwareInDocuments: URL? {
        let url = URL.documentsDirectory.appending(path: "PS3UPDAT.PUP")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The Files-app location of the running game, accessed until it stops.
    private var scopedGameURL: URL?

    private var debuggerTimer: Timer?

    /// Documents/rpcs3-app.log: what the app itself did (JIT, core loading), for scripts/run.sh.
    private let appLog = URL.documentsDirectory.appending(path: "rpcs3-app.log")

    func log(_ line: String) {
        let text = "\(Date().formatted(.iso8601)) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: appLog) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: appLog)
        }
    }

    private init() {
        try? FileManager.default.createDirectory(at: gamesDirectory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: appLog)
        // Test hook: RPCS3_STDERR=1 sends stderr (MoltenVK's messages, the core's own) to Documents/stderr.log
        if ProcessInfo.processInfo.environment["RPCS3_STDERR"] == "1" {
            let path = URL.documentsDirectory.appending(path: "stderr.log").path
            freopen(path, "w", stderr)
            setvbuf(stderr, nil, _IONBF, 0)
        }
        log("launched, pid \(getpid()), JIT pool request \(poolMegabytes) MB")
        refreshGames()
        watchForDebugger()
        if jit == .waitingForDebugger && hasPairingFile {
            enableJITOnDevice()
        }
    }

    // MARK: JIT

    /// A debugger (StikDebug, or scripts/run.sh on a Mac) sets CS_DEBUGGED when it attaches.
    private func watchForDebugger() {
        if rpcs3_jit_is_debugged() {
            acquirePool()
            return
        }
        debuggerTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, rpcs3_jit_is_debugged() else { return }
                timer.invalidate()
                self.debuggerTimer = nil
                self.acquirePool()
            }
        }
    }

    /// JIT without a Mac: the rpcs3JITHelper extension attaches StikJIT's debugger through LocalDevVPN.
    /// When it is attached, the debugger timer above notices and the pool is acquired as usual.
    func enableJITOnDevice() {
        guard jit == .waitingForDebugger else { return }
        jit = .attaching
        onDeviceJITError = nil
        log("enabling JIT on the iPhone (LocalDevVPN)")

        DispatchQueue.global(qos: .userInitiated).async {
            let tunnelUp = OnDeviceJIT.tunnelIsUp()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard tunnelUp else {
                        self.onDeviceAttachEnded(.failure(OnDeviceJIT.Failure.text(OnDeviceJIT.tunnelHint)))
                        return
                    }
                    OnDeviceJIT.attach { result in self.onDeviceAttachEnded(result) }
                    // The first time, the Developer Disk Image is downloaded and mounted, which takes a while
                    DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
                        MainActor.assumeIsolated {
                            if self.jit == .attaching {
                                self.onDeviceAttachEnded(.failure(OnDeviceJIT.Failure.text("The debugger did not attach within two minutes. Check that LocalDevVPN is connected, then try again.")))
                            }
                        }
                    }
                }
            }
        }
    }

    private func onDeviceAttachEnded(_ result: Result<String, Error>) {
        switch result {
        case .success(let message):
            log("JIT helper finished: \(message)")
            if jit == .attaching {
                // It left without the app asking for memory
                jit = .waitingForDebugger
                onDeviceJITError = "The debugger left before RPCS3 could use it. Try again."
            }
        case .failure(let error):
            log("JIT helper failed: \(error.localizedDescription)")
            if jit == .attaching {
                jit = .waitingForDebugger
                onDeviceJITError = error.localizedDescription
            }
        }
    }

    func importPairingFile(from url: URL) {
        do {
            try OnDeviceJIT.importPairingFile(from: url)
            log("pairing file imported from \(url.lastPathComponent)")
            hasPairingFile = true
            onDeviceJITError = nil
            enableJITOnDevice()
        } catch {
            log("pairing file not imported: \(error.localizedDescription)")
            lastMessage = error.localizedDescription
        }
    }

    func forgetPairingFile() {
        OnDeviceJIT.forgetPairingFile()
        hasPairingFile = false
    }

    private func acquirePool() {
        guard jit == .waitingForDebugger || jit == .attaching else { return }
        jit = .acquiring
        let bytes = poolMegabytes << 20

        // The debugger writes every page of the pool before answering: keep it off the main thread.
        Thread.detachNewThread {
            var pool = rpcs3_jit_pool()
            var error = [CChar](repeating: 0, count: 512)
            let code = rpcs3_jit_acquire(bytes, true, &pool, &error, error.count)
            let message = String(cString: error)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if code == 0 {
                        self.log(String(format: "JIT ready: RX 0x%lx RW 0x%lx, %lu MB", pool.rx, pool.rw, pool.size >> 20))
                        self.jit = .ready(megabytes: Int(pool.size >> 20))
                        self.loadCore()
                    } else {
                        self.log("JIT failed (\(code)): \(message)")
                        self.jit = .failed(message)
                    }
                }
            }
        }
    }

    // MARK: Core

    private func loadCore() {
        var error = [CChar](repeating: 0, count: 512)
        guard core_load(&error, error.count) else {
            coreError = String(cString: error)
            log("core not loaded: \(coreError ?? "")")
            return
        }
        guard core_initialize(coreEvent) == 0 else {
            coreError = "The emulator core did not initialize. See the log."
            return
        }
        coreReady = true
        firmwareVersion = String(cString: core_firmware_version())
        refreshGames() // with the games installed in dev_hdd0
        runTestHook()
        log("core ready, emulator dir \(String(cString: core_emulator_dir())), firmware '\(firmwareVersion)'")
    }

    fileprivate func handle(event: Int32) {
        switch event {
        case 2, 4: isRunning = true      // run, resume
        case 5:  // stop
            isRunning = false
            releaseGameAccess()
            if let game = buildingCache {
                buildingCache = nil
                log("PPU cache of \(game.title) finished")
                lastMessage = "The PPU cache of \(game.title) is built."
            }
        case 6: lastMessage = "This game needs the PS3 firmware. Install PS3UPDAT.PUP first."
        default: break
        }
    }

    // MARK: Test hook

    /// For scripts/run.sh SETTINGS_SELFTEST=<title ID>: reads every setting, gives the game its own
    /// value for one, checks it, then lets it follow the global settings again. Results in the app log.
    private func settingsSelfTest(game: String) {
        let path = ["Video", "Frame limit"]
        if let pointer = core_settings(nil) {
            try? Data(String(cString: pointer).utf8).write(to: URL.documentsDirectory.appending(path: "settings-dump.json"))
            core_free(pointer)
        }
        let global = SettingsStore()
        let shown = SettingsLayout.shared.tabs.flatMap { $0.groups.flatMap(\.items) }.filter { global.setting($0.path) != nil }.count
        log("settings test: \(global.settings.count) settings, \(shown) of them in \(SettingsLayout.shared.tabs.count) tabs, \(global.otherSettings.count) under Other")
        guard let globalLimit = global.setting(path) else { log("settings test: no \(path)"); return }

        let store = SettingsStore(gameID: game)
        guard let before = store.setting(path) else { log("settings test: no \(path) for \(game)"); return }
        let other = (before.options ?? []).first { $0 != globalLimit.value } ?? before.value
        store.set(before, to: other)
        let set = store.setting(path)
        log("settings test: \(game) frame limit \(before.value) (overridden \(before.overridden ?? false)) -> \(set?.value ?? "?") (overridden \(set?.overridden ?? false)); global stays \(SettingsStore().setting(path)?.value ?? "?")")
        if let set { store.reset(set) }
        let after = store.setting(path)
        log("settings test: after reset \(after?.value ?? "?") (overridden \(after?.overridden ?? false)), error \(store.lastError ?? "none")")
        if let neptunia = games.first(where: { $0.titleID == game }), let data = gameData(neptunia) {
            log("game data test: own settings \(data.customConfig), shaders \(data.shaderCache), PPU \(data.ppuCache), SPU \(data.spuCache), HDD1 \(data.hdd1Cache), saves \(data.saveData), installed \(data.installedData), savestates \(data.savestates.count), resolutions \(neptunia.numbers["RESOLUTION"] ?? -1), icon \(neptunia.iconURL != nil)")
        }
    }

    /// For scripts/run.sh: RPCS3_AUTO_FIRMWARE=1 installs Documents/PS3UPDAT.PUP when no
    /// firmware is installed; RPCS3_AUTO_BOOT=<folder in Games> then boots that game.
    private func runTestHook() {
        let env = ProcessInfo.processInfo.environment
        if let game = env["RPCS3_SETTINGS_SELFTEST"], !game.isEmpty {
            settingsSelfTest(game: game)
        }
        // RPCS3_PATCH_TEST=1: downloads the patches, lists the first game's, turns one on and off again
        if env["RPCS3_PATCH_TEST"] != nil, let game = games.first {
            Task { @MainActor in
                let store = PatchStore(game: game)
                await store.downloadLatest()
                self.log("patch test: download: \(store.message ?? "no message"); \(store.patches.count) patches for \(game.title) \(store.appVersion), \(store.patches.filter { !$0.isForAllGames }.count) of them its own")
                for patch in store.patches.filter({ !$0.isForAllGames }).prefix(8) {
                    self.log("patch test:   \(patch.enabled ? "on " : "off") \(patch.description) [\(patch.group)] by \(patch.author), values \(patch.configValues.map(\.name))")
                }
                if let first = store.patches.first(where: { !$0.enabled }) {
                    store.setEnabled(first, true)
                    let on = store.patches.first { $0.id == first.id }?.enabled ?? false
                    store.setEnabled(first, false)
                    let off = store.patches.first { $0.id == first.id }?.enabled ?? true
                    self.log("patch test: '\(first.description)' on -> \(on), off -> \(!off), message \(store.message ?? "none")")
                }
            }
        }
        // RPCS3_CONTROLS_TEST=1: reads the controls, gives the first game its own deadzone, then removes its controls
        if env["RPCS3_CONTROLS_TEST"] != nil, let game = games.first, let id = game.titleID {
            let global = ControlsStore(gameID: nil)
            let p1 = global.players.first
            log("controls test: devices \(global.devices), \(global.buttons.count) button names, player 1 \(p1?.handler ?? "?") \(p1?.device ?? "?"), Cross = \(p1?.settings[["Config", "Cross"]]?.value ?? "?"), \(p1?.settings.count ?? 0) entries, error \(global.lastError ?? "none")")
            let own = ControlsStore(gameID: id)
            let before = own.gameHasOwn
            own.set(player: 0, ["Config", "Left Stick Deadzone"], to: "5000")
            let deadzone = own.players.first?.settings[["Config", "Left Stick Deadzone"]]?.value ?? "?"
            let globalDeadzone = ControlsStore(gameID: nil).players.first?.settings[["Config", "Left Stick Deadzone"]]?.value ?? "?"
            log("controls test: \(game.title) own before \(before), after \(own.gameHasOwn), deadzone \(deadzone), global deadzone \(globalDeadzone), error \(own.lastError ?? "none")")
            removeData("input", of: game)
            log("controls test: after removing, own \(ControlsStore(gameID: id).gameHasOwn)")
        }
        // RPCS3_USERDATA_TEST=1: lists users, saves and trophies; creates, renames, logs into and deletes a user
        if env["RPCS3_USERDATA_TEST"] != nil {
            let users = UserList.load()
            log("userdata test: active \(users.active), users \(users.users.map { "\($0.id) \($0.name)" })")
            let saves = CoreCall.decode(SaveList.self, core_saves(nil))
            log("userdata test: savedata dir \(saves?.dir ?? "?"), \(saves?.saves.count ?? -1) saves: \(saves?.saves.prefix(3).map { "\($0.dir) '\($0.title)' \($0.size) icon \(!$0.icon.isEmpty)" } ?? [])")
            let trophyGames = TrophyGame.all()
            log("userdata test: \(trophyGames.count) trophy sets: \(trophyGames.map { "\($0.id) '\($0.name)' \($0.earned)/\($0.total) icon \(!$0.icon.isEmpty)" })")
            if let set = trophyGames.first {
                let list = CoreCall.decode([Trophy].self, core_trophies(set.id)) ?? []
                log("userdata test: \(list.count) trophies, first \(list.first.map { "\($0.id) '\($0.name)' \($0.grade) hidden \($0.hidden) earned \($0.earned) icon \(!$0.icon.isEmpty)" } ?? "none")")
            }
            if let game = games.first { log("userdata test: \(game.title) trophy sets in the game: \(game.trophyIDs)") }
            let bad = CoreCall.message { core_user_create("x", $0, $1) }
            log("userdata test: bad name -> \(bad ?? "accepted!")")
            let created = CoreCall.message { core_user_create("Tester_1", $0, $1) }
            let added = UserList.load().users.first { $0.name == "Tester_1" }
            log("userdata test: create -> \(created ?? "ok"), id \(added?.id ?? "none")")
            if let added {
                let renamed = CoreCall.message { core_user_rename(added.id, "Tester-2", $0, $1) }
                let login = CoreCall.message { core_user_login(added.id, $0, $1) }
                let removeActive = CoreCall.message { core_user_remove(added.id, $0, $1) }
                log("userdata test: rename -> \(renamed ?? "ok"), login -> \(login ?? "ok"), active \(UserList.load().active), remove active -> \(removeActive ?? "accepted!"), saves now \(CoreCall.decode(SaveList.self, core_saves(nil))?.dir ?? "?")")
                let back = CoreCall.message { core_user_login(users.active, $0, $1) }
                let removed = CoreCall.message { core_user_remove(added.id, $0, $1) }
                log("userdata test: back -> \(back ?? "ok"), active \(UserList.load().active), remove -> \(removed ?? "ok"), users \(UserList.load().users.count)")
            }
        }
        // RPCS3_PACKAGES_TEST=1: an invalid package, a licence file, the installed games, trophy dates
        if env["RPCS3_PACKAGES_TEST"] != nil {
            let docs = URL.documentsDirectory
            let junk = docs.appending(path: "test-junk.pkg")
            let rap = docs.appending(path: "TESTLICENSE0000000000000000000000.rap")
            try? Data(repeating: 0x42, count: 4096).write(to: junk)
            try? Data(repeating: 0x17, count: 16).write(to: rap)
            let info = CoreCall.decode(PackageInfo.self, core_package_info(junk.path))
            log("packages test: junk package valid \(info?.valid.description ?? "nil")")
            let failure = CoreCall.message { core_install_packages(junk.path, nil, nil, $0, $1) }
            log("packages test: installing it -> \(failure ?? "accepted!")")
            let license = CoreCall.message { core_install_license(rap.path, $0, $1) }
            let exdata = URL(fileURLWithPath: String(cString: core_emulator_dir())).appending(path: "dev_hdd0/home/\(UserList.load().active)/exdata/\(rap.lastPathComponent)")
            log("packages test: licence -> \(license ?? "ok"), in exdata \(FileManager.default.fileExists(atPath: exdata.path))")
            try? FileManager.default.removeItem(at: exdata)
            try? FileManager.default.removeItem(at: junk)
            try? FileManager.default.removeItem(at: rap)
            let hdd0 = String(cString: core_hdd0_game_dir())
            let folders = (try? FileManager.default.contentsOfDirectory(atPath: hdd0)) ?? []
            log("packages test: dev_hdd0/game \(folders.sorted()), installed games in library \(games.filter(\.isInstalled).map(\.title))")
            if let set = TrophyGame.all().first {
                let earned = (CoreCall.decode([Trophy].self, core_trophies(set.id)) ?? []).filter(\.earned)
                log("packages test: earned trophies \(earned.map { "\($0.name) at \($0.earnedDate?.description ?? "none")" })")
            }
        }
        // RPCS3_REMOVE_DATA=<item>: removes that item (GameData) of the first game, then reports what is left
        if let item = env["RPCS3_REMOVE_DATA"], let game = games.first, let before = gameData(game) {
            let ok = removeData(item, of: game)
            let after = gameData(game)
            log("test hook: removed \(item) of \(game.title): \(ok); PPU \(before.ppuCache) -> \(after?.ppuCache ?? 0), caches \(before.caches) -> \(after?.caches ?? 0)")
        }
        // RPCS3_BUILD_CACHE=<folder in Games>: builds that game's PPU cache (Build PPU Cache Now)
        if let name = env["RPCS3_BUILD_CACHE"], let game = games.first(where: { $0.url.lastPathComponent == name }) {
            log("test hook: building the PPU cache of \(game.title)")
            autoBoot = BootRequest(game: game, buildsPPUCache: true)
        }
        let bootName = env["RPCS3_AUTO_BOOT"]

        let bootIfAsked = { [self] in
            guard let name = bootName, !name.isEmpty else { return }
            refreshGames()
            if let game = games.first(where: { $0.url.lastPathComponent == name }) {
                // RPCS3_AUTO_BOOT_DELAY: seconds to wait first, e.g. to attach a debugger
                let delay = Double(env["RPCS3_AUTO_BOOT_DELAY"] ?? "") ?? 0
                log("test hook: booting \(name) in \(delay) s")
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    // RPCS3_AUTO_BOOT_MODE: 1 global settings, 2 defaults (BootRequest.Mode)
                    let mode = BootRequest.Mode(rawValue: Int32(env["RPCS3_AUTO_BOOT_MODE"] ?? "") ?? 0) ?? .normal
                    MainActor.assumeIsolated { self.autoBoot = BootRequest(game: game, mode: mode) }
                }
            } else {
                log("test hook: no game named \(name) in Games")
            }
        }

        if env["RPCS3_AUTO_FIRMWARE"] == "1", firmwareVersion.isEmpty, let pup = firmwareInDocuments {
            log("test hook: installing \(pup.lastPathComponent)")
            installFirmware(from: pup, then: bootIfAsked)
        } else {
            bootIfAsked()
        }
    }

    // MARK: Firmware

    func installFirmware(from url: URL, then completion: (() -> Void)? = nil) {
        guard coreReady, firmwareProgress == nil else { return }
        firmwareProgress = 0
        let scoped = url.startAccessingSecurityScopedResource()

        Thread.detachNewThread {
            var error = [CChar](repeating: 0, count: 256)
            let code = url.withUnsafeFileSystemRepresentation { path in
                core_install_firmware(path, firmwareProgressCallback, nil, &error, UInt32(error.count))
            }
            if scoped { url.stopAccessingSecurityScopedResource() }
            let message = String(cString: error)

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.firmwareProgress = nil
                    self.firmwareVersion = String(cString: core_firmware_version())
                    self.log(code == 0 ? "firmware \(self.firmwareVersion) installed" : "firmware install failed: \(message)")
                    self.lastMessage = code == 0 ? "Firmware \(self.firmwareVersion) installed." : message
                    if code == 0 { completion?() }
                }
            }
        }
    }

    fileprivate func setFirmwareProgress(_ value: Double) {
        if firmwareProgress != nil { firmwareProgress = value }
    }

    // MARK: Games

    func refreshGames() {
        let installed = coreReady ? String(cString: core_hdd0_game_dir()) : ""
        games = GameLibrary.load(gamesFolder: gamesDirectory, installedFolder: installed.isEmpty ? nil : URL(fileURLWithPath: installed))
    }

    /// A game folder or ISO chosen in the Files app.
    func addGame(from url: URL) {
        if let game = GameLibrary.add(pickedURL: url) {
            refreshGames()
            log("added \(game.title) (\(game.titleID ?? "?")) from \(url.path)")
        } else {
            lastMessage = "That is not a PS3 game. Choose the game's folder (the one containing PS3_GAME or USRDIR), or an ISO file."
        }
    }

    /// Deletes a game installed from a package, with its updates and DLC (dev_hdd0/game/<title ID>*).
    func uninstall(_ game: Game) {
        guard game.isInstalled else { return }
        removeData("installed", of: game)
        refreshGames()
    }

    func remove(_ game: Game) {
        GameLibrary.remove(game)
        refreshGames()
    }

    /// Deletes a game copied into the app's Games folder (its saves and settings stay).
    func deleteGameFiles(_ game: Game) {
        guard !game.isExternal, game.url.path.hasPrefix(gamesDirectory.path) else { return }
        do {
            try FileManager.default.removeItem(at: game.url)
            log("deleted \(game.url.lastPathComponent)")
        } catch {
            lastMessage = "The game could not be deleted: \(error.localizedDescription)"
        }
        refreshGames()
    }

    /// Returns nil when the game started, otherwise a reason.
    func boot(_ request: BootRequest) -> String? {
        guard coreReady else { return "The emulator is not ready." }
        let game = request.game
        guard let url = accessGame(game) else {
            return "The game's location is no longer available. Add it again from the Files app."
        }

        // A config file from the Files app is read at boot: copied where RPCS3 can always reach it
        var configPath = ""
        if let file = request.configFile {
            let scoped = file.startAccessingSecurityScopedResource()
            defer { if scoped { file.stopAccessingSecurityScopedResource() } }
            let copy = FileManager.default.temporaryDirectory.appending(path: "boot-config.yml")
            try? FileManager.default.removeItem(at: copy)
            guard (try? FileManager.default.copyItem(at: file, to: copy)) != nil else {
                releaseGameAccess()
                return "The configuration file could not be read."
            }
            configPath = copy.path
        }

        let result: Int32
        if request.buildsPPUCache {
            log("building the PPU cache of \(game.title)")
            result = core_create_llvm_cache(url.path, game.titleID ?? "")
            if result == 0 { buildingCache = game }
        } else {
            log("booting \(game.title) (\(game.titleID ?? "?")) from \(url.path), mode \(request.mode), savestate \(request.savestate ?? "none")")
            result = core_boot_with(url.path, game.titleID ?? "", request.mode.rawValue, configPath, request.savestate ?? "")
        }
        if result == 0 {
            isRunning = true
            return nil
        }
        releaseGameAccess()
        log("boot failed: \(result)")
        return "The game did not start (error \(result)). See RPCS3.log."
    }

    /// The game's folder or ISO, readable until the game stops (a game chosen in the Files app is
    /// readable only while its security scope is held).
    private func accessGame(_ game: Game) -> URL? {
        guard let bookmark = game.bookmark else { return game.url }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) else { return nil }
        if url.startAccessingSecurityScopedResource() { scopedGameURL = url }
        return url
    }

    // MARK: Game actions (desktop's game menu)

    /// The game whose PPU cache is being built, if any.
    private(set) var buildingCache: Game?

    func gameData(_ game: Game) -> GameData? {
        guard let id = game.titleID, let pointer = core_game_data(id, game.url.path) else { return nil }
        defer { core_free(pointer) }
        return try? JSONDecoder().decode(GameData.self, from: Data(String(cString: pointer).utf8))
    }

    /// Removes one of GameData's items ("config", "input", "shaders", "ppu", "spu", "hdd1",
    /// "caches", "savestates", "savedata", "installed").
    @discardableResult
    func removeData(_ item: String, of game: Game) -> Bool {
        guard let id = game.titleID, !isRunning, buildingCache == nil else { return false }
        let ok = core_game_remove(id, item) == 0
        log("removing \(item) of \(game.title): \(ok ? "done" : "failed")")
        if !ok { lastMessage = "Could not remove all of it. See RPCS3.log." }
        return ok
    }

    /// The version a game runs as: an installed update's (RPCS3 boots a disc game from its update
    /// on the console's drive), otherwise the game's own. Patches are made for one version.
    func appVersion(of game: Game) -> String {
        let own = game.info["APP_VER"] ?? ""
        guard coreReady, let id = game.titleID else { return own }
        let update = URL(fileURLWithPath: String(cString: core_emulator_dir()))
            .appending(path: "dev_hdd0/game/\(id)/PARAM.SFO")
        if let data = try? Data(contentsOf: update), let version = ParamSFO(data: data)?.strings["APP_VER"], !version.isEmpty {
            return version
        }
        return own
    }

    func pause() { core_pause() }
    func resume() { core_resume() }

    func stop() {
        core_stop()
        isRunning = false
        releaseGameAccess()
    }

    private func releaseGameAccess() {
        scopedGameURL?.stopAccessingSecurityScopedResource()
        scopedGameURL = nil
    }

    func dismissMessage() { lastMessage = nil }
}

/// How to start a game: the choices of desktop's game menu.
struct BootRequest: Identifiable, Hashable {
    enum Mode: Int32 {
        case normal = 0      // the game's own settings if it has any, else the global ones
        case global = 1      // the global settings, even if the game has its own
        case defaults = 2    // RPCS3's default settings
        case configFile = 3  // a config file chosen in the Files app
    }

    let game: Game
    var mode: Mode = .normal
    var configFile: URL?
    /// A .SAVESTAT file to resume.
    var savestate: String?
    /// Only compile the game's PPU code ("Create LLVM Cache"): RPCS3 shows its progress on the
    /// game screen and stops when done.
    var buildsPPUCache = false

    var id: String { "\(game.id)|\(mode.rawValue)|\(configFile?.path ?? "")|\(savestate ?? "")|\(buildsPPUCache)" }
}

/// What a game stores (rpcs3_ios_game_data in core/rpcs3_ios.h).
struct GameData: Decodable {
    struct Savestate: Decodable, Hashable, Identifiable {
        let path: String
        let date: Int64
        let size: UInt64
        let compatible: Bool
        var id: String { path }
    }

    let customConfig: Bool
    let customInput: Bool
    let shaderCache, ppuCache, spuCache, hdd1Cache: UInt64
    let saveData, installedData, savestatesSize: UInt64
    let lastSavestate: String
    let savestates: [Savestate]

    var caches: UInt64 { shaderCache + ppuCache + spuCache + hdd1Cache }
}

// C callbacks from the core (any thread).
private func coreEvent(_ event: Int32) {
    DispatchQueue.main.async {
        MainActor.assumeIsolated { Emulator.shared.handle(event: event) }
    }
}

private func firmwareProgressCallback(_ ctx: UnsafeMutableRawPointer?, _ done: UInt32, _ total: UInt32) {
    let value = total > 0 ? Double(done) / Double(total) : 0
    DispatchQueue.main.async {
        MainActor.assumeIsolated { Emulator.shared.setFirmwareProgress(value) }
    }
}
