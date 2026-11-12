import Foundation
import StikJIT

// 6.3.0: NexPlay's JIT helper, a classic app extension that NexPlay starts by its bundle ID (JITHelperHost.swift).
// One NexJITRequest per extension request, answered when the request completes. Enable completes only when
// NexPlay's JIT script has detached, so this process lives as long as the debugger does.
// Adapted from BCD's MadeiraJITHelper.swift (GPL-3.0-or-later, Madeira Converter Exception).
// Includes work from BCD by thebcd69 (https://github.com/thebcd69/bcd-games).
// Uses StikJIT, https://github.com/StikDebug/StikJIT (MPL-2.0), with idevice (MIT).

private enum HelperWork {
    /// One request at a time: StikJIT's calls are blocking and must not overlap.
    static let queue = DispatchQueue(label: "com.nexplay.jit-helper")

    static func handle(_ request: NexJITRequest) -> NexJITRequest.Response {
        let manager = FileManager.default
        let root = manager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StikJIT", isDirectory: true)
        let paths = DDIPaths.default(in: root)

        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            if request.operation == .resetDDI {
                try StikJIT.resetCachedDDI(at: paths)
                return .init(success: true,
                             message: "The cached Developer Disk Image was cleared.",
                             txmPresent: StikJIT.isTXMPresent)
            }

            guard let pairingData = request.pairingData, !pairingData.isEmpty else {
                throw NSError(domain: "NexPlayJITHelper", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "No pairing file came with the request."])
            }
            let pairingURL = root.appendingPathComponent("pairingFile-\(UUID().uuidString).plist")
            try pairingData.write(to: pairingURL, options: .atomic)
            defer { try? manager.removeItem(at: pairingURL) }

            switch request.operation {
            case .prepare:
                let readiness = StikJIT.prepareDevice(
                    pairingFile: pairingURL, paths: paths,
                    progress: { NSLog("[NexPlayJIT] prepare: %@", String(describing: $0)) })
                switch readiness {
                case .ready(let security):
                    return .init(success: true,
                                 message: "All set: this iPhone answers through LocalDevVPN and the Developer Disk Image is ready.",
                                 txmPresent: security.isTXMPresent)
                case .unreachable(let reason), .preparationFailed(let reason):
                    return .init(success: false, message: reason, txmPresent: StikJIT.isTXMPresent)
                @unknown default:
                    return .init(success: false,
                                 message: "StikJIT reported a state NexPlay doesn't know.",
                                 txmPresent: StikJIT.isTXMPresent)
                }
            case .enable:
                guard let targetPID = request.targetPID,
                      let scriptBase64 = request.scriptBase64, !scriptBase64.isEmpty else {
                    throw NSError(domain: "NexPlayJITHelper", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "The request has no process or JIT script."])
                }
                try StikJIT.enableJIT(
                    targetPID: targetPID,
                    pairingFile: pairingURL,
                    ddiPaths: paths,
                    script: .customBase64(scriptBase64),
                    forceScript: true,
                    preparationProgress: { NSLog("[NexPlayJIT] prepare: %@", String(describing: $0)) },
                    progress: { NSLog("[NexPlayJIT] %@", $0) })
                return .init(success: true,
                             message: "The JIT script detached from NexPlay.",
                             txmPresent: StikJIT.isTXMPresent)
            case .resetDDI:
                return .init(success: true, message: "", txmPresent: nil)
            }
        } catch {
            return .init(success: false, message: error.localizedDescription, txmPresent: StikJIT.isTXMPresent)
        }
    }
}

/// NSExtensionPrincipalClass (Info.plist). The request arrives as JSON in the first input item; the response goes
/// back as JSON in the item the request completes with.
@objc(NexPlayJITHelperHandler)
final class NexPlayJITHelperHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let info = (context.inputItems.first as? NSExtensionItem)?.userInfo
        let data = info?[NexJITRequest.itemKey] as? Data
        HelperWork.queue.async {
            let response: NexJITRequest.Response
            if let data, let request = try? JSONDecoder().decode(NexJITRequest.self, from: data) {
                response = HelperWork.handle(request)
            } else {
                response = .init(success: false, message: "The JIT helper got no request from NexPlay.", txmPresent: nil)
            }
            let item = NSExtensionItem()
            item.userInfo = [NexJITRequest.Response.itemKey: (try? JSONEncoder().encode(response)) ?? Data()]
            context.completeRequest(returningItems: [item], completionHandler: nil)
        }
    }
}
