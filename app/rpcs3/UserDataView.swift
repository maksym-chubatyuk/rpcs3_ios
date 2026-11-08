import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Users, save data and trophies, as desktop RPCS3's user, save data and trophy managers keep them
// (rpcs3_ios_users and the following in core/rpcs3_ios.h).

/// Reading the core's JSON and its messages.
enum CoreCall {
    static func decode<T: Decodable>(_ type: T.Type, _ pointer: UnsafeMutablePointer<CChar>?) -> T? {
        guard let pointer else { return nil }
        defer { core_free(pointer) }
        return try? JSONDecoder().decode(T.self, from: Data(String(cString: pointer).utf8))
    }

    /// Runs a call that reports failure with a message; nil when it worked.
    static func message(_ body: (UnsafeMutablePointer<CChar>, Int) -> Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 512)
        let result = buffer.withUnsafeMutableBufferPointer { body($0.baseAddress!, $0.count) }
        return result == 0 ? nil : String(cString: buffer)
    }
}

// MARK: - Users

struct UserAccount: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
}

struct UserList: Decodable {
    let active: String
    let users: [UserAccount]

    static func load() -> UserList { CoreCall.decode(UserList.self, core_users()) ?? UserList(active: "", users: []) }

    var activeUser: UserAccount? { users.first { $0.id == active } }
}

/// The console's users: each has its own saves and trophies. One is logged in.
struct UsersView: View {
    @State private var list = UserList.load()
    @State private var naming: Naming?
    @State private var name = ""
    @State private var deleting: UserAccount?
    @State private var message: String?

    /// Creating a user, or renaming one.
    private enum Naming: Identifiable {
        case create
        case rename(UserAccount)
        var id: String { if case .rename(let user) = self { user.id } else { "" } }
    }

    var body: some View {
        List {
            Section {
                ForEach(list.users) { user in
                    Button {
                        login(user)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(user.name.isEmpty ? "User" : user.name).foregroundStyle(.primary)
                                Text("ID \(user.id)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if user.id == list.active {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                                    .accessibilityLabel("Logged in")
                            }
                        }
                    }
                    .swipeActions {
                        if user.id != list.active {
                            Button("Delete", role: .destructive) { deleting = user }
                        }
                        Button("Rename") { startNaming(.rename(user)) }
                            .tint(.blue)
                    }
                    .contextMenu {
                        if user.id != list.active {
                            Button("Log In", systemImage: "person.crop.circle.badge.checkmark") { login(user) }
                        }
                        Button("Rename", systemImage: "pencil") { startNaming(.rename(user)) }
                        if user.id != list.active {
                            Button("Delete", systemImage: "trash", role: .destructive) { deleting = user }
                        }
                    }
                }
            } footer: {
                Text("Each user has their own saves and trophies. Games see the logged-in user's name.")
            }
        }
        .navigationTitle("Users")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("New User", systemImage: "plus") { startNaming(.create) }
            }
        }
        .alert(namingTitle, isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $name)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button(namingButton) { finishNaming() }
        } message: {
            Text("3 to 16 letters, digits, underscores or hyphens.")
        }
        .confirmationDialog("Delete \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { user in
            Button("Delete User", role: .destructive) {
                message = CoreCall.message { core_user_remove(user.id, $0, $1) }
                reload()
            }
        } message: { _ in
            Text("Their saves and trophies are deleted with them.")
        }
        .alert("Users", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    private var namingTitle: String {
        if case .rename = naming { "Rename User" } else { "New User" }
    }

    private var namingButton: String {
        if case .rename = naming { "Rename" } else { "Create" }
    }

    private func startNaming(_ what: Naming) {
        if case .rename(let user) = what { name = user.name } else { name = "" }
        naming = what
    }

    private func finishNaming() {
        let text = name.trimmingCharacters(in: .whitespaces)
        switch naming {
        case .create: message = CoreCall.message { core_user_create(text, $0, $1) }
        case .rename(let user): message = CoreCall.message { core_user_rename(user.id, text, $0, $1) }
        case nil: break
        }
        naming = nil
        reload()
    }

    private func login(_ user: UserAccount) {
        guard user.id != list.active else { return }
        message = CoreCall.message { core_user_login(user.id, $0, $1) }
        reload()
    }

    private func reload() { list = UserList.load() }
}

// MARK: - Save data

struct SaveData: Decodable, Identifiable, Hashable {
    let dir: String
    let title: String
    let subtitle: String
    let details: String
    let listParam: String
    let size: UInt64
    let modified: Double
    let icon: String

    var id: String { dir }
    var modifiedDate: Date { Date(timeIntervalSince1970: modified) }
}

struct SaveList: Decodable {
    let dir: String
    let saves: [SaveData]
}

/// Icons from the console's files (ICON0.PNG, TROPxxx.PNG), or a placeholder.
struct FileIcon: View {
    let path: String
    var width: CGFloat = 64
    var aspect: CGFloat = 176.0 / 320.0
    var placeholder = "doc"

    var body: some View {
        Group {
            if !path.isEmpty, let image = UIImage(contentsOfFile: path) {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: placeholder)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
        .frame(width: width, height: width * aspect)
        .clipShape(RoundedRectangle(cornerRadius: width / 16))
        .accessibilityHidden(true)
    }
}

/// The logged-in user's saves: all of them, or one game's. Saves can be deleted, exported to the
/// Files app (to keep them, or for desktop RPCS3 or a PS3) and imported from there.
struct SaveDataView: View {
    /// nil: every game's saves.
    let serial: String?
    let gameTitle: String?

    @State private var saves: [SaveData] = []
    @State private var directory = ""
    @State private var query = ""
    @State private var importing = false
    @State private var exporting: SaveData?
    @State private var deleting: [SaveData] = []
    @State private var replacing: (source: URL, name: String)?
    @State private var details: SaveData?
    @State private var message: String?

    init(serial: String? = nil, gameTitle: String? = nil) {
        self.serial = serial
        self.gameTitle = gameTitle
    }

    var body: some View {
        List {
            if saves.isEmpty {
                ContentUnavailableView {
                    Label("No Save Data", systemImage: "externaldrive")
                } description: {
                    Text(gameTitle.map { "\($0) has no saves yet." } ?? "No game has saved yet.")
                } actions: {
                    Button("Import Save…") { importing = true }
                }
            } else {
                Section {
                    ForEach(filtered) { save in
                        row(save)
                    }
                } footer: {
                    Text("\(saves.count) \(saves.count == 1 ? "save" : "saves"), \(saves.reduce(0) { $0 + $1.size }.formatted(.byteCount(style: .file)))")
                }
            }
        }
        .navigationTitle(gameTitle.map { "Saves: \($0)" } ?? "Save Data")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search saves")
        .refreshable { reload() }
        .onAppear(perform: reload)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Import Save…", systemImage: "square.and.arrow.down") { importing = true }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { importSave(from: url) }
        }
        .sheet(item: $exporting) { save in
            FolderExporter(url: URL(fileURLWithPath: directory).appending(path: save.dir)) { exporting = nil }
                .ignoresSafeArea()
        }
        .sheet(item: $details) { save in
            SaveDetails(save: save)
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                for save in deleting where core_save_remove(save.dir) != 0 {
                    message = "\(save.title) could not be deleted. See RPCS3.log."
                }
                deleting = []
                reload()
            }
        } message: {
            Text("The game's progress in it is lost for good.")
        }
        .confirmationDialog("Replace \(replacing?.name ?? "")?", isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } }),
                            titleVisibility: .visible) {
            Button("Replace", role: .destructive) {
                if let replacing { copySave(from: replacing.source, as: replacing.name, replace: true) }
                replacing = nil
            }
        } message: {
            Text("A save with this name is already there; it is replaced by the imported one.")
        }
        .alert("Save Data", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    private var filtered: [SaveData] {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return saves }
        return saves.filter { save in
            let text = "\(save.title) \(save.subtitle) \(save.details) \(save.dir)".lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    private var deleteTitle: String {
        deleting.count == 1 ? "Delete \(deleting[0].title)?" : "Delete \(deleting.count) saves?"
    }

    private func row(_ save: SaveData) -> some View {
        Button {
            details = save
        } label: {
            HStack(spacing: 12) {
                FileIcon(path: save.icon, width: 80, placeholder: "externaldrive")
                VStack(alignment: .leading, spacing: 2) {
                    Text(save.title).foregroundStyle(.primary).lineLimit(1)
                    if !save.subtitle.isEmpty {
                        Text(save.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text("\(save.modifiedDate.formatted(date: .abbreviated, time: .shortened)) · \(save.size.formatted(.byteCount(style: .file)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .swipeActions {
            Button("Delete", role: .destructive) { deleting = [save] }
            Button("Export") { exporting = save }.tint(.blue)
        }
        .contextMenu {
            Button("Details", systemImage: "info.circle") { details = save }
            Button("Export to Files…", systemImage: "square.and.arrow.up") { exporting = save }
            Button("Copy Name", systemImage: "doc.on.doc") { UIPasteboard.general.string = save.dir }
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = [save] }
        }
    }

    private func reload() {
        let list = CoreCall.decode(SaveList.self, core_saves(serial))
        directory = list?.dir ?? ""
        saves = (list?.saves ?? []).sorted { $0.modified > $1.modified }
    }

    /// A save folder as the PS3 writes it: PARAM.SFO naming its directory, and the game's files.
    private func importSave(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url.appending(path: "PARAM.SFO")), let sfo = ParamSFO(data: data),
              sfo.strings["CATEGORY"] == "SD" || sfo.strings["SAVEDATA_DIRECTORY"] != nil else {
            message = "\(url.lastPathComponent) is not a PS3 save: a save folder holds a PARAM.SFO. Saves exported as PSV files or from a PS3's Copy to USB with encryption are not supported."
            return
        }
        let name = sfo.strings["SAVEDATA_DIRECTORY"].flatMap { $0.isEmpty ? nil : $0 } ?? url.lastPathComponent
        if let serial, !name.hasPrefix(serial) {
            message = "This save is for \(name.prefix(9)), not \(gameTitle ?? serial). Import it from Save Data in the library."
            return
        }
        if FileManager.default.fileExists(atPath: URL(fileURLWithPath: directory).appending(path: name).path) {
            replacing = (url, name)
            return
        }
        copySave(from: url, as: name, replace: false)
    }

    private func copySave(from url: URL, as name: String, replace: Bool) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let target = URL(fileURLWithPath: directory).appending(path: name)
        let staging = URL(fileURLWithPath: directory).appending(path: ".import-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: URL(fileURLWithPath: directory), withIntermediateDirectories: true)
            try fm.copyItem(at: url, to: staging)
            if replace, fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: target)
            }
            message = "Imported \(name)."
        } catch {
            try? fm.removeItem(at: staging)
            message = "The save could not be imported: \(error.localizedDescription)"
        }
        reload()
    }
}

private struct SaveDetails: View {
    let save: SaveData
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Spacer()
                        FileIcon(path: save.icon, width: 240, placeholder: "externaldrive")
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
                Section {
                    LabeledContent("Title", value: save.title)
                    if !save.subtitle.isEmpty { LabeledContent("Subtitle", value: save.subtitle) }
                    if !save.details.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Details").font(.subheadline).foregroundStyle(.secondary)
                            Text(save.details)
                        }
                    }
                }
                Section {
                    LabeledContent("Saved", value: save.modifiedDate.formatted(date: .long, time: .shortened))
                    LabeledContent("Size", value: save.size.formatted(.byteCount(style: .file)))
                    LabeledContent("Directory", value: save.dir)
                        .textSelection(.enabled)
                    if !save.listParam.isEmpty { LabeledContent("List Parameter", value: save.listParam) }
                }
            }
            .navigationTitle(save.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Copies a folder to a place the user picks in the Files app.
struct FolderExporter: UIViewControllerRepresentable {
    let url: URL
    let done: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let done: () -> Void
        init(done: @escaping () -> Void) { self.done = done }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { done() }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { done() }
    }
}

// MARK: - Trophies

struct TrophyGame: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String
    let total: Int
    let earned: Int
    let platinum: [Int]
    let gold: [Int]
    let silver: [Int]
    let bronze: [Int]

    var progress: Double { total > 0 ? Double(earned) / Double(total) : 0 }

    static func all() -> [TrophyGame] {
        (CoreCall.decode([TrophyGame].self, core_trophy_games()) ?? [])
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct Trophy: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let detail: String
    let grade: String
    let hidden: Bool
    let earned: Bool
    let time: Double
    let icon: String
    let group: String

    var earnedDate: Date? { time > 0 ? Date(timeIntervalSince1970: time) : nil }
}

/// A trophy grade's symbol, in its colour.
struct TrophyGradeIcon: View {
    let grade: String

    var body: some View {
        Image(systemName: "trophy.fill")
            .foregroundStyle(Self.color(grade))
            .accessibilityLabel(grade.capitalized)
    }

    static func color(_ grade: String) -> Color {
        switch grade {
        case "platinum": Color(red: 0.55, green: 0.72, blue: 0.85)
        case "gold": Color(red: 0.85, green: 0.65, blue: 0.13)
        case "silver": Color(white: 0.62)
        case "bronze": Color(red: 0.72, green: 0.45, blue: 0.2)
        default: .secondary
        }
    }
}

/// Every game the logged-in user has trophies for.
struct TrophyGamesView: View {
    @State private var games: [TrophyGame] = []
    @State private var removing: TrophyGame?

    var body: some View {
        List {
            if games.isEmpty {
                ContentUnavailableView("No Trophies", systemImage: "trophy",
                                       description: Text("A game's trophies appear here once it has been started."))
            }
            ForEach(games) { game in
                NavigationLink {
                    TrophyListView(communicationID: game.id, title: game.name)
                } label: {
                    TrophyGameRow(game: game)
                }
                .contextMenu {
                    Button("Copy Communication ID", systemImage: "doc.on.doc") { UIPasteboard.general.string = game.id }
                    Button("Remove Trophy Data", systemImage: "trash", role: .destructive) { removing = game }
                }
            }
        }
        .navigationTitle("Trophies")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { games = TrophyGame.all() }
        .refreshable { games = TrophyGame.all() }
        .confirmationDialog("Remove the trophy data of \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { game in
            Button("Remove", role: .destructive) {
                _ = core_trophy_game_remove(game.id)
                games = TrophyGame.all()
            }
        } message: { _ in
            Text("Every trophy earned in it is lost. The game sets its trophies up again the next time it starts.")
        }
    }
}

struct TrophyGameRow: View {
    let game: TrophyGame

    var body: some View {
        HStack(spacing: 12) {
            FileIcon(path: game.icon, width: 80, placeholder: "trophy")
            VStack(alignment: .leading, spacing: 4) {
                Text(game.name).lineLimit(2)
                ProgressView(value: game.progress)
                HStack(spacing: 10) {
                    Text("\(Int(game.progress * 100))% · \(game.earned)/\(game.total)")
                    Spacer()
                    ForEach([("platinum", game.platinum), ("gold", game.gold), ("silver", game.silver), ("bronze", game.bronze)], id: \.0) { grade, counts in
                        if counts.count == 2, counts[1] > 0 {
                            HStack(spacing: 2) {
                                TrophyGradeIcon(grade: grade)
                                Text("\(counts[0])")
                            }
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// One game's trophies, with when each was earned.
struct TrophyListView: View {
    let communicationID: String
    let title: String

    private enum Filter: String, CaseIterable {
        case all = "All", earned = "Earned", notEarned = "Not Earned"
    }

    @State private var trophies: [Trophy] = []
    @AppStorage("trophiesShowHidden") private var showHidden = false
    @State private var filter = Filter.all
    @State private var changing: Trophy?
    @State private var message: String?

    var body: some View {
        List {
            if trophies.isEmpty {
                ContentUnavailableView("No Trophies", systemImage: "trophy",
                                       description: Text("\(title)'s trophies appear here once it has been started."))
            } else {
                Section {
                    let earned = trophies.filter(\.earned).count
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: Double(earned), total: Double(trophies.count))
                        Text("\(earned * 100 / max(trophies.count, 1))% · \(earned) of \(trophies.count) earned")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Picker("Show", selection: $filter) {
                        ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Show Hidden Trophies", isOn: $showHidden)
                }
                let groups = Dictionary(grouping: shown, by: \.group)
                ForEach(groups.keys.sorted(), id: \.self) { group in
                    Section(group.isEmpty ? (groups.count > 1 ? "Base Game" : "") : group) {
                        ForEach(groups[group] ?? []) { trophy in
                            row(trophy)
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .refreshable { reload() }
        .confirmationDialog(changing.map { $0.earned ? "Mark \($0.name) as not earned?" : "Mark \($0.name) as earned?" } ?? "",
                            isPresented: Binding(get: { changing != nil }, set: { if !$0 { changing = nil } }),
                            titleVisibility: .visible, presenting: changing) { trophy in
            Button(trophy.earned ? "Mark as Not Earned" : "Mark as Earned", role: trophy.earned ? .destructive : nil) {
                if core_trophy_set_earned(communicationID, Int32(trophy.id), trophy.earned ? 0 : 1) != 0 {
                    message = "The trophy could not be changed. Stop the game first, or see RPCS3.log."
                }
                reload()
            }
        } message: { _ in
            Text("This changes the trophy record of this user only, not what the game itself knows.")
        }
        .alert("Trophies", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    private var shown: [Trophy] {
        trophies.filter { trophy in
            switch filter {
            case .all: true
            case .earned: trophy.earned
            case .notEarned: !trophy.earned
            }
        }
    }

    @ViewBuilder private func row(_ trophy: Trophy) -> some View {
        let concealed = trophy.hidden && !trophy.earned && !showHidden
        HStack(spacing: 12) {
            FileIcon(path: concealed ? "" : trophy.icon, width: 52, aspect: 1, placeholder: concealed ? "questionmark" : "trophy")
                .opacity(trophy.earned ? 1 : 0.45)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    TrophyGradeIcon(grade: trophy.grade).font(.caption)
                    Text(concealed ? "Hidden Trophy" : trophy.name).lineLimit(2)
                }
                if !concealed, !trophy.detail.isEmpty {
                    Text(trophy.detail).font(.caption).foregroundStyle(.secondary)
                }
                if let date = trophy.earnedDate {
                    Text("Earned \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if trophy.earned {
                    Text("Earned").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .contextMenu {
            Button(trophy.earned ? "Mark as Not Earned" : "Mark as Earned", systemImage: trophy.earned ? "xmark.circle" : "checkmark.circle") {
                changing = trophy
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func reload() {
        trophies = (CoreCall.decode([Trophy].self, core_trophies(communicationID)) ?? []).sorted { $0.id < $1.id }
    }
}

extension Game {
    /// The trophy sets the game brings (TROPDIR/NPWR00000_00), by communication ID.
    var trophyIDs: [String] {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        for folder in [url.appending(path: "PS3_GAME/TROPDIR"), url.appending(path: "TROPDIR")] {
            if let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path), !names.isEmpty {
                return names.filter { !$0.hasPrefix(".") }.sorted()
            }
        }
        return []
    }
}
