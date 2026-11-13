import Foundation

struct ExportPhotoRequest {
    let token: String
    let id: String

    init?(_ body: [String: Any]) {
        guard let token = body["token"] as? String, !token.isEmpty, token.count <= 48,
              token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              let id = body["id"] as? String, id == "uexport_" + token else { return nil }
        self.token = token; self.id = id
    }

    static func allows(_ origin: URL?, mainFrame: Bool) -> Bool {
        EditorTrustPolicy.allows(origin, mainFrame: mainFrame)
    }
}

// Source compatibility for existing callers/tests; no second Photos ledger.
typealias ExportPhotoSave = ExportOperationStore
