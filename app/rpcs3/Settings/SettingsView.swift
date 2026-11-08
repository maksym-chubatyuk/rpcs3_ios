import SwiftUI

/// RPCS3's settings, organised like the desktop settings dialog. For a game, its own settings:
/// each one either follows the global settings or is set for that game only.
struct SettingsView: View {
    @State var store: SettingsStore
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private let layout = SettingsLayout.shared

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    overview
                } else {
                    searchResults
                }
            }
            .navigationTitle(store.gameTitle ?? "Settings")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Settings", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(store.lastError ?? "")
            }
        }
    }

    @ViewBuilder private var overview: some View {
        Section {
            ForEach(layout.tabs, id: \.title) { tab in
                NavigationLink {
                    SettingsTabView(store: store, tab: tab)
                } label: {
                    Label(tab.title, systemImage: Self.symbol(for: tab.title))
                        .badge(changedCount(in: tab))
                }
            }
            NavigationLink {
                OtherSettingsView(store: store)
            } label: {
                Label("Other", systemImage: "ellipsis.circle")
            }
        } footer: {
            if store.gameID != nil {
                Text("Settings this game sets for itself are marked; all others follow the global settings.")
            } else if store.isGameRunning {
                Text("Some settings apply only from the next time a game starts.")
            }
        }
    }

    @ViewBuilder private var searchResults: some View {
        let words = query.lowercased().split(separator: " ")
        let matches = layout.tabs.flatMap { tab in
            tab.groups.flatMap { group in
                group.items.filter { item in
                    let text = "\(item.label) \(group.title) \(tab.title) \(item.description)".lowercased()
                    return words.allSatisfy { text.contains($0) }
                }.map { (tab: tab.title, item: $0) }
            }
        }
        if matches.isEmpty {
            ContentUnavailableView.search(text: query)
        }
        ForEach(matches, id: \.item.path) { match in
            if let setting = store.setting(match.item.path), !SettingsLayout.hidden.contains(match.item.path) {
                Section(match.tab) {
                    SettingRow(store: store, setting: setting, label: match.item.label, description: match.item.description)
                }
            }
        }
    }

    private func changedCount(in tab: SettingsLayout.Tab) -> Int {
        tab.groups.flatMap(\.items).filter { store.setting($0.path)?.isChanged == true && !SettingsLayout.hidden.contains($0.path) }.count
    }

    static func symbol(for tab: String) -> String {
        switch tab {
        case "CPU": "cpu"
        case "GPU": "display"
        case "Audio": "speaker.wave.2"
        case "I/O": "gamecontroller"
        case "System": "gearshape"
        case "Network": "network"
        case "Advanced": "slider.horizontal.3"
        case "Emulator": "square.stack.3d.up"
        case "Debug": "ant"
        default: "folder"
        }
    }
}

/// One tab of the desktop dialog: its groups as sections.
struct SettingsTabView: View {
    let store: SettingsStore
    let tab: SettingsLayout.Tab

    var body: some View {
        List {
            ForEach(tab.groups, id: \.self) { group in
                let rows = group.items.filter { !SettingsLayout.hidden.contains($0.path) }
                if !rows.isEmpty {
                    Section(group.title) {
                        ForEach(rows, id: \.path) { item in
                            if let setting = store.setting(item.path) {
                                SettingRow(store: store, setting: setting, label: item.label, description: item.description)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(tab.title)
    }
}

/// Settings the desktop dialog has no control for, by their place in config.yml.
struct OtherSettingsView: View {
    let store: SettingsStore

    var body: some View {
        let settings = store.otherSettings
        let sections = Dictionary(grouping: settings) { $0.path.dropLast().joined(separator: " › ") }
        List {
            ForEach(sections.keys.sorted(), id: \.self) { section in
                Section(section) {
                    ForEach(sections[section] ?? []) { setting in
                        SettingRow(store: store, setting: setting, label: setting.path.last ?? "", description: "")
                    }
                }
            }
        }
        .navigationTitle("Other")
    }
}

/// One setting, with the control its type needs.
struct SettingRow: View {
    let store: SettingsStore
    let setting: Setting
    let label: String
    let description: String

    @State private var showsDescription = false
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            control
            if setting.isChanged || (store.isGameRunning && !setting.dynamic) {
                HStack(spacing: 6) {
                    if store.gameID != nil, setting.overridden == true {
                        Text("This game").foregroundStyle(.tint)
                    } else if setting.isChanged {
                        Text("Changed").foregroundStyle(.orange)
                    }
                    if store.isGameRunning && !setting.dynamic {
                        Text("Next start").foregroundStyle(.secondary)
                    }
                }
                .font(.caption2.weight(.medium))
            }
        }
        .contextMenu {
            if setting.isChanged {
                Button(store.gameID == nil ? "Reset to Default" : "Use Global Setting", systemImage: "arrow.uturn.backward") {
                    store.reset(setting)
                }
            }
            if !description.isEmpty {
                Button("About This Setting", systemImage: "info.circle") { showsDescription = true }
            }
        }
        .swipeActions(edge: .trailing) {
            if setting.isChanged {
                Button(store.gameID == nil ? "Reset" : "Use Global") { store.reset(setting) }
                    .tint(.orange)
            }
        }
        .sheet(isPresented: $showsDescription) {
            NavigationStack {
                ScrollView {
                    Text(description)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(label)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showsDescription = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder private var control: some View {
        switch setting.type {
        case .bool:
            Toggle(isOn: Binding(get: { setting.value == "true" }, set: { store.set(setting, to: $0 ? "true" : "false") })) {
                title
            }
        case .enum:
            let unavailable = SettingsLayout.unavailableOptions[setting.path] ?? []
            Picker(selection: Binding(get: { setting.value }, set: { store.set(setting, to: $0) })) {
                ForEach((setting.options ?? []).filter { !unavailable.contains($0) || $0 == setting.value }, id: \.self) { option in
                    Text(option).tag(option)
                }
            } label: {
                title
            }
        case .int, .uint, .float:
            NumberField(setting: setting, title: title) { store.set(setting, to: $0) }
        case .string:
            LabeledContent {
                TextField("", text: $text)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { store.set(setting, to: text) }
                    .onAppear { text = setting.value }
                    .onChange(of: setting.value) { _, value in text = value }
            } label: {
                title
            }
        }
    }

    private var title: some View {
        HStack(spacing: 6) {
            Text(label)
            if !description.isEmpty {
                Button {
                    showsDescription = true
                } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("About \(label)")
            }
        }
    }
}

/// A number within the setting's range: a stepper for small ranges, typed otherwise.
private struct NumberField<Title: View>: View {
    let setting: Setting
    let title: Title
    let commit: (String) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    private var range: ClosedRange<Double>? {
        guard let low = setting.min.flatMap(Double.init), let high = setting.max.flatMap(Double.init), low <= high else { return nil }
        return low...high
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                TextField("", text: $text)
                    .keyboardType(setting.type == .float ? .decimalPad : (setting.min?.hasPrefix("-") == true ? .numbersAndPunctuation : .numberPad))
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 90)
                    .focused($focused)
                    .onSubmit(apply)
                    .onChange(of: focused) { _, isFocused in if !isFocused { apply() } }
                if let range, setting.type != .float, range.upperBound - range.lowerBound <= 10_000 {
                    Stepper("", onIncrement: { step(1, in: range) }, onDecrement: { step(-1, in: range) })
                        .labelsHidden()
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                title
                if let low = setting.min, let high = setting.max, (Double(high) ?? 0) < 1e9 {
                    Text("\(Self.short(low)) – \(Self.short(high))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { text = Self.short(setting.value) }
        .onChange(of: setting.value) { _, value in text = Self.short(value) }
    }

    private func step(_ delta: Double, in range: ClosedRange<Double>) {
        let value = min(range.upperBound, max(range.lowerBound, (Double(setting.value) ?? range.lowerBound) + delta))
        commit(String(Int64(value)))
    }

    private func apply() {
        let typed = text.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty, typed != Self.short(setting.value) else { text = Self.short(setting.value); return }
        commit(typed)
    }

    /// "1.000000" -> "1", "0.500000" -> "0.5"
    static func short(_ number: String) -> String {
        guard number.contains("."), !number.contains("e") else { return number }
        var text = number
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
