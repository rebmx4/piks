import Foundation

extension MediaBridge {
    func probeSource(_ body: [String: Any]) {
        guard let id = body["id"] as? String, !id.isEmpty, id.count <= 512,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return }
        let generation = mediaAccess.generation, request = "probe-" + UUID().uuidString
        func report(_ fields: [String: Any]) {
            var event = fields; event["event"] = "media-diagnostic"
            event["req"] = request; event["phase"] = "source-decoder"
            send(event, generation: generation)
        }
        if let cached = sourceProbeResults[id] { report(cached); return }
        guard !sourceProbeRunning else { return }
        sourceProbeRunning = true
        resolveFile(id) { [weak self] file in
            guard let self = self else { return }
            guard let file = file else { self.sourceProbeRunning = false; return }
            self.sourceProbeQueue.async {
                let result = NativeSourceProbe.decode(file)
                DispatchQueue.main.async {
                    self.sourceProbeRunning = false
                    if self.sourceProbeResults.count >= 16 { self.sourceProbeResults.removeAll() }
                    self.sourceProbeResults[id] = result; report(result)
                }
            }
        }
    }
}
