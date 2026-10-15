import Foundation
import AVFoundation
import CoreImage

// Export-only presentation. The web preset supplies the values once; legacy
// plans omit this object and keep their original timing and composition.
struct ExportPresentation {
    let rate: Double
    let foregroundScale: CGFloat
    let backgroundGain: CGFloat

    init?(json: [String: Any]) {
        guard let rate = (json["rate"] as? NSNumber)?.doubleValue,
              let scale = (json["foregroundScale"] as? NSNumber)?.doubleValue,
              let gain = (json["backgroundGain"] as? NSNumber)?.doubleValue,
              rate.isFinite, (0.25...8).contains(rate),
              scale.isFinite, scale > 0, scale <= 1,
              gain.isFinite, (0...1).contains(gain) else { return nil }
        self.rate = rate
        foregroundScale = CGFloat(scale)
        backgroundGain = CGFloat(gain)
    }

    func outputTime(_ source: CMTime) -> CMTime {
        // A frame-count time may have timescale 25/30. Keep sub-frame precision
        // for the shared audio/video clock instead of rounding to those ticks.
        CMTime(seconds: CMTimeGetSeconds(source) / rate, preferredTimescale: 60000)
    }

    // Reuse the final composed frame, including captions, without another
    // source file, decoder, timeline layer or audio track.
    func frame(_ image: CIImage, in bounds: CGRect) -> CIImage {
        let g = backgroundGain
        let background = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: g, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: g, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        let scale = foregroundScale
        let transform = CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: bounds.midX * (1 - scale),
                                            y: bounds.midY * (1 - scale)))
        return image.transformed(by: transform).composited(over: background).cropped(to: bounds)
    }
}
