import Foundation

public struct GainPoint: Equatable, Sendable {
    public let time: Double
    public let gain: Double
    public init(time: Double, gain: Double) { self.time = time; self.gain = gain }
}

/// Evaluate only the requested animation sample, regardless of project length.
public struct RenderMotion: Sendable {
    public let clip: Clip
    public let asset: MediaAsset
    public let width: Int
    public let height: Int
    public func matrix(at time: Double) -> [Double] {
        RenderPlanBuilder.matrix(clip: clip, asset: asset, time: max(0, min(clip.duration, time)), width: width, height: height)
    }
}

public struct RenderItem: Sendable {
    public let clipID: UUID
    public let assetID: UUID
    public let at: Double
    public let from: Double
    public let duration: Double
    public let sourceDuration: Double
    public let transforms: [[Double]]
    public let motion: RenderMotion?
    public let crop: UnitRect
    public let effects: ClipEffects
    public func matrix(at time: Double) -> [Double] { motion?.matrix(at: time) ?? transforms[0] }
}

public struct RenderSound: Sendable {
    public let assetID: UUID
    public let at: Double
    public let from: Double
    public let duration: Double
    public let sourceDuration: Double
    public let volume: Double
    public let channel: String
    public let gains: [GainPoint]
}

public struct NativeRenderPlan: Sendable {
    public let projectID: UUID
    public let revision: Int
    public let width: Int
    public let height: Int
    public let fps: Int
    public let frames: Int
    public let assets: [MediaAsset]
    public let layers: [[RenderItem]]
    public let sounds: [RenderSound]
    public let texts: [TextOverlay]
}

public enum RenderPlanBuilder {
    public enum Mode { case preview, export }
    public static func build(_ project: Project, mode: Mode) throws -> NativeRenderPlan {
        try project.validate()
        guard project.duration > 0, project.duration <= 24 * 3600 else { throw EditorError.invalid("Проект должен содержать клипы и быть короче суток.") }
        let ratio = mode == .preview ? min(1, 1080.0 / Double(min(project.width, project.height))) : 1
        let width = max(16, Int(Double(project.width) * ratio) / 2 * 2)
        let height = max(16, Int(Double(project.height) * ratio) / 2 * 2)
        let assets = Dictionary(uniqueKeysWithValues: project.assets.map { ($0.id, $0) })
        var visual: [Int: [RenderItem]] = [:]
        var sounds: [RenderSound] = []
        var used = Set<UUID>()
        for clip in project.clips.sorted(by: { $0.at < $1.at }) {
            guard let asset = assets[clip.assetID] else { continue }
            used.insert(asset.id)
            if asset.kind != .audio && clip.lane >= 0 {
                let animated = !clip.keyframes.isEmpty || clip.transitionIn > 0
                let rows = [matrix(clip: clip, asset: asset, time: 0, width: width, height: height)]
                let motion = animated ? RenderMotion(clip: clip, asset: asset, width: width, height: height) : nil
                visual[clip.lane, default: []].append(RenderItem(clipID: clip.id, assetID: asset.id,
                    at: clip.at, from: clip.sourceStart, duration: clip.duration, sourceDuration: clip.sourceDuration,
                    transforms: rows, motion: motion, crop: clip.crop, effects: clip.effects))
            }
            if (asset.hasAudio || asset.kind == .audio) && !clip.muted {
                let sum = clip.fadeIn + clip.fadeOut
                let factor = sum > clip.duration ? clip.duration / sum : 1
                let start = clip.fadeIn * factor, end = clip.fadeOut * factor
                var gains: [GainPoint] = []
                if start > 0 || end > 0 {
                    gains.append(GainPoint(time: clip.at, gain: start > 0 ? 0 : clip.volume))
                    if start > 0 { gains.append(GainPoint(time: clip.at + start, gain: clip.volume)) }
                    if clip.duration - end > start + 0.000001 {
                        gains.append(GainPoint(time: clip.end - end, gain: clip.volume))
                    }
                    if end > 0 { gains.append(GainPoint(time: clip.end, gain: 0)) }
                }
                sounds.append(RenderSound(assetID: asset.id, at: clip.at, from: clip.sourceStart,
                    duration: clip.duration, sourceDuration: clip.sourceDuration,
                    volume: clip.volume, channel: clip.channel, gains: gains))
            }
        }
        return NativeRenderPlan(projectID: project.id, revision: project.revision,
            width: width, height: height, fps: project.fps, frames: Int(ceil(project.duration * Double(project.fps))),
            assets: project.assets.filter { used.contains($0.id) },
            layers: visual.keys.sorted().map { visual[$0]! }, sounds: sounds, texts: project.texts)
    }
    public static func matrix(clip: Clip, asset: MediaAsset, time: Double, width: Int, height: Int) -> [Double] {
        let k = clip.transform(at: time)
        let fit = min(Double(width) / Double(asset.width), Double(height) / Double(asset.height)) * k.scale
        let w = Double(asset.width) * fit, h = Double(asset.height) * fit
        let angle = k.rotation * .pi / 180, c = cos(angle), s = sin(angle)
        let a = w * c, b = w * s, cc = -h * s, d = h * c
        let x = Double(width) * (0.5 + k.x), y = Double(height) * (0.5 + k.y)
        let fade = clip.transitionIn > 0 ? min(1, max(0, time / clip.transitionIn)) : 1
        return [a, b, cc, d, x - (a + cc) / 2, y - (b + d) / 2, k.opacity * fade]
    }
}
