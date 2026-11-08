import Darwin
import Foundation
import Security

/// JIT without a Mac: the bundled rpcs3JITHelper extension attaches StikJIT's debugger to this app
/// through LocalDevVPN, using this iPhone's pairing file. Once attached, the app asks for its JIT
/// memory exactly as it does with scripts/run.sh (rpcs3/JIT/JITPool.c).
@MainActor
enum OnDeviceJIT {
    enum Failure: LocalizedError {
        case text(String)
        var errorDescription: String? {
            switch self { case .text(let text): text }
        }
    }

    // MARK: Pairing file

    /// The pairing file is a credential for this iPhone, so it lives in the Keychain. One copied into
    /// Documents as pairingFile.plist (Files app, or `devicectl device copy to` from a Mac) is moved there.
    private static let keychainItem: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "rpcs3.pairing-file",
        kSecAttrAccount as String: "this-iphone",
    ]

    private static var droppedFile: URL { URL.documentsDirectory.appending(path: "pairingFile.plist") }

    static var hasPairingFile: Bool { pairingFile() != nil }

    static func pairingFile() -> Data? {
        if let dropped = try? Data(contentsOf: droppedFile), (try? store(dropped)) != nil {
            try? FileManager.default.removeItem(at: droppedFile)
        }
        var query = keychainItem
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess else { return nil }
        return found as? Data
    }

    static func importPairingFile(from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try store(try Data(contentsOf: url))
    }

    static func forgetPairingFile() {
        SecItemDelete(keychainItem as CFDictionary)
    }

    private static func store(_ data: Data) throws {
        guard (try? PropertyListSerialization.propertyList(from: data, format: nil)) is [String: Any] else {
            throw Failure.text("That is not a pairing file. It is a .plist made for this iPhone by iloader, SideStore or StikDebug's pairing tools.")
        }
        SecItemDelete(keychainItem as CFDictionary)
        var item = keychainItem
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw Failure.text("The pairing file could not be saved (Keychain error \(status)).")
        }
    }

    // MARK: Checks

    /// LocalDevVPN routes 10.7.0.1 to this iPhone's own lockdownd (port 62078). It does not work over cellular data.
    nonisolated static func tunnelIsUp(timeout: Int32 = 700) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(62078).bigEndian
        inet_pton(AF_INET, "10.7.0.1", &address.sin_addr)

        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var waiter = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&waiter, 1, timeout) == 1 else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
        return error == 0
    }

    static let tunnelHint = "LocalDevVPN is not connected. Open LocalDevVPN and connect (on Wi-Fi, or with no network; it does not work over cellular data), then try again."

    // MARK: Attaching

    /// Starts the helper, which attaches the debugger and stays until the app detaches it.
    /// `finished` is called once, with the helper's result, when it ends.
    static func attach(finished: @escaping (Result<String, Error>) -> Void) {
        guard let pairing = pairingFile() else {
            finished(.failure(Failure.text("Import this iPhone's pairing file first.")))
            return
        }
        let request: [String: Any] = ["action": "enable", "pid": getpid(), "pairing": pairing]
        HelperExtension.send(request, finished: finished)
    }
}

// MARK: - Starting the extension

/// The helper runs as an app extension. Apps start their own extensions with NSExtension, a
/// private class in ExtensionFoundation (LiveContainer and other sideloaded apps do the same).
@MainActor
private final class HelperExtension {
    private static var running: [HelperExtension] = []

    private let instance: NSObject
    private var finished: ((Result<String, Error>) -> Void)?

    private init(instance: NSObject, finished: @escaping (Result<String, Error>) -> Void) {
        self.instance = instance
        self.finished = finished
    }

    static func send(_ request: [String: Any], finished: @escaping (Result<String, Error>) -> Void) {
        do {
            let helper = HelperExtension(instance: try loadExtension(), finished: finished)
            running.append(helper)
            helper.begin(request)
        } catch {
            finished(.failure(error))
        }
    }

    private static func loadExtension() throws -> NSObject {
        guard let url = Bundle.main.builtInPlugInsURL?.appending(path: "rpcs3JITHelper.appex"),
              let identifier = Bundle(url: url)?.bundleIdentifier else {
            throw OnDeviceJIT.Failure.text("The JIT helper is missing from this build.")
        }
        if NSClassFromString("NSExtension") == nil {
            dlopen("/System/Library/Frameworks/ExtensionFoundation.framework/ExtensionFoundation", RTLD_NOW)
        }
        guard let type = NSClassFromString("NSExtension") as AnyObject? else {
            throw OnDeviceJIT.Failure.text("This iOS version does not let the app start its JIT helper.")
        }
        let factory = unsafeBitCast(type, to: ExtensionFactory.self)
        guard let instance = try factory.extension(withIdentifier: identifier) as? NSObject else {
            throw OnDeviceJIT.Failure.text("The JIT helper could not be loaded.")
        }
        return instance
    }

    private func begin(_ request: [String: Any]) {
        let calls = unsafeBitCast(instance, to: ExtensionCalls.self)

        calls.setRequestCompletionBlock { [weak self] _, items in
            let reply = (items?.first as? NSExtensionItem)?.userInfo?["rpcs3.jit.response"] as? [String: Any]
            let ok = reply?["ok"] as? Bool ?? false
            let message = reply?["message"] as? String ?? "The JIT helper ended without an answer."
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.end(ok ? .success(message) : .failure(OnDeviceJIT.Failure.text(message))) }
            }
        }
        calls.setRequestCancellationBlock { [weak self] _, error in
            let reason = error?.localizedDescription ?? "it was cancelled"
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.end(.failure(OnDeviceJIT.Failure.text("The JIT helper stopped: \(reason)"))) }
            }
        }
        calls.setRequestInterruptionBlock { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.end(.failure(OnDeviceJIT.Failure.text("The JIT helper quit unexpectedly."))) }
            }
        }

        let item = NSExtensionItem()
        item.userInfo = ["rpcs3.jit.request": request]
        calls.beginExtensionRequest(withInputItems: [item]) { [weak self] identifier in
            guard identifier == nil else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.end(.failure(OnDeviceJIT.Failure.text("The JIT helper did not start."))) }
            }
        }
    }

    private func end(_ result: Result<String, Error>) {
        guard let finished else { return }
        self.finished = nil
        Self.running.removeAll { $0 === self }
        finished(result)
    }
}

@objc private protocol ExtensionFactory {
    @objc(extensionWithIdentifier:error:)
    func `extension`(withIdentifier identifier: String) throws -> AnyObject
}

@objc private protocol ExtensionCalls {
    @objc(beginExtensionRequestWithInputItems:completion:)
    func beginExtensionRequest(withInputItems items: [Any], completion: @escaping (NSUUID?) -> Void)
    @objc(setRequestCompletionBlock:)
    func setRequestCompletionBlock(_ block: @escaping (NSUUID?, [Any]?) -> Void)
    @objc(setRequestCancellationBlock:)
    func setRequestCancellationBlock(_ block: @escaping (NSUUID?, NSError?) -> Void)
    @objc(setRequestInterruptionBlock:)
    func setRequestInterruptionBlock(_ block: @escaping (NSUUID?) -> Void)
}
