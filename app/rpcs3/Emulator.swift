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

    /// Set by the test hook (RPCS3_AUTO_BOOT): the library opens this game by itself.
    var autoBoot: Game?

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
        runTestHook()
        log("core ready, emulator dir \(String(cString: core_emulator_dir())), firmware '\(firmwareVersion)'")
    }

    fileprivate func handle(event: Int32) {
        switch event {
        case 2, 4: isRunning = true      // run, resume
        case 5: isRunning = false; releaseGameAccess()  // stop
        case 6: lastMessage = "This game needs the PS3 firmware. Install PS3UPDAT.PUP first."
        default: break
        }
    }

    // MARK: Test hook

    /// For scripts/run.sh SETTINGS_SELFTEST=<title ID>: reads every setting, gives the game its own
    /// value for one, checks it, then lets it follow the global settings again. Results in the app log.
    private func settingsSelfTest(game: String) {
        let path = ["Video", "Frame limit"]
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
    }

    /// For scripts/run.sh: RPCS3_AUTO_FIRMWARE=1 installs Documents/PS3UPDAT.PUP when no
    /// firmware is installed; RPCS3_AUTO_BOOT=<folder in Games> then boots that game.
    private func runTestHook() {
        let env = ProcessInfo.processInfo.environment
        if let game = env["RPCS3_SETTINGS_SELFTEST"], !game.isEmpty {
            settingsSelfTest(game: game)
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
                    MainActor.assumeIsolated { self.autoBoot = game }
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
        games = GameLibrary.load(gamesFolder: gamesDirectory)
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

    func remove(_ game: Game) {
        GameLibrary.remove(game)
        refreshGames()
    }

    /// Returns nil when the game started, otherwise a reason.
    func boot(_ game: Game) -> String? {
        guard coreReady else { return "The emulator is not ready." }

        // A game chosen in the Files app stays readable only while its security scope is held
        var url = game.url
        if let bookmark = game.bookmark {
            var stale = false
            guard let resolved = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) else {
                return "The game's location is no longer available. Add it again from the Files app."
            }
            url = resolved
            if url.startAccessingSecurityScopedResource() { scopedGameURL = url }
        }

        log("booting \(game.title) (\(game.titleID ?? "?")) from \(url.path)")
        let result = url.withUnsafeFileSystemRepresentation { core_boot($0) }
        if result == 0 {
            isRunning = true
            return nil
        }
        releaseGameAccess()
        log("boot failed: \(result)")
        return "The game did not start (error \(result)). See RPCS3.log."
    }

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
