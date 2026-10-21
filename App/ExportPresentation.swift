import Foundation
import AVFoundation
import CoreImage

// Export-only presentation. The web preset supplies the values once; legacy
// plans omit this object and keep their original timing and composition.
struct ExportPresentation {
    let rate: Double
    let foregroundScale: CGFloat
    let backgroundGain: CGFloat
    let isVariant: Bool
    let brightness: CGFloat
    let contrast: CGFloat
    let saturation: CGFloat

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
        if let version = json["variantVersion"] {
            guard (version as? Int) == 1,
                  (0.97...0.99).contains(rate), (0.95...0.98).contains(scale), gain == 0,
                  let brightness = (json["brightness"] as? NSNumber)?.doubleValue,
                  let contrast = (json["contrast"] as? NSNumber)?.doubleValue,
                  let saturation = (json["saturation"] as? NSNumber)?.doubleValue,
                  brightness.isFinite, (-0.015...0.015).contains(brightness),
                  contrast.isFinite, (0.96...1.04).contains(contrast),
                  saturation.isFinite, (0.97...1.03).contains(saturation) else { return nil }
            isVariant = true
            self.brightness = CGFloat(brightness)
            self.contrast = CGFloat(contrast)
            self.saturation = CGFloat(saturation)
        } else {
            isVariant = false
            brightness = 0; contrast = 1; saturation = 1
        }
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
        let foreground = isVariant ? image.applyingFilter("CIColorControls", parameters: [
            kCIInputBrightnessKey: brightness, kCIInputContrastKey: contrast, kCIInputSaturationKey: saturation,
        ]) : image
        return foreground.transformed(by: transform).composited(over: background).cropped(to: bounds)
    }
}
