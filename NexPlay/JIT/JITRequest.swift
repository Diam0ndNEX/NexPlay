import Foundation

// 6.3.0: messages between NexPlay and its JIT helper extension (NexPlayJITHelper.appex). Each travels as JSON in an
// extension request's item (userInfo[itemKey]), to the helper and back. Compiled into both targets.
// Adapted from BCD's JITBuiltInMessages.swift (GPL-3.0-or-later, Madeira Converter Exception).
// Includes work from BCD by thebcd69 (https://github.com/thebcd69/bcd-games).

struct NexJITRequest: Codable {
    static let itemKey = "nexplay-jit-request"

    enum Operation: String, Codable {
        case prepare
        case enable
        case resetDDI
    }

    let operation: Operation
    let targetPID: Int32?
    let pairingData: Data?
    let scriptBase64: String?

    static func prepare(pairingData: Data) -> NexJITRequest {
        NexJITRequest(operation: .prepare, targetPID: nil, pairingData: pairingData, scriptBase64: nil)
    }

    static func enable(targetPID: Int32, pairingData: Data, scriptBase64: String) -> NexJITRequest {
        NexJITRequest(operation: .enable, targetPID: targetPID, pairingData: pairingData, scriptBase64: scriptBase64)
    }

    static var resetDDI: NexJITRequest {
        NexJITRequest(operation: .resetDDI, targetPID: nil, pairingData: nil, scriptBase64: nil)
    }

    struct Response: Codable {
        static let itemKey = "nexplay-jit-response"
        let success: Bool
        let message: String
        let txmPresent: Bool?
    }
}
