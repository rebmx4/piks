import Foundation
import AVFoundation
import CoreVideo

// A small compatibility measurement, not a render benchmark. It reads the
// original asset locally and returns only numeric/codec metadata, never media.
enum NativeSourceProbe {
    static func decode(_ file: URL) -> [String: Any] {
        let began = Date(), expected = 3
        var result: [String: Any] = ["frames": 0, "expected": expected, "decoded": false]
        do {
            let asset = AVURLAsset(url: file)
            guard let track = asset.tracks(withMediaType: .video).first else {
                throw NSError(domain: "apiks.source", code: 1)
            }
            result["width"] = Int(abs(track.naturalSize.width)); result["height"] = Int(abs(track.naturalSize.height))
            if let first = track.formatDescriptions.first {
                let format = first as! CMFormatDescription
                let value = CMFormatDescriptionGetMediaSubType(format)
                let bytes = [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]
                result["codec"] = String(bytes: bytes, encoding: .ascii) ?? "unknown"
                if let atoms = CMFormatDescriptionGetExtension(format,
                    extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
                   let avc = atoms["avcC"] as? Data, avc.count >= 4 {
                    result["codec"] = String(format: "avc1.%02x%02x%02x", avc[1], avc[2], avc[3])
                }
            }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw NSError(domain: "apiks.source", code: 2) }
            reader.add(output)
            let watchdog = DispatchWorkItem { reader.cancelReading() }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8, execute: watchdog)
            defer { watchdog.cancel(); reader.cancelReading() }
            guard reader.startReading() else { throw reader.error ?? NSError(domain: "apiks.source", code: 3) }
            var frames = 0
            while frames < expected, let sample = output.copyNextSampleBuffer() {
                guard CMSampleBufferGetImageBuffer(sample) != nil else { break }
                frames += 1
            }
            result["frames"] = frames
            if frames == expected || (frames > 0 && reader.status == .completed) { result["decoded"] = true }
            else { throw reader.error ?? NSError(domain: "apiks.source", code: 4) }
        } catch {
            let error = error as NSError
            result["code"] = error.code
            result["domain"] = String(error.domain.prefix(80).filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") })
        }
        result["ms"] = Int(Date().timeIntervalSince(began) * 1000)
        return result
    }
}
