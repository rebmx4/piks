import Foundation
import Photos
import AVFoundation

extension MediaBridge {
    @discardableResult
    func videoFile(_ asset: PHAsset, progress: ((Double) -> Void)? = nil,
                   done: @escaping (URL?) -> Void) -> (() -> Void) {
        return videoRequests.request(asset.localIdentifier, timeout: 600, progress: progress, start: { [weak self] report, finish in
            guard let self = self else { finish(nil); return {} }
            self.mediaSequence += 1
            let req = "file-\(self.mediaSequence)", started = Date()
            self.send(["event": "media-diagnostic", "req": req, "phase": "photos-start"])
            var requestID = PHInvalidImageRequestID
            var cancelled = false
            func request(_ version: PHVideoRequestOptionsVersion) {
                let options = PHVideoRequestOptions()
                options.isNetworkAccessAllowed = true
                options.deliveryMode = .highQualityFormat
                options.version = version
                options.progressHandler = { value, _, _, _ in report(value) }
                requestID = PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                    DispatchQueue.main.async {
                        guard !cancelled else { return }
                        if let file = avAsset as? AVURLAsset, FileManager.default.isReadableFile(atPath: file.url.path) {
                            self.send(["event": "media-diagnostic", "req": req, "phase": "photos-ready",
                                       "ms": Int(Date().timeIntervalSince(started) * 1000)])
                            finish(file.url)
                        } else if version == .current {
                            request(.original)
                        } else {
                            var fields: [String: Any] = ["event": "media-diagnostic", "req": req, "phase": "photos-error"]
                            if let error = info?[PHImageErrorKey] as? NSError {
                                fields["domain"] = String(error.domain.prefix(128))
                                fields["code"] = error.code
                            }
                            self.send(fields)
                            finish(nil)
                        }
                    }
                }
            }
            request(.current)
            return {
                cancelled = true
                PHImageManager.default().cancelImageRequest(requestID)
                self.send(["event": "media-diagnostic", "req": req, "phase": "photos-cancel",
                           "ms": Int(Date().timeIntervalSince(started) * 1000)])
            }
        }, done: done)
    }
}
