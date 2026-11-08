import Foundation
import SwiftUI

/// rpcs3.net's compatibility list, the same export desktop downloads (its compat_database.dat),
/// kept in Application Support and refreshed with the game list.
@Observable
final class CompatibilityDatabase {
    static let shared = CompatibilityDatabase()

    /// Desktop's status names and colours (game_compatibility.h)
    enum Status: Equatable {
        case playable, ingame, intro, loadable, nothing, noResult, missing, downloading

        init(_ name: String) {
            switch name {
            case "Playable": self = .playable
            case "Ingame": self = .ingame
            case "Intro": self = .intro
            case "Loadable": self = .loadable
            case "Nothing": self = .nothing
            default: self = .noResult
            }
        }

        var title: String {
            switch self {
            case .playable: "Playable"
            case .ingame: "Ingame"
            case .intro: "Intro"
            case .loadable: "Loadable"
            case .nothing: "Nothing"
            case .noResult: "No results found"
            case .missing: "Database missing"
            case .downloading: "Retrieving database"
            }
        }

        var color: Color {
            switch self {
            case .playable: Color(red: 0x1e / 255, green: 0xbc / 255, blue: 0x61 / 255)
            case .ingame: Color(red: 0xf9 / 255, green: 0xb3 / 255, blue: 0x2f / 255)
            case .intro: Color(red: 0xe0 / 255, green: 0x8a / 255, blue: 0x1e / 255)
            case .loadable: Color(red: 0xe7 / 255, green: 0x4c / 255, blue: 0x3c / 255)
            case .nothing: Color(red: 0x45 / 255, green: 0x55 / 255, blue: 0x56 / 255)
            case .noResult, .missing, .downloading: .gray
            }
        }

        /// Best first, as desktop sorts the column
        var rank: Int {
            switch self {
            case .playable: 0
            case .ingame: 1
            case .intro: 2
            case .loadable: 3
            case .nothing: 4
            case .noResult: 5
            case .missing, .downloading: 6
            }
        }
    }

    private(set) var statuses: [String: String] = [:]
    private(set) var downloading = false
    private(set) var downloadedAt: Date?

    private static let url = URL(string: "https://rpcs3.net/compatibility?api=v1&export")!
    private static var file: URL { URL.applicationSupportDirectory.appending(path: "compat_database.json") }

    func status(of serial: String?) -> Status {
        if statuses.isEmpty { return downloading ? .downloading : .missing }
        guard let serial, let name = statuses[serial] else { return .noResult }
        return Status(name)
    }

    /// Reads the saved database, or downloads it the first time.
    func load() {
        let file = Self.file
        Task {
            let parsed = await Task.detached { (try? Data(contentsOf: file)).flatMap(Self.parse) }.value
            if let parsed {
                statuses = parsed
                downloadedAt = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
            } else {
                await download()
            }
        }
    }

    /// Downloads the database again, at most once an hour.
    func refresh() {
        if let downloadedAt, downloadedAt.timeIntervalSinceNow > -3600 { return }
        Task { await download() }
    }

    private func download() async {
        guard !downloading else { return }
        downloading = true
        defer { downloading = false }
        do {
            let (data, _) = try await URLSession.shared.data(from: Self.url)
            guard let parsed = await Task.detached(operation: { Self.parse(data) }).value else {
                Emulator.shared.log("compatibility database: unusable answer")
                return
            }
            try FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
            try data.write(to: Self.file, options: .atomic)
            statuses = parsed
            downloadedAt = .now
            Emulator.shared.log("compatibility database: \(parsed.count) games")
        } catch {
            Emulator.shared.log("compatibility database: \(error.localizedDescription)")
        }
    }

    /// {"return_code": 0, "results": {"BLUS30919": {"status": "Playable", ...}}} → serial: status
    nonisolated private static func parse(_ data: Data) -> [String: String]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["return_code"] as? Int) ?? -1 >= 0,
              let results = json["results"] as? [String: Any] else { return nil }
        var statuses: [String: String] = [:]
        statuses.reserveCapacity(results.count)
        for (serial, entry) in results {
            if let status = (entry as? [String: Any])?["status"] as? String { statuses[serial] = status }
        }
        return statuses.isEmpty ? nil : statuses
    }
}

/// When each game was last played and for how long in all, as desktop's persistent settings keep them.
enum PlayHistory {
    private static let storageKey = "playHistory"

    struct Entry: Codable {
        var lastPlayed: Date
        var seconds: Int
    }

    static func all() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    /// A game started: it is the last played from now on.
    static func started(_ game: Game) {
        update(game) { $0.lastPlayed = .now }
    }

    /// A game stopped after `seconds`.
    static func stopped(_ game: Game, after seconds: TimeInterval) {
        update(game) { $0.seconds += max(0, Int(seconds)) }
    }

    private static func update(_ game: Game, _ change: (inout Entry) -> Void) {
        var entries = all()
        let id = key(for: game)
        var entry = entries[id] ?? Entry(lastPlayed: .now, seconds: 0)
        change(&entry)
        entries[id] = entry
        if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: storageKey) }
    }

    /// By serial, so a game keeps its history wherever it is; by place for games without one
    static func key(for game: Game) -> String { game.titleID ?? game.id }

    static func timePlayed(_ seconds: Int) -> String {
        guard seconds > 0 else { return "Never" }
        if seconds < 60 { return "\(seconds) s" }
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}

/// How much space each game takes, measured in the background as desktop does.
@Observable
final class GameSizes {
    static let shared = GameSizes()
    private(set) var bytes: [String: UInt64] = [:]
    private var measuring: Set<String> = []

    func measure(_ games: [Game]) {
        for game in games where bytes[game.id] == nil && !measuring.contains(game.id) {
            measuring.insert(game.id)
            let url = game.url, external = game.isExternal, id = game.id
            Task {
                let size = await Task.detached(priority: .utility) { Self.size(of: url, scoped: external) }.value
                bytes[id] = size
                measuring.remove(id)
            }
        }
    }

    /// After a refresh, so changed games are measured again
    func reset() { bytes = [:] }

    nonisolated private static func size(of url: URL, scoped: Bool) -> UInt64 {
        let access = scoped && url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        if let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true {
            return UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        var total: UInt64 = 0
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)
        while let file = files?.nextObject() as? URL {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}
