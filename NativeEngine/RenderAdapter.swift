import Foundation
import AVFoundation
import UIKit
import PiksCore

enum RenderAdapter {
    /// This dictionary is an internal Swift boundary for the existing AV compositor,
    /// not a JavaScript bridge. Both preview and export consume the same typed model.
    static func plan(_ model: NativeRenderPlan, save: Bool = false, codec: String = "hevc") throws -> ExportPlan {
        let media = model.assets.map { ["id": $0.id.uuidString, "url": "piks-media://local/\($0.id.uuidString).\($0.fileExtension)"] }
        let layers: [[String: Any]] = model.layers.map { layer in
            ["items": layer.map { item -> [String: Any] in
                let e = item.effects
                var ci: [[String: Any]] = []
                if e.brightness != 0 || e.contrast != 1 || e.saturation != 1 {
                    ci.append(["name": "CIColorControls", "params": ["inputBrightness": e.brightness,
                               "inputContrast": e.contrast, "inputSaturation": e.saturation]])
                }
                if e.temperature != 0 {
                    ci.append(["name": "CITemperatureAndTint", "params": ["inputNeutral": [6500.0, 0.0],
                               "inputTargetNeutral": [6500.0 + e.temperature * 2500, 0.0]]])
                }
                if e.blur > 0 { ci.append(["name": "CIGaussianBlur", "params": ["inputRadius": e.blur * 30]]) }
                return ["media": item.assetID.uuidString, "at": item.at, "from": item.from,
                        "dur": item.duration, "src": item.sourceDuration,
                        "k0": Int((item.at * Double(model.fps)).rounded()), "frames": item.transforms,
                        "crop": [item.crop.x, item.crop.y, item.crop.width, item.crop.height], "ci": ci,
                        "fx": ["lut": -1, "sharpen": e.sharpen, "vignette": e.vignette, "grain": e.grain]]
            }]
        }
        let sounds: [[String: Any]] = model.sounds.map { sound in
            ["media": sound.assetID.uuidString, "at": sound.at, "from": sound.from,
             "dur": sound.duration, "src": sound.sourceDuration, "volume": sound.volume,
             "keys": sound.gains.map { ["at": $0.time, "g": $0.gain] },
             "ear": sound.channel == "left" ? "L" : sound.channel == "right" ? "R" : ""]
        }
        let images: [[String: Any]] = try model.texts.map { text in
            let rendered = try TextRasterizer.render(text, width: model.width, height: model.height)
            return ["png": rendered.png.base64EncodedString(), "at": text.at, "dur": text.duration,
                    "rect": [rendered.rect.minX, rendered.rect.minY, rendered.rect.width, rendered.rect.height]]
        }
        let bitrate = max(4_000_000, min(80_000_000, model.width * model.height * model.fps / 6))
        guard let plan = ExportPlan(json: ["width": model.width, "height": model.height, "fps": model.fps,
                                           "frames": model.frames, "bitrate": bitrate, "codec": codec,
                                           "media": media, "layers": layers, "sounds": sounds,
                                           "images": images, "save": save]) else {
            throw EditorError.invalid("Не удалось собрать план экспорта.")
        }
        return plan
    }
    static func files(_ model: NativeRenderPlan, repository: ProjectRepository, usage: ProjectRepository.Usage) throws -> [String: URL] {
        try Dictionary(uniqueKeysWithValues: model.assets.map {
            ($0.id.uuidString, try repository.resolve(project: model.projectID, asset: $0, usage: usage))
        })
    }
}

enum TextRasterizer {
    struct Rendered { let png: Data; let rect: CGRect }
    static func render(_ text: TextOverlay, width: Int, height: Int) throws -> Rendered {
        let font = UIFont.systemFont(ofSize: CGFloat(text.fontSize * Double(min(width, height))), weight: .semibold)
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        let hex = UInt32(text.colorHex, radix: 16) ?? 0xFFFFFF
        let color = UIColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                            blue: CGFloat(hex & 255) / 255, alpha: 1)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        let content = NSAttributedString(string: text.text, attributes: attrs)
        let limit = CGSize(width: Double(width) * 0.9, height: Double(height) * 0.9)
        let measured = content.boundingRect(with: limit, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let pad = CGFloat(min(width, height)) * 0.018
        let size = CGSize(width: min(limit.width, ceil(measured.width) + 2 * pad), height: min(limit.height, ceil(measured.height) + 2 * pad))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            if text.background {
                UIColor.black.withAlphaComponent(0.65).setFill()
                UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: pad).fill()
            }
            content.draw(with: CGRect(x: pad, y: pad, width: size.width - 2 * pad, height: size.height - 2 * pad),
                         options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }
        guard let png = image.pngData() else { throw EditorError.invalid("Надпись не отрисовалась.") }
        return Rendered(png: png, rect: CGRect(x: Double(width) * text.x - size.width / 2,
                                               y: Double(height) * text.y - size.height / 2,
                                               width: size.width, height: size.height))
    }
}
