import UIKit
import ObjectiveC.runtime

// 8.20.6: the Files picker's "Open" button did nothing. Found in BCD's ExternalGamesPicker.swift (GPL-3.0,
// "Includes work from BCD by thebcd69 (https://github.com/thebcd69/bcd-games)"): when the app is signed with a
// provisioning profile whose App ID differs from Info.plist's CFBundleIdentifier (the signing tool keeps the
// bundle id, the certificate says something else), the picker asks fileproviderd for access in the name of the
// bundle id, fileproviderd refuses, the picked item is dropped and the delegate is never called (Cancel still
// works). The fix: tell the picker's DOCConfiguration the real signed App ID. Nothing is copied or changed
// otherwise. Active for every document picker of the app (games, folders, saves, mods, covers, pairing file,
// Ren'Py saves...), installed once at launch, and only on an install that really has the mismatch. No App ID
// value is written to the log.

/// The decision, kept apart from UIKit.
struct NexPickerIdentity: Equatable {
    /// The signed App ID without its team prefix equals CFBundleIdentifier: nothing to repair.
    let matches: Bool
    /// The signed App ID is a wildcard ("TEAM.*").
    let wildcard: Bool
    /// The host identifier to give the picker, or nil to leave it alone.
    let targetHostID: String?

    static func decide(entitlementAppID: String?, bundleID: String) -> NexPickerIdentity {
        guard let raw = entitlementAppID, !raw.isEmpty else {
            return NexPickerIdentity(matches: true, wildcard: false, targetHostID: nil)
        }
        let stripped = strip(raw)
        let wildcard = stripped.hasSuffix("*")
        let matches = stripped == bundleID
        let target = (!wildcard && !matches && !bundleID.isEmpty && !stripped.isEmpty) ? stripped : nil
        return NexPickerIdentity(matches: matches, wildcard: wildcard, targetHostID: target)
    }

    static func strip(_ appID: String) -> String {
        guard let dot = appID.firstIndex(of: ".") else { return appID }
        return String(appID[appID.index(after: dot)...])
    }
}

final class NexPickerFix: @unchecked Sendable {
    static let shared = NexPickerFix()

    private let lock = NSLock()
    private var installed = false
    private let bundleID: String
    private let identity: NexPickerIdentity

    private init() {
        bundleID = Bundle.main.bundleIdentifier ?? ""
        identity = NexPickerIdentity.decide(entitlementAppID: NexPickerFix.signedAppID(), bundleID: bundleID)
    }

    /// For Diagnostics and the log: booleans only.
    var summary: String {
        "appid-match=\(identity.matches ? 1 : 0) wildcard=\(identity.wildcard ? 1 : 0) fix=\(identity.targetHostID != nil ? 1 : 0)"
    }

    /// Installs the repair when this install needs it. Safe to call again and from any place before a picker opens.
    static func installIfNeeded() { shared.install() }

    private func install() {
        guard let target = identity.targetHostID else { return }
        lock.lock(); defer { lock.unlock() }
        guard !installed else { return }
        installed = true
        swizzleSetHostIdentifier(target: target)
        swizzlePickerViewWillAppear(target: target)
        AppLog.log("picker: the signed App ID differs from the bundle id; Files pickers use the signed id (\(summary))")
    }

    /// `-[DOCConfiguration setHostIdentifier:]`: the auto-assigned bundle id is replaced by the signed App ID.
    /// Any other value is left as it is.
    private func swizzleSetHostIdentifier(target: String) {
        guard let cls = NSClassFromString("DOCConfiguration") else { return }
        let sel = NSSelectorFromString("setHostIdentifier:")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, NSString?) -> Void
        let orig = unsafeBitCast(method_getImplementation(method), to: Fn.self)
        let bundleID = self.bundleID
        let block: @convention(block) (AnyObject, NSString?) -> Void = { obj, hostID in
            let incoming = hostID as String?
            if incoming == nil || incoming == bundleID {
                orig(obj, sel, target as NSString)
            } else {
                orig(obj, sel, hostID)
            }
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    /// Belt and braces: set the picker configuration's host identifier just before the picker appears.
    private func swizzlePickerViewWillAppear(target: String) {
        let sel = #selector(UIViewController.viewWillAppear(_:))
        guard let method = class_getInstanceMethod(UIDocumentPickerViewController.self, sel) else { return }
        typealias Fn = @convention(c) (UIDocumentPickerViewController, Selector, Bool) -> Void
        let orig = unsafeBitCast(method_getImplementation(method), to: Fn.self)
        let block: @convention(block) (UIDocumentPickerViewController, Bool) -> Void = { picker, animated in
            if let config = NexPickerFix.configuration(of: picker),
               config.responds(to: NSSelectorFromString("setHostIdentifier:")) {
                config.setValue(target, forKey: "hostIdentifier")
            }
            orig(picker, sel, animated)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func configuration(of picker: UIDocumentPickerViewController) -> NSObject? {
        let object = picker as NSObject
        if object.responds(to: NSSelectorFromString("configuration")),
           let config = object.value(forKey: "configuration") as? NSObject {
            return config
        }
        if class_getInstanceVariable(type(of: object), "_configuration") != nil,
           let config = object.value(forKey: "_configuration") as? NSObject {
            return config
        }
        return nil
    }

    /// The process's `application-identifier` entitlement (reuses Diagnostics.swift's SecTask declarations).
    private static func signedAppID() -> String? {
        guard let task = nexSecTaskCreateFromSelf(nil),
              let value = nexSecTaskCopyValueForEntitlement(task, "application-identifier" as NSString, nil) as? String,
              !value.isEmpty else { return nil }
        return value
    }
}
