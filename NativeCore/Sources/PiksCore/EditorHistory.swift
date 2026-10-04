import Foundation

public enum EditCommand {
    case split(UUID, at: Double), trim(UUID, from: Double, duration: Double), speed(UUID, Double)
    case delete(UUID), replace(Clip), reorder(UUID, before: UUID?), move(UUID, lane: Int, at: Double)
    case importMedia(MediaAsset, lane: Int, at: Double, duration: Double)
    case text(TextOverlay), deleteText(UUID), rename(String), canvas(Int, Int, Int)
}

public struct EditorHistory {
    public private(set) var project: Project
    private var previous: [Project] = []
    private var future: [Project] = []
    private var transaction: Project?
    private let limit: Int
    public init(project: Project, limit: Int = 60) { self.project = project; self.limit = max(1, limit) }
    public var canUndo: Bool { !previous.isEmpty }
    public var canRedo: Bool { !future.isEmpty }
    public mutating func beginTransaction() { if transaction == nil { transaction = project } }
    public mutating func endTransaction() {
        if let start = transaction, start != project { remember(start) }
        transaction = nil
    }
    public mutating func cancelTransaction() {
        if let start = transaction { restore(start) }
        transaction = nil
    }
    private mutating func remember(_ snapshot: Project) {
        previous.append(snapshot)
        if previous.count > limit { previous.removeFirst(previous.count - limit) }
    }
    private mutating func restore(_ snapshot: Project) {
        let revision = project.revision + 1
        project = snapshot; project.revision = revision; project.modified = Date()
    }
    public mutating func undo() {
        endTransaction()
        guard let old = previous.popLast() else { return }
        future.append(project); restore(old)
    }
    public mutating func redo() {
        guard let next = future.popLast() else { return }
        remember(project); restore(next)
    }
    public mutating func apply(_ command: EditCommand) throws {
        var next = project
        func index(_ id: UUID) throws -> Int {
            guard let i = next.clips.firstIndex(where: { $0.id == id }) else { throw EditorError.invalid("Клип не найден.") }
            return i
        }
        func retimeMain(after: Double, delta: Double, excluding: UUID) {
            for i in next.clips.indices where next.clips[i].lane == 0 && next.clips[i].id != excluding && next.clips[i].at >= after - 0.000001 {
                next.clips[i].at = max(0, next.clips[i].at + delta)
            }
        }
        switch command {
        case .split(let id, let at):
            let i = try index(id); let old = next.clips[i]; let local = at - old.at
            guard local.isFinite, local > 0.001, local < old.duration - 0.001 else { throw EditorError.invalid("Поставьте курсор внутри клипа.") }
            var first = old, second = old
            first.sliceAnimation(from: 0, duration: local)
            first.sourceDuration = local * old.speed
            second.id = UUID(); second.at = at; second.sourceStart += first.sourceDuration
            second.sourceDuration -= first.sourceDuration
            second.sliceAnimation(from: local, duration: old.duration - local)
            first.fadeOut = 0; second.fadeIn = 0; second.transitionIn = 0
            next.clips[i] = first; next.clips.insert(second, at: i + 1)
        case .trim(let id, let from, let duration):
            let i = try index(id); let old = next.clips[i]
            var c = old
            c.sliceAnimation(from: (from - old.sourceStart) / old.speed, duration: duration / old.speed)
            c.sourceStart = from; c.sourceDuration = duration
            next.clips[i] = c
            if old.lane == 0 { retimeMain(after: old.end, delta: c.duration - old.duration, excluding: id) }
        case .speed(let id, let value):
            let i = try index(id); let old = next.clips[i]
            guard value.isFinite, (0.05...20).contains(value) else { throw EditorError.invalid("Скорость должна быть от 0,05× до 20×.") }
            next.clips[i].speed = value
            next.clips[i].keyframes = old.keyframes.map { $0.at($0.time * old.speed / value) }
            if old.lane == 0 { retimeMain(after: old.end, delta: next.clips[i].duration - old.duration, excluding: id) }
        case .delete(let id):
            let i = try index(id); let old = next.clips.remove(at: i)
            if old.lane == 0 { retimeMain(after: old.end, delta: -old.duration, excluding: id) }
        case .replace(let clip):
            let i = try index(clip.id); let old = next.clips[i]; next.clips[i] = clip
            if old.lane == 0 { retimeMain(after: old.end, delta: clip.duration - old.duration, excluding: clip.id) }
        case .move(let id, let lane, let at):
            let i = try index(id); next.clips[i].lane = lane; next.clips[i].at = at
        case .reorder(let id, let before):
            let i = try index(id); let clip = next.clips[i]
            guard clip.lane == 0 else { throw EditorError.invalid("Перестановка доступна для основной дорожки.") }
            var ordered = next.clips.filter { $0.lane == 0 && $0.id != id }.sorted { $0.at < $1.at }
            if let before {
                guard let target = ordered.firstIndex(where: { $0.id == before }) else { throw EditorError.invalid("Целевой клип не найден.") }
                ordered.insert(clip, at: target)
            } else { ordered.append(clip) }
            var cursor = 0.0
            for var c in ordered {
                c.at = cursor; cursor += c.duration
                next.clips[try index(c.id)] = c
            }
        case .importMedia(let asset, let lane, let at, let duration):
            next.assets.append(asset)
            next.clips.append(Clip(assetID: asset.id, lane: lane, at: at, sourceDuration: duration))
            if next.clips.filter({ $0.lane >= 0 }).count == 1, asset.kind != .audio {
                next.width = max(16, min(8192, asset.width / 2 * 2))
                next.height = max(16, min(8192, asset.height / 2 * 2))
            }
        case .text(let text):
            if let i = next.texts.firstIndex(where: { $0.id == text.id }) { next.texts[i] = text }
            else { next.texts.append(text) }
        case .deleteText(let id): next.texts.removeAll { $0.id == id }
        case .rename(let name): next.name = name
        case .canvas(let width, let height, let fps): next.width = width; next.height = height; next.fps = fps
        }
        try next.validate()
        if next == project { return }
        if transaction == nil { remember(project) }
        future.removeAll(); next.revision = project.revision + 1; next.modified = Date(); project = next
    }
}
