// RPCS3 JIT helper: an app extension the app starts to get JIT without a Mac.
//
// A process cannot debug itself, so this separate process attaches StikJIT's debugger to the app
// (through LocalDevVPN's tunnel and the iPhone's pairing file) and runs StikJIT's universal script,
// which answers the app's `brk #0xf00d` requests (rpcs3/JIT/JITPool.c) as scripts/jit_host.py does
// from a Mac. StikJIT is MPL-2.0, see third_party/StikJIT.

import Foundation
import StikJIT

/// Keys of the dictionaries exchanged with the app (rpcs3/JIT/OnDeviceJIT.swift).
enum HelperMessage {
    static let request = "rpcs3.jit.request"
    static let response = "rpcs3.jit.response"
    static let action = "action"        // "enable"
    static let pid = "pid"              // Int32, for "enable"
    static let pairing = "pairing"      // Data: the pairing file
    static let ok = "ok"                // Bool
    static let message = "message"      // String
}

private let workQueue = DispatchQueue(label: "rpcs3.jit-helper")

private func run(_ request: [String: Any]) -> (ok: Bool, message: String) {
    guard let pairing = request[HelperMessage.pairing] as? Data, !pairing.isEmpty else {
        return (false, "No pairing file was given to the JIT helper.")
    }

    let files = FileManager.default
    let root = files.urls(for: .libraryDirectory, in: .userDomainMask)[0].appending(path: "StikJIT", directoryHint: .isDirectory)
    let diskImage = DDIPaths.default(in: root)

    do {
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        // StikJIT reads the pairing file from a path; it exists only while this request runs.
        let pairingURL = root.appending(path: "pairing-\(UUID().uuidString).plist")
        try pairing.write(to: pairingURL, options: [.atomic, .completeFileProtection])
        defer { try? files.removeItem(at: pairingURL) }

        guard request[HelperMessage.action] as? String == "enable", let pid = request[HelperMessage.pid] as? Int32 else {
            return (false, "The JIT helper got an unknown request.")
        }
        // Mounts the Developer Disk Image first if needed (downloaded once), then attaches and runs
        // the script; returns when the script detaches, after the app has its JIT memory.
        try StikJIT.enableJIT(targetPID: pid, pairingFile: pairingURL, ddiPaths: diskImage,
                              script: .universal, forceScript: true,
                              preparationProgress: { NSLog("[rpcs3-jit] %@", String(describing: $0)) },
                              progress: { NSLog("[rpcs3-jit] %@", $0) })
        return (true, "The debugger detached.")
    } catch {
        return (false, error.localizedDescription)
    }
}

/// NSExtensionPrincipalClass. One request per extension process; it completes when the work is done,
/// so for "enable" the process lives as long as the debugger.
@objc(RPCS3JITHelper)
final class RPCS3JITHelper: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let request = (context.inputItems.first as? NSExtensionItem)?.userInfo?[HelperMessage.request] as? [String: Any]

        workQueue.async {
            let result: (ok: Bool, message: String) = request.map(run) ?? (false, "The JIT helper received no request.")
            let item = NSExtensionItem()
            item.userInfo = [HelperMessage.response: [HelperMessage.ok: result.ok, HelperMessage.message: result.message]]
            context.completeRequest(returningItems: [item], completionHandler: nil)
        }
    }
}
