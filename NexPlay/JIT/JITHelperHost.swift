import Foundation

// 6.3.0: starts NexPlay's JIT helper (PlugIns/NexPlayJITHelper.appex) with the private NSExtension API
// (ExtensionFoundation), the calls LiveContainer uses for its LiveProcess. The helper is found by the bundle ID it
// has in this installation, so a signing app that renames NexPlay's IDs still finds it.
// One extension request per NexJITRequest: JSON in the input item's userInfo, JSON back in the returned item.
// Adapted from BCD's JITBuiltInHost.swift (GPL-3.0-or-later, Madeira Converter Exception).
// Includes work from BCD by thebcd69 (https://github.com/thebcd69/bcd-games).

@objc private protocol NexExtensionClassShim {
    @objc(extensionWithIdentifier:error:)
    func `extension`(withIdentifier identifier: String) throws -> AnyObject
}

@objc private protocol NexExtensionShim {
    @objc(beginExtensionRequestWithInputItems:completion:)
    func beginExtensionRequest(withInputItems items: [Any], completion: @escaping (NSUUID?) -> Void)
    @objc(pidForRequestIdentifier:)
    func pid(forRequestIdentifier identifier: NSUUID) -> Int32
    @objc(setRequestCompletionBlock:)
    func setRequestCompletionBlock(_ block: @escaping (NSUUID?, [Any]?) -> Void)
    @objc(setRequestCancellationBlock:)
    func setRequestCancellationBlock(_ block: @escaping (NSUUID?, NSError?) -> Void)
    @objc(setRequestInterruptionBlock:)
    func setRequestInterruptionBlock(_ block: @escaping (NSUUID?) -> Void)
}

enum JITHelperHost {
    static let helperFile = "NexPlayJITHelper.appex"

    /// Requests that started and haven't finished, kept alive until they do. Main thread only.
    fileprivate static var running: [JITHelperRequest] = []

    /// The helper's bundle ID in this installation; nil when the signing app left the extension out.
    static var helperIdentifier: String? {
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent(helperFile) else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }

    /// Why built-in JIT can't run here, or nil.
    static var unavailableReason: String? {
        guard #available(iOS 17.4, *) else { return "Built-in JIT needs iOS 17.4 or later." }
        if getenv("LC_HOME_PATH") != nil {
            return "Built-in JIT can't run inside LiveContainer. Use StikDebug instead."
        }
        if helperIdentifier == nil {
            return "This copy of NexPlay has no JIT helper. Install it again and keep its app extensions when signing."
        }
        return nil
    }

    /// Call on the main thread. `started` and `completion` run on the main thread; `completion` runs once.
    static func send(_ request: NexJITRequest,
                     started: @escaping () -> Void = {},
                     completion: @escaping (Result<NexJITRequest.Response, Error>) -> Void) {
        func fail(_ code: Int, _ message: String) {
            AppLog.log("jit: helper: \(message)")
            completion(.failure(NSError(domain: "NexPlayJIT", code: code,
                                        userInfo: [NSLocalizedDescriptionKey: message])))
        }
        if let reason = unavailableReason {
            fail(1, reason)
            return
        }
        guard let identifier = helperIdentifier else {
            fail(2, "This copy of NexPlay has no JIT helper.")
            return
        }
        if NSClassFromString("NSExtension") == nil {
            dlopen("/System/Library/Frameworks/ExtensionFoundation.framework/ExtensionFoundation", RTLD_NOW)
        }
        guard let extensionClass = NSClassFromString("NSExtension") else {
            fail(3, "The JIT helper can't start: iOS is missing the extension API it relies on.")
            return
        }
        let factory = unsafeBitCast(extensionClass as AnyObject, to: NexExtensionClassShim.self)
        let found: AnyObject
        do {
            found = try factory.extension(withIdentifier: identifier)
        } catch {
            fail(2, "iOS couldn't find NexPlay's JIT helper (\(identifier)): \(error.localizedDescription) Install NexPlay again.")
            return
        }
        guard let data = try? JSONEncoder().encode(request) else {
            fail(4, "NexPlay couldn't package the request for its JIT helper.")
            return
        }
        let helper = JITHelperRequest(extension: found, operation: request.operation.rawValue, completion: completion)
        running.append(helper)
        helper.begin(data: data, identifier: identifier, started: started)
    }

    fileprivate static func finished(_ helper: JITHelperRequest) {
        running.removeAll { $0 === helper }
    }
}

/// One request to the helper, from its start to its one result. Everything runs on the main thread.
private final class JITHelperRequest {
    private let shim: NexExtensionShim
    private let found: AnyObject   // the NSExtension, kept alive for the request
    private let operation: String
    private var completion: ((Result<NexJITRequest.Response, Error>) -> Void)?

    init(extension found: AnyObject, operation: String,
         completion: @escaping (Result<NexJITRequest.Response, Error>) -> Void) {
        self.found = found
        self.shim = unsafeBitCast(found, to: NexExtensionShim.self)
        self.operation = operation
        self.completion = completion
    }

    func begin(data: Data, identifier: String, started: @escaping () -> Void) {
        shim.setRequestCompletionBlock { [weak self] _, items in
            let info = (items?.first as? NSExtensionItem)?.userInfo
            let payload = info?[NexJITRequest.Response.itemKey] as? Data
            DispatchQueue.main.async { self?.returned(payload) }
        }
        shim.setRequestCancellationBlock { [weak self] _, error in
            let message = error?.localizedDescription ?? "no reason given"
            DispatchQueue.main.async {
                self?.end(.failure(JITHelperRequest.error(5, "The JIT helper's request was canceled: \(message)")))
            }
        }
        shim.setRequestInterruptionBlock { [weak self] _ in
            DispatchQueue.main.async {
                self?.end(.failure(JITHelperRequest.error(6, "The JIT helper quit without warning. Try again.")))
            }
        }
        let item = NSExtensionItem()
        item.userInfo = [NexJITRequest.itemKey: data]
        shim.beginExtensionRequest(withInputItems: [item]) { [weak self] uuid in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let uuid else {
                    self.end(.failure(JITHelperRequest.error(7, "The JIT helper couldn't be started. Install NexPlay again and keep its app extensions when signing.")))
                    return
                }
                AppLog.log("jit: helper \(self.operation): started \(identifier) as pid \(self.shim.pid(forRequestIdentifier: uuid))")
                started()
            }
        }
    }

    private func returned(_ payload: Data?) {
        guard let payload, let response = try? JSONDecoder().decode(NexJITRequest.Response.self, from: payload) else {
            end(.failure(JITHelperRequest.error(8, "The JIT helper ended without sending a result.")))
            return
        }
        end(.success(response))
    }

    private func end(_ result: Result<NexJITRequest.Response, Error>) {
        guard let completion else { return }   // the first result counts
        self.completion = nil
        if case .failure(let failure) = result {
            AppLog.log("jit: helper \(operation): \(failure.localizedDescription)")
        }
        JITHelperHost.finished(self)
        completion(result)
    }

    private static func error(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "NexPlayJIT", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
