import SwiftUI

/// RPCS3's logs, as desktop's log and TTY panes show them, and sharing them for a bug report.
struct LogView: View {
    enum File: String, CaseIterable, Identifiable {
        case rpcs3 = "RPCS3.log", tty = "TTY.log", app = "App"
        var id: Self { self }

        var url: URL {
            switch self {
            case .rpcs3, .tty: URL(fileURLWithPath: String(cString: core_log_dir())).appending(path: rawValue)
            case .app: URL.documentsDirectory.appending(path: "rpcs3-app.log")
            }
        }

        var about: String {
            switch self {
            case .rpcs3: "What the emulator did: the log RPCS3's developers ask for with a bug report."
            case .tty: "What the game itself printed."
            case .app: "What the app did: JIT, loading the emulator, installs."
            }
        }
    }

    enum Level: String, CaseIterable, Identifiable {
        case all = "All", warnings = "Warnings and Errors", errors = "Errors"
        var id: Self { self }
    }

    struct Line: Identifiable {
        let id: Int
        let text: String
        /// RPCS3's level letter after the '·' that starts a line: F fatal, E error, U unimplemented, W warning, S success, ! notice
        var level: Character? {
            guard text.first == "·", text.count > 1 else { return nil }
            return text[text.index(after: text.startIndex)]
        }
    }

    @State private var file = File.rpcs3
    @State private var level = Level.all
    @State private var query = ""
    @State private var lines: [Line] = []
    @State private var size: UInt64 = 0
    @State private var truncated = false

    /// The end of a long log: RPCS3.log grows to hundreds of megabytes
    private static let tail = 2 << 20

    var body: some View {
        List {
            Section {
                Picker("Log", selection: $file) {
                    ForEach(File.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                if file == .rpcs3 {
                    Picker("Show", selection: $level) {
                        ForEach(Level.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
            } footer: {
                Text(file.about + (truncated ? " The last \(Int64(Self.tail).formatted(.byteCount(style: .file))) of \(size.formatted(.byteCount(style: .file))) are shown; sharing sends all of it." : ""))
            }

            let shown = filtered
            if shown.isEmpty {
                ContentUnavailableView(lines.isEmpty ? "Empty" : "No Matches", systemImage: "doc.plaintext",
                                       description: Text(lines.isEmpty ? "Nothing has been written to this log yet." : "No line matches."))
            } else {
                Section {
                    ForEach(shown) { line in
                        Text(line.text)
                            .font(.caption.monospaced())
                            .foregroundStyle(color(line.level))
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search the log")
        .refreshable { load() }
        .onAppear(perform: load)
        .onChange(of: file) { load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if FileManager.default.fileExists(atPath: file.url.path) {
                    ShareLink(item: file.url) { Label("Share", systemImage: "square.and.arrow.up") }
                }
            }
        }
    }

    private var filtered: [Line] {
        let words = query.lowercased().split(separator: " ")
        return lines.filter { line in
            switch level {
            case .all: break
            case .warnings: guard let l = line.level, "FEUW".contains(l) else { return false }
            case .errors: guard let l = line.level, "FE".contains(l) else { return false }
            }
            guard !words.isEmpty else { return true }
            let text = line.text.lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    private func color(_ level: Character?) -> Color {
        switch level {
        case "F", "E": .red
        case "U": .purple
        case "W": .orange
        case "S": .green
        default: .primary
        }
    }

    private func load() {
        let url = file.url
        size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            lines = []
            truncated = false
            return
        }
        defer { try? handle.close() }
        truncated = size > UInt64(Self.tail)
        if truncated { try? handle.seek(toOffset: size - UInt64(Self.tail)) }
        let data = (try? handle.readToEnd()) ?? Data()
        var text = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        if truncated, !text.isEmpty { text.removeFirst() } // a cut line
        // The newest last, as the log is written; at most the last 5000 lines for a quick list
        lines = text.suffix(5000).enumerated().map { Line(id: $0.offset, text: String($0.element)) }
    }
}
