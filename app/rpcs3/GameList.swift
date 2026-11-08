import SwiftUI

/// Desktop's game list columns. In landscape they are a table; in portrait each row folds them under the name.
enum GameColumn: String, CaseIterable, Identifiable {
    case name, serial, version, category, lastPlayed, timePlayed, compatibility, size
    var id: Self { self }

    var title: String {
        switch self {
        case .name: "Name"
        case .serial: "Serial"
        case .version: "Version"
        case .category: "Category"
        case .lastPlayed: "Last Played"
        case .timePlayed: "Time Played"
        case .compatibility: "Compatibility"
        case .size: "Size"
        }
    }

    /// Fixed widths in the table; Name takes the rest
    var width: CGFloat? {
        switch self {
        case .name: nil
        case .serial: 80
        case .version: 52
        case .category: 78
        case .lastPlayed: 92
        case .timePlayed: 78
        case .compatibility: 112
        case .size: 62
        }
    }

    /// What fits an iPhone in landscape; the header's long-press menu shows the others
    static let defaultShown = "serial,version,lastPlayed,compatibility,size"
}

/// One game with everything its columns show.
struct GameEntry: Identifiable {
    let game: Game
    let history: PlayHistory.Entry?
    let compatibility: CompatibilityDatabase.Status
    let size: UInt64?
    var id: String { game.id }

    var version: String { game.info["APP_VER"] ?? game.info["VERSION"] ?? "" }

    /// Desktop's category names
    var category: String {
        guard let code = game.info["CATEGORY"] else { return game.isISO ? "Disc Game" : "" }
        switch code {
        case "DG": return "Disc Game"
        case "HG": return "HDD Game"
        case "GD": return "Game Data"
        case "2P": return "PS2 Game"
        case "1P": return "PS1 Game"
        case "PP", "PE": return "PSP Game"
        case "MN": return "PSP Minis"
        case "AP", "AM", "AV", "AT", "CB", "HM", "SF": return "App"
        default: return code
        }
    }

    var lastPlayed: String { history.map { $0.lastPlayed.formatted(date: .abbreviated, time: .omitted) } ?? "Never" }
    var timePlayed: String { PlayHistory.timePlayed(history?.seconds ?? 0) }
    var sizeText: String { size.map { $0.formatted(.byteCount(style: .file)) } ?? "…" }

    static func ordered(_ a: GameEntry, _ b: GameEntry, by column: GameColumn) -> Bool {
        switch column {
        case .name: a.game.title.localizedStandardCompare(b.game.title) == .orderedAscending
        case .serial: (a.game.titleID ?? "") < (b.game.titleID ?? "")
        case .version: a.version < b.version
        case .category: a.category < b.category
        case .lastPlayed: (a.history?.lastPlayed ?? .distantPast) > (b.history?.lastPlayed ?? .distantPast)
        case .timePlayed: (a.history?.seconds ?? 0) > (b.history?.seconds ?? 0)
        case .compatibility: a.compatibility.rank < b.compatibility.rank
        case .size: (a.size ?? 0) > (b.size ?? 0)
        }
    }
}

/// Desktop's tool buttons: a symbol over its name.
struct ToolButton: View {
    let title: String
    let symbol: String
    var enabled = true
    let action: () -> Void

    init(_ title: String, _ symbol: String, enabled: Bool = true, action: @escaping () -> Void = {}) {
        self.title = title
        self.symbol = symbol
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) { ToolLabel(title: title, symbol: symbol) }
            .buttonStyle(.plain)
            .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.5))
            .disabled(!enabled)
    }
}

/// A tool button's look, for menus in the toolbar too.
struct ToolLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .frame(height: 24)
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 50)
        .contentShape(Rectangle())
    }
}

struct CompatibilityLabel: View {
    let status: CompatibilityDatabase.Status

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(status.color).frame(width: 8, height: 8)
            Text(status.title).lineLimit(2)
        }
    }
}

/// Portrait: desktop's columns under the name.
struct GameListRow: View {
    let entry: GameEntry
    let iconWidth: CGFloat

    var body: some View {
        HStack(spacing: 12) {
            GameIcon(game: entry.game, width: iconWidth)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.game.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text([entry.game.titleID, entry.version.isEmpty ? nil : entry.version, entry.category.isEmpty ? nil : entry.category]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    CompatibilityLabel(status: entry.compatibility)
                    Text(entry.sizeText).foregroundStyle(.secondary)
                }
                .font(.caption)
                if let history = entry.history {
                    Text(history.seconds < 60 ? history.lastPlayed.formatted(.relative(presentation: .named))
                         : "\(history.lastPlayed.formatted(.relative(presentation: .named))) · \(entry.timePlayed) played")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

/// Landscape: one row of desktop's table.
struct GameTableRow: View {
    let entry: GameEntry
    let iconWidth: CGFloat
    let columns: Set<GameColumn>

    var body: some View {
        HStack(spacing: 10) {
            GameIcon(game: entry.game, width: iconWidth)
            Text(entry.game.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if columns.contains(.serial) { cell(entry.game.titleID ?? "", .serial) }
            if columns.contains(.version) { cell(entry.version, .version) }
            if columns.contains(.category) { cell(entry.category, .category) }
            if columns.contains(.lastPlayed) { cell(entry.lastPlayed, .lastPlayed) }
            if columns.contains(.timePlayed) { cell(entry.timePlayed, .timePlayed) }
            if columns.contains(.compatibility) {
                CompatibilityLabel(status: entry.compatibility)
                    .frame(width: GameColumn.compatibility.width, alignment: .leading)
            }
            if columns.contains(.size) { cell(entry.sizeText, .size) }
        }
        .font(.caption)
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func cell(_ text: String, _ column: GameColumn) -> some View {
        Text(text).lineLimit(2).frame(width: column.width, alignment: .leading)
    }
}

/// A row's highlight while pressed, as in a UIKit table.
struct RowPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(configuration.isPressed ? Color.primary.opacity(0.1) : .clear)
    }
}

/// A step that is still missing before games can run: JIT or the firmware.
struct SetupRow<Actions: View>: View {
    let symbol: String
    let title: String
    let detail: String
    var tint: Color = .orange
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            actions
                .buttonStyle(.glassProminent)
                .controlSize(.small)
        }
    }
}
