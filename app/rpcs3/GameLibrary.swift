import Foundation

/// A game RPCS3 can boot: a disc game folder (PS3_GAME/USRDIR/EBOOT.BIN), a game folder in
/// HDD layout (USRDIR/EBOOT.BIN), or an ISO. Either inside the app's Games folder or anywhere
/// the Files app reaches (iCloud Drive, On My iPhone, an external drive), kept as a bookmark.
struct Game: Identifiable, Hashable {
    let id: String
    let url: URL
    let title: String
    let titleID: String?
    /// Security-scoped bookmark for a game chosen in the Files app; nil inside the Games folder.
    let bookmark: Data?

    var isExternal: Bool { bookmark != nil }
}

enum GameLibrary {
    private static let bookmarksKey = "externalGameBookmarks"

    /// Games in `folder` and those added from the Files app.
    static func load(gamesFolder folder: URL) -> [Game] {
        var games: [Game] = []

        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for url in items where isBootable(url) {
            games.append(make(url: url, bookmark: nil))
        }

        for bookmark in storedBookmarks() {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) else { continue }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let fresh = stale ? (try? url.bookmarkData()) ?? bookmark : bookmark
            games.append(make(url: url, bookmark: fresh))
        }

        return games.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Adds a folder or ISO chosen in the Files app. Returns nil when it is not a PS3 game.
    static func add(pickedURL url: URL) -> Game? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard isBootable(url), let bookmark = try? url.bookmarkData() else { return nil }

        var bookmarks = storedBookmarks()
        // Replace an earlier bookmark of the same place
        bookmarks.removeAll { existing in
            var stale = false
            return (try? URL(resolvingBookmarkData: existing, bookmarkDataIsStale: &stale))?.standardizedFileURL == url.standardizedFileURL
        }
        bookmarks.append(bookmark)
        UserDefaults.standard.set(bookmarks, forKey: bookmarksKey)
        return make(url: url, bookmark: bookmark)
    }

    /// Forgets a game added from the Files app (its files stay where they are).
    static func remove(_ game: Game) {
        guard let bookmark = game.bookmark else { return }
        var bookmarks = storedBookmarks()
        bookmarks.removeAll { $0 == bookmark }
        UserDefaults.standard.set(bookmarks, forKey: bookmarksKey)
    }

    private static func storedBookmarks() -> [Data] {
        UserDefaults.standard.array(forKey: bookmarksKey) as? [Data] ?? []
    }

    static func isBootable(_ url: URL) -> Bool {
        let fm = FileManager.default
        if url.pathExtension.lowercased() == "iso" { return fm.fileExists(atPath: url.path) }
        return fm.fileExists(atPath: url.appending(path: "PS3_GAME/USRDIR/EBOOT.BIN").path)
            || fm.fileExists(atPath: url.appending(path: "USRDIR/EBOOT.BIN").path)
    }

    private static func make(url: URL, bookmark: Data?) -> Game {
        let sfo = ["PS3_GAME/PARAM.SFO", "PARAM.SFO"]
            .lazy
            .compactMap { try? Data(contentsOf: url.appending(path: $0)) }
            .first
            .flatMap(ParamSFO.init(data:))
        let fallback = url.deletingPathExtension().lastPathComponent
        return Game(id: (bookmark != nil ? "ext:" : "local:") + url.path,
                    url: url,
                    title: sfo?.strings["TITLE"] ?? fallback,
                    titleID: sfo?.strings["TITLE_ID"],
                    bookmark: bookmark)
    }
}

/// The string entries of a PARAM.SFO (the PS3's game metadata file).
struct ParamSFO {
    let strings: [String: String]

    init?(data: Data) {
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }

        guard bytes.count >= 20, bytes[0] == 0, bytes[1] == 0x50, bytes[2] == 0x53, bytes[3] == 0x46 else { return nil }
        let keys = u32(8), values = u32(12), count = u32(16)
        var result: [String: String] = [:]

        for i in 0..<count {
            let entry = 20 + i * 16
            guard entry + 16 <= bytes.count else { break }
            let keyAt = keys + u16(entry), format = u16(entry + 2), length = u32(entry + 4), valueAt = values + u32(entry + 12)
            guard keyAt < bytes.count, valueAt + length <= bytes.count else { continue }
            let keyEnd = bytes[keyAt...].firstIndex(of: 0) ?? bytes.count
            let key = String(decoding: bytes[keyAt..<keyEnd], as: UTF8.self)
            // 0x0204: UTF-8 string, null-terminated
            if format == 0x0204 {
                let raw = bytes[valueAt..<(valueAt + length)]
                let end = raw.firstIndex(of: 0) ?? raw.endIndex
                result[key] = String(decoding: raw[raw.startIndex..<end], as: UTF8.self)
            }
        }
        strings = result
    }
}
