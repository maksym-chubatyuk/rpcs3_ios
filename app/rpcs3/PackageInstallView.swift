import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// What a picked file is, as the core reads it (rpcs3_ios_package_info in core/rpcs3_ios.h).
struct PackageInfo: Decodable, Hashable {
    let valid: Bool
    var title = ""
    var titleID = ""
    var version = ""
    var category = ""
    var type = ""
    var size: UInt64 = 0
    var installed = ""
    var problem = ""

    enum CodingKeys: String, CodingKey { case valid, title, titleID, version, category, type, size, installed, problem }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        valid = try c.decode(Bool.self, forKey: .valid)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        titleID = try c.decodeIfPresent(String.self, forKey: .titleID) ?? ""
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        size = try c.decodeIfPresent(UInt64.self, forKey: .size) ?? 0
        installed = try c.decodeIfPresent(String.self, forKey: .installed) ?? ""
        problem = try c.decodeIfPresent(String.self, forKey: .problem) ?? ""
    }

    var typeName: String {
        switch type {
        case "game": "Game"
        case "update": "Update"
        case "dlc": "Add-on (DLC)"
        default: "Other content"
        }
    }
}

/// Installing what desktop RPCS3's "Install Packages/Raps/Edats" installs: .pkg files (games,
/// updates, DLC) and licences (.rap) and .edat files for the logged-in user.
@Observable
@MainActor
final class PackageInstaller: Identifiable {
    struct Item: Identifiable {
        enum Kind { case package(PackageInfo), license, unknown }
        let url: URL
        let kind: Kind
        var id: URL { url }
        var name: String { url.lastPathComponent }
    }

    enum State: Equatable {
        case reviewing
        case installing(Double)
        case finished(String, succeeded: Bool)
    }

    let items: [Item]
    private(set) var state = State.reviewing
    private var scopedURLs: [URL] = []

    static let fileTypes: [UTType] = [UTType(filenameExtension: "pkg"), UTType(filenameExtension: "rap"), UTType(filenameExtension: "edat")]
        .compactMap { $0 } + [.data]

    init(urls: [URL]) {
        var scoped: [URL] = []
        items = urls.map { url in
            if url.startAccessingSecurityScopedResource() { scoped.append(url) }
            switch url.pathExtension.lowercased() {
            case "pkg":
                let info = CoreCall.decode(PackageInfo.self, url.withUnsafeFileSystemRepresentation { core_package_info($0) })
                return Item(url: url, kind: info.map { .package($0) } ?? .unknown)
            case "rap", "edat":
                return Item(url: url, kind: .license)
            default:
                return Item(url: url, kind: .unknown)
            }
        }
        scopedURLs = scoped
    }

    /// The valid packages, installed in this order
    var packages: [Item] {
        items.filter { if case .package(let info) = $0.kind { info.valid && info.problem.isEmpty } else { false } }
    }
    var licenses: [Item] {
        items.filter { if case .license = $0.kind { true } else { false } }
    }
    var canInstall: Bool { !packages.isEmpty || !licenses.isEmpty }

    func install() {
        guard state == .reviewing, canInstall else { return }

        // Licences first (as desktop): they unlock the games the packages install
        var notes: [String] = []
        var failed = false
        for item in licenses {
            if let problem = CoreCall.message({ buffer, size in
                item.url.withUnsafeFileSystemRepresentation { core_install_license($0, buffer, size) }
            }) {
                notes.append(problem)
                failed = true
            }
        }
        if !licenses.isEmpty, !failed {
            notes.append(licenses.count == 1 ? "Installed the licence file." : "Installed \(licenses.count) licence files.")
        }

        let paths = packages.map(\.url.path).joined(separator: "\n")
        guard !paths.isEmpty else {
            finish(notes.joined(separator: "\n"), succeeded: !failed)
            return
        }

        state = .installing(0)
        UIApplication.shared.isIdleTimerDisabled = true
        // A few more minutes if the app goes to the background meanwhile
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "Install packages") { core_cancel_install() }

        let context = Unmanaged.passRetained(self).toOpaque()
        Thread.detachNewThread {
            var buffer = [CChar](repeating: 0, count: 1024)
            let code = core_install_packages(paths, packageProgress, context, &buffer, buffer.count)
            let message = String(cString: buffer)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Unmanaged<PackageInstaller>.fromOpaque(context).release()
                    UIApplication.shared.isIdleTimerDisabled = false
                    UIApplication.shared.endBackgroundTask(task)
                    notes.append(message)
                    self.finish(notes.joined(separator: "\n"), succeeded: code == 0 && !failed)
                }
            }
        }
    }

    func cancel() {
        if case .installing = state { core_cancel_install() }
    }

    fileprivate func setProgress(_ value: Double) {
        if case .installing = state { state = .installing(value) }
    }

    private func finish(_ message: String, succeeded: Bool) {
        state = .finished(message, succeeded: succeeded)
        Emulator.shared.log("packages: \(message)")
        Emulator.shared.refreshGames()
        releaseFiles()
    }

    func releaseFiles() {
        scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        scopedURLs = []
    }
}

private func packageProgress(_ ctx: UnsafeMutableRawPointer?, _ done: UInt32, _ total: UInt32) {
    guard let ctx else { return }
    let value = total > 0 ? Double(done) / Double(total) : 0
    let installer = Unmanaged<PackageInstaller>.fromOpaque(ctx).takeUnretainedValue()
    DispatchQueue.main.async {
        MainActor.assumeIsolated { installer.setProgress(value) }
    }
}

/// What will be installed, then the installation's progress and outcome.
struct PackageInstallView: View {
    @State var installer: PackageInstaller
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                switch installer.state {
                case .reviewing:
                    review
                case .installing(let progress):
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: progress)
                            Text("Installing… \(Int(progress * 100))%").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Button("Cancel", role: .destructive) { installer.cancel() }
                    } footer: {
                        Text("Keep RPCS3 open until the installation has finished.")
                    }
                case .finished(let message, let succeeded):
                    Section {
                        Label(message, systemImage: succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(succeeded ? .green : .orange)
                    } footer: {
                        if succeeded && installer.packages.contains(where: { if case .package(let info) = $0.kind { info.type == "game" } else { false } }) {
                            Text("Installed games are in the library.")
                        }
                    }
                }
            }
            .navigationTitle("Install")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isInstalling)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if installer.state == .reviewing {
                        Button("Cancel") { close() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    switch installer.state {
                    case .reviewing:
                        Button("Install") { installer.install() }.disabled(!installer.canInstall)
                    case .installing:
                        ProgressView()
                    case .finished:
                        Button("Done") { close() }
                    }
                }
            }
        }
    }

    private var isInstalling: Bool {
        if case .installing = installer.state { true } else { false }
    }

    private func close() {
        installer.releaseFiles()
        dismiss()
    }

    @ViewBuilder private var review: some View {
        Section {
            ForEach(installer.items) { item in
                row(item)
            }
        } footer: {
            Text("Games bought on PSN also need their licence (a .rap file) to start; pick it together with the package.")
        }
    }

    @ViewBuilder private func row(_ item: PackageInstaller.Item) -> some View {
        switch item.kind {
        case .package(let info) where info.valid:
            VStack(alignment: .leading, spacing: 4) {
                Text(info.title.isEmpty ? item.name : info.title)
                Text([info.typeName, info.titleID.isEmpty ? nil : info.titleID,
                      info.version.isEmpty ? nil : "version \(GameDetailView.version(info.version))",
                      info.size > 0 ? info.size.formatted(.byteCount(style: .file)) : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                if !info.problem.isEmpty {
                    Label("\(info.problem) It is skipped.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                } else if !info.installed.isEmpty {
                    Text(info.installed == "?" ? "Installs over what is already there." : "Version \(GameDetailView.version(info.installed)) is installed now.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        case .license:
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                Text(item.url.pathExtension.lowercased() == "rap" ? "Licence" : "Licensed data (EDAT)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        default:
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                Label("Not a PS3 package, licence or EDAT file; it is skipped.", systemImage: "xmark.circle")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }
}
