import Foundation

public enum EditorError: Error, LocalizedError, Equatable {
    case invalid(String), missingOriginal, missingProject, staleRevision, unsupportedSchema
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .missingOriginal: return "Оригинал недоступен. Импортируйте исходный файл заново."
        case .missingProject: return "Проект не найден на этом устройстве."
        case .staleRevision: return "Сохранение устаревшей версии проекта отклонено."
        case .unsupportedSchema: return "Эта версия проекта не поддерживается приложением."
        }
    }
}

public struct MediaAsset: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case video, image, audio }
    public var id: UUID
    public var kind: Kind
    public var originalName: String
    public var duration: Double
    /// Display dimensions after applying the source's preferred transform.
    public var width: Int
    public var height: Int
    public var hasAudio: Bool
    public var frameRate: Double
    public init(id: UUID = UUID(), kind: Kind, originalName: String, duration: Double,
                width: Int, height: Int, hasAudio: Bool = false, frameRate: Double = 30) {
        self.id = id; self.kind = kind; self.originalName = originalName
        self.duration = duration; self.width = width; self.height = height
        self.hasAudio = hasAudio; self.frameRate = frameRate
    }
    public var fileExtension: String {
        let ext = (originalName as NSString).pathExtension.lowercased()
        let allowed = ["mov", "mp4", "m4v", "jpg", "jpeg", "png", "heic", "heif", "wav", "m4a", "mp3", "aac", "caf"]
        return allowed.contains(ext) ? ext : (kind == .image ? "png" : kind == .audio ? "m4a" : "mov")
    }
}

public struct TransformKeyframe: Codable, Equatable, Sendable {
    public var time: Double
    /// Center offset in fractions of canvas size, scale relative to aspect-fit.
    public var x: Double
    public var y: Double
    public var scale: Double
    public var rotation: Double
    public var opacity: Double
    public init(time: Double, x: Double = 0, y: Double = 0, scale: Double = 1,
                rotation: Double = 0, opacity: Double = 1) {
        self.time = time; self.x = x; self.y = y; self.scale = scale
        self.rotation = rotation; self.opacity = opacity
    }
    public func at(_ newTime: Double) -> Self { var copy = self; copy.time = newTime; return copy }
    public static func interpolate(_ a: Self, _ b: Self, time: Double) -> Self {
        let t = min(1, max(0, (time - a.time) / max(0.000001, b.time - a.time)))
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        return Self(time: time, x: mix(a.x, b.x), y: mix(a.y, b.y), scale: mix(a.scale, b.scale),
                    rotation: mix(a.rotation, b.rotation), opacity: mix(a.opacity, b.opacity))
    }
}

public struct ClipEffects: Codable, Equatable, Sendable {
    public var brightness: Double = 0
    public var contrast: Double = 1
    public var saturation: Double = 1
    public var temperature: Double = 0
    public var sharpen: Double = 0
    public var vignette: Double = 0
    public var grain: Double = 0
    public var blur: Double = 0
    public var retouch: Double = 0
    public var removeBackground: Bool = false
    public var lutName: String? = nil
    public init() {}
}

public struct UnitRect: Codable, Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct Clip: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var assetID: UUID
    public var lane: Int
    public var at: Double
    public var sourceStart: Double
    public var sourceDuration: Double
    public var speed: Double = 1
    public var volume: Double = 1
    public var fadeIn: Double = 0
    public var fadeOut: Double = 0
    public var transitionIn: Double = 0
    public var channel: String = "stereo"
    public var muted: Bool = false
    public var crop = UnitRect()
    public var baseTransform = TransformKeyframe(time: 0)
    public var keyframes: [TransformKeyframe] = []
    public var effects = ClipEffects()
    public init(id: UUID = UUID(), assetID: UUID, lane: Int = 0, at: Double = 0,
                sourceStart: Double = 0, sourceDuration: Double) {
        self.id = id; self.assetID = assetID; self.lane = lane; self.at = at
        self.sourceStart = sourceStart; self.sourceDuration = sourceDuration
    }
    public var duration: Double { sourceDuration / speed }
    public var end: Double { at + duration }
    public func transform(at time: Double) -> TransformKeyframe {
        guard let first = keyframes.first, let last = keyframes.last else { return baseTransform.at(time) }
        if time <= first.time { return first.at(time) }
        if time >= last.time { return last.at(time) }
        for (a, b) in zip(keyframes, keyframes.dropFirst()) where time <= b.time {
            return TransformKeyframe.interpolate(a, b, time: time)
        }
        return last.at(time)
    }
    public mutating func sliceAnimation(from: Double, duration: Double) {
        guard !keyframes.isEmpty else { return }
        let first = transform(at: from).at(0)
        let last = transform(at: from + duration).at(duration)
        keyframes = [first] + keyframes.filter { $0.time > from && $0.time < from + duration }
            .map { $0.at($0.time - from) } + [last]
    }
}

public struct TextOverlay: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var text: String
    public var at: Double
    public var duration: Double
    public var x: Double = 0.5
    public var y: Double = 0.72
    public var fontSize: Double = 0.055
    public var colorHex: String = "FFFFFF"
    public var background: Bool = true
    public init(text: String, at: Double, duration: Double) {
        self.text = text; self.at = at; self.duration = duration
    }
}

public struct Project: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchema = 1
    public var schema = currentSchema
    public var id: UUID
    public var name: String
    public var revision: Int = 0
    public var created = Date()
    public var modified = Date()
    public var width: Int = 1080
    public var height: Int = 1920
    public var fps: Int = 30
    public var assets: [MediaAsset]
    public var clips: [Clip]
    public var texts: [TextOverlay] = []
    public init(id: UUID = UUID(), name: String, assets: [MediaAsset] = [], clips: [Clip] = []) {
        self.id = id; self.name = name; self.assets = assets; self.clips = clips
        if let first = assets.first(where: { $0.kind != .audio }) {
            width = first.width / 2 * 2; height = first.height / 2 * 2
        }
    }
    public var duration: Double { max(clips.map(\.end).max() ?? 0, texts.map { $0.at + $0.duration }.max() ?? 0) }
    public func validate() throws {
        guard schema == Self.currentSchema else { throw EditorError.unsupportedSchema }
        guard revision >= 0, (16...8192).contains(width), (16...8192).contains(height),
              width % 2 == 0, height % 2 == 0, (1...60).contains(fps), name.count <= 200 else {
            throw EditorError.invalid("Некорректные настройки проекта.")
        }
        guard Set(assets.map(\.id)).count == assets.count, Set(clips.map(\.id)).count == clips.count,
              Set(texts.map(\.id)).count == texts.count else { throw EditorError.invalid("Повторяющиеся идентификаторы.") }
        let map = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        for a in assets {
            guard a.duration.isFinite, a.duration >= 0, a.frameRate.isFinite,
                  a.kind == .audio || (a.width > 0 && a.height > 0) else { throw EditorError.invalid("Некорректные параметры исходника.") }
        }
        for c in clips {
            guard let a = map[c.assetID] else { throw EditorError.invalid("Клип ссылается на неизвестный исходник.") }
            let values = [c.at, c.sourceStart, c.sourceDuration, c.speed, c.volume, c.fadeIn, c.fadeOut,
                          c.transitionIn, c.crop.x, c.crop.y, c.crop.width, c.crop.height]
            guard values.allSatisfy(\.isFinite), c.at >= 0, c.sourceStart >= 0,
                  c.sourceDuration > 0.00001, (0.05...20).contains(c.speed), (0...8).contains(c.volume),
                  (-4...8).contains(c.lane), c.fadeIn >= 0, c.fadeOut >= 0, c.transitionIn >= 0,
                  c.crop.x >= 0, c.crop.y >= 0, c.crop.width > 0, c.crop.height > 0,
                  c.crop.x + c.crop.width <= 1.000001, c.crop.y + c.crop.height <= 1.000001,
                  a.kind == .image || c.sourceStart + c.sourceDuration <= a.duration + 0.002 else {
                throw EditorError.invalid("Обрезка или скорость выходит за допустимые границы.")
            }
            var prior = -Double.infinity
            for k in [c.baseTransform] + c.keyframes {
                guard [k.time, k.x, k.y, k.scale, k.rotation, k.opacity].allSatisfy(\.isFinite),
                      k.time >= 0, k.time <= c.duration + 0.002, k.scale > 0, (0...1).contains(k.opacity) else {
                    throw EditorError.invalid("Некорректный ключевой кадр.")
                }
            }
            for k in c.keyframes {
                guard k.time > prior else { throw EditorError.invalid("Ключевые кадры должны идти по времени.") }
                prior = k.time
            }
            let e = c.effects
            guard [e.brightness, e.contrast, e.saturation, e.temperature, e.sharpen, e.vignette,
                   e.grain, e.blur, e.retouch].allSatisfy(\.isFinite) else { throw EditorError.invalid("Некорректный эффект.") }
        }
        for t in texts {
            guard [t.at, t.duration, t.x, t.y, t.fontSize].allSatisfy(\.isFinite), t.at >= 0,
                  t.duration > 0, t.fontSize > 0, t.text.count <= 4000 else { throw EditorError.invalid("Некорректная надпись.") }
        }
    }
}
