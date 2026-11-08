import Observation
import SwiftUI

/// The seven players' controls, globally or for one game (rpcs3_ios_controls in core/rpcs3_ios.h).
@Observable
@MainActor
final class ControlsStore {
    struct Player {
        var settings: [[String]: Setting]
        var handler: String { settings[["Handler"]]?.value ?? "Null" }
        var device: String { settings[["Device"]]?.value ?? "" }
        var isConnected: Bool { handler != "Null" }
    }

    /// nil: the global controls.
    let gameID: String?
    private(set) var players: [Player] = []
    private(set) var devices: [String] = []
    private(set) var buttons: [String] = []
    private(set) var isGameRunning = false
    private(set) var gameHasOwn = false
    var lastError: String?

    /// The app's controller as RPCS3 sees it (core/rpcs3_ios.mm): touch controls and the first physical controller
    static let virtualPad = "RPCS3 Virtual Pad 1"

    init(gameID: String?) {
        self.gameID = gameID
        reload()
    }

    func reload() {
        guard let pointer = gameID.withCStringOrNull({ core_controls($0) }) else { return }
        defer { core_free(pointer) }

        struct Reply: Decodable {
            struct PlayerReply: Decodable { let settings: [Setting] }
            let running: Bool
            let gameHasOwn: Bool
            let devices: [String]
            let buttons: [String]
            let players: [PlayerReply]
        }

        do {
            let reply = try JSONDecoder().decode(Reply.self, from: Data(String(cString: pointer).utf8))
            isGameRunning = reply.running
            gameHasOwn = reply.gameHasOwn
            devices = reply.devices
            buttons = reply.buttons
            players = reply.players.map { player in
                Player(settings: Dictionary(player.settings.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first }))
            }
        } catch {
            lastError = "The controls could not be read: \(error.localizedDescription)"
        }
    }

    func set(player: Int, _ path: [String], to value: String) {
        var error = [CChar](repeating: 0, count: 512)
        let result = gameID.withCStringOrNull { game in
            core_control_set(game, Int32(player), path.joined(separator: "\n"), value, &error, error.count)
        }
        if result != 0 { lastError = String(cString: error) }
        reload()
    }

    /// Connects a player to a device ("" for none).
    func connect(player: Int, to device: String) {
        if device.isEmpty {
            set(player: player, ["Handler"], to: "Null")
            return
        }
        if players[player].handler != "SDL" {
            set(player: player, ["Handler"], to: "SDL")
        }
        set(player: player, ["Device"], to: device)
    }

    func editor(for player: Int) -> PlayerEditor { PlayerEditor(store: self, player: player) }

    static func name(of device: String) -> String {
        device == virtualPad ? "On-screen controls & controller" : device
    }
}

/// Edits one player's entries through the settings rows.
@MainActor
final class PlayerEditor: SettingsEditing {
    let store: ControlsStore
    let player: Int

    init(store: ControlsStore, player: Int) {
        self.store = store
        self.player = player
    }

    var isGameScope: Bool { store.gameID != nil }
    var isGameRunning: Bool { false } // controls apply at once, also while a game runs
    func set(_ setting: Setting, to value: String) { store.set(player: player, setting.path, to: value) }
    func reset(_ setting: Setting) { store.set(player: player, setting.path, to: setting.reset) }
}

private extension Optional where Wrapped == String {
    func withCStringOrNull<Result>(_ body: (UnsafePointer<CChar>?) -> Result) -> Result {
        switch self {
        case .some(let text): text.withCString { body($0) }
        case .none: body(nil)
        }
    }
}

/// The players, and what each is connected to.
struct ControlsView: View {
    let gameID: String?
    let gameTitle: String?
    @State private var store: ControlsStore
    @State private var editingLayout = false
    @State private var ownLayout = false
    @Environment(\.dismiss) private var dismiss

    init(gameID: String? = nil, gameTitle: String? = nil) {
        self.gameID = gameID
        self.gameTitle = gameTitle
        _store = State(initialValue: ControlsStore(gameID: gameID))
    }

    var body: some View {
        List {
            if gameID != nil {
                Section {
                    Text(store.gameHasOwn
                         ? "\(gameTitle ?? "This game") has its own controls."
                         : "\(gameTitle ?? "This game") uses the global controls. Changing anything here gives it its own, starting from the global ones.")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(store.players.indices, id: \.self) { index in
                    NavigationLink {
                        PlayerControlsView(store: store, player: index)
                    } label: {
                        LabeledContent("Player \(index + 1)") {
                            Text(store.players[index].isConnected ? ControlsStore.name(of: store.players[index].device) : "Not connected")
                        }
                    }
                }
            } footer: {
                Text("Player 1 is normally the on-screen controls together with the first controller connected to the iPhone. Other controllers can be given to other players.")
            }
            Section {
                Button("Edit Layout…", systemImage: "rectangle.and.hand.point.up.left") { editingLayout = true }
                if let gameID, ownLayout {
                    Button("Use the Layout for All Games", systemImage: "arrow.uturn.backward") {
                        TouchLayout.removeOwn(gameID)
                        ownLayout = false
                    }
                }
            } header: {
                Text("On-Screen Controls")
            } footer: {
                Text(gameID == nil
                     ? "Where the on-screen buttons are, their size and opacity, for all games. A game can have a layout of its own, set on its page."
                     : ownLayout ? "This game has its own layout of the on-screen buttons." : "This game uses the layout for all games.")
            }
            if !store.devices.isEmpty {
                Section("Connected Controllers") {
                    ForEach(store.devices, id: \.self) { device in
                        Label(ControlsStore.name(of: device), systemImage: device == ControlsStore.virtualPad ? "hand.tap" : "gamecontroller")
                    }
                }
            }
        }
        .navigationTitle(gameTitle.map { "Controls: \($0)" } ?? "Controls")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { store.reload() }
        .onAppear { ownLayout = gameID.map(TouchLayout.hasOwn) ?? false }
        .fullScreenCover(isPresented: $editingLayout, onDismiss: { ownLayout = gameID.map(TouchLayout.hasOwn) ?? false }) {
            TouchLayoutEditor(gameID: gameID, gameTitle: gameTitle)
        }
        .alert("Controls", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.lastError ?? "")
        }
    }
}

/// One player: the device, the button mapping, and how sticks, triggers and vibration behave.
struct PlayerControlsView: View {
    let store: ControlsStore
    let player: Int

    private var settings: [[String]: Setting] { store.players.indices.contains(player) ? store.players[player].settings : [:] }

    // The PS3 controller, as RPCS3's pad config names its buttons
    private static let buttons = ["Cross", "Circle", "Square", "Triangle", "L1", "L2", "L3", "R1", "R2", "R3", "Start", "Select", "PS Button", "Up", "Down", "Left", "Right"]
    private static let leftStick = ["Left Stick Up", "Left Stick Down", "Left Stick Left", "Left Stick Right"]
    private static let rightStick = ["Right Stick Up", "Right Stick Down", "Right Stick Left", "Right Stick Right"]

    var body: some View {
        if store.players.indices.contains(player) {
            playerList
        } else {
            ContentUnavailableView("No Controls", systemImage: "gamecontroller", description: Text("The controls could not be read."))
        }
    }

    private var playerList: some View {
        List {
            Section {
                Picker("Connected To", selection: Binding(
                    get: { store.players[player].isConnected ? store.players[player].device : "" },
                    set: { store.connect(player: player, to: $0) })) {
                    Text("Nothing").tag("")
                    ForEach(deviceChoices, id: \.self) { device in
                        Text(ControlsStore.name(of: device)).tag(device)
                    }
                }
            } footer: {
                if !store.players[player].isConnected {
                    Text("Connect a controller to the iPhone to give it to this player.")
                }
            }

            if store.players[player].isConnected {
                Section("Buttons") {
                    ForEach(Self.buttons, id: \.self) { mappingRow($0) }
                }
                Section("Left Stick") {
                    DisclosureGroup("Directions") {
                        ForEach(Self.leftStick, id: \.self) { mappingRow($0) }
                    }
                    rows(["Left Stick Deadzone", "Left Stick Anti-Deadzone", "Left Stick Multiplier"])
                }
                Section("Right Stick") {
                    DisclosureGroup("Directions") {
                        ForEach(Self.rightStick, id: \.self) { mappingRow($0) }
                    }
                    rows(["Right Stick Deadzone", "Right Stick Anti-Deadzone", "Right Stick Multiplier"])
                }
                Section("Triggers") {
                    rows(["Left Trigger Threshold", "Right Trigger Threshold"])
                }
                Section("Vibration") {
                    rows(["Large Vibration Motor Multiplier", "Small Vibration Motor Multiplier", "Switch Vibration Motors", "Vibration Threshold"])
                }
                Section {
                    mappingRow("Pressure Intensity Button")
                    rows(["Pressure Intensity Percent", "Pressure Intensity Toggle Mode", "Pressure Intensity Deadzone"])
                } header: {
                    Text("Pressure-Sensitive Buttons")
                } footer: {
                    Text("Holding the button makes the PS3 buttons report the set pressure, for games that read how hard a button is pressed.")
                }
                Section {
                    mappingRow("Analog Limiter Button")
                    rows(["Analog Limiter Toggle Mode"])
                } header: {
                    Text("Analog Limiter")
                } footer: {
                    Text("Holding the button limits the sticks, for walking instead of running.")
                }
                Section {
                    DisclosureGroup("Advanced") {
                        rows(["Left Pad Squircling Factor", "Right Pad Squircling Factor", "Left Stick Lerp Factor", "Right Stick Lerp Factor",
                              "Analog Button Lerp Factor", "Trigger Lerp Factor", "Device Class Type"])
                    }
                }
            }
        }
        .navigationTitle("Player \(player + 1)")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var deviceChoices: [String] {
        var choices = store.devices
        // The current device even if it is not connected now
        let current = store.players[player].device
        if store.players[player].isConnected, !current.isEmpty, !choices.contains(current) { choices.append(current) }
        return choices
    }

    /// Which of the device's buttons a PS3 button is.
    @ViewBuilder private func mappingRow(_ name: String) -> some View {
        if let setting = settings[["Config", name]] {
            let choices = (store.buttons + [setting.value]).filter { !$0.isEmpty }
            Picker(name, selection: Binding(get: { setting.value }, set: { store.set(player: player, setting.path, to: $0) })) {
                Text("None").tag("")
                ForEach(Array(Set(choices)).sorted(), id: \.self) { button in
                    Text(button).tag(button)
                }
            }
            .contextMenu {
                if setting.value != setting.reset {
                    Button("Reset to Default", systemImage: "arrow.uturn.backward") {
                        store.set(player: player, setting.path, to: setting.reset)
                    }
                }
            }
        }
    }

    @ViewBuilder private func rows(_ names: [String]) -> some View {
        let editor = store.editor(for: player)
        ForEach(names, id: \.self) { name in
            if let setting = settings[["Config", name]] {
                SettingRow(store: editor, setting: setting, label: name, description: "")
            }
        }
    }
}
